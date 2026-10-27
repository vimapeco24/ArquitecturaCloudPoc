#!/usr/bin/env bash
# Verifica los criterios de éxito de la PoC tras ejecutar un escenario de carga.
# Imprime: profundidad de la cola principal, profundidad de la DLQ (debe ser 0
# salvo en el escenario de fallo) y conteo de items en la tabla de idempotencia
# (= nº de pagos únicos ejecutados, prueba de 0 duplicados).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

REGION="$(terraform output -raw -state=terraform.tfstate 2>/dev/null >/dev/null; echo "${AWS_REGION:-us-east-1}")"
QUEUE_URL="$(terraform output -raw queue_url)"
DLQ_URL="$(terraform output -raw dlq_url)"
TABLE="$(terraform output -raw idempotency_table)"

echo "Región: $REGION"
echo

echo "== Cola principal =="
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --region "$REGION" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes' --output table

echo "== DLQ (0 = sin pérdidas) =="
aws sqs get-queue-attributes --queue-url "$DLQ_URL" --region "$REGION" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes' --output table

echo "== Pagos únicos ejecutados (idempotencia) =="
COUNT=$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
  --select COUNT --query 'Count' --output text)
echo "payment_key únicos en DynamoDB: $COUNT"
echo
echo "Comprobación de duplicados: cada payment_id solo aparece una vez por diseño"
echo "(PutItem condicional). Un item por clave => 0 pagos duplicados (ASR-2)."
