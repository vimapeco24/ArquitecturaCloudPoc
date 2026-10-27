# ---------------------------------------------------------------------------
# Cola principal + DLQ — patrón Queue-Based Load Leveling
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 días: tiempo para inspeccionar no procesables
}

resource "aws_sqs_queue" "main" {
  name                       = "${var.name_prefix}-queue"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = 86400 # 1 día

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Permite redrive manual desde la DLQ hacia la cola principal (reproceso tras corregir).
resource "aws_sqs_queue_redrive_allow_policy" "dlq_allow" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
