#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Dispara la máquina de estados (arquitectura Step Functions + Map distribuido)
# y espera a que termine. Genera el dataset del día y procesa los pagos en
# paralelo contra el core, dosificado por MaxConcurrency + token bucket
# (ASR: banda 10–15 TPS para proteger al core).
#
# Uso:
#   ./scripts/run_sfn.sh [TOTAL] [DUPLICATE_EVERY]
#
#   TOTAL            nº de pagos a procesar (default 20000, el volumen del ASR)
#   DUPLICATE_EVERY  si >0, 1 de cada N pagos reutiliza un payment_id previo
#                    (duplicado intencional para evidenciar idempotencia ASR-2)
#
# Ejemplos:
#   ./scripts/run_sfn.sh                # 20.000 pagos, sin duplicados
#   ./scripts/run_sfn.sh 2000           # prueba rápida de 2.000
#   ./scripts/run_sfn.sh 20000 50       # 20.000 con 1 de cada 50 duplicado
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

REGION="${AWS_REGION:-us-east-2}"
TOTAL="${1:-20000}"
DUP="${2:-0}"

SM_ARN="$(terraform output -raw state_machine_arn)"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"

echo "Región:          $REGION"
echo "State machine:   $SM_ARN"
echo "run_id:          $RUN_ID"
echo "total pagos:     $TOTAL"
echo "duplicate_every: $DUP"
echo

INPUT=$(printf '{"total":%s,"run_id":"%s","duplicate_every":%s}' "$TOTAL" "$RUN_ID" "$DUP")

EXEC_ARN=$(aws stepfunctions start-execution \
  --region "$REGION" \
  --state-machine-arn "$SM_ARN" \
  --name "$RUN_ID" \
  --input "$INPUT" \
  --query 'executionArn' --output text)

echo "Ejecución iniciada:"
echo "  $EXEC_ARN"
echo
echo "Esperando a que termine (poll cada 10 s)..."

START=$(date +%s)
while true; do
  STATUS=$(aws stepfunctions describe-execution \
    --region "$REGION" --execution-arn "$EXEC_ARN" \
    --query 'status' --output text)
  ELAPSED=$(( $(date +%s) - START ))
  printf "  [%4ss] estado: %s\n" "$ELAPSED" "$STATUS"
  case "$STATUS" in
    SUCCEEDED) echo; echo "✅ Lote COMPLETADO en ${ELAPSED}s."; break ;;
    FAILED|TIMED_OUT|ABORTED) echo; echo "❌ Ejecución terminó en estado $STATUS."; break ;;
  esac
  sleep 10
done

echo
echo "Evidencia en AWS:"
echo "  - Consola Step Functions (historia + mapa de ejecución):"
echo "    $(terraform output -raw state_machine_console_url)"
echo "  - Resultados del Map en S3:"
echo "    s3://$(terraform output -raw data_bucket)/resultados/$RUN_ID/"
echo "  - Dashboard CloudWatch:"
echo "    https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=breb-poc-sfn-dashboard"
echo
echo "Para verificar idempotencia y conteos:  ./scripts/verify_sfn.sh $RUN_ID"
