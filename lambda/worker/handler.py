"""
Worker de la PoC Bre-B — Pagos Programados (arquitectura Step Functions).

Este Lambda es invocado por el estado Map DISTRIBUIDO de la máquina de estados,
UNA VEZ POR PAGO (o por lote pequeño de pagos si ItemBatcher está activo). Con
MaxConcurrency=N, la máquina de estados ejecuta hasta N workers EN PARALELO,
cada uno disparando su evento contra el core y esperando la respuesta.

Reemplaza a la antigua pareja "cola SQS + Lambda consumer": el Load Leveling
ya NO lo da una cola, sino la CONCURRENCIA del Map distribuido (MaxConcurrency),
que es el control que protege al backend transaccional del pico de las 6:00 a.m.

Responsabilidades (valida ASR-1 y ASR-2):
  * Garantiza procesamiento EXACTAMENTE-UNA-VEZ con un PutItem condicional en
    DynamoDB sobre `payment_key` (ASR-2: 0 duplicados).
  * Dispara el evento al core (stub backend) con reintentos y backoff.
  * Verifica el estado de la respuesta y actualiza el estado del pago (DONE/FAILED).
  * Devuelve un resultado estructurado que el Map agrega y el ResultWriter escribe
    a S3 (evidencia en AWS). Si el pago falla de forma definitiva, lanza excepción
    para que la máquina de estados lo cuente como fallido y pueda notificar al usuario.

Evento de entrada (un ítem del dataset):
    {"payment_id": "...", "amount": 123.45, "dest": "...", ...}
Cuando ItemBatcher está activo, el evento es:
    {"Items": [ {pago}, {pago}, ... ]}
"""

import json
import os
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
BACKEND_FUNCTION = os.environ["BACKEND_FUNCTION"]
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
BASE_BACKOFF_SECONDS = float(os.environ.get("BASE_BACKOFF_SECONDS", "0.2"))
BACKEND_TIMEOUT_SECONDS = float(os.environ.get("BACKEND_TIMEOUT_SECONDS", "5"))
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", str(7 * 24 * 3600)))

_ddb = boto3.resource("dynamodb", config=Config(retries={"max_attempts": 3, "mode": "standard"}))
_table = _ddb.Table(IDEMPOTENCY_TABLE)

_lambda = boto3.client(
    "lambda",
    config=Config(
        read_timeout=BACKEND_TIMEOUT_SECONDS,
        connect_timeout=BACKEND_TIMEOUT_SECONDS,
        retries={"max_attempts": 0},
    ),
)


class PermanentError(Exception):
    """Error no recuperable: el pago queda FAILED; la máquina de estados lo contabiliza."""


def _reserve_idempotency_key(key: str) -> bool:
    """Reserva atómica de la clave de idempotencia (True=nuevo, False=duplicado)."""
    now = int(time.time())
    try:
        _table.put_item(
            Item={
                "payment_key": key,
                "status": "PROCESSING",
                "created_at": now,
                "expires_at": now + IDEMPOTENCY_TTL_SECONDS,
            },
            ConditionExpression="attribute_not_exists(payment_key)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _mark(key: str, status: str) -> None:
    _table.update_item(
        Key={"payment_key": key},
        UpdateExpression="SET #s = :st, done_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":st": status, ":ts": int(time.time())},
    )


def _release_idempotency_key(key: str) -> None:
    try:
        _table.delete_item(
            Key={"payment_key": key},
            ConditionExpression="#s = :processing",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":processing": "PROCESSING"},
        )
    except ClientError:
        pass


def _call_backend(payload: dict) -> dict:
    """Dispara el evento al core (stub) con reintentos/backoff. Devuelve el cuerpo."""
    invoke_event = {
        "body": json.dumps(payload),
        "headers": {"x-idempotency-key": payload["payment_id"]},
    }
    raw_event = json.dumps(invoke_event).encode("utf-8")

    last_err = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = _lambda.invoke(
                FunctionName=BACKEND_FUNCTION,
                InvocationType="RequestResponse",
                Payload=raw_event,
            )
            if resp.get("FunctionError"):
                last_err = resp["FunctionError"]
            else:
                result = json.loads(resp["Payload"].read())
                status = int(result.get("statusCode", 500))
                if 200 <= status < 300:
                    return json.loads(result.get("body", "{}"))
                last_err = f"HTTP {status}"
                if 400 <= status < 500 and status != 429:
                    raise PermanentError(f"core rechazó el pago: {last_err}")
        except PermanentError:
            raise
        except ClientError as exc:
            last_err = str(exc)
        except Exception as exc:  # red/timeout → reintentar
            last_err = str(exc)

        if attempt < MAX_RETRIES:
            time.sleep(BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)))

    raise PermanentError(f"core no disponible tras {MAX_RETRIES} intentos: {last_err}")


def _process_one(payment: dict) -> dict:
    payment_id = payment["payment_id"]

    if not _reserve_idempotency_key(payment_id):
        # Duplicado: no se ejecuta el pago dos veces (ASR-2).
        print(json.dumps({"event": "duplicate_skipped", "payment_id": payment_id}))
        return {"payment_id": payment_id, "status": "DUPLICATE_SKIPPED"}

    try:
        backend = _call_backend(payment)
        _mark(payment_id, "DONE")
        print(json.dumps({"event": "processed", "payment_id": payment_id}))
        return {
            "payment_id": payment_id,
            "status": "DONE",
            "backend_status": backend.get("status"),
            "latency_ms": backend.get("latency_ms"),
        }
    except Exception:
        # Falla definitiva: marca FAILED y propaga para que la máquina de estados
        # cuente el fallo y dispare la notificación al usuario.
        _mark(payment_id, "FAILED")
        print(json.dumps({"event": "process_failed", "payment_id": payment_id}))
        raise


def handler(event, context):
    """Entry point. Soporta ítem único o lote (ItemBatcher: event['Items'])."""
    if isinstance(event, dict) and "Items" in event:
        return [_process_one(p) for p in event["Items"]]
    return _process_one(event)
