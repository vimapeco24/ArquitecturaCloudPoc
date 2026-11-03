#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_experiment.sh — Orquesta un escenario completo de la PoC de un tirón:
#   1) purga cola + DLQ (parte de cero)
#   2) inyecta la carga (load/load_cli.sh)
#   3) espera el drenado
#   4) imprime verificación (verify.sh) + métricas (metrics.sh)
#
# Pensado para la demostración en vivo ante los profesores.
#
# Uso:  ./scripts/run_experiment.sh [ESCENARIO] [TOTAL] [DUP_EVERY]
#   ESCENARIO  normal | stress | fault     (def. normal)
#   TOTAL      nº de mensajes               (def. 2000; stress sugerido 6000)
#   DUP_EVERY  solo 'fault': 1 de cada N duplicado (def. 25)
#
# Ejemplos:
#   ./scripts/run_experiment.sh normal 2000
#   ./scripts/run_experiment.sh stress 6000
#   ./scripts/run_experiment.sh fault  2000 25
# ---------------------------------------------------------------------------
set -euo pipefail

SCENARIO="${1:-normal}"
# TOTAL por defecto según escenario (rápido y eficiente para la demo):
#   normal/fault = 500 ; stress = 1500 (mayor, para que el pico sea representativo).
# Puedes sobrescribirlo pasando el nº como 2º argumento.
if [ "$SCENARIO" = "stress" ]; then
  TOTAL="${2:-1500}"
else
  TOTAL="${2:-500}"
fi
DUP_EVERY="${3:-25}"
REGION="${AWS_REGION:-us-east-2}"
export AWS_REGION="$REGION"
# PURGE=0 salta la purga + el sleep de 60s (útil para encadenar escenarios rápido,
# ya que cada escenario usa payment_id únicos: pay-normal-*, pay-stress-*, pay-fault-*).
#   ./scripts/run_experiment.sh normal             (500 msg, con purga, parte de cero)
#   PURGE=0 ./scripts/run_experiment.sh stress 3000 (sin purga, arranca al instante)
PURGE="${PURGE:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"
QUEUE_URL="$(terraform output -raw queue_url)"
DLQ_URL="$(terraform output -raw dlq_url)"
cd "$ROOT"

echo "################################################################"
echo "# EXPERIMENTO PoC Bre-B · escenario=$SCENARIO · total=$TOTAL · región=$REGION"
echo "################################################################"

echo; echo ">>> [1/4] Purgando cola principal y DLQ (parten de cero)…"
if [ "$PURGE" = "1" ]; then
  aws sqs purge-queue --region "$REGION" --queue-url "$QUEUE_URL" || true
  aws sqs purge-queue --region "$REGION" --queue-url "$DLQ_URL"   || true
  echo "    (las colas tardan ~60 s en quedar totalmente vacías)"
  sleep 60
else
  echo "    PURGE=0 → se omite la purga y la espera (encadenado rápido de escenarios)."
fi

echo; echo ">>> [2/4] Inyectando carga ($SCENARIO, $TOTAL mensajes)…"
export QUEUE_URL
# Inyector rápido con boto3 + hilos (segundos). Fallback al CLI si no hay python/boto3.
if python3 -c "import boto3" 2>/dev/null; then
  if [ "$SCENARIO" = "fault" ]; then
    python3 ./load/load_fast.py "$TOTAL" fault "$DUP_EVERY"
  else
    python3 ./load/load_fast.py "$TOTAL" "$SCENARIO"
  fi
else
  if [ "$SCENARIO" = "fault" ]; then
    ./load/load_cli.sh "$TOTAL" fault "$DUP_EVERY"
  else
    ./load/load_cli.sh "$TOTAL" "$SCENARIO"
  fi
fi

echo; echo ">>> [3/4] Esperando el drenado de la cola (consumo dosificado)…"
for i in $(seq 1 60); do
  VIS=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'join(`+`,[Attributes.ApproximateNumberOfMessages,Attributes.ApproximateNumberOfMessagesNotVisible])' \
    --output text 2>/dev/null || echo "?+?")
  echo "    t=$((i*5))s  cola(visible+enVuelo) = $VIS"
  LEFT=$(echo "$VIS" | awk -F+ '{print ($1+$2)}')
  [ "${LEFT:-1}" = "0" ] && { echo "    cola drenada."; break; }
  sleep 5
done

echo; echo ">>> [4/4] Verificación y métricas"
echo "----------------------------------------------------------------"
./scripts/verify.sh || true
echo "----------------------------------------------------------------"
./scripts/metrics.sh 15 || true
echo "----------------------------------------------------------------"

echo
echo "LISTO. Abre el dashboard para la evidencia visual:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=breb-poc-dashboard"
