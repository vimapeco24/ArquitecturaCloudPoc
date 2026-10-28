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
- `e540f38` fix: permiso público de invocación para la Function URL del stub (corrige HTTP 403)  ← ÚLTIMO

## Problema encontrado y resuelto

**Síntoma:** todos los mensajes fallaban con `HTTP 403` en el consumer
(`"error": "backend rechazó el pago: HTTP 403"`), nunca llegaban a DynamoDB.

**Causa raíz:** la Function URL del stub tiene `authorization_type = "NONE"` pero
faltaba el `aws_lambda_permission` que autoriza la invocación pública
(`lambda:InvokeFunctionUrl`, principal `*`, `function_url_auth_type = "NONE"`).
Sin ese permiso AWS responde 403 aunque la URL exista. El handler del stub solo
devuelve 200 o 503, así que el 403 era de infraestructura, no de código.

**Fix:** se añadió `aws_lambda_permission.stub_url_public` en `terraform/lambda.tf`
(commit `e540f38`, ya en GitHub).

## DÓNDE QUEDAMOS / PRÓXIMO PASO

El fix ya está en GitHub. **Falta aplicarlo en CloudShell y verificar.**
Ejecutar en CloudShell (`~/ArquitecturaCloudPoc/terraform`):

```bash
# 1. Traer el fix y aplicar (debe crear SOLO 1 recurso: aws_lambda_permission.stub_url_public)
cd ~/ArquitecturaCloudPoc && git pull && cd terraform
terraform apply -auto-approve

# 2. Verificar que la Function URL ya responde 200 (no 403)
STUB_URL=$(terraform output -raw stub_function_url)
curl -s -w "\nHTTP %{http_code}\n" -X POST "$STUB_URL" \
  -H "Content-Type: application/json" -d '{"payment_id":"curl-ok","amount":1000}'
#   Esperado: {"status": "EXECUTED", ...}  HTTP 200

# 3. Pago de prueba por la cola + logs
QUEUE_URL=$(terraform output -raw queue_url)
aws sqs send-message --region us-east-2 --queue-url "$QUEUE_URL" \
  --message-body '{"payment_id":"demo-ok-001","amount":15000,"currency":"COP","account":"cuenta-demo"}'
sleep 12
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 2m --format short
#   Esperado en logs: {"event": "processed", "payment_id": "demo-ok-001"}

# 4. Confirmar persistencia/idempotencia en DynamoDB
aws dynamodb get-item --region us-east-2 --table-name breb-poc-idempotency \
  --key '{"payment_key":{"S":"demo-ok-001"}}' --output json
#   Esperado: "status": {"S": "DONE"}
```

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
