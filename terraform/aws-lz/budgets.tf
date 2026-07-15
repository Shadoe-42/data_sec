##############################################################################
# budgets.tf — AWS Landing Zone
# Per-account budgets with SNS notification. Mirrors budget_alerts.tf in
# gcp-lz: threshold-based alerts, prod is alert-only, never auto-remediated.
##############################################################################

# ── SNS Topic for Budget Notifications ───────────────────────────────────────

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.org_prefix}-budget-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "budget_alerts_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_notification_email
}

# ── Budget — Network Account ─────────────────────────────────────────────────

resource "aws_budgets_budget" "network" {
  name         = "${var.org_prefix}-network-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [aws_organizations_account.network.id]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }
}

# ── Budget — Per Workload Account ────────────────────────────────────────────
# Alert-only for every environment, including prod — same posture as the
# GCP LZ. No auto-remediation on prod; dev/staging COULD wire a Lambda off
# the SNS topic to cap spend, but that's a deliberate future decision, not
# a default.

resource "aws_budgets_budget" "workloads" {
  for_each = toset(var.environments)

  name         = "${var.org_prefix}-${each.key}-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [aws_organizations_account.workloads[each.key].id]
  }

  dynamic "notification" {
    for_each = var.budget_alert_thresholds
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }
}
