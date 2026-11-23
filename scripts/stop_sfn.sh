#!/usr/bin/env bash
# Detiene todas las ejecuciones RUNNING de la maquina de estados de la PoC.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"
REGION="${AWS_REGION:-us-east-2}"
SM_ARN="$(terraform output -raw state_machine_arn)"
for a in $(aws stepfunctions list-executions --region "$REGION" --state-machine-arn "$SM_ARN" \
  --status-filter RUNNING --query 'executions[].executionArn' --output text); do
  echo "Deteniendo $a"
  aws stepfunctions stop-execution --region "$REGION" --execution-arn "$a" >/dev/null
done
echo "Listo. En ejecucion ahora:"
aws stepfunctions list-executions --region "$REGION" --state-machine-arn "$SM_ARN" \
  --status-filter RUNNING --query 'executions[].name' --output text
