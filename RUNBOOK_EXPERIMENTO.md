# Runbook del experimento — PoC Bre-B "Pagos Programados" (AWS)

> Paso a paso para **ejecutar y demostrar** la PoC ante los profesores, usando la
> **consola web de AWS + CloudShell**. Pensado para proyectar en pantalla.
>
> - Cuenta: **aftc_test (803647807230)**
> - Región: **US East (Ohio) · us-east-2**  ← confirmar SIEMPRE arriba a la derecha
> - Repo: https://github.com/vimapeco24/ArquitecturaCloudPoc
> - Patrón validado: **Queue-Based Load Leveling** + **idempotencia** (ASR-1 y ASR-2)

El experimento valida dos Requisitos de Arquitectura Significativos:

| ASR | Qué prueba | Criterio de éxito |
|-----|------------|-------------------|
| ASR-1 | Desempeño en la ventana de 6:00 a.m. | ≥ 10 TPS sostenido · p95 ≤ 2 s · ≥ 99 % procesado en ≤ 60 min |
| ASR-2 | Integridad (0 pérdidas / 0 duplicados) | 0 mensajes perdidos · 0 pagos duplicados · error rate < 1 % |

---

## Fase 0 — Entrar a AWS y abrir CloudShell

1. Abre el navegador en **https://us-east-2.console.aws.amazon.com/** e inicia sesión
   con el usuario de la cuenta `aftc_test`.
2. Arriba a la derecha, confirma que la región dice **Ohio / us-east-2**.
   Si dice otra, cámbiala a *US East (Ohio) us-east-2* (todos los recursos viven ahí).
3. Abre **CloudShell**: clic en el icono de terminal `>_` de la barra superior
   (o busca "CloudShell"). Espera a que aparezca el prompt `~ $` en la pestaña `us-east-2`.

> CloudShell ya viene con AWS CLI, git, python3 y jq, y resuelve las credenciales
> de tu sesión automáticamente (no hay que configurar `aws configure`).

---

## Fase 1 — Traer el código y desplegar la infraestructura

> Si la PoC YA está desplegada (lo normal para la demo), igual corre estos pasos:
> `terraform apply` será idempotente y dirá **"No changes"**, confirmando que la
> infraestructura coincide con el código.

```bash
# 1. Clonar (primera vez) o actualizar el repo
cd ~
git clone https://github.com/vimapeco24/ArquitecturaCloudPoc.git 2>/dev/null || true
cd ~/ArquitecturaCloudPoc && git pull

# 2. Desplegar / verificar la infraestructura con Terraform
cd ~/ArquitecturaCloudPoc/terraform
terraform init -input=false
terraform apply -auto-approve
```

Al terminar, Terraform imprime las **salidas** (outputs). Guárdalas a la vista:

```bash
terraform output
```

Deberías ver, entre otros:
- `queue_url`        → URL de la cola principal `breb-poc-queue`
- `dlq_url`          → URL de la DLQ `breb-poc-dlq`
- `idempotency_table`→ `breb-poc-idempotency`
- `dashboard_url`    → enlace directo al dashboard de CloudWatch

Exporta variables que usaremos en todos los comandos:

```bash
export AWS_REGION=us-east-2
export QUEUE_URL=$(terraform output -raw queue_url)
export DLQ_URL=$(terraform output -raw dlq_url)
export TABLE=$(terraform output -raw idempotency_table)
echo "Cola:  $QUEUE_URL"
echo "DLQ:   $DLQ_URL"
echo "Tabla: $TABLE"
```

---

## Fase 2 — Dejar el entorno limpio antes de medir

Para que las métricas de la demo partan de cero (y la alarma de la DLQ esté en verde),
purga ambas colas y confirma que están vacías:

```bash
# Purga la cola principal y la DLQ (solo se puede purgar 1 vez cada 60 s)
aws sqs purge-queue --region "$AWS_REGION" --queue-url "$QUEUE_URL"
aws sqs purge-queue --region "$AWS_REGION" --queue-url "$DLQ_URL"

# Espera ~60 s y confirma que ambas están en 0
sleep 60
aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages
```

---

## Fase 3 — Ejecutar los escenarios de carga

La carga se inyecta con **`load/load_cli.sh`** (AWS CLI, `send-message-batch` en
paralelo). Uso: `./load_cli.sh [TOTAL] [ESCENARIO] [DUP_EVERY]`.

> **Consejo de demo:** abre una **segunda pestaña de CloudShell** (botón `+`) y deja
> corriendo el observador de la cola (Fase 4) mientras en la primera pestaña lanzas
> la carga. Así se ve en vivo cómo la cola sube y drena.

```bash
cd ~/ArquitecturaCloudPoc/load

# --- Escenario A · NORMAL (2.000 mensajes) -> valida ASR-1 en condiciones nominales
./load_cli.sh 2000 normal

# --- Escenario B · ESTRÉS / pico 6:00 a.m. (6.000 mensajes) -> degradación controlada
./load_cli.sh 6000 stress

# --- Escenario C · FALLO + DUPLICADOS (2.000 msjs, 1 de cada 25 duplicado)
#     Valida ASR-2: reintentos con backoff, DLQ e idempotencia (0 duplicados)
./load_cli.sh 2000 fault 25
```

Cada corrida imprime `Enviados N mensajes en Ns`. Tras lanzar, espera ~1–2 min a que
el consumidor drene la cola (el dosificado `max_concurrency=2` lo hace de forma gradual).

---

## Fase 4 — Observar en vivo (segunda pestaña de CloudShell)

```bash
export AWS_REGION=us-east-2
export QUEUE_URL=$(cd ~/ArquitecturaCloudPoc/terraform && terraform output -raw queue_url)

# Profundidad de la cola: "Messages" baja a 0 al drenar; "NotVisible" = en vuelo
watch -n2 "aws sqs get-queue-attributes --region $AWS_REGION --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query Attributes --output table"
```

En otra línea (o tras parar el `watch` con Ctrl+C), sigue los logs del consumidor:

```bash
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 5m --follow
```

Busca eventos JSON:
- `{"event": "processed", ...}`        → pago ejecutado con éxito
- `{"event": "duplicate_skipped", ...}`→ duplicado omitido (idempotencia, ASR-2)
- `{"event": "process_failed", ...}`   → fallo (irá a reintento y, si persiste, a la DLQ)

---

## Fase 5 — Verificar los resultados (criterios de éxito)

Script que resume todo de una vez:

```bash
cd ~/ArquitecturaCloudPoc
./scripts/verify.sh
```

O comando a comando:

```bash
# 1) ¿Cuántos pagos se procesaron con éxito? (cuenta de "processed" en los logos)
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 15m --format short \
  | grep -c '"event": "processed"'

# 2) ¿Cuántos duplicados se omitieron? (ASR-2: deben ser los duplicados inyectados)
aws logs tail /aws/lambda/breb-poc-consumer --region us-east-2 --since 15m --format short \
  | grep -c '"event": "duplicate_skipped"'

# 3) Cola principal drenada a 0 (ASR-1)
aws sqs get-queue-attributes --region us-east-2 --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

# 4) DLQ: 0 en normal/estrés; algunos en 'fault' (mensajes no procesables tras 5 intentos)
aws sqs get-queue-attributes --region us-east-2 --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages

# 5) Pagos únicos ejecutados (nº de payment_key en DynamoDB == pagos sin duplicar)
aws dynamodb scan --table-name "$TABLE" --region us-east-2 --select COUNT \
  --query 'Count' --output text
```

Interpretación:
- **ASR-1 cumplido** si la cola llega a 0 (todo drenado) dentro de la ventana y el
  dashboard muestra throughput sostenido con p95 bajo.
- **ASR-2 cumplido** si: (enviados únicos) == (payment_key en DynamoDB), los duplicados
  aparecen como `duplicate_skipped`, y la DLQ queda en 0 (normal/estrés) o contiene
  solo los no procesables del escenario de fallo (que NO se perdieron: se inspeccionan).

---

## Fase 6 — Mostrar la evidencia por la CONSOLA WEB (para los profesores)

Sigue la guía detallada en **`GUIA_CONSOLA_AWS.md`**. Resumen del guion (5–7 min):

1. **Diagrama** `BreB_PoC_AWS.png` → explicar Queue-Based Load Leveling e idempotencia.
2. **CloudWatch → Dashboards → `breb-poc-dashboard`**
   (https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=breb-poc-dashboard)
   → señalar la cola subiendo con la inyección y drenando (Queue-Based Load Leveling),
   el throughput y p95, y la DLQ en 0.
3. **SQS → `breb-poc-queue`** → pestaña *Monitoring*; mostrar la relación con la DLQ
   (`Dead-letter queue redrive`, `maxReceiveCount = 5`).
4. **Lambda → `breb-poc-consumer` → Monitor → View CloudWatch logs** → mostrar
   líneas `processed` y `duplicate_skipped`.
5. **DynamoDB → `breb-poc-idempotency` → Explore table items** → cada `payment_key`
   aparece una sola vez con `status = DONE` (prueba de 0 duplicados, ASR-2).
6. **CloudWatch → X-Ray traces → Service map** → grafo `consumer → stub-backend →
   DynamoDB` con latencias por segmento.
7. **CloudWatch → All alarms** → `breb-poc-consumer-errors` y `breb-poc-dlq-not-empty`.

> Cierre: *"Ningún pago se pierde (DLQ + reintentos con backoff) y ninguno se duplica
> (idempotencia con PutItem condicional en DynamoDB), incluso absorbiendo el pico de
> las 6:00 a.m. mediante Queue-Based Load Leveling."*

---

## Fase 7 — (Opcional) Demo manual de 1 pago desde la consola

Para mostrar el flujo con un solo mensaje, sin CLI:

1. **SQS → `breb-poc-queue` → Send and receive messages**. En *Message body* pega
   (usa un `payment_id` NUEVO cada vez):
   ```json
   {"payment_id":"demo-profe-001","amount":15000,"currency":"COP","account_from":"000123","account_to":"000987"}
   ```
   → **Send message**.
2. En segundos, **Lambda `breb-poc-consumer` → logs** mostrará `{"event":"processed","payment_id":"demo-profe-001"}`.
3. **DynamoDB → Explore items** mostrará el ítem `demo-profe-001` con `status = DONE`.
4. Para demostrar idempotencia: envía **el mismo JSON otra vez** → en los logs verás
   `{"event":"duplicate_skipped","payment_id":"demo-profe-001"}` y en DynamoDB el ítem
   sigue siendo **uno solo** (el pago NO se ejecutó dos veces).

---

## Fase 8 — (Opcional) Limpieza / apagar la PoC

Para no dejar recursos corriendo tras la entrega:

```bash
cd ~/ArquitecturaCloudPoc/terraform
terraform destroy -auto-approve
```

> El `terraform.tfstate` vive en el home de CloudShell (persiste entre sesiones).
> Mientras no hagas `destroy`, la PoC sigue desplegada y lista para demostrar.

---

## Anexo — Solución de problemas (troubleshooting)

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| `terraform: command not found` | CloudShell no trae Terraform | Instálalo en el home: ver bloque de instalación abajo |
| `purge-queue` falla "only once every 60 seconds" | Ya purgaste hace < 1 min | Espera 60 s y reintenta |
| `No space left on device` al `git pull` | Home de CloudShell (1 GB) lleno | `git -C ~/ArquitecturaCloudPoc gc --aggressive --prune=now` |
| La cola no drena | El consumer está limitado por `max_concurrency=2` | Es intencional (dosificado). Espera; drena gradualmente |
| Logs vacíos | Aún no llegó la carga / región equivocada | Confirma `--region us-east-2` y espera unos segundos |
| El stub devuelve 403 por Function URL | La org bloquea las Function URLs | Ya resuelto: el consumer invoca por `lambda:InvokeFunction` |

Instalar Terraform en CloudShell (si no está):

```bash
cd ~ && TFV=1.9.8
curl -sLo tf.zip "https://releases.hashicorp.com/terraform/${TFV}/terraform_${TFV}_linux_amd64.zip"
unzip -o tf.zip -d ~/bin >/dev/null && rm -f tf.zip && export PATH="$HOME/bin:$PATH"
terraform version
```
