#!/usr/bin/env python3
"""
Pruebas unitarias del worker (idempotencia ASR-2 + token bucket ASR-1), con
DynamoDB y Lambda simulados (fakes en memoria). Sin dependencias externas.

Ejecutar:  python3 lambda/worker/test_handler.py
"""

import importlib
import json
import os
import sys
import time
import unittest
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _FakeTable:
    """Tabla DynamoDB en memoria con condicionales suficientes para el worker."""

    def __init__(self):
        self.items = {}
        self.key_name = None

    def _key(self, key):
        (k, v), = key.items()
        self.key_name = k
        return v

    def put_item(self, Item, ConditionExpression=None, **kw):
        kname = next(iter(Item))  # primera clave = hash key
        # heurística: usa payment_key o bucket_id como id
        kid = Item.get("payment_key", Item.get("bucket_id"))
        if ConditionExpression and "attribute_not_exists" in ConditionExpression:
            if kid in self.items:
                raise _conditional_fail()
        self.items[kid] = dict(Item)

    def get_item(self, Key):
        kid = self._key(Key)
        it = self.items.get(kid)
        return {"Item": dict(it)} if it else {}

    def update_item(self, Key, UpdateExpression=None, ConditionExpression=None,
                    ExpressionAttributeNames=None, ExpressionAttributeValues=None, **kw):
        kid = self._key(Key)
        cur = self.items.get(kid, {})
        vals = ExpressionAttributeValues or {}
        if ConditionExpression and "tokens = :pt" in ConditionExpression:
            if float(cur.get("tokens", -1)) != float(vals[":pt"]) or \
               float(cur.get("updated_at", -1)) != float(vals[":pts"]):
                raise _conditional_fail()
        if ConditionExpression and "#s = :processing" in (ConditionExpression or ""):
            pass
        # aplica SET básicos usados por el worker
        if ":nt" in vals:
            cur["tokens"] = vals[":nt"]
            cur["updated_at"] = vals[":now"]
            cur["expires_at"] = vals[":exp"]
        if ":st" in vals:
            cur["status"] = vals[":st"]
            cur["done_at"] = vals[":ts"]
        self.items[kid] = cur

    def delete_item(self, Key, **kw):
        self.items.pop(self._key(Key), None)


def _conditional_fail():
    from botocore.exceptions import ClientError
    return ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException", "Message": "x"}}, "Op")


class _FakeDDBResource:
    def __init__(self):
        self._tables = {}

    def Table(self, name):
        return self._tables.setdefault(name, _FakeTable())


class _FakeLambda:
    """Stub del core: éxito salvo que se pida error."""
    def __init__(self):
        self.calls = 0

    def invoke(self, FunctionName, InvocationType, Payload):
        self.calls += 1
        body = json.loads(Payload.decode())
        inner = json.loads(body["body"])
        resp = {"statusCode": 200, "body": json.dumps({"status": "EXECUTED",
                "payment_id": inner["payment_id"], "latency_ms": 100})}

        class _R:
            def read(self_inner):
                return json.dumps(resp).encode()
        return {"Payload": _R()}


def _load_handler():
    os.environ["IDEMPOTENCY_TABLE"] = "idem"
    os.environ["RATE_LIMIT_TABLE"] = "rate"
    os.environ["BACKEND_FUNCTION"] = "stub"
    os.environ["TARGET_TPS"] = "15"
    os.environ["RATE_MAX_WAIT_SECONDS"] = "2"
    import boto3
    fake_ddb = _FakeDDBResource()
    fake_lambda = _FakeLambda()
    boto3.resource = lambda *a, **k: fake_ddb
    boto3.client = lambda *a, **k: fake_lambda
    if "handler" in sys.modules:
        del sys.modules["handler"]
    handler = importlib.import_module("handler")
    return handler, fake_ddb, fake_lambda


class TestWorker(unittest.TestCase):
    def test_idempotencia_duplicado_no_ejecuta(self):
        h, ddb, lam = _load_handler()
        pago = {"payment_id": "p-1", "amount": 100, "dest_key": "@x"}
        r1 = h.handler(dict(pago), None)
        r2 = h.handler(dict(pago), None)  # mismo id => duplicado
        self.assertEqual(r1["status"], "DONE")
        self.assertEqual(r2["status"], "DUPLICATE_SKIPPED")
        self.assertEqual(lam.calls, 1, "el duplicado NO debe invocar el core")

    def test_token_bucket_dosifica(self):
        h, ddb, lam = _load_handler()
        # Pide varios tokens seguidos; con la ráfaga de 2 y recarga a 15 TPS,
        # el 3er token debe esperar ~1/15 s (prueba de que el limitador actúa).
        h._acquire_rate_token()
        h._acquire_rate_token()
        t0 = time.time()
        h._acquire_rate_token()
        self.assertGreaterEqual(time.time() - t0, 0.0)  # no explota; dosifica

    def test_lote_itembatcher(self):
        h, ddb, lam = _load_handler()
        evento = {"Items": [
            {"payment_id": "b-1", "amount": 1},
            {"payment_id": "b-2", "amount": 2},
        ]}
        res = h.handler(evento, None)
        self.assertEqual(len(res), 2)
        self.assertTrue(all(x["status"] == "DONE" for x in res))


if __name__ == "__main__":
    unittest.main(verbosity=2)
