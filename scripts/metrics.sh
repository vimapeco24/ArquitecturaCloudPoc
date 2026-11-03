#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# metrics.sh — calcula e imprime las métricas de desempeño de la PoC (ASR-1)
# a partir de CloudWatch, para evidenciar throughput y latencia p95 como NÚMEROS.
#
# Uso:  ./scripts/metrics.sh [MINUTOS_ATRAS]      (def. 15)
#
# Métricas (Lambda consumer breb-poc-consumer):
#   * Invocations (Sum)           -> throughput (mensajes/min y TPS)
#   * Duration p95 (ms)           -> latencia p95 por mensaje (ASR-1: <= 2 s)
#   * Errors (Sum)                -> error rate
#   * ConcurrentExecutions (Max)  -> dosificado del Queue-Based Load Leveling
# ---------------------------------------------------------------------------
set -euo pipefail

MINUTES="${1:-15}"
REGION="${AWS_REGION:-us-east-2}"
FN="breb-poc-consumer"

# Rango de tiempo (UTC) compatible con GNU y BSD date.
if date -u -d "@0" >/dev/null 2>&1; then
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -d "-${MINUTES} min" +%Y-%m-%dT%H:%M:%SZ)
else
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START=$(date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)
fi

echo "=============================================="
echo " Métricas PoC Bre-B (ASR-1) · función $FN"
echo " Ventana: últimos $MINUTES min · región $REGION"
echo " $START  ->  $END"
echo "=============================================="

get() { # $1=MetricName $2=Stat  -> imprime el valor agregado del periodo
  aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/Lambda --metric-name "$1" \
    --dimensions Name=FunctionName,Value="$FN" \
    --start-time "$START" --end-time "$END" \
    --period "$(( MINUTES * 60 ))" \
    --statistics "$2" ${3:-} \
    --query "Datapoints[0].${2}" --output text 2>/dev/null
}

INVOCATIONS=$(get Invocations Sum); INVOCATIONS=${INVOCATIONS//None/0}
ERRORS=$(get Errors Sum); ERRORS=${ERRORS//None/0}
# p95 requiere ExtendedStatistics
P95=$(aws cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value="$FN" \
  --start-time "$START" --end-time "$END" --period "$(( MINUTES * 60 ))" \
  --extended-statistics p95 \
  --query 'Datapoints[0].ExtendedStatistics.p95' --output text 2>/dev/null)
P95=${P95//None/0}
CONC=$(get ConcurrentExecutions Maximum); CONC=${CONC//None/n/d}

# Derivados
python3 - "$INVOCATIONS" "$ERRORS" "$P95" "$MINUTES" <<'PY'
import sys
inv=float(sys.argv[1] or 0); err=float(sys.argv[2] or 0)
p95=float(sys.argv[3] or 0); mins=float(sys.argv[4] or 1)
secs=mins*60
tps = inv/secs if secs else 0
errrate = (err/inv*100) if inv else 0
print()
print(f"  Invocaciones totales   : {int(inv)}")
print(f"  Throughput promedio    : {tps:.2f} TPS   (objetivo ASR-1: >= 10 TPS)")
print(f"  Latencia p95 / mensaje : {p95:.0f} ms = {p95/1000:.2f} s   (objetivo ASR-1: <= 2 s)")
print(f"  Errores Lambda         : {int(err)}")
print(f"  Error rate             : {errrate:.2f} %   (objetivo: < 1 %)")
def ok(c): return "OK" if c else "REVISAR"
print()
print(f"  ASR-1 throughput  : {ok(tps>=10)}")
print(f"  ASR-1 latencia p95: {ok(0<p95<=2000)}")
print(f"  Error rate        : {ok(errrate<1)}")
PY

echo "  Concurrencia máx.      : $CONC   (dosificado Queue-Based Load Leveling)"
echo
echo "Nota: el throughput pico durante el drenado suele superar el promedio;"
echo "para el valor sostenido real, mira el dashboard breb-poc-dashboard."
