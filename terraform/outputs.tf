output "queue_url" {
  description = "URL de la cola principal SQS (para inyectar carga con load/load_cli.sh)."
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

# --- Arquitectura Step Functions + Map distribuido -------------------------

output "state_machine_arn" {
  description = "ARN de la máquina de estados de pagos programados."
  value       = aws_sfn_state_machine.pagos.arn
}

output "state_machine_name" {
  value = aws_sfn_state_machine.pagos.name
}

output "data_bucket" {
  description = "Bucket S3 con el dataset de entrada y los resultados del Map (evidencia)."
  value       = aws_s3_bucket.data.bucket
}

output "controller_function_name" {
  value = aws_lambda_function.controller.function_name
}

output "worker_function_name" {
  value = aws_lambda_function.worker.function_name
}

output "state_machine_console_url" {
  description = "Consola de Step Functions (historia de ejecuciones = evidencia en AWS)."
  value       = "https://${var.aws_region}.console.aws.amazon.com/states/home?region=${var.aws_region}#/statemachines/view/${aws_sfn_state_machine.pagos.arn}"
}
