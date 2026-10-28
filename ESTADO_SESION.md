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
- `e540f38` fix: permiso público Function URL (NO funcionó — ver abajo)
- `04b1979` docs: handoff ESTADO_SESION.md
- `dd06f7a` fix: migrar Function URL del stub a AWS_IAM + SigV4 en consumer  ← ÚLTIMO

## Problema encontrado (HTTP 403) — RESUELTO en código, falta aplicar

**Síntoma:** todos los mensajes fallan con `HTTP 403` en el consumer
(`"error": "backend rechazó el pago: HTTP 403"`), nunca llegan a DynamoDB.

**Intento 1 (commit e540f38) — FALLÓ:** añadir `aws_lambda_permission` público
(`principal=*`, `AuthType=NONE`). Se aplicó pero el `curl` siguió dando 403.
La `get-policy` mostró el permiso presente y la URL con `AuthType=NONE`, y aun así 403.

**Causa raíz real:** la cuenta/organización `aftc_test` **bloquea Function URLs
públicas** (SCP o "block public access" de la org). Con `AuthType=NONE` siempre da
403, sin importar el resource-policy. No es resoluble a nivel de recurso.

**Fix definitivo (commit dd06f7a):** migrar a invocación autenticada con IAM:
- `terraform/lambda.tf`: Function URL del stub → `authorization_type = "AWS_IAM"`;
  `aws_lambda_permission.stub_url_invoke` con `principal = rol del consumer` y
  `function_url_auth_type = "AWS_IAM"`.
- `terraform/iam.tf`: statement `InvokeStubFunctionUrl` → el rol del consumer puede
  `lambda:InvokeFunctionUrl` sobre el ARN del stub.
- `lambda/consumer/handler.py`: la llamada al backend ahora se firma con **SigV4**
  (botocore `SigV4Auth` + `AWSRequest`, servicio `lambda`). Sin dependencias extra.

NOTA: con AWS_IAM la Function URL ya NO es accesible por `curl` simple (daría 403
"correcto"); solo responde a peticiones firmadas. La verificación se hace por SQS.

## DÓNDE QUEDAMOS / PRÓXIMO PASO

El fix definitivo (dd06f7a) ya está en GitHub. **Falta aplicarlo en CloudShell y verificar.**
Ejecutar en CloudShell (`~/ArquitecturaCloudPoc/terraform`):

```bash
# 1. Traer el fix y aplicar (debe modificar la Function URL + crear/actualizar permisos e IAM)
cd ~/ArquitecturaCloudPoc && git pull && cd terraform
terraform apply -auto-approve

# 2. (Opcional) Purgar mensajes viejos que rebotan con 403
QUEUE_URL=$(terraform output -raw queue_url)
aws sqs purge-queue --region us-east-2 --queue-url "$QUEUE_URL"
sleep 60   # purge tarda hasta 60s

# 3. Pago de prueba por la cola (usar payment_id NUEVO) + logs
aws sqs send-message --region us-east-2 --queue-url "$QUEUE_URL" \
  --message-body '{"payment_id":"demo-iam-001","amount":15000,"currency":"COP","account":"cuenta-demo"}'
sleep 12
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 2m --format short
#   Esperado en logs: {"event": "processed", "payment_id": "demo-iam-001"}

# 4. Confirmar persistencia/idempotencia en DynamoDB
aws dynamodb get-item --region us-east-2 --table-name breb-poc-idempotency \
  --key '{"payment_key":{"S":"demo-iam-001"}}' --output json
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
