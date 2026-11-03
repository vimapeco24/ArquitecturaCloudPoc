#!/usr/bin/env python3
"""
Inyector de carga RÁPIDO para la PoC Bre-B (boto3 + hilos).

Reemplaza al bucle de bash + AWS CLI (que lanzaba un proceso por lote): aquí un
solo proceso Python mantiene la conexión a SQS y envía send_message_batch (10
mensajes por llamada) desde un pool de hilos. Envía miles de mensajes en segundos.

Uso:
  python3 load/load_fast.py TOTAL ESCENARIO [DUP_EVERY]
    TOTAL      nº de mensajes            (p. ej. 1000)
    ESCENARIO  normal | stress | fault
    DUP_EVERY  en 'fault': 1 de cada N es duplicado (def. 25)

Variables de entorno:
  AWS_REGION  (def. us-east-2)
  QUEUE_URL   (obligatoria: URL de la cola destino)
  WORKERS     (def. 20) nº de hilos concurrentes de envío
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

TOTAL = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
SCENARIO = sys.argv[2] if len(sys.argv) > 2 else "normal"
DUP_EVERY = int(sys.argv[3]) if len(sys.argv) > 3 else 25
REGION = os.environ.get("AWS_REGION", "us-east-2")
QUEUE_URL = os.environ["QUEUE_URL"]
WORKERS = int(os.environ.get("WORKERS", "20"))

sqs = boto3.client(
    "sqs",
    region_name=REGION,
    config=Config(max_pool_connections=WORKERS * 2, retries={"max_attempts": 3, "mode": "standard"}),
)


def pid_for(i: int) -> str:
    # En 'fault', 1 de cada DUP_EVERY reutiliza el pid anterior (duplicado intencional).
    if SCENARIO == "fault" and DUP_EVERY > 0 and i > 0 and i % DUP_EVERY == 0:
        return f"pay-{SCENARIO}-{i-1}"
    return f"pay-{SCENARIO}-{i}"


def body_for(i: int) -> str:
    return json.dumps({
        "payment_id": pid_for(i),
        "account_from": "000123456789",
        "account_to": "000987654321",
        "key_breb": f"@llave{i}",
        "amount": 50000 + (i % 100) * 1000,
        "currency": "COP",
        "scheduled_for": "2026-01-01T06:00:00-05:00",
        "periodicity": "ONCE",
    })


def send_batch(from_i: int) -> int:
    to_i = min(from_i + 10, TOTAL)
    entries = [{"Id": f"m{i}", "MessageBody": body_for(i)} for i in range(from_i, to_i)]
    sqs.send_message_batch(QueueUrl=QUEUE_URL, Entries=entries)
    return to_i - from_i


def main():
    print(f"Inyectando {TOTAL} mensajes ({SCENARIO}) a SQS con {WORKERS} hilos…", flush=True)
    start = time.time()
    sent = 0
    batches = range(0, TOTAL, 10)
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for n in pool.map(send_batch, batches):
            sent += n
    dur = time.time() - start
    rate = sent / dur if dur else 0
    print(f"Enviados {sent} mensajes en {dur:.1f}s  (~{rate:.0f} msg/s de inyección)", flush=True)


if __name__ == "__main__":
    main()
