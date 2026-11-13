variable "aws_region" {
  description = "Región AWS donde se despliega la PoC."
  type        = string
  default     = "us-east-2" # Ohio: región usada en el despliegue verificado de la PoC.
}

variable "name_prefix" {
  description = "Prefijo para nombrar los recursos de la PoC."
  type        = string
  default     = "breb-poc"
}

# --- Comportamiento del consumidor / Queue-Based Load Leveling -------------

variable "reserved_concurrency" {
  description = "Concurrencia RESERVADA a nivel de función (reserved_concurrent_executions). En cuentas sandbox con límite total de 10, dejar en 0 (no reservar): AWS no permite reservar todo el límite. El dosificado efectivo lo da sqs_max_concurrency. En producción, p. ej. 20."
  type        = number
  default     = 0
}

variable "sqs_max_concurrency" {
  description = "maximum_concurrency del event source mapping SQS→Lambda: nº máx. de invocaciones concurrentes que SQS dispara (control efectivo de Queue-Based Load Leveling). Mín. permitido 2. En sandbox 10 sostiene throughput alto; en producción dimensionar al backend."
  type        = number
  default     = 10
}

variable "sqs_batch_size" {
  description = "Nº de mensajes que Lambda toma por invocación desde SQS."
  type        = number
  default     = 10
}

variable "max_receive_count" {
  description = "Recepciones antes de mover un mensaje a la DLQ (redrive policy)."
  type        = number
  default     = 5
}

variable "visibility_timeout_seconds" {
  description = "Visibility timeout de la cola. Debe ser >= timeout de la Lambda."
  type        = number
  default     = 60
}

# --- Parámetros del consumidor --------------------------------------------

variable "consumer_timeout_seconds" {
  description = "Timeout de la Lambda consumidora."
  type        = number
  default     = 30
}

variable "consumer_memory_mb" {
  description = "Memoria de la Lambda consumidora."
  type        = number
  default     = 256
}

variable "max_retries" {
  description = "Reintentos de aplicación hacia el backend antes de fallar el mensaje."
  type        = number
  default     = 3
}

# --- Parámetros del stub backend ------------------------------------------

variable "stub_error_rate" {
  description = "Probabilidad de error transitorio del stub (0.05 = 5%). Escenario de fallo."
  type        = number
  default     = 0.05
}

variable "stub_latency_min_ms" {
  description = "Latencia mínima simulada del stub (ms)."
  type        = number
  default     = 50
}

variable "stub_latency_max_ms" {
  description = "Latencia máxima simulada del stub (ms)."
  type        = number
  default     = 300
}

# --- Arquitectura Step Functions + Distributed Map (PoC nueva) ------------
# Reemplaza "cola SQS + consumer" por una máquina de estados con Map distribuido.

variable "sfn_total_payments" {
  description = "Nº de pagos que el controller genera por corrida (volumen diario objetivo del ASR)."
  type        = number
  default     = 20000
}

variable "sfn_max_concurrency" {
  description = <<-EOT
    MaxConcurrency del Map DISTRIBUIDO: nº máximo de workers que corren EN PARALELO.
    Es el control que dosifica el ritmo contra el core (reemplaza el Load Leveling
    de la cola). El ASR exige procesar 20.000 pagos en una ventana de 1 h dentro de
    la banda objetivo de 10–15 TPS (tope que protege al core).

    Dimensionamiento (latencia media del core ~0.175 s; TPS ≈ concurrencia / latencia):
      - concurrencia 2 → ~11,4 TPS  → 20.000 pagos ≈ 29 min  (dentro de 10–15 TPS)
      - concurrencia 3 → ~17,1 TPS  (borde superior; usar solo si el core lo admite)
    Default 3 con tope de ritmo por token bucket (ver sfn_target_tps): el worker
    autolimita el ritmo para mantener la banda 10–15 TPS incluso con 3 en paralelo,
    y encaja en el límite de concurrencia 10 de la cuenta sandbox.
  EOT
  type        = number
  default     = 3
}

variable "sfn_target_tps" {
  description = <<-EOT
    Ritmo objetivo (TPS) hacia el core. El worker autolimita su ritmo a este valor
    mediante un token bucket distribuido en DynamoDB, manteniendo el throughput
    sostenido dentro de la banda 10–15 TPS del ASR independientemente de la
    concurrencia del Map. Default 15 (borde superior de la banda; 20.000 pagos ≈ 22 min).
  EOT
  type        = number
  default     = 15
}

variable "sfn_item_batch_count" {
  description = "Pagos por invocación del worker (ItemBatcher del Map). 1 = un pago por worker."
  type        = number
  default     = 1
}

variable "worker_timeout_seconds" {
  description = "Timeout de la Lambda worker."
  type        = number
  default     = 30
}

variable "worker_memory_mb" {
  description = "Memoria de la Lambda worker."
  type        = number
  default     = 256
}

# --- EventBridge Scheduler (opcional) -------------------------------------

variable "enable_scheduler" {
  description = "Si true, crea un EventBridge Scheduler que dispara un lote (simula 6:00 a.m.)."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "Expresión del scheduler (p.ej. cron(0 6 * * ? *) para las 6:00 a.m.)."
  type        = string
  default     = "cron(0 6 * * ? *)"
}
