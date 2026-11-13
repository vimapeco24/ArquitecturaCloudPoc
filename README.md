# PoC Bre-B — Pagos Programados (AWS)

Prueba de concepto que valida los requisitos de arquitectura significativos (ASR) del proyecto
**Pagos Programados para Transferencias Inmediatas Bre-B (GloMo)**:

- **ASR-1 — Desempeño en la ventana de ejecución:** la arquitectura serverless orientada a
  eventos debe procesar el lote diario de **20.000 pagos** dentro de la ventana de **60 min**,
  a un ritmo sostenido dentro de la **banda de 10–15 TPS** (tope que protege al core) con
  **p95 ≤ 2 s**. A 15 TPS, 20.000 pagos se procesan en ≈ 22–24 min; a 10 TPS en ≈ 33 min,
  holgadamente dentro de la ventana.
- **ASR-2 — Integridad (0 pérdidas / 0 duplicados):** ningún mensaje se pierde y ningún pago se
  ejecuta dos veces, incluso ante fallos transitorios del backend.

## Dos arquitecturas en este repo

Este repositorio implementa **dos** materializaciones del mismo flujo, para comparar patrones:

1. **Step Functions + Map DISTRIBUIDO (arquitectura objetivo, recomendada).**
   Una máquina de estados orquesta todo: un **Controller** consulta/genera los 20.000 pagos del
   día y los deja en S3; un estado **Map distribuido** los itera **en paralelo** invocando un
   **Worker** por pago (idempotencia + llamada al core + verificación + actualización de estado).
   **No hay cola ni Lambda disparadora**: el dosificado (Load Leveling) lo dan el `MaxConcurrency`
   del Map **y un token bucket distribuido** (DynamoDB) que fija el ritmo sostenido en la banda
   **10–15 TPS**. Es lo que pide el ASR y lo que se lleva a la entrega. Archivos:
   `terraform/stepfunctions.tf`, `lambda/controller/`, `lambda/worker/`, `scripts/run_sfn.sh`,
   `scripts/verify_sfn.sh`, `sim/` (simulador determinista del dosificado),
   diagrama `BreB_PoC_SFN.(drawio|png)`.

2. **SQS + Lambda consumer (baseline, Queue-Based Load Leveling).**
   Una cola (SQS) desacopla al generador del consumidor y la **concurrencia del consumidor**
   dosifica el ritmo. Se conserva como línea base de comparación. Archivos: `terraform/sqs.tf`,
   `terraform/lambda.tf`, `lambda/consumer/`, `load/`, diagrama `BreB_PoC_AWS.(drawio|png)`.

Ambas **comparten** el stub del core (`lambda/stub_backend/`) y la tabla de idempotencia DynamoDB.

> **ASR-1 (dimensionamiento):** el objetivo es procesar **20.000 pagos** en una ventana de **1 hora**
> a un ritmo sostenido dentro de la **banda 10–15 TPS** (para proteger el core). A 15 TPS,
> 20.000 / 15 ≈ **22 min**; a 10 TPS ≈ **33 min**, dentro de la ventana. En la arquitectura de
> Step Functions el ritmo lo fijan el `MaxConcurrency` del Map (default 3) **más un token bucket
> distribuido** en DynamoDB (`sfn_target_tps`, default 15), de modo que el throughput agregado
> hacia el core se mantiene en la banda aunque corran varios workers en paralelo.

> **Validación reproducible (sin AWS):** `./scripts/validate_dosing.sh` corre un simulador
> determinista del dosificado (`sim/simulate_dosing.py`) que, con los parámetros reales del core
> (latencia 50–300 ms, 5 % de errores), reproduce las cifras que se citan en el documento:
> **20.000 pagos a 13,9 TPS sostenidos en ≈ 23,5 min (100 % dentro de la ventana de 1 h) y 0
> duplicados**. Para la corrida EN VIVO sobre AWS se usa `./scripts/run_sfn.sh` (requiere credenciales).

> **Estado:** la baseline SQS está DESPLEGADA y VERIFICADA end-to-end (2026-10-28, cuenta `aftc_test`
> `803647807230`, **us-east-2**). La arquitectura de Step Functions está **lista para desplegar**
> (`terraform validate` OK, Lambdas compiladas y probadas). Diagramas: `BreB_PoC_SFN.*` (Step
> Functions), `BreB_PoC_AWS.*` (baseline SQS), `BreB_PoC_Secuencia.*`, `BreB_PoC_Resultados.*`,
> `BreB_PoC_Idempotencia.*`.

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

| Métrica                | Objetivo   | Fuente                                    |
|------------------------|------------|-------------------------------------------|
| Throughput sostenido   | 10–15 TPS  | CloudWatch (invocaciones Worker / s)      |
| Latencia p95 / mensaje | ≤ 2 s      | X-Ray / CloudWatch                        |
| % completado en ventana| ≥ 99 %     | CloudWatch (lote terminado antes de 60 min)|
| Mensajes perdidos      | 0          | Items enviados vs resultados del Map + DLQ|
| Pagos duplicados       | 0          | Verificación de idempotencia en DynamoDB  |
| Error rate             | < 1 %      | CloudWatch Logs Insights                  |

## Escenarios de prueba

| Escenario       | Carga                    | Criterio de éxito                                         |
|-----------------|--------------------------|-----------------------------------------------------------|
| Normal          | 20.000 pagos/ventana     | ≥ 99 % procesados en ≤ 60 min; 10–15 TPS; p95 ≤ 2 s; error < 1 % |
| Conservador     | 20.000 pagos @ 10 TPS    | Mismos criterios en el borde inferior de la banda          |
| Fallo + duplicados | 5 % errores + 1/50 dup | Reintentos con backoff; no procesables a DLQ; 0 duplicados |

---

## Estructura del repositorio

```
poc-breb-aws/
├── terraform/          IaC. Arquitectura Step Functions: stepfunctions.tf (S3, controller,
│                       worker, state machine con Map distribuido). Baseline SQS: sqs.tf,
│                       lambda.tf. Compartido: dynamodb.tf (idempotencia + token bucket de
│                       ritmo), iam.tf, observability.tf (2 dashboards + alarmas),
│                       scheduler.tf (dispara la state machine), outputs.tf
├── lambda/
│   ├── controller/     Genera/consulta los 20.000 pagos del día → dataset JSONL en S3
│   ├── worker/         Procesa un pago en el Map: idempotencia + token bucket (10–15 TPS) +
│   │                   core + estado. Incluye test_handler.py (pruebas unitarias)
│   ├── consumer/       (baseline) Consumidor SQS: idempotencia + llamada al stub + backoff
│   └── stub_backend/   Core bancario simulado (latencia + 5% de errores) — compartido
├── sim/                Simulador DETERMINISTA del dosificado (simulate_dosing.py) + pruebas
│                       (test_dosing.py). Reproduce las cifras del documento sin desplegar AWS
├── load/               (baseline) Scripts de carga para la cola SQS
├── scripts/            run_sfn.sh / verify_sfn.sh / validate_dosing.sh (Step Functions) ·
│                       deploy/verify/metrics (baseline)
├── BreB_PoC_SFN.*      Diagrama de la arquitectura Step Functions + Map distribuido
├── BreB_PoC_AWS.*      Diagrama de la baseline SQS
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

## Ejecución — arquitectura Step Functions + Map distribuido (recomendada)

Despliega y dispara el lote de las 20.000 transacciones; todo queda registrado en AWS.

```bash
# (Opcional, sin AWS) Valida el dosificado 10–15 TPS / 20.000 pagos de forma reproducible
./scripts/validate_dosing.sh

cd poc-breb-aws/terraform
terraform init
terraform apply -auto-approve      # crea S3, controller, worker, state machine, IAM, dashboard

# Dispara el lote completo (20.000 pagos) y espera a que termine
cd ..
./scripts/run_sfn.sh                     # 20.000 pagos, sin duplicados
./scripts/run_sfn.sh 2000                # prueba rápida de 2.000
./scripts/run_sfn.sh 20000 50            # 20.000 con 1 de cada 50 duplicado (evidencia ASR-2)

# Verifica resultados (estado de la ejecución, 0 duplicados, manifiesto en S3)
./scripts/verify_sfn.sh <run_id>
```

**Evidencia en AWS para la entrega (todo registrado):**
- **Step Functions** → consola de la máquina de estados: historia de ejecuciones, el mapa visual
  del Map distribuido y el conteo de ítems OK/fallidos (URL en `terraform output state_machine_console_url`).
- **S3** → `s3://<data_bucket>/resultados/<run_id>/`: `manifest.json` + archivos `SUCCEEDED/FAILED`
  con el resultado por pago (salida del `ResultWriter`).
- **DynamoDB** → `breb-poc-idempotency`: un item por `payment_id` con `status=DONE` (prueba de 0 duplicados).
- **CloudWatch** → dashboard `breb-poc-sfn-dashboard` (throughput, p95, ejecuciones, errores) + logs
  de la máquina de estados + alarma `breb-poc-sfn-failed`.
- **X-Ray** → trazas end-to-end de cada ejecución.

> **Ajuste de ritmo (ASR: banda 10–15 TPS).** El ritmo sostenido lo fija el token bucket
> distribuido (`sfn_target_tps`, default `15`) y el nº de workers en paralelo lo acota
> `sfn_max_concurrency` (default `3`, que encaja en el límite de concurrencia 10 de la cuenta
> sandbox). Con `sfn_target_tps=15` el throughput se mantiene ~14 TPS (borde superior de la banda);
> bajar a `10` lo lleva al borde inferior (≈33 min). Si se amplía el límite del core, subir ambos.

> **Validación sin desplegar:** `./scripts/validate_dosing.sh` corre el simulador determinista y
> las pruebas unitarias; reproduce las mismas cifras que se citan en el documento.

---

## Ejecución — baseline SQS (Queue-Based Load Leveling)
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
