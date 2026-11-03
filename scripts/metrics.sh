#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# metrics.sh — métricas de desempeño de la PoC (ASR-1) desde CloudWatch.
#
# Mide el THROUGHPUT en MENSAJES/segundo (no invocaciones): cada invocación del
# consumer procesa un lote de hasta BATCH mensajes, por lo que
#   mensajes/min = invocaciones/min * mensajes_por_invocacion
# y el TPS se calcula sobre el MINUTO PICO (sostenido), no sobre una ventana fija
# en la que la carga solo estuvo activa unos segundos (eso diluía el promedio).
#
# Uso:  ./scripts/metrics.sh [MINUTOS_ATRAS]      (def. 20)
#
# Métricas (Lambda consumer breb-poc-consumer, periodo 60 s):
#   * Invocations (Sum/min)       -> throughput pico (invocaciones y mensajes)
#   * Duration p95 / p50 (ms)     -> latencia por invocación de lote (ASR-1)
#   * Errors (Sum)                -> error rate
#   * ConcurrentExecutions (Max)  -> dosificado del Queue-Based Load Leveling
# ---------------------------------------------------------------------------
set -euo pipefail

MINUTES="${1:-20}"
REGION="${AWS_REGION:-us-east-2}"
FN="breb-poc-consumer"

# mensajes por invocación = batch_size del event source mapping (def. 10).
BATCH="${BATCH_SIZE:-10}"

# Rango de medición: por defecto 20 min hacia atrás, pero acotado a los últimos
# minutos de actividad real. Todas las llamadas a CloudWatch llevan timeout para
# que el script no se quede colgado si la API tarda.
AWS="aws --cli-read-timeout 15 --cli-connect-timeout 5"

if date -u -d "@0" >/dev/null 2>&1; then
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -d "-${MINUTES} min" +%Y-%m-%dT%H:%M:%SZ)
else
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)
fi

echo "=============================================="
echo " Métricas PoC Bre-B (ASR-1) · función $FN"
echo " Ventana: últimos $MINUTES min · región $REGION · lote=$BATCH msg/invocación"
echo " $START  ->  $END"
echo "=============================================="

# Serie por minuto de invocaciones (para hallar el minuto pico sostenido).
INV_SERIES=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period 60 --statistics Sum \
  --query 'Datapoints[].Sum' --output text 2>/dev/null)

ERRORS=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES*60 ))" --statistics Sum \
  --query 'Datapoints[0].Sum' --output text 2>/dev/null); ERRORS=${ERRORS//None/0}

INV_TOTAL=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES*60 ))" --statistics Sum \
  --query 'Datapoints[0].Sum' --output text 2>/dev/null); INV_TOTAL=${INV_TOTAL//None/0}

P95=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES*60 ))" \
  --extended-statistics p95 \
  --query 'Datapoints[0].ExtendedStatistics.p95' --output text 2>/dev/null); P95=${P95//None/0}
P50=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES*60 ))" \
  --extended-statistics p50 \
  --query 'Datapoints[0].ExtendedStatistics.p50' --output text 2>/dev/null); P50=${P50//None/0}

CONC=$($AWS cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name ConcurrentExecutions \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES*60 ))" --statistics Maximum \
  --query 'Datapoints[0].Maximum' --output text 2>/dev/null); CONC=${CONC//None/n/d}

python3 - "$INV_SERIES" "$INV_TOTAL" "$ERRORS" "$P95" "$P50" "$BATCH" <<'PY'
import sys
series=[float(x) for x in sys.argv[1].split()] if sys.argv[1].strip() else []
inv_total=float(sys.argv[2] or 0); err=float(sys.argv[3] or 0)
p95=float(sys.argv[4] or 0); p50=float(sys.argv[5] or 0); batch=float(sys.argv[6] or 1)

peak_inv_min = max(series) if series else 0.0      # invocaciones en el minuto pico
# throughput en mensajes/segundo durante el minuto pico sostenido
tps_msgs = (peak_inv_min * batch) / 60.0
tps_inv  = peak_inv_min / 60.0
msgs_total = inv_total * batch
errrate = (err/inv_total*100) if inv_total else 0.0

print()
print(f"  Invocaciones (total)       : {int(inv_total)}")
print(f"  Mensajes procesados (aprox): {int(msgs_total)}  (= invocaciones x lote {int(batch)})")
print(f"  Invocaciones minuto pico   : {int(peak_inv_min)} /min")
print()
print(f"  THROUGHPUT PICO            : {tps_msgs:.1f} mensajes/s (TPS)   (objetivo ASR-1: >= 10 TPS)")
print(f"     (equivale a {tps_inv:.1f} invocaciones/s x lote {int(batch)})")
print(f"  Latencia por lote  p50     : {p50:.0f} ms = {p50/1000:.2f} s")
print(f"  Latencia por lote  p95     : {p95:.0f} ms = {p95/1000:.2f} s")
print(f"  Latencia p95 / MENSAJE     : {p95/batch:.0f} ms = {p95/batch/1000:.2f} s   (objetivo ASR-1: <= 2 s)")
print(f"  Errores Lambda             : {int(err)}")
print(f"  Error rate                 : {errrate:.2f} %   (objetivo: < 1 %)")

def ok(c): return "OK" if c else "REVISAR"
print()
print(f"  ASR-1 throughput (TPS)       : {ok(tps_msgs>=10)}")
print(f"  ASR-1 latencia p95/mensaje   : {ok(0<(p95/batch)<=2000)}")
print(f"  Error rate                   : {ok(errrate<1)}")
PY

echo "  Concurrencia máx.          : $CONC   (dosificado Queue-Based Load Leveling)"
echo
echo "Notas:"
echo " - El TPS se mide como MENSAJES/s en el minuto pico (cada invocación procesa un lote)."
echo " - La latencia 'por lote' es la Duration de la Lambda (procesa ~$BATCH mensajes);"
echo "   la latencia por mensaje individual es mucho menor (Duration/lote)."
echo " - Para el valor sostenido y la curva completa, mira el dashboard breb-poc-dashboard."
