# ---------------------------------------------------------------------------
# EventBridge Scheduler (opcional) — dispara la máquina de estados a hora fija
# (simula el lote de las 6:00 a.m.). Arquitectura nueva: el scheduler inicia la
# Step Function, que genera el dataset del día y procesa los pagos con el Map
# distribuido. Deshabilitado por defecto; para la PoC se dispara a mano con
# scripts/run_sfn.sh (da control fino del volumen y el run_id de cada corrida).
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

data "aws_iam_policy_document" "scheduler_start" {
  count = var.enable_scheduler ? 1 : 0
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pagos.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count  = var.enable_scheduler ? 1 : 0
  name   = "${var.name_prefix}-scheduler-policy"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_start[0].json
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
    arn      = aws_sfn_state_machine.pagos.arn
    role_arn = aws_iam_role.scheduler[0].arn

    # Semilla del lote: el controller usará DEFAULT_TOTAL (20.000) y un run_id propio.
    input = jsonencode({
      type = "SCHEDULED_BATCH_START"
    })
  }
}
