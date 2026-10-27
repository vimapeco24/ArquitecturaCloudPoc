"""
Stub del backend transaccional on-premise (core bancario) para la PoC.

Representa el componente Java/Core que ejecuta la transferencia Bre-B real.
Para la PoC solo necesitamos:
  * Latencia simulada (configurable) para parecerse a una llamada al host.
  * Un porcentaje de errores transitorios (por defecto 5%) para ejercitar el
    escenario de fallo: reintentos con backoff en el consumidor y DLQ.
  * Responder la clave de idempotencia recibida, para trazabilidad en X-Ray.

Se expone mediante una Lambda Function URL (HTTP) — no requiere API Gateway.
"""

import json
import os
import random
import time

# Latencia simulada en milisegundos (rango uniforme min..max).
LATENCY_MIN_MS = int(os.environ.get("LATENCY_MIN_MS", "50"))
LATENCY_MAX_MS = int(os.environ.get("LATENCY_MAX_MS", "300"))
# Probabilidad de error transitorio (0.05 = 5%).
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0.05"))


def handler(event, context):
    # Latencia simulada.
    latency_ms = random.uniform(LATENCY_MIN_MS, LATENCY_MAX_MS)
    time.sleep(latency_ms / 1000.0)

    # Cuerpo entrante (Function URL entrega el body como string).
    raw_body = event.get("body") or "{}"
    try:
        body = json.loads(raw_body)
    except json.JSONDecodeError:
        return _response(400, {"status": "REJECTED", "reason": "invalid_json"})

    idempotency_key = (
        event.get("headers", {}).get("x-idempotency-key")
        or body.get("payment_id", "unknown")
    )

    # Error transitorio inyectado → 503 para provocar reintento/backoff en el consumidor.
    if random.random() < ERROR_RATE:
        return _response(503, {
            "status": "TRANSIENT_ERROR",
            "payment_id": idempotency_key,
            "latency_ms": round(latency_ms, 1),
        })

    # Éxito: la transferencia Bre-B "se ejecutó".
    return _response(200, {
        "status": "EXECUTED",
        "payment_id": idempotency_key,
        "latency_ms": round(latency_ms, 1),
    })


def _response(status_code: int, payload: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }
