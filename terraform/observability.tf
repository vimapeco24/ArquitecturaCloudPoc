# ---------------------------------------------------------------------------
# Observabilidad — Dashboard y alarmas de CloudWatch (criterios de éxito PoC)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "poc" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Throughput — invocaciones Lambda (≥ 10 TPS)"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.consumer.function_name]
          ]
        }
      },
      {
        type = "metric"
        x    = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Latencia p95 por mensaje (≤ 2 s = 2000 ms)"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.consumer.function_name, { stat = "p95" }]
          ]
        }
      },
      {
        type = "metric"
        x    = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Profundidad de cola (backlog drenado en la ventana)"
          region = var.aws_region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.main.name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name]
          ]
        }
      },
      {
        type = "metric"
        x    = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Error rate (< 1 %) y mensajes en DLQ (= 0)"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.consumer.function_name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name]
          ]
        }
      }
    ]
  })
}

# Alarma: cualquier mensaje en la DLQ viola ASR-2 (0 pérdidas).
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name_prefix}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Hay mensajes en la DLQ: posible pérdida (viola ASR-2)."
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}

# Alarma: errores del consumidor por encima del umbral (error rate).
resource "aws_cloudwatch_metric_alarm" "consumer_errors" {
  alarm_name          = "${var.name_prefix}-consumer-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Errores del consumidor elevados (vigila error rate < 1%)."
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.consumer.function_name
  }
}

# ===========================================================================
# Observabilidad — Arquitectura Step Functions + Map distribuido
# ===========================================================================

resource "aws_cloudwatch_dashboard" "sfn" {
  dashboard_name = "${var.name_prefix}-sfn-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # --- KPIs tipo k6 (sobre el rango de tiempo visible) ---------------
      {
        type = "metric"
        x    = 0, y = 0, width = 6, height = 3
        properties = {
          title                = "Requests al core"
          region               = var.aws_region
          view                 = "singleValue"
          stat                 = "Sum"
          setPeriodToTimeRange = true
          metrics              = [["BrebPoC", "CoreCalls", "Service", "core"]]
        }
      },
      {
        type = "metric"
        x    = 6, y = 0, width = 6, height = 3
        properties = {
          title                = "Fallos HTTP/core"
          region               = var.aws_region
          view                 = "singleValue"
          stat                 = "Sum"
          setPeriodToTimeRange = true
          metrics              = [["BrebPoC", "CoreFailures", "Service", "core"]]
        }
      },
      {
        type = "metric"
        x    = 12, y = 0, width = 6, height = 3
        properties = {
          title                = "TPS promedio (rango visible)"
          region               = var.aws_region
          view                 = "singleValue"
          period               = 60
          setPeriodToTimeRange = true
          metrics = [[{ expression = "m1/PERIOD(m1)", label = "TPS", id = "e1" }],
          ["BrebPoC", "CoreCalls", "Service", "core", { id = "m1", stat = "Sum", visible = false }]]
        }
      },
      {
        type = "metric"
        x    = 18, y = 0, width = 6, height = 3
        properties = {
          title                = "Tiempo de respuesta p95 (ms)"
          region               = var.aws_region
          view                 = "singleValue"
          setPeriodToTimeRange = true
          metrics              = [["BrebPoC", "ResponseTimeMs", "Service", "core", { stat = "p95" }]]
        }
      },
      # --- Grafico principal tipo k6: TPS (izq.) + tiempo de respuesta (der.) ---
      {
        type = "metric"
        x    = 0, y = 3, width = 24, height = 9
        properties = {
          title  = "Performance overview — TPS hacia el core y tiempo de respuesta (banda ASR 10–15 TPS)"
          region = var.aws_region
          view   = "timeSeries"
          period = 10
          yAxis = {
            left  = { label = "TPS (req/s)", min = 0, max = 20 }
            right = { label = "ms", min = 0 }
          }
          annotations = {
            horizontal = [
              { label = "Máx ASR 15 TPS", value = 15, color = "#d62728" },
              { label = "Mín ASR 10 TPS", value = 10, color = "#2ca02c" }
            ]
          }
          metrics = [
            [{ expression = "calls/PERIOD(calls)", label = "Request rate (TPS)", id = "tps", color = "#f2c500" }],
            ["BrebPoC", "CoreCalls", "Service", "core", { id = "calls", stat = "Sum", visible = false }],
            [{ expression = "fails/PERIOD(fails)", label = "Failure rate (/s)", id = "fr", color = "#d62728" }],
            ["BrebPoC", "CoreFailures", "Service", "core", { id = "fails", stat = "Sum", visible = false }],
            ["BrebPoC", "ResponseTimeMs", "Service", "core", { id = "rt", stat = "p95", label = "Response time p95 (ms)", yAxis = "right", color = "#7aa7ff" }],
            ["BrebPoC", "ResponseTimeMs", "Service", "core", { id = "rta", stat = "Average", label = "Response time avg (ms)", yAxis = "right", color = "#aec7e8" }]
          ]
        }
      },
      {
        type = "metric"
        x    = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Ejecuciones de la máquina de estados (iniciadas/OK/fallidas)"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.pagos.arn],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.pagos.arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", aws_sfn_state_machine.pagos.arn]
          ]
        }
      },
      {
        type = "metric"
        x    = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Errores del worker (error rate < 1 %)"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.worker.function_name],
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.worker.function_name]
          ]
        }
      }
    ]
  })
}

# Alarma: la máquina de estados falló (ejecución del lote no completó).
resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name          = "${var.name_prefix}-sfn-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Una ejecución de la máquina de estados falló (lote no completado)."
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pagos.arn
  }
}
