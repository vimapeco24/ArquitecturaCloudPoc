variable "aws_region" {
  description = "Región AWS donde se despliega la PoC."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefijo para nombrar los recursos de la PoC."
  type        = string
  default     = "breb-poc"
}

# --- Comportamiento del consumidor / Queue-Based Load Leveling -------------

variable "reserved_concurrency" {
  description = "Concurrencia reservada de la Lambda consumidora (N). Dosifica el ritmo hacia el backend."
  type        = number
  default     = 20
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
