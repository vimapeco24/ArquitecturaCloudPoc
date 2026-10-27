# PoC Bre-B — Pagos Programados (AWS)

Prueba de concepto que valida los requisitos de arquitectura significativos (ASR) del proyecto
**Pagos Programados para Transferencias Inmediatas Bre-B (GloMo)**:

- **ASR-1 — Desempeño en la ventana de ejecución:** la arquitectura serverless orientada a
  eventos debe absorber el pico de las 6:00 a.m. procesando el lote dentro de la ventana de 60 min,
  sosteniendo **≥ 10 TPS** con **p95 ≤ 2 s**.
- **ASR-2 — Integridad (0 pérdidas / 0 duplicados):** ningún mensaje se pierde y ningún pago se
  ejecuta dos veces, incluso ante fallos transitorios del backend.

El patrón central es **Queue-Based Load Leveling**: una cola (SQS) desacopla el generador del
consumidor, y la **concurrencia reservada** de Lambda dosifica el ritmo con el que el backend
transaccional recibe solicitudes, protegiéndolo del pico.

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
aws configure            # access key, secret, región (p.ej. us-east-1)
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

```bash
# Exporta la URL de la cola (sale de terraform output)
export QUEUE_URL=$(cd terraform && terraform output -raw queue_url)
export AWS_REGION=us-east-1

# Escenario normal (2.000 mensajes)
k6 run load/normal.js

# Escenario de estrés (6.000 mensajes)
k6 run load/stress.js

# El escenario de fallo transitorio se valida con el stub en modo 5% de error
# (variable error_rate del stub, configurable en terraform.tfvars) + revisar la DLQ.
```

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
