# ---------------------------------------------------------------------------
# Empaquetado del código y funciones Lambda
# ---------------------------------------------------------------------------

# Empaqueta el consumidor desde el fuente (no requiere ./scripts/package.sh).
data "archive_file" "consumer" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/consumer"
  output_path = "${path.module}/build/consumer.zip"
}

data "archive_file" "stub" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/stub_backend"
  output_path = "${path.module}/build/stub_backend.zip"
}

# ---- Stub backend transaccional (Function URL) ----------------------------

resource "aws_lambda_function" "stub" {
  function_name = "${var.name_prefix}-stub-backend"
  role          = aws_iam_role.stub.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  filename         = data.archive_file.stub.output_path
  source_code_hash = data.archive_file.stub.output_base64sha256
  timeout       = 15
  memory_size   = 128

  tracing_config {
    mode = "Active" # X-Ray
  }

  environment {
    variables = {
      ERROR_RATE      = tostring(var.stub_error_rate)
      LATENCY_MIN_MS  = tostring(var.stub_latency_min_ms)
      LATENCY_MAX_MS  = tostring(var.stub_latency_max_ms)
    }
  }
}

resource "aws_lambda_function_url" "stub" {
  function_name      = aws_lambda_function.stub.function_name
  authorization_type = "NONE" # PoC: endpoint público; en real iría tras IAM/VPC
}

# ---- Consumidor SQS -------------------------------------------------------

resource "aws_lambda_function" "consumer" {
  function_name = "${var.name_prefix}-consumer"
  role          = aws_iam_role.consumer.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256
  timeout       = var.consumer_timeout_seconds
  memory_size   = var.consumer_memory_mb

  # Concurrencia reservada N — corazón del Queue-Based Load Leveling.
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active" # X-Ray
  }

  environment {
    variables = {
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      BACKEND_URL       = aws_lambda_function_url.stub.function_url
      MAX_RETRIES       = tostring(var.max_retries)
    }
  }
}

# Mapea la cola principal al consumidor con fallos parciales por lote.
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.consumer.arn
  batch_size                         = var.sqs_batch_size
  maximum_batching_window_in_seconds = 0
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    # No sobrepasar la concurrencia reservada con pollers de SQS.
    maximum_concurrency = var.reserved_concurrency
  }
}
