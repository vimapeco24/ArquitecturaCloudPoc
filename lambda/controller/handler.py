"""
Controller de la PoC Bre-B — Pagos Programados (arquitectura Step Functions).

Primer estado de la máquina de estados. Equivale al punto 1 y 2 de la propuesta:
  1. "consultar cuántas transacciones hay que hacer en el día"
  2. "bajar ese dataset" para que el Map distribuido itere en paralelo.

En producción consultaría la Base de Pagos Programados (los pagos cuya fecha de
ejecución es hoy). Para la PoC GENERA un dataset sintético de N pagos (por defecto
20.000, el volumen diario objetivo del ASR) y lo escribe en S3 como JSON Lines,
que es el formato que el ItemReader del Distributed Map lee de forma eficiente
(una línea = un ítem, sin cargar todo en memoria).

Devuelve a la máquina de estados la ubicación del dataset (bucket/key) y el conteo,
para que el estado Map lo use como ItemReader.

Entrada (opcional, para sobreescribir en pruebas):
    {"total": 20000, "run_id": "demo-20k", "duplicate_every": 0}
Salida:
    {"bucket": "...", "key": "datasets/<run_id>.jsonl", "total": 20000, "run_id": "..."}
"""

import json
import os
import time
import uuid

import boto3

DATA_BUCKET = os.environ["DATA_BUCKET"]
DEFAULT_TOTAL = int(os.environ.get("DEFAULT_TOTAL", "20000"))

_s3 = boto3.client("s3")


def handler(event, context):
    event = event or {}
    total = int(event.get("total", DEFAULT_TOTAL))
    run_id = str(event.get("run_id") or f"run-{int(time.time())}-{uuid.uuid4().hex[:6]}")
    # Si >0, cada N pagos reutiliza un payment_id previo (duplicado intencional)
    # para evidenciar la idempotencia ASR-2 end-to-end.
    duplicate_every = int(event.get("duplicate_every", 0))

    key = f"datasets/{run_id}.jsonl"

    # Construcción en memoria por streaming de líneas (20k líneas ~ pocos MB).
    lines = []
    for i in range(total):
        pid = f"{run_id}-{i:06d}"
        if duplicate_every and i > 0 and i % duplicate_every == 0:
            # Reusa el id anterior → el worker debe marcarlo DUPLICATE_SKIPPED.
            pid = f"{run_id}-{i - 1:06d}"
        payment = {
            "payment_id": pid,
            "amount": round(1000 + (i % 9000) + 0.99, 2),
            "dest_key": f"@llave{i % 1000}",
            "scheduled_date": "2026-11-11",
        }
        lines.append(json.dumps(payment))

    body = "\n".join(lines).encode("utf-8")
    _s3.put_object(Bucket=DATA_BUCKET, Key=key, Body=body, ContentType="application/x-ndjson")

    print(json.dumps({
        "event": "dataset_ready",
        "run_id": run_id,
        "bucket": DATA_BUCKET,
        "key": key,
        "total": total,
        "duplicate_every": duplicate_every,
    }))

    return {
        "bucket": DATA_BUCKET,
        "key": key,
        "total": total,
        "run_id": run_id,
    }
