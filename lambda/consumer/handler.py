"""
Consumidor SQS de la PoC Bre-B — Pagos Programados.

Responsabilidades (valida ASR-1 y ASR-2):
  * Lee cada mensaje de ejecución de pago programado desde SQS.
  * Garantiza procesamiento EXACTAMENTE-UNA-VEZ mediante una clave de idempotencia
    persistida en DynamoDB con un `PutItem` condicional (ASR-2: 0 duplicados).
  * Llama al stub del backend transaccional con reintentos y backoff exponencial.
  * Ante fallo definitivo, relanza la excepción para que SQS reintregue el mensaje;
    agotados los reintentos, SQS lo envía a la DLQ (ASR-2: 0 pérdidas).
  * Reporta "batch item failures" parciales para no reprocesar mensajes ya confirmados.

La concurrencia reservada (configurada en Terraform, N=20) dosifica el ritmo con el
que este consumidor golpea el backend, protegiéndolo del pico de las 6:00 a.m.
(patrón Queue-Based Load Leveling).
"""

import json
import os
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Configuración (inyectada por variables de entorno desde Terraform)
# ---------------------------------------------------------------------------
IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
# Nombre (o ARN) de la Lambda del stub backend. Se invoca por la API de Lambda
# (lambda:InvokeFunction), no por Function URL: la organización de la cuenta
# bloquea las Function URLs (devuelven 403 con cualquier AuthType).
BACKEND_FUNCTION = os.environ["BACKEND_FUNCTION"]
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
BASE_BACKOFF_SECONDS = float(os.environ.get("BASE_BACKOFF_SECONDS", "0.2"))
BACKEND_TIMEOUT_SECONDS = float(os.environ.get("BACKEND_TIMEOUT_SECONDS", "5"))
# TTL para limpiar la tabla de idempotencia tras la PoC (segundos).
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", str(7 * 24 * 3600)))

_ddb = boto3.resource("dynamodb", config=Config(retries={"max_attempts": 3, "mode": "standard"}))
_table = _ddb.Table(IDEMPOTENCY_TABLE)

# Cliente Lambda para invocar el stub backend. Timeout de lectura acotado y sin
# reintentos de botocore (los reintentos de aplicación los controlamos nosotros).
_lambda = boto3.client(
    "lambda",
    config=Config(
        read_timeout=BACKEND_TIMEOUT_SECONDS,
        connect_timeout=BACKEND_TIMEOUT_SECONDS,
        retries={"max_attempts": 0},
    ),
)


class PermanentError(Exception):
    """Error no recuperable: el mensaje debe ir a la DLQ sin más reintentos de aplicación."""


def _reserve_idempotency_key(key: str) -> bool:
    """Intenta reservar la clave de idempotencia.

    Devuelve True si la clave es nueva (procesar), False si ya existía (duplicado → omitir).
    El PutItem condicional es atómico: dos invocaciones concurrentes con la misma clave
    no pueden tener éxito ambas.
    """
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
            # Ya existe → es un duplicado (reintento de SQS o doble entrega at-least-once).
            return False
        raise


def _mark_done(key: str) -> None:
    _table.update_item(
        Key={"payment_key": key},
        UpdateExpression="SET #s = :done, done_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":done": "DONE", ":ts": int(time.time())},
    )


def _release_idempotency_key(key: str) -> None:
    """Libera la reserva si el procesamiento falló, para permitir un reintento limpio."""
    try:
        _table.delete_item(
            Key={"payment_key": key},
            ConditionExpression="#s = :processing",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":processing": "PROCESSING"},
        )
    except ClientError:
        # Si ya no está en PROCESSING, no hay nada que liberar.
        pass


def _call_backend(payload: dict) -> None:
    """Invoca el stub del backend (por API de Lambda) con reintentos y backoff.

    Lanza PermanentError si se agotan los reintentos o si el backend rechaza el
    pago con un error permanente (4xx distinto de 429); así SQS reintentará la
    entrega y, tras maxReceiveCount, moverá el mensaje a la DLQ.
    """
    # El stub conserva el contrato de una Function URL: lee event["body"] (string)
    # y event["headers"]. Reproducimos ese sobre para no tocar el stub.
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
            # Error de la plataforma Lambda (función reventó, throttling, etc.).
            if resp.get("FunctionError"):
                last_err = resp["FunctionError"]
            else:
                result = json.loads(resp["Payload"].read())
                status = int(result.get("statusCode", 500))
                if 200 <= status < 300:
                    return
                last_err = f"HTTP {status}"
                print(json.dumps({
                    "event": "backend_http_error",
                    "payment_id": payload["payment_id"],
                    "code": status,
                    "body": str(result.get("body"))[:500],
                }))
                # 4xx (excepto 429) es error de datos: no reintentar.
                if 400 <= status < 500 and status != 429:
                    raise PermanentError(f"backend rechazó el pago: {last_err}")
        except PermanentError:
            raise
        except ClientError as exc:
            # Throttling de Lambda u otro error transitorio del servicio → reintentar.
            last_err = str(exc)
        except Exception as exc:  # errores de red/timeout → reintentar
            last_err = str(exc)

        if attempt < MAX_RETRIES:
            time.sleep(BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)))

    raise PermanentError(f"backend no disponible tras {MAX_RETRIES} intentos: {last_err}")


def _process_record(record: dict) -> None:
    body = json.loads(record["body"])
    # Clave de idempotencia por mensaje (exactamente-una-vez).
    payment_id = body["payment_id"]

    if not _reserve_idempotency_key(payment_id):
        # Duplicado: ya procesado o en curso. No se ejecuta el pago dos veces.
        print(json.dumps({"event": "duplicate_skipped", "payment_id": payment_id}))
        return

    try:
        _call_backend(body)
        _mark_done(payment_id)
        print(json.dumps({"event": "processed", "payment_id": payment_id}))
    except Exception:
        # Falló el procesamiento: libera la reserva para permitir reintento de SQS.
        _release_idempotency_key(payment_id)
        raise


def handler(event, context):
    """Entry point de Lambda. Reporta fallos parciales por mensaje."""
    failures = []
    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception as exc:  # noqa: BLE001 - queremos capturar todo para el fallo parcial
            print(json.dumps({
                "event": "process_failed",
                "message_id": record.get("messageId"),
                "error": str(exc),
            }))
            failures.append({"itemIdentifier": record["messageId"]})

    # ReportBatchItemFailures: solo se reintegran a la cola los mensajes fallidos.
    return {"batchItemFailures": failures}
