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

TOTAL="${1:-500}"
SCENARIO="${2:-normal}"
DUP_EVERY="${3:-25}"
REGION="${AWS_REGION:-us-east-2}"
PARALLEL="${PARALLEL:-40}"   # nº de lotes send-message-batch en paralelo (no afecta la concurrencia del consumer)

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

# ---------------------------------------------------------------------------
# Envío RÁPIDO: cada lote de 10 mensajes se arma con UNA sola invocación de jq
# (sin lanzar un proceso por mensaje). jq ya viene en CloudShell. El escape de
# JSON para MessageBody lo hace jq con @json. Si no hay jq, cae a un fallback.
# ---------------------------------------------------------------------------

# pid de un índice (en 'fault', 1 de cada DUP_EVERY reutiliza el pid anterior).
pid_for() {
  local i="$1"
  if [ "$SCENARIO" = "fault" ] && [ "$DUP_EVERY" -gt 0 ] && [ "$i" -gt 0 ] && [ $(( i % DUP_EVERY )) -eq 0 ]; then
    echo "pay-${SCENARIO}-$(( i - 1 ))"
  else
    echo "pay-${SCENARIO}-${i}"
  fi
}

# Envía un lote [from, to) con una sola llamada a jq + una a aws.
send_batch() {
  local from="$1" to="$2" i
  # Genera líneas "id<TAB>pid<TAB>amount" para el lote y deja que jq arme el --entries.
  {
    for (( i=from; i<to; i++ )); do
      printf 'm%s\t%s\t%s\n' "$i" "$(pid_for "$i")" "$(( 50000 + (i % 100) * 1000 ))"
    done
  } | jq -R -s '
      split("\n") | map(select(length>0)) | map(split("\t")) |
      map({
        Id: .[0],
        MessageBody: ({
          payment_id: .[1],
          account_from: "000123456789",
          account_to: "000987654321",
          key_breb: ("@llave" + (.[0]|ltrimstr("m"))),
          amount: (.[2]|tonumber),
          currency: "COP",
          scheduled_for: "2026-01-01T06:00:00-05:00",
          periodicity: "ONCE"
        } | tojson)
      })' > "$WORKDIR/batch_${from}.json"
  aws sqs send-message-batch --region "$REGION" --queue-url "$QUEUE_URL" \
    --entries "file://$WORKDIR/batch_${from}.json" >/dev/null
}

export -f send_batch pid_for
export SCENARIO DUP_EVERY REGION QUEUE_URL WORKDIR

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
