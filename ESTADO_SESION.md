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

## DÓNDE VAMOS EXACTAMENTE (2026-10-28 ~01:30)

Estado: PoC desplegada y VERIFICADA end-to-end (processed + DynamoDB DONE). ✅
Diagrama rehecho con ÍCONOS OFICIALES de AWS (shapes mxgraph.aws4) + PNG regenerado.
Guía de consola web creada. Todo en GitHub.

Tarea en curso: correr pruebas de carga k6 desde CloudShell. Pasos ya resueltos:
- k6 instalado en ~/bin/k6 (v0.49.0). OK.
- Espacio: home al 92% (ArquitecturaCloudPoc pesa 693M, sobre todo .git/.terraform).
  No bloquea k6. Limpieza opcional: `git gc --aggressive --prune=now`.
- Credenciales: obtenerlas SOLO con `eval "$(aws configure export-credentials --format env)"`.
  NO usar el fallback de jq/python (devuelve vacío y las pisa).

PROBLEMA ACTUAL: aunque las vars están exportadas (AKID=ASIA3W SECRET? yes TOKEN? yes),
k6 sigue diciendo "invalid AWS access key ID ... undefined". Causa: k6 no copia el
entorno a __ENV de forma fiable. SOLUCIÓN: pasar las credenciales con -e explícito:

```bash
export AWS_REGION=us-east-2
eval "$(aws configure export-credentials --format env)"
export QUEUE_URL=$(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw queue_url)
cd ~/ArquitecturaCloudPoc/load
k6 run \
  -e AWS_REGION=us-east-2 \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
  -e QUEUE_URL="$QUEUE_URL" \
  -e TOTAL=100 \
  normal.js
```

Si TOTAL=100 entra bien → repetir con -e TOTAL=2000 (corrida completa).
NOTA: las credenciales de CloudShell CADUCAN; si tras un rato k6 da 403/expired,
volver a correr el `eval` para refrescarlas.

Tras la carga: ver CloudWatch dashboard (cola llenándose/drenando), DLQ en 0.

## k6 DESCARTADO — usar load/load_cli.sh (AWS CLI) 2026-10-28 ~01:40

Se intentó 4 veces correr k6; SIEMPRE falla con "invalid AWS access key ID ...
undefined" en buildClient (producer.js:8), AUNQUE:
- las credenciales están completas (AKID len=20, SECRET len=40, TOKEN len=1236),
- se pasan con -e explícito,
- se cargan desde /tmp/awscreds.env con source.
=> No es problema de credenciales ni de entorno. Es un bug/incompatibilidad de la
jslib de AWS para k6 (https://jslib.k6.io/aws/0.12.3/sqs.js) en este runtime: el
constructor new AWSConfig({...}) rechaza las credenciales.

DECISIÓN (cambio de enfoque, no seguir con k6): inyectar la carga con el AWS CLI.
Nuevo script en el repo: **load/load_cli.sh** (usa send-message-batch, 10 msg por
llamada, en paralelo; el CLI resuelve solo las credenciales de CloudShell).

### Cómo correr la carga (CloudShell) — SIN k6

```bash
cd ~/ArquitecturaCloudPoc && git pull
cd load
# prueba rápida
./load_cli.sh 100 normal
# escenario NORMAL completo
./load_cli.sh 2000 normal
# ESTRÉS (pico)
./load_cli.sh 6000 stress
# FALLO + duplicados (valida reintentos/DLQ e idempotencia ASR-2)
./load_cli.sh 2000 fault 25
```

Observar en paralelo (otra pestaña del CloudShell o tras lanzar):
```bash
# profundidad de la cola (buffering de Queue-Based Load Leveling)
watch -n2 'aws sqs get-queue-attributes --region us-east-2 \
  --queue-url $(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw queue_url) \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible'
# logs del consumer
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 5m --follow
```

Y el dashboard: breb-poc-dashboard (ver cola subir/bajar y DLQ en 0).

OJO espacio CloudShell: home al 92%. Si "No space left on device" al git pull:
`git -C ~/ArquitecturaCloudPoc gc --aggressive --prune=now` para recuperar espacio.

## DÓNDE VAMOS EXACTAMENTE (2026-10-28 ~01:30) — CARGA NORMAL VALIDADA ✅

Resumen para retomar: la PoC está DESPLEGADA, el bug del 403 RESUELTO (invoke API
de Lambda), la carga se inyecta con `load/load_cli.sh` (k6 descartado), y el
escenario NORMAL ya pasó. Todo el código y docs están en GitHub (último trabajo
en `main`). El state de Terraform vive en CloudShell (~/ArquitecturaCloudPoc/terraform).

### Resultado escenario NORMAL (100 msg) — VERIFICADO
- `./load_cli.sh 100 normal` → 100 mensajes enviados en 15s.
- Logs consumer: **100 "processed"** (grep -c = 100). 0 fallos.
- Cola principal: ApproximateNumberOfMessages=0, NotVisible=0 (todo drenado). ✅
- => ASR-1 (desacople/drenado) y ASR-2 (0 pérdidas) OK en caso normal.

### IMPORTANTE sobre la DLQ (no confundir)
- `breb-poc-dlq` mostró **502 mensajes**, pero NO son del escenario normal.
  Son BASURA HISTÓRICA de los intentos del bug del 403 (demo-iam-*, demo-*, pay-*
  viejos) que agotaron maxReceiveCount=5 y cayeron a la DLQ antes del fix.
- Acción pendiente: PURGAR la DLQ para limpiar métricas y la alarma dlq-not-empty:
  ```bash
  aws sqs purge-queue --region us-east-2 \
    --queue-url "$(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw dlq_url)"
  ```

### EN CURSO / PRÓXIMO PASO
- Se lanzó `./load_cli.sh 2000 normal` (corrida completa). Falta ver su resultado.
  Al terminar ("Enviados 2000 mensajes en Ns"):
  ```bash
  sleep 60
  aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 10m --format short | grep -c '"event": "processed"'
  aws sqs get-queue-attributes --region us-east-2 \
    --queue-url "$(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw queue_url)" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
  ```
  Esperado: ~2000 processed, cola en 0.
- Abrir dashboard (navegador) para evidenciar Queue-Based Load Leveling:
  https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=breb-poc-dashboard
  (la cola sube con la inyección y baja al drenar; con concurrencia total=10 el
  dosificado es muy visible).

### DESPUÉS (escenarios restantes)
1. PURGAR la DLQ (ver arriba) ANTES de medir, para partir limpio.
2. `./load_cli.sh 6000 stress`  → pico; verificar 0 pérdidas y backlog drenado.
3. `./load_cli.sh 2000 fault 25` → fallo+duplicados; demostrar:
   - reintentos con backoff y algunos mensajes a la DLQ (por el 5% de error del stub),
   - 0 duplicados: los payment_id repetidos salen como "duplicate_skipped" en logs
     y en DynamoDB cada payment_key aparece una sola vez con status DONE.
4. Capturas del dashboard + conteos para la evidencia de la entrega.

### Artefactos clave en el repo (GitHub)
- BreB_PoC_AWS.drawio / .png  — diagrama con íconos AWS, ordenado, fecha 2026-10-28.
- GUIA_CONSOLA_AWS.md         — cómo demostrar la PoC por la consola web (links us-east-2).
- load/load_cli.sh           — generador de carga por AWS CLI (normal/stress/fault).
- ESTADO_SESION.md           — este archivo (handoff).
- terraform/ + lambda/       — infra y código (consumer invoca stub por lambda:InvokeFunction).

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
