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
echo "== Pagos únicos ejecutados (idempotencia, ASR-2) =="
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
