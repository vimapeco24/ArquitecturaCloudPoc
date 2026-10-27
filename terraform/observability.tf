# ---------------------------------------------------------------------------
# Observabilidad — Dashboard y alarmas de CloudWatch (criterios de éxito PoC)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "poc" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0, y = 0, width = 12, height = 6
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
        type   = "metric"
        x      = 12, y = 0, width = 12, height = 6
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
        type   = "metric"
        x      = 0, y = 6, width = 12, height = 6
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
        type   = "metric"
        x      = 12, y = 6, width = 12, height = 6
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
