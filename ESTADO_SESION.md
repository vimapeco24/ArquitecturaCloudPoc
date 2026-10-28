# Estado de la sesión — PoC Bre-B Pagos Programados (AWS)

> Archivo de handoff para retomar el trabajo si se pierde la sesión.
> Última actualización: 2026-10-28 (sesión CloudShell)

## Contexto general

- **Proyecto:** PoC de Bre-B "Pagos Programados" sobre AWS.
- **Repo GitHub:** https://github.com/vimapeco24/ArquitecturaCloudPoc.git (rama `main`)
- **Copia local:** `221026/poc-breb-aws/` (mismo remoto, sincronizada)
- **Cuenta AWS:** `aftc_test (803647807230)`
- **Región:** `us-east-2` (Ohio)
- **Entorno de despliegue:** AWS CloudShell → `~/ArquitecturaCloudPoc/terraform`
  (el `terraform.tfstate` es **local** en CloudShell y persiste en el home ~1GB)

## Arquitectura / recursos desplegados

Todos creados y confirmados en la cuenta (`terraform plan` = "No changes"):

- 2 Lambdas: `breb-poc-consumer`, `breb-poc-stub-backend`
- SQS: `breb-poc-queue` (principal) + `breb-poc-dlq` (DLQ con redrive)
- DynamoDB: `breb-poc-idempotency` (clave: `payment_key`)
- Event source mapping SQS → consumer (ReportBatchItemFailures)
- Observabilidad: dashboard `breb-poc-dashboard` + 2 alarmas (errores consumer, DLQ no vacía) + X-Ray activo
- IAM roles/policies para ambas Lambdas
- **NUEVO (fix):** `aws_lambda_permission.stub_url_public` → permiso público de la Function URL

Nota: `scheduler.tf` existe pero el EventBridge Scheduler **NO se crea** (está condicionado/desactivado).
La PoC se prueba inyectando mensajes a SQS directamente. Esto es intencional, no un error.

## Outputs clave (Terraform)

- `queue_url`        = https://sqs.us-east-2.amazonaws.com/803647807230/breb-poc-queue
- `dlq_url`          = https://sqs.us-east-2.amazonaws.com/803647807230/breb-poc-dlq
- `stub_function_url`= https://zrbf23apnld2rb6ssixokxqhcm0nbxca.lambda-url.us-east-2.on.aws/
- `idempotency_table`= breb-poc-idempotency
- `dashboard_url`    = https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=breb-poc-dashboard

## Historial de commits

- `3795914` PoC inicial completa
- `64f24a8` fix: concurrencia reservada opcional para cuentas sandbox (límite 10)
- `e540f38` fix: permiso público Function URL (NO funcionó)
- `04b1979` docs: handoff ESTADO_SESION.md
- `dd06f7a` fix: Function URL a AWS_IAM + SigV4 (NO funcionó)
- `f9b6df6` debug: loguear cuerpo del 403
- `3e8bc6a` fix: firmar+enviar con botocore (NO funcionó)
- `9071ec1` fix: invocar stub por API de Lambda (invoke)  ← FUNCIONÓ ✅

## Problema del HTTP 403 — RESUELTO ✅

**Síntoma:** todos los pagos fallaban con `HTTP 403` llamando al stub.

**Causa raíz:** la organización de la cuenta `aftc_test` **bloquea las Lambda
Function URLs** (devuelven 403 "Forbidden" genérico con cualquier AuthType: NONE
o AWS_IAM). Confirmado porque `aws lambda invoke` directo al stub SÍ funciona
(devuelve 200 EXECUTED), pero cualquier llamada por la Function URL da 403.

**Solución (commit 9071ec1):** el consumer invoca el stub por la **API de Lambda**
(`lambda:InvokeFunction` vía `boto3.client("lambda").invoke()`), NO por Function URL.
- `lambda/consumer/handler.py`: `_call_backend` usa `_lambda.invoke()`; arma el
  evento con formato Function URL (`body` string + `headers`) para no tocar el stub.
  Env var `BACKEND_FUNCTION` (nombre de la Lambda) en vez de `BACKEND_URL`.
- `terraform/lambda.tf`: eliminado `aws_lambda_permission` de la URL; env var del
  consumer → `BACKEND_FUNCTION`. (La Function URL se deja creada pero NO se usa.)
- `terraform/iam.tf`: statement `InvokeStubFunction` → `lambda:InvokeFunction`.

**VERIFICADO el 2026-10-28 01:14 UTC:**
- Logs consumer: `{"event": "processed", "payment_id": "demo-inv-001"}`
- DynamoDB: item `demo-inv-001` con `status = DONE`, created_at/done_at/expires_at.
- Flujo end-to-end OK → ASR-1 (desacople) y ASR-2 (exactamente-una-vez) validados.

## DÓNDE QUEDAMOS / PRÓXIMO PASO

PoC FUNCIONANDO end-to-end. Siguiente: **pruebas de carga k6** para demostrar
Queue-Based Load Leveling. Ver sección "Pruebas de carga" abajo.

## Artefactos de la sesión 2026-10-28 (post-fix)

- `BreB_PoC_AWS.drawio` — diagrama ACTUALIZADO a la realidad desplegada:
  región us-east-2, invoke por API de Lambda (no Function URL), dosificado
  maximum_concurrency=2, scheduler deshabilitado. Con fecha 2026-10-28.
- `BreB_PoC_AWS.png` — imagen exportada del diagrama (para presentación).
- `GUIA_CONSOLA_AWS.md` — guía paso a paso para mostrar la PoC desde la CONSOLA
  WEB de AWS (no CLI): dashboard, SQS, Lambda+logs, DynamoDB, X-Ray, alarmas,
  con links directos a us-east-2 y guion de demo.

## BLOQUEO ACTUAL — pruebas de carga k6 en CloudShell (2026-10-28 ~01:20)

Al preparar k6 aparecieron dos problemas en CloudShell:
1. `No space left on device` — el home de 1 GB se llenó (tgz de k6 + extraído +
   git pull). Fix: `rm -rf ~/k6.tgz ~/k6-v0.49.0-linux-amd64`; si sigue lleno,
   `du -sh ~/* ~/.* | sort -h | tail -10` para ver qué ocupa.
2. Credenciales no parseadas: el parse con `python3 json.load` del endpoint
   169.254.170.2 falló ("Extra data"), variables quedaron undefined y k6 no firmó
   ("invalid AWS access key ID"). Fix robusto:
   `eval "$(aws configure export-credentials --format env)"`
   o fallback con jq:
   `export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)` (y Secret/Token).

Tras liberar espacio y exportar credenciales (ver Key=ASIA... Token set? yes),
reintentar: `export QUEUE_URL=...; cd ~/ArquitecturaCloudPoc/load; TOTAL=100 k6 run normal.js`

### Después de verificar (pendientes)

1. (Opcional) Purgar la cola antes de la prueba de carga — hay mensajes viejos
   (`test-001`, `demo-001`) que fallaron con 403 y rebotan hacia la DLQ:
   ```bash
   aws sqs purge-queue --region us-east-2 --queue-url "$QUEUE_URL"
   ```
2. **Pruebas de carga k6** (demuestran Queue-Based Load Leveling): `load/normal.js`, `load/stress.js`, `load/fault.js`
3. Revisar el dashboard de CloudWatch durante la carga.

## Recordatorios de idempotencia / payload

- El consumer usa `body["payment_id"]` como clave de idempotencia (NO `idempotency_key`).
- Payload mínimo válido: `{"payment_id":"..."}`.
- Un `payment_id` ya procesado se marca `DONE` y se omite como duplicado (exactamente-una-vez).
  Usar un `payment_id` nuevo en cada prueba limpia.


## Pruebas de carga (k6)

Escenarios en `load/`:
- `normal.js`  — 2.000 mensajes, 20 VUs. Éxito: >=99% procesados, p95<=2s.
- `stress.js`  — pico alto (simula las 6:00 a.m.).
- `fault.js`   — con inyección de errores del stub (ejercita reintentos + DLQ).

Helper `load/lib/producer.js` inyecta a SQS con SigV4 usando credenciales del entorno.
OJO: los comentarios dicen us-east-1, pero el despliegue está en **us-east-2**.

Ejecutar en CloudShell:

```bash
# k6 no viene en CloudShell → instalar binario estático en el home (persiste)
cd ~
curl -sL https://github.com/grafana/k6/releases/download/v0.49.0/k6-v0.49.0-linux-amd64.tar.gz -o k6.tgz
tar xzf k6.tgz && mkdir -p ~/bin && cp k6-v0.49.0-linux-amd64/k6 ~/bin/ && export PATH=$PATH:~/bin
k6 version

# Exportar credenciales de CloudShell para que k6 firme (SigV4)
export AWS_REGION=us-east-2
CREDS=$(curl -s "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Token"])')

# QUEUE_URL
export QUEUE_URL=$(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw queue_url)

# Correr escenario normal
cd ~/ArquitecturaCloudPoc/load
k6 run normal.js
```

Mientras corre, observar en CloudWatch (dashboard `breb-poc-dashboard`):
ApproximateNumberOfMessagesVisible (cola subiendo y bajando = buffering),
invocaciones concurrentes del consumer (dosificadas), y DLQ en 0.
