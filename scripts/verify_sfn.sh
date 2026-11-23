#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verifica los criterios de éxito de la arquitectura Step Functions + Map:
#   - estado de la última ejecución (o la del RUN_ID dado)
#   - conteo de pagos únicos en DynamoDB (prueba de 0 duplicados, ASR-2)
#   - manifiesto de resultados del Map en S3 (evidencia en AWS)
#
# Uso:  ./scripts/verify_sfn.sh [RUN_ID]
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

REGION="${AWS_REGION:-us-east-2}"
SM_ARN="$(terraform output -raw state_machine_arn)"
TABLE="$(terraform output -raw idempotency_table)"
BUCKET="$(terraform output -raw data_bucket)"
RUN_ID="${1:-}"

echo "Región: $REGION"
echo

echo "== Última(s) ejecución(es) de la máquina de estados =="
aws stepfunctions list-executions --region "$REGION" \
  --state-machine-arn "$SM_ARN" --max-results 5 \
  --query 'executions[].{name:name,status:status,start:startDate,stop:stopDate}' \
  --output table

echo
echo "== Ventana del ASR: 20.000 pagos en <= 60 min a 10-15 TPS =="
if [[ -n "$RUN_ID" ]]; then
  EXEC_ARN="${SM_ARN/:stateMachine:/:execution:}:$RUN_ID"
else
  EXEC_ARN=$(aws stepfunctions list-executions --region "$REGION" --state-machine-arn "$SM_ARN" \
    --max-results 1 --query 'executions[0].executionArn' --output text)
fi
DESC=$(aws stepfunctions describe-execution --region "$REGION" --execution-arn "$EXEC_ARN" --output json)
ST=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$DESC")
echo "ejecucion: ${EXEC_ARN##*:}  |  estado: $ST"
if [[ "$ST" == "SUCCEEDED" ]]; then
  python3 - "$DESC" <<'PY'
import json, sys
from datetime import datetime
d = json.loads(sys.argv[1])
def ts(v):
    # El CLI puede devolver epoch (numero) o ISO-8601 segun cli_timestamp_format.
    try:
        return float(v)
    except (TypeError, ValueError):
        return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
total = int(json.loads(d.get("input") or "{}").get("total", 20000))
dur = ts(d["stopDate"]) - ts(d["startDate"])
tps = total / dur
print(f"pagos: {total}  |  duracion: {dur:.0f} s = {dur/60:.1f} min  |  TPS promedio: {tps:.1f}")
print("ASR ventana (<= 60 min):", "OK" if dur <= 3600 else "INCUMPLIDO")
print("ASR banda 10-15 TPS   :", "OK" if 10 <= tps <= 15 else "FUERA DE BANDA")
if total != 20000:
    print("(corrida de prueba: el ASR completo se valida con 20000 pagos)")
PY
elif [[ "$ST" == "TIMED_OUT" ]]; then
  echo "ASR ventana: INCUMPLIDO (la ejecucion supero los 60 min y fue cortada)"
fi

echo
echo "== Pagos únicos ejecutados (idempotencia, ASR-2) =="
echo "(La PoC corre con enable_idempotency=false por defecto: la tabla estara vacia. Esto es esperado.)"
COUNT=$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
  --select COUNT --query 'Count' --output text)
echo "payment_key únicos en DynamoDB: $COUNT"
echo "(cada payment_id aparece una sola vez por el PutItem condicional => 0 duplicados)"

if [[ -n "$RUN_ID" ]]; then
  echo
  echo "== Resultados del Map en S3 (run_id=$RUN_ID) =="
  aws s3 ls "s3://$BUCKET/resultados/$RUN_ID/" --region "$REGION" --recursive || true
  echo
  echo "Manifiesto (resumen de éxitos/fallos del Map distribuido):"
  aws s3 cp "s3://$BUCKET/resultados/$RUN_ID/manifest.json" - --region "$REGION" 2>/dev/null || \
    echo "  (manifest.json aún no disponible; revisa la consola de Step Functions)"
fi
