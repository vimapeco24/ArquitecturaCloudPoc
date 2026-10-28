# Guía para mostrar la PoC desde la Consola Web de AWS

> Para presentar/demostrar la PoC Bre-B "Pagos Programados" navegando por la consola
> (no por CLI). Pensada para proyección en pantalla.
>
> - Cuenta: **aftc_test (803647807230)**
> - Región: **US East (Ohio) · us-east-2** ← verificar arriba a la derecha SIEMPRE
> - Estado: desplegado y verificado end-to-end el 2026-10-28
> - Actualizado: 2026-10-28

---

## 0. Antes de empezar

1. Inicia sesión en la consola: https://us-east-2.console.aws.amazon.com/
2. Arriba a la derecha confirma que la región dice **Ohio / us-east-2**.
   Si no, cámbiala: todos los recursos de la PoC viven en us-east-2.
3. Ten a la mano el diagrama `BreB_PoC_AWS.png` para explicar el flujo primero.

---

## 1. Panorama — CloudWatch Dashboard (empezar aquí)

Es la mejor vista para contar la historia completa en una sola pantalla.

- Servicio: **CloudWatch** → menú izquierdo **Dashboards** → abrir **breb-poc-dashboard**
- Link directo:
  https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=breb-poc-dashboard
- Qué señalar:
  - Profundidad de la cola (mensajes visibles) → sube con la carga y baja al drenar
    = **Queue-Based Load Leveling**.
  - Invocaciones / concurrencia del consumer → dosificadas (no se dispara sin control).
  - Errores del consumer y mensajes en la DLQ (deben quedar en 0 en el caso normal).

---

## 2. La cola — Amazon SQS

- Servicio: **SQS** → **Queues**. Verás dos colas:
  - `breb-poc-queue`  (principal)
  - `breb-poc-dlq`    (Dead Letter Queue)
- Link:
  https://us-east-2.console.aws.amazon.com/sqs/v3/home?region=us-east-2#/queues
- En `breb-poc-queue` → pestaña **Monitoring**: gráficas de mensajes recibidos/eliminados.
- Para una demo manual (enviar 1 pago): botón **Send and receive messages** →
  en *Message body* pega:
  ```json
  {"payment_id":"consola-001","amount":15000,"currency":"COP","account":"cuenta-demo"}
  ```
  → **Send message**. Usa un `payment_id` nuevo cada vez.
- Mostrar la relación con la DLQ: en `breb-poc-queue` → **Dead-letter queue redrive**;
  señalar `maxReceiveCount = 5`.

---

## 3. Las Lambdas — AWS Lambda

- Servicio: **Lambda** → **Functions**. Verás:
  - `breb-poc-consumer`      (lee SQS, idempotencia, invoca el backend)
  - `breb-poc-stub-backend`  (simula el core transaccional: latencia + 5% error)
- Link:
  https://us-east-2.console.aws.amazon.com/lambda/home?region=us-east-2#/functions

### 3.1 Consumer — ver que SQS lo dispara
- Abrir `breb-poc-consumer` → pestaña **Configuration** → **Triggers**:
  se ve el disparador **SQS: breb-poc-queue** (event source mapping).
- **Configuration → Environment variables**: señalar
  `IDEMPOTENCY_TABLE`, `BACKEND_FUNCTION` (= breb-poc-stub-backend), `MAX_RETRIES`.
  (Nota: invoca el stub por API de Lambda, NO por Function URL — la org bloquea las URLs.)

### 3.2 Ver los logs (la evidencia de que procesa)
- En `breb-poc-consumer` → pestaña **Monitor** → **View CloudWatch logs**
  (o botón *Logs*). Abre el log group `/aws/lambda/breb-poc-consumer`.
- Entrar al último **Log stream** y buscar líneas como:
  ```json
  {"event": "processed", "payment_id": "consola-001"}
  ```
  Si un pago falla de forma permanente verás `process_failed`; si es duplicado,
  `duplicate_skipped`.

---

## 4. Idempotencia — Amazon DynamoDB (ASR-2: 0 duplicados)

- Servicio: **DynamoDB** → **Tables** → `breb-poc-idempotency`
- Link:
  https://us-east-2.console.aws.amazon.com/dynamodbv2/home?region=us-east-2#tables
- Botón **Explore table items**. Por cada pago procesado hay un ítem:
  - `payment_key` = el payment_id (clave de partición)
  - `status` = `DONE` (procesado) o `PROCESSING`
  - `created_at`, `done_at`, `expires_at` (TTL para limpieza)
- Mensaje clave para la demo: el `PutItem` condicional garantiza que un mismo
  `payment_id` **no se ejecuta dos veces** aunque SQS reentregue el mensaje.

---

## 5. Trazabilidad extremo a extremo — AWS X-Ray / CloudWatch Traces

- Servicio: **CloudWatch** → **X-Ray traces** → **Traces** (o **Service map**)
- Link (service map):
  https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#xray:service-map
- Se ve el grafo: **consumer → (invoke) → stub-backend** y las llamadas a DynamoDB,
  con latencias por segmento. Útil para explicar dónde se va el tiempo.

---

## 6. Alarmas — CloudWatch Alarms

- Servicio: **CloudWatch** → **All alarms**. Dos alarmas de la PoC:
  - `breb-poc-consumer-errors`  (errores del consumer)
  - `breb-poc-dlq-not-empty`    (hay mensajes en la DLQ = algo no se pudo procesar)
- Link:
  https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#alarmsV2:

---

## 7. Guion sugerido para la demostración (5–7 min)

1. Mostrar el **diagrama** (`BreB_PoC_AWS.png`) y explicar el patrón
   Queue-Based Load Leveling y la idempotencia.
2. **SQS** → enviar un pago de prueba (sección 2) con un `payment_id` nuevo.
3. **Lambda consumer → logs** (sección 3.2) → mostrar la línea `processed`.
4. **DynamoDB** (sección 4) → mostrar el ítem con `status = DONE`.
5. (Si se corrió carga k6) **CloudWatch Dashboard** (sección 1) → mostrar el pico
   de la cola llenándose y drenándose de forma controlada, y la DLQ en 0.
6. **X-Ray** (sección 5) → mostrar la traza consumer → stub → DynamoDB.

> Mensaje de cierre: ningún pago se pierde (DLQ + reintentos) y ninguno se duplica
> (idempotencia en DynamoDB), incluso bajo el pico de las 6:00 a.m.
