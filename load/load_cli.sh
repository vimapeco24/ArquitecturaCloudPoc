#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Generador de carga para la PoC Bre-B usando AWS CLI (sin k6).
#
# Por qué: en CloudShell la jslib de AWS para k6 (0.12.3) falla al construir el
# cliente ("invalid AWS access key ID ... undefined") aunque las credenciales
# estén presentes. El AWS CLI ya resuelve las credenciales de CloudShell solo,
# así que inyectamos a SQS con send-message-batch (10 msg por llamada) en paralelo.
#
# Uso:
#   ./load_cli.sh [TOTAL] [ESCENARIO] [DUP_EVERY]
#     TOTAL      nº de mensajes a enviar           (def. 2000)
#     ESCENARIO  normal | stress | fault           (def. normal)
#     DUP_EVERY  en 'fault': 1 de cada N es duplicado (def. 25)
#
# Ejemplos:
#   ./load_cli.sh 100                 # prueba rápida
#   ./load_cli.sh 2000 normal         # escenario NORMAL
#   ./load_cli.sh 6000 stress         # escenario ESTRÉS
#   ./load_cli.sh 2000 fault 25       # FALLO + duplicados (ASR-2)
# ---------------------------------------------------------------------------
set -euo pipefail

TOTAL="${1:-2000}"
SCENARIO="${2:-normal}"
DUP_EVERY="${3:-25}"
REGION="${AWS_REGION:-us-east-2}"
PARALLEL="${PARALLEL:-10}"   # nº de lotes en paralelo (ojo: límite de concurrencia de la cuenta)

QUEUE_URL="$(cd "$(dirname "$0")/../terraform" && terraform output -raw queue_url)"

echo "=============================================="
echo " Carga PoC Bre-B (AWS CLI)"
echo "   Escenario : $SCENARIO"
echo "   Total     : $TOTAL mensajes"
echo "   Región    : $REGION"
echo "   Cola      : $QUEUE_URL"
[ "$SCENARIO" = "fault" ] && echo "   Duplicados: 1 de cada $DUP_EVERY"
echo "=============================================="
START=$(date +%s)

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Construye el cuerpo JSON de un pago. $1 = índice.
build_body() {
  local i="$1" pid="pay-${SCENARIO}-${i}"
  # En 'fault', cada DUP_EVERY reutilizamos un payment_id previo (duplicado intencional).
  if [ "$SCENARIO" = "fault" ] && [ "$DUP_EVERY" -gt 0 ] && [ "$i" -gt 0 ] && [ $(( i % DUP_EVERY )) -eq 0 ]; then
    pid="pay-${SCENARIO}-$(( i - 1 ))"
  fi
  printf '{"payment_id":"%s","account_from":"000123456789","account_to":"000987654321","key_breb":"@llave%s","amount":%s,"currency":"COP","scheduled_for":"2026-01-01T06:00:00-05:00","periodicity":"ONCE"}' \
    "$pid" "$i" "$(( 50000 + (i % 100) * 1000 ))"
}

# Envía un lote de hasta 10 mensajes [desde, hasta).
send_batch() {
  local from="$1" to="$2" entries="[" first=1 i
  for (( i=from; i<to; i++ )); do
    local body; body="$(build_body "$i")"
    # Escapar el body para incrustarlo como string JSON en MessageBody.
    local esc; esc="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    [ $first -eq 0 ] && entries+=","
    entries+="{\"Id\":\"m${i}\",\"MessageBody\":${esc}}"
    first=0
  done
  entries+="]"
  aws sqs send-message-batch --region "$REGION" --queue-url "$QUEUE_URL" \
    --entries "$entries" >/dev/null
}

export -f send_batch build_body
export SCENARIO DUP_EVERY REGION QUEUE_URL

# Lanza lotes de 10, con PARALLEL en vuelo a la vez.
running=0
for (( b=0; b<TOTAL; b+=10 )); do
  end=$(( b + 10 )); [ "$end" -gt "$TOTAL" ] && end="$TOTAL"
  send_batch "$b" "$end" &
  running=$(( running + 1 ))
  if [ "$running" -ge "$PARALLEL" ]; then wait -n 2>/dev/null || wait; running=$(( running - 1 )); fi
done
wait

END=$(date +%s)
echo "----------------------------------------------"
echo " Enviados $TOTAL mensajes en $(( END - START ))s"
echo " Observa la cola y el consumer:"
echo "   watch -n2 aws sqs get-queue-attributes --region $REGION --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible"
echo "   aws logs tail /aws/lambda/breb-poc-consumer --region $REGION --since 5m --follow"
echo "----------------------------------------------"
