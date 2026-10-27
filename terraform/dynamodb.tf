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
