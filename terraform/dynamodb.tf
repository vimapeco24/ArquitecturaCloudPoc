# ---------------------------------------------------------------------------
# Tabla de idempotencia — garantiza "exactamente-una-vez" (ASR-2: 0 duplicados)
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.name_prefix}-idempotency"
  billing_mode = "PAY_PER_REQUEST" # serverless, sin capacidad aprovisionada
  hash_key     = "payment_key"

  attribute {
    name = "payment_key"
    type = "S"
  }

  # Limpieza automática de registros de la PoC.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false # PoC: no requiere PITR
  }
}

# ---------------------------------------------------------------------------
# Tabla del token bucket distribuido — control de ritmo (ASR-1: banda 10–15 TPS)
#
# El Map distribuido puede correr hasta MaxConcurrency workers en paralelo. Para
# que el throughput SOSTENIDO hacia el core no se salga de la banda 10–15 TPS
# (tope que protege al backend transaccional), los workers comparten un token
# bucket almacenado en esta tabla: cada pago consume 1 token y el bucket se
# recarga a `sfn_target_tps` tokens/segundo mediante operaciones atómicas
# (UpdateItem condicional). Es el equivalente serverless/distribuido al "control
# de concurrencia" del diseño, pero expresado como límite de TASA (TPS), que es
# lo que realmente protege al core.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "rate_limiter" {
  name         = "${var.name_prefix}-rate-limiter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "bucket_id"

  attribute {
    name = "bucket_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}
