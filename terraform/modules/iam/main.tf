# ECS Task Execution Role: pull image, push logs, read secrets
data "aws_iam_policy_document" "exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.exec_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "exec_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Narrow secret read policy
data "aws_iam_policy_document" "exec_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.app_secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "exec_secrets" {
  name   = "${var.name}-exec-secrets"
  policy = data.aws_iam_policy_document.exec_secrets.json
}

resource "aws_iam_role_policy_attachment" "exec_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.exec_secrets.arn
}

# Task Role: what the app itself can do at runtime
data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = var.tags
}

# Example: app only allowed to write logs to its own log group
data "aws_iam_policy_document" "task_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${var.log_group_arn}:*"]
  }
}

resource "aws_iam_policy" "task_logs" {
  name   = "${var.name}-task-logs"
  policy = data.aws_iam_policy_document.task_logs.json
}

resource "aws_iam_role_policy_attachment" "task_logs" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_logs.arn
}