##############################################################################
# budget_alerts.tf — GCP Landing Zone
# Per-project billing budgets with Pub/Sub notification.
#
# Alert thresholds fire at configurable spend % (default: 50/75/90/100%).
# Pub/Sub topic → Cloud Function can auto-cap sandbox environments.
# Production environments: alert only (never auto-disable billing).
##############################################################################

# ── Pub/Sub Topic for Budget Notifications ───────────────────────────────────

resource "google_pubsub_topic" "budget_alerts" {
  project = var.bootstrap_project_id
  name    = "${var.org_prefix}-budget-alerts"
  labels  = local.common_labels
}

# ── Budget Alert — Host Projects ─────────────────────────────────────────────

resource "google_billing_budget" "host_projects" {
  for_each = toset(var.environments)

  billing_account = var.billing_account_id
  display_name    = "${var.org_prefix}-${each.key}-host-budget"

  budget_filter {
    projects = ["projects/${google_project.host[each.key].number}"]
    services = [] # empty = all services
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  # Threshold rules — one alert per threshold % defined in variables.
  dynamic "threshold_rules" {
    for_each = var.budget_alert_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_alerts.id
    schema_version                   = "1.0"
    monitoring_notification_channels = []

    # Disable billing on breach for non-prod only.
    # Set this to true in a Cloud Function for sandbox envs.
    disable_default_iam_recipients = false
  }

  depends_on = [google_project.host]
}

# ── Budget Alert — Services Projects ─────────────────────────────────────────

resource "google_billing_budget" "svc_projects" {
  for_each = toset(var.environments)

  billing_account = var.billing_account_id
  display_name    = "${var.org_prefix}-${each.key}-svc-budget"

  budget_filter {
    projects = ["projects/${google_project.services[each.key].number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.budget_alert_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    schema_version = "1.0"
  }

  depends_on = [google_project.services]
}

# ── IAM: Allow Billing API to Publish to Pub/Sub ─────────────────────────────
# The Billing service publishes budget notifications to the topic.
# This SA is Google-managed — grant it publish rights.

resource "google_pubsub_topic_iam_member" "billing_publisher" {
  project = var.bootstrap_project_id
  topic   = google_pubsub_topic.budget_alerts.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:billing-budgets-pagerduty@system.gserviceaccount.com"
}
