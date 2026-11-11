# ===========================================================================
# Arquitectura NUEVA (propuesta del profe): Step Functions + Map DISTRIBUIDO
#
#   Scheduler (6:00 a.m.)  →  State Machine:
#     1. Controller (Lambda): consulta/genera el dataset del día → S3 (JSONL)
#     2. Map DISTRIBUIDO: itera el dataset EN PARALELO (MaxConcurrency = N)
#          └─ Worker (Lambda): dispara el evento al core, espera respuesta,
#             idempotencia (DynamoDB), verifica estado y actualiza el pago
#     3. ResultWriter: escribe el resultado agregado a S3 (evidencia en AWS)
#
# Reemplaza la pareja "cola SQS + consumer": el Load Leveling lo da ahora la
# CONCURRENCIA del Map (MaxConcurrency), alineada al ASR (máx 10 TPS / 20.000
# en una ventana de 1 h). Reutiliza el stub backend y la tabla de idempotencia.
# ===========================================================================

# ---- Bucket S3: dataset de entrada + resultados del Map (evidencia) -------

resource "aws_s3_bucket" "data" {
  bucket        = "${var.name_prefix}-data-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = true # PoC: permite destroy limpio aunque tenga objetos
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---- Empaquetado de las Lambdas nuevas ------------------------------------

data "archive_file" "controller" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/controller"
  output_path = "${path.module}/build/controller.zip"
}

data "archive_file" "worker" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/worker"
  output_path = "${path.module}/build/worker.zip"
}

# ---- Lambda Controller (genera el dataset del día en S3) ------------------

resource "aws_lambda_function" "controller" {
  function_name    = "${var.name_prefix}-controller"
  role             = aws_iam_role.controller.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.controller.output_path
  source_code_hash = data.archive_file.controller.output_base64sha256
  timeout          = 120
  memory_size      = 512

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DATA_BUCKET   = aws_s3_bucket.data.bucket
      DEFAULT_TOTAL = tostring(var.sfn_total_payments)
    }
  }
}

# ---- Lambda Worker (procesa un pago dentro del Map distribuido) -----------

resource "aws_lambda_function" "worker" {
  function_name    = "${var.name_prefix}-worker"
  role             = aws_iam_role.worker.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = var.worker_timeout_seconds
  memory_size      = var.worker_memory_mb

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      BACKEND_FUNCTION  = aws_lambda_function.stub.function_name
      MAX_RETRIES       = tostring(var.max_retries)
    }
  }
}

# ---- Log group de la máquina de estados (evidencia/observabilidad) --------

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-pagos"
  retention_in_days = 14
}

# ---- Definición de la máquina de estados (ASL) ----------------------------

locals {
  sfn_definition = jsonencode({
    Comment = "PoC Bre-B — Ejecución de pagos programados con Map distribuido"
    StartAt = "GenerarDataset"
    States = {
      # 1) Controller: consulta/genera el dataset del día en S3.
      GenerarDataset = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.controller.arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "bucket.$" = "$.Payload.bucket"
          "key.$"    = "$.Payload.key"
          "total.$"  = "$.Payload.total"
          "run_id.$" = "$.Payload.run_id"
        }
        ResultPath = "$.dataset"
        Next       = "ProcesarPagos"
      }

      # 2) Map DISTRIBUIDO: itera el dataset en paralelo contra el core.
      ProcesarPagos = {
        Type  = "Map"
        Label = "pagos"
        ItemProcessor = {
          ProcessorConfig = {
            Mode          = "DISTRIBUTED"
            ExecutionType = "STANDARD"
          }
          StartAt = "EjecutarPago"
          States = {
            EjecutarPago = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.worker.arn
                "Payload.$"  = "$"
              }
              # Reintentos de la propia máquina de estados ante fallos transitorios
              # del worker/core (además del backoff interno del worker).
              Retry = [{
                ErrorEquals     = ["States.TaskFailed", "Lambda.TooManyRequestsException", "Lambda.ServiceException"]
                IntervalSeconds = 1
                MaxAttempts     = 3
                BackoffRate     = 2.0
              }]
              End = true
            }
          }
        }
        # Lee el dataset JSONL directamente desde S3 (ItemReader), sin cargarlo
        # entero en memoria: escala a 20.000+ ítems.
        ItemReader = {
          Resource = "arn:aws:states:::s3:getObject"
          ReaderConfig = {
            InputType = "JSONL"
          }
          Parameters = {
            "Bucket.$" = "$.dataset.bucket"
            "Key.$"    = "$.dataset.key"
          }
        }
        ItemBatcher = {
          MaxItemsPerBatch = var.sfn_item_batch_count
        }
        # CONTROL DE RITMO (reemplaza la cola): workers en paralelo = MaxConcurrency.
        MaxConcurrency             = var.sfn_max_concurrency
        ToleratedFailurePercentage = 100 # la PoC debe terminar para evidenciar fallos/DLQ-equivalente
        # Escribe el resultado agregado (éxitos/fallos por ítem) a S3 = evidencia.
        ResultWriter = {
          Resource = "arn:aws:states:::s3:putObject"
          Parameters = {
            "Bucket.$" = "$.dataset.bucket"
            "Prefix.$" = "States.Format('resultados/{}', $.dataset.run_id)"
          }
        }
        ResultPath = "$.resultado"
        End        = true
      }
    }
  })
}

resource "aws_sfn_state_machine" "pagos" {
  name     = "${var.name_prefix}-pagos"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = local.sfn_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true # X-Ray end-to-end
  }
}
