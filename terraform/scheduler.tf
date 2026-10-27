# ---------------------------------------------------------------------------
# EventBridge Scheduler (opcional) — dispara un lote a hora fija (simula 6:00 a.m.)
# Para la PoC, la carga principal se inyecta con k6 (control fino del volumen).
# Este scheduler demuestra el disparo programado del lote real.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_scheduler ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.enable_scheduler ? 1 : 0
  name               = "${var.name_prefix}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
}

data "aws_iam_policy_document" "scheduler_send" {
  count = var.enable_scheduler ? 1 : 0
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count  = var.enable_scheduler ? 1 : 0
  name   = "${var.name_prefix}-scheduler-policy"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_send[0].json
}

resource "aws_scheduler_schedule" "batch_kickoff" {
  count = var.enable_scheduler ? 1 : 0
  name  = "${var.name_prefix}-batch-6am"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "America/Bogota"

  target {
    arn      = aws_sqs_queue.main.arn
    role_arn = aws_iam_role.scheduler[0].arn

    # Mensaje "semilla" del lote. En un escenario real el disparador invocaría
    # al productor que encola las ~20.000 ejecuciones del día.
    input = jsonencode({
      payment_id = "batch-kickoff"
      type       = "SCHEDULED_BATCH_START"
    })
  }
}
