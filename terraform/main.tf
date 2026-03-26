terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────
# PHASE 1: VISIBILITY
# CUR → S3 → Athena
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "cur_bucket" {
  bucket        = "${var.project}-cur-reports-${var.account_id}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_policy" "cur_bucket_policy" {
  bucket = aws_s3_bucket.cur_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCURDelivery"
        Effect = "Allow"
        Principal = { Service = "billingreports.amazonaws.com" }
        Action   = ["s3:GetBucketAcl", "s3:GetBucketPolicy", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.cur_bucket.arn,
          "${aws_s3_bucket.cur_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_cur_report_definition" "finops_cur" {
  report_name                = "${var.project}-cur"
  time_unit                  = "DAILY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES", "SPLIT_COST_ALLOCATION_DATA"]
  s3_bucket                  = aws_s3_bucket.cur_bucket.bucket
  s3_region                  = var.aws_region
  s3_prefix                  = "cur"
  report_versioning          = "OVERWRITE_REPORT"
  refresh_closed_reports     = true
}

resource "aws_athena_database" "finops" {
  name   = "${replace(var.project, "-", "_")}_finops"
  bucket = aws_s3_bucket.cur_bucket.bucket
}

resource "aws_athena_workgroup" "finops" {
  name = "${var.project}-finops"
  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.cur_bucket.bucket}/athena-results/"
    }
  }
  tags = local.common_tags
}

# ─────────────────────────────────────────────
# PHASE 3: GOVERNANCE — SNS for all alerts
# ─────────────────────────────────────────────

resource "aws_sns_topic" "finops_alerts" {
  name = "${var.project}-finops-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.finops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─────────────────────────────────────────────
# PHASE 3: GOVERNANCE — AWS Budgets
# Alert at 50%, 80%, 100%
# ─────────────────────────────────────────────

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { threshold = 50, type = "FORECASTED" },
      { threshold = 80, type = "ACTUAL" },
      { threshold = 100, type = "ACTUAL" }
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_sns_topic_arns  = [aws_sns_topic.finops_alerts.arn]
    }
  }
}

# Per-environment budgets (dev/stage/prod)
resource "aws_budgets_budget" "per_env" {
  for_each     = var.env_budgets
  name         = "${var.project}-${each.key}-budget"
  budget_type  = "COST"
  limit_amount = each.value
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${each.key}"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.finops_alerts.arn]
  }
}

# ─────────────────────────────────────────────
# PHASE 3: GOVERNANCE — Cost Anomaly Detection
# ─────────────────────────────────────────────

resource "aws_ce_anomaly_monitor" "service_monitor" {
  name              = "${var.project}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alert" {
  name      = "${var.project}-anomaly-alert"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.service_monitor.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.finops_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["20"]   # alert if anomaly > $20
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}

# ─────────────────────────────────────────────
# PHASE 2: OPTIMIZATION — Lambda cleanup
# ─────────────────────────────────────────────

resource "aws_iam_role" "cleanup_lambda" {
  name = "${var.project}-cleanup-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cleanup_lambda_policy" {
  role = aws_iam_role.cleanup_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:StopInstances",
          "ec2:DescribeVolumes", "ec2:DeleteVolume",
          "ec2:DescribeSnapshots", "ec2:DeleteSnapshot",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DeleteLoadBalancer",
          "sns:Publish",
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "cleanup_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/cleanup.py"
  output_path = "${path.module}/../lambda/cleanup.zip"
}

resource "aws_lambda_function" "cleanup" {
  function_name    = "${var.project}-cleanup"
  role             = aws_iam_role.cleanup_lambda.arn
  handler          = "cleanup.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.cleanup_zip.output_path
  source_code_hash = data.archive_file.cleanup_zip.output_base64sha256
  timeout          = 300

  environment {
    variables = {
      SNS_TOPIC_ARN    = aws_sns_topic.finops_alerts.arn
      DRY_RUN          = "false"
      IDLE_CPU_PERCENT = "5"
    }
  }
  tags = local.common_tags
}

# Run cleanup every night at 11 PM UTC
resource "aws_cloudwatch_event_rule" "nightly_cleanup" {
  name                = "${var.project}-nightly-cleanup"
  schedule_expression = "cron(0 23 * * ? *)"
}

resource "aws_cloudwatch_event_target" "cleanup_target" {
  rule      = aws_cloudwatch_event_rule.nightly_cleanup.name
  target_id = "CleanupLambda"
  arn       = aws_lambda_function.cleanup.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nightly_cleanup.arn
}

# ─────────────────────────────────────────────
# LOCALS & VARIABLES
# ─────────────────────────────────────────────

locals {
  common_tags = {
    Project     = var.project
    ManagedBy   = "terraform"
    Owner       = "finops-team"
  }
}

variable "aws_region"        { default = "us-east-1" }
variable "account_id"        { description = "AWS Account ID" }
variable "project"           { default = "myapp" }
variable "alert_email"       { description = "Email for cost alerts" }
variable "monthly_budget_usd" { default = "1000" }
variable "env_budgets" {
  type    = map(string)
  default = { dev = "200", stage = "300", prod = "500" }
}
