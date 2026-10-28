# ---------------------------------------------------------------------------
# Roles IAM con privilegio mínimo para cada Lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---- Rol del consumidor ---------------------------------------------------

resource "aws_iam_role" "consumer" {
  name               = "${var.name_prefix}-consumer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "consumer" {
  # Leer de la cola principal.
  statement {
    sid = "SQSConsume"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.main.arn]
  }

  # Idempotencia en DynamoDB.
  statement {
    sid = "DynamoIdempotency"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.idempotency.arn]
  }

  # Invocar el stub backend por la API de Lambda (invoke).
  statement {
    sid       = "InvokeStubFunction"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.stub.arn]
  }
}

resource "aws_iam_role_policy" "consumer" {
  name   = "${var.name_prefix}-consumer-policy"
  role   = aws_iam_role.consumer.id
  policy = data.aws_iam_policy_document.consumer.json
}

# Logs en CloudWatch + trazas X-Ray para el consumidor.
resource "aws_iam_role_policy_attachment" "consumer_logs" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "consumer_xray" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ---- Rol del stub backend -------------------------------------------------

resource "aws_iam_role" "stub" {
  name               = "${var.name_prefix}-stub-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "stub_logs" {
  role       = aws_iam_role.stub.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "stub_xray" {
  role       = aws_iam_role.stub.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
