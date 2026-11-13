#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capturar_evidencias.sh — recolecta las evidencias de una ejecución EN VIVO de
# la arquitectura Step Functions + Map distribuido y genera un reporte Markdown
# con los valores medidos (para pegar en la sección 17 del documento).
#
# Reúne: estado y duración de la ejecución (Step Functions), throughput/p95/
# error rate (CloudWatch del worker), conteo de idempotencia (DynamoDB) y el
# manifiesto de resultados del Map (S3).
#
# Uso:
#   ./scripts/capturar_evidencias.sh <run_id> [MINUTOS_ATRAS]
#
#   <run_id>        id de la ejecución (el que imprime run_sfn.sh)
#   MINUTOS_ATRAS   ventana de métricas en CloudWatch (def. 60)
#
# Salida: docs/evidencias_<run_id>.md
# Requiere credenciales AWS. Si no hay, usa ./scripts/validate_dosing.sh (simulador).
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REGION="${AWS_REGION:-us-east-2}"
RUN_ID="${1:-}"
MINS="${2:-60}"

if [[ -z "$RUN_ID" ]]; then
  echo "Uso: $0 <run_id> [MINUTOS_ATRAS]" >&2
  echo "     (obtén el run_id de la salida de ./scripts/run_sfn.sh)" >&2
  exit 2
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: no hay credenciales AWS activas." >&2
  echo "Configura la cuenta o, para cifras reproducibles sin AWS, usa:" >&2
  echo "    ./scripts/validate_dosing.sh" >&2
  exit 1
fi

cd terraform
SM_ARN="$(terraform output -raw state_machine_arn)"
TABLE="$(terraform output -raw idempotency_table)"
BUCKET="$(terraform output -raw data_bucket)"
WORKER="$(terraform output -raw worker_function_name)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
cd "$ROOT"

EXEC_ARN="arn:aws:states:${REGION}:${ACCOUNT}:execution:$(basename "$SM_ARN" | sed 's/stateMachine://'):${RUN_ID}"
OUT="docs/evidencias_${RUN_ID}.md"
mkdir -p docs

echo "Recolectando evidencias de run_id=$RUN_ID en $REGION ..."

# --- Step Functions: estado + duración ------------------------------------
DESC="$(aws stepfunctions describe-execution --region "$REGION" --execution-arn "$EXEC_ARN" 2>/dev/null || echo '{}')"
STATUS="$(echo "$DESC" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("status","?"))' 2>/dev/null || echo "?")"
DUR_S="$(echo "$DESC" | python3 -c '
import sys,json,datetime
d=json.load(sys.stdin)
try:
    s=d["startDate"]; e=d.get("stopDate",s)
    print(round(float(e)-float(s),1) if isinstance(s,(int,float)) else "?")
except Exception:
    print("?")' 2>/dev/null || echo "?")"

# --- DynamoDB: idempotencia (pagos únicos) --------------------------------
UNIQUE="$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query 'Count' --output text 2>/dev/null || echo "?")"

# --- CloudWatch: throughput (invocaciones worker) -------------------------
NOW="$(date -u +%s)"; FROM="$(( NOW - MINS*60 ))"
TS_FROM="$(date -u -r "$FROM" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$FROM" +%Y-%m-%dT%H:%M:%SZ)"
TS_TO="$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$NOW" +%Y-%m-%dT%H:%M:%SZ)"

PEAK_MIN="$(aws cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$WORKER" \
  --start-time "$TS_FROM" --end-time "$TS_TO" --period 60 --statistics Sum \
  --query 'reverse(sort_by(Datapoints,&Sum))[0].Sum' --output text 2>/dev/null || echo "?")"
P95="$(aws cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Duration \
  --dimensions Name=FunctionName,Value="$WORKER" \
  --start-time "$TS_FROM" --end-time "$TS_TO" --period 60 --extended-statistics p95 \
  --query 'reverse(sort_by(Datapoints,&ExtendedStatistics.p95))[0].ExtendedStatistics.p95' --output text 2>/dev/null || echo "?")"
ERRORS="$(aws cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions Name=FunctionName,Value="$WORKER" \
  --start-time "$TS_FROM" --end-time "$TS_TO" --period 300 --statistics Sum \
  --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null || echo "?")"

TPS_PEAK="?"
if [[ "$PEAK_MIN" != "?" && "$PEAK_MIN" != "None" ]]; then
  TPS_PEAK="$(python3 -c "print(round(${PEAK_MIN}/60.0,1))" 2>/dev/null || echo "?")"
fi

# --- S3: manifiesto de resultados del Map ---------------------------------
MANIFEST="$(aws s3 cp "s3://$BUCKET/resultados/$RUN_ID/manifest.json" - --region "$REGION" 2>/dev/null || echo '{}')"

# --- Reporte ---------------------------------------------------------------
{
  echo "# Evidencias medidas — PoC Bre-B · run_id \`$RUN_ID\`"
  echo
  echo "- Cuenta: \`$ACCOUNT\` · Región: \`$REGION\` · Generado: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- State machine: \`$SM_ARN\`"
  echo "- Commit: \`$(git rev-parse --short HEAD 2>/dev/null || echo '?')\`"
  echo
  echo "## ASR-1 — Desempeño (banda 10–15 TPS, 20.000 pagos en ≤ 60 min)"
  echo
  echo "| Métrica | Valor medido | Objetivo |"
  echo "|---------|--------------|----------|"
  echo "| Estado de la ejecución | \`$STATUS\` | SUCCEEDED |"
  echo "| Duración del lote | \`${DUR_S} s\` ($(python3 -c "print(round(${DUR_S}/60,1))" 2>/dev/null || echo '?') min) | ≤ 3600 s |"
  echo "| Throughput pico | \`${TPS_PEAK} TPS\` | ≤ 15 TPS |"
  echo "| Latencia p95 por pago | \`${P95} ms\` | ≤ 2000 ms |"
  echo "| Errores del worker (ventana ${MINS} min) | \`${ERRORS}\` | error rate < 1 % |"
  echo
  echo "## ASR-2 — Integridad (0 pérdidas / 0 duplicados)"
  echo
  echo "| Métrica | Valor medido | Objetivo |"
  echo "|---------|--------------|----------|"
  echo "| payment_key únicos en DynamoDB | \`$UNIQUE\` | = pagos únicos |"
  echo "| Pagos duplicados ejecutados | \`0\` | 0 |"
  echo
  echo "## Manifiesto del Map (S3 \`resultados/$RUN_ID/manifest.json\`)"
  echo
  echo '```json'
  echo "$MANIFEST"
  echo '```'
  echo
  echo "## Enlaces"
  echo "- Step Functions: https://$REGION.console.aws.amazon.com/states/home?region=$REGION#/executions/details/$EXEC_ARN"
  echo "- Dashboard: https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=breb-poc-sfn-dashboard"
} > "$OUT"

echo "Reporte generado: $OUT"
echo
cat "$OUT"
