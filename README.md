# PoC Bre-B — Pagos Programados (AWS)

Prueba de concepto que valida los requisitos de arquitectura significativos (ASR) del proyecto
**Pagos Programados para Transferencias Inmediatas Bre-B (GloMo)**:

- **ASR-1 — Desempeño en la ventana de ejecución:** la arquitectura serverless orientada a
  eventos debe absorber el pico de las 6:00 a.m. procesando el lote dentro de la ventana de 60 min,
  sosteniendo **≥ 10 TPS** con **p95 ≤ 2 s**.
- **ASR-2 — Integridad (0 pérdidas / 0 duplicados):** ningún mensaje se pierde y ningún pago se
  ejecuta dos veces, incluso ante fallos transitorios del backend.

El patrón central es **Queue-Based Load Leveling**: una cola (SQS) desacopla el generador del
consumidor, y la **concurrencia del consumidor** (concurrencia reservada de Lambda en producción,
o `maximum_concurrency` del event source mapping en la cuenta sandbox) dosifica el ritmo con el
que el backend transaccional recibe solicitudes, protegiéndolo del pico.

> **Estado:** DESPLEGADO y VERIFICADO end-to-end el 2026-10-28 en la cuenta `aftc_test`
> (`803647807230`), región **us-east-2 (Ohio)**. Diagramas de la PoC en
> `BreB_PoC_AWS.(drawio|png)` (arquitectura), `BreB_PoC_Secuencia.*` (flujo end-to-end),
> `BreB_PoC_Resultados.*` (tablero de métricas) y `BreB_PoC_Idempotencia.*` (ASR-2).

---

## Arquitectura

```
Generador de carga (k6)                 ┌──────────── Entorno de PoC en AWS ────────────┐
  │  SendMessageBatch                   │                                                │
  │  (2.000 → 6.000 msjs)               │   EventBridge Scheduler                        │
  ▼                                     │   (opcional: dispara lote, simula 6:00 a.m.)   │
Amazon SQS  ◄───────────────────────────┤        │                                       │
  │  (+ DLQ, Queue-Based Load Leveling) │        ▼                                       │
  │  consumo dosificado                 │   Amazon SQS ──► AWS Lambda consumidor          │
  ▼                                     │                  (concurrencia reservada N=20,  │
AWS Lambda consumidor                   │                   clave de idempotencia)        │
  │  concurrencia reservada = 20        │         │                 │                     │
  ├────────────────► DynamoDB           │         ▼                 ▼                     │
  │   put condicional (idempotencia)    │   Stub backend        DynamoDB                  │
  ▼                                     │   (HTTP, latencia     (idempotencia)            │
Stub backend transaccional             │    simulada + 5% err) │                         │
  (Lambda Function URL, 5% errores)     │                                                │
  │  reintentos agotados                └────────────────────────────────────────────────┘
  ▼
DLQ (mensajes no procesables)

Observabilidad: CloudWatch (throughput, p95, backlog, error rate) + X-Ray (trazas E2E)
```

## Criterios de éxito

| Métrica                | Objetivo | Fuente                                    |
|------------------------|----------|-------------------------------------------|
| Throughput sostenido   | ≥ 10 TPS | CloudWatch (invocaciones Lambda / s)      |
| Latencia p95 / mensaje | ≤ 2 s    | X-Ray / CloudWatch                        |
| % completado en ventana| ≥ 99 %   | CloudWatch (cola vaciada antes de 60 min) |
| Mensajes perdidos      | 0        | SQS enviados vs procesados + DLQ          |
| Pagos duplicados       | 0        | Verificación de idempotencia en DynamoDB  |
| Error rate             | < 1 %    | CloudWatch Logs Insights                  |

## Escenarios de prueba

| Escenario       | Carga                    | Criterio de éxito                                         |
|-----------------|--------------------------|-----------------------------------------------------------|
| Normal          | 2.000 mensajes/ventana   | ≥ 99 % procesados; p95 ≤ 2 s; error rate < 1 %            |
| Estrés (pico)   | 6.000 mensajes (3×)      | Degradación controlada; 0 perdidos; backlog drenado       |
| Fallo transitorio | 5 % de errores en stub | Reintentos con backoff; no procesables a DLQ; 0 duplicados |

---

## Estructura del repositorio

```
poc-breb-aws/
├── terraform/          IaC: SQS + DLQ, Lambda consumidor, stub backend,
│                       DynamoDB, EventBridge Scheduler, IAM, dashboard y alarmas
├── lambda/
│   ├── consumer/       Consumidor SQS: idempotencia + llamada al stub + backoff
│   └── stub_backend/   Backend simulado (latencia + 5% de errores)
├── load/               Scripts de carga k6 (normal, estrés, fallo transitorio)
├── scripts/            Helpers de empaquetado, despliegue y ejecución
└── README.md
```

---

## Requisitos previos

Las herramientas no venían instaladas en este equipo. Instálalas antes de desplegar:

```bash
# En macOS (requiere aceptar la licencia de Xcode: sudo xcodebuild -license accept)
brew install terraform awscli k6

# Credenciales AWS
aws configure            # access key, secret, región us-east-2
aws sts get-caller-identity   # debe devolver tu cuenta
```

> Si Homebrew falla con "You have not agreed to the Xcode license", ejecuta primero
> `sudo xcodebuild -license accept`.

## Despliegue

```bash
cd poc-breb-aws

# 1. Empaqueta el código de las Lambdas en .zip
./scripts/package.sh

# 2. Despliega la infraestructura
cd terraform
terraform init
terraform apply -auto-approve

# Terraform imprime las salidas: URL de la cola, nombre del dashboard, etc.
```

## Ejecución de las pruebas

La carga se inyecta con **`load/load_cli.sh`** (AWS CLI, `send-message-batch` en paralelo).
Se evaluó k6 pero se descartó por una incompatibilidad de su jslib de AWS con el runtime de
CloudShell; los scripts k6 (`load/normal.js`, `load/stress.js`, `load/fault.js`) quedan como
alternativa.

```bash
# Escenario NORMAL (2.000 mensajes)
./load/load_cli.sh 2000 normal

# Escenario de ESTRÉS / pico 6:00 a.m. (6.000 mensajes)
./load/load_cli.sh 6000 stress

# Escenario de FALLO transitorio + duplicados (valida reintentos, DLQ e idempotencia ASR-2)
# 1 de cada 25 mensajes reutiliza un payment_id previo (duplicado intencional)
./load/load_cli.sh 2000 fault 25
```

Observa en paralelo la profundidad de la cola y los logs del consumidor:

```bash
QUEUE_URL=$(cd terraform && terraform output -raw queue_url)
watch -n2 "aws sqs get-queue-attributes --region us-east-2 --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible"
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 5m --follow
```

> **Nota de implementación real:** la organización de la cuenta `aftc_test` bloquea las Lambda
> Function URLs (responden HTTP 403 con cualquier AuthType). Por eso el consumidor invoca el stub
> por la **API de Lambda** (`lambda:InvokeFunction`), no por Function URL. La URL se deja
> aprovisionada por completitud pero no se usa.

## Verificación de resultados

```bash
./scripts/verify.sh     # imprime enviados vs procesados, profundidad de DLQ e idempotencia
```

Abre el **dashboard de CloudWatch** (nombre en `terraform output dashboard_name`) para ver
throughput, latencia p95, profundidad de cola y error rate. Las trazas E2E están en **X-Ray**.

## Limpieza

```bash
cd terraform && terraform destroy -auto-approve
```
