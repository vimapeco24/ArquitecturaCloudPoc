output "queue_url" {
  description = "URL de la cola principal SQS (para inyectar carga con k6)."
  value       = aws_sqs_queue.main.id
}

output "queue_arn" {
  value = aws_sqs_queue.main.arn
}

output "dlq_url" {
  description = "URL de la DLQ (verificación de 0 pérdidas)."
  value       = aws_sqs_queue.dlq.id
}

output "consumer_function_name" {
  value = aws_lambda_function.consumer.function_name
}

output "stub_function_url" {
  description = "Endpoint HTTP del stub backend transaccional."
  value       = aws_lambda_function_url.stub.function_url
}

output "idempotency_table" {
  value = aws_dynamodb_table.idempotency.name
}

output "dashboard_name" {
  description = "Dashboard de CloudWatch con las métricas de la PoC."
  value       = aws_cloudwatch_dashboard.poc.dashboard_name
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.poc.dashboard_name}"
}
