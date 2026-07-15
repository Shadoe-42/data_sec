##############################################################################
# logging.tf — GCP Landing Zone
# Org-wide audit log aggregation.
#
# Pattern: org-level log sink → logging project
#   BigQuery dataset  — queryable compliance archive (SQL on audit logs)
#   GCS bucket        — long-term cold storage (90-day → Nearline → Coldline)
#
# Cloud Audit Logs captured:
#   Admin Activity   — always on, can't be disabled, no charge
#   Data Access      — must be explicitly enabled; can be large/costly
#   System Event     — GCP-generated, always on
##############################################################################

# ── BigQuery Dataset (queryable compliance store) ────────────────────────────

resource "google_bigquery_dataset" "audit_logs" {
  project                    = google_project.logging.project_id
  dataset_id                 = "audit_logs"
  friendly_name              = "Org Audit Logs"
  description                = "Aggregated audit logs from org-level log sink."
  location                   = var.primary_region
  delete_contents_on_destroy = false

  # Partition expiry: 365 days. Adjust for your retention policy.
  default_partition_expiration_ms = 365 * 24 * 60 * 60 * 1000

  labels = local.common_labels
}

# ── GCS Bucket (long-term retention) ─────────────────────────────────────────
# Dual-region location, not single-region. Flagged in
# resilience_disaster_recovery.md: a single-region bucket for Regulated-tier
# audit evidence is a resilience gap specifically because it's the evidence
# an auditor or incident responder needs during exactly the kind of regional
# event that would take the bucket itself offline. GCS dual-region storage
# replicates synchronously across two regions within the same location pair
# as a bucket-level property — unlike S3, there's no separate replication
# rule/IAM role to wire up, which is a genuine GCP-side simplicity advantage
# worth naming in the room. Mirrors the AWS CRR setup in aws-lz/logging.tf.

resource "google_storage_bucket" "audit_logs" {
  project = google_project.logging.project_id
  name    = "${var.org_prefix}-audit-logs-archive"
  # Custom dual-region syntax: "<region1>+<region2>". Google only supports
  # specific pairings within the same continent — confirm var.primary_region
  # and var.secondary_region form a valid pair before apply; this is
  # reference-grade config, not yet validated against a real pairing.
  location = "${var.primary_region}+${var.secondary_region}"
  custom_placement_config {
    data_locations = [upper(var.primary_region), upper(var.secondary_region)]
  }
  force_destroy               = false
  uniform_bucket_level_access = true # required by org policy

  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition { age = 2555 } # 7 years — common compliance requirement
    action { type = "Delete" }
  }

  labels = local.common_labels
}

# ── Org-Level Log Sink → BigQuery ────────────────────────────────────────────
# Captures Admin Activity logs from every project in the org.
# The sink writer SA gets bigquery.dataEditor on the dataset (below).

resource "google_logging_organization_sink" "audit_bq" {
  name             = "${var.org_prefix}-audit-sink-bq"
  org_id           = var.org_id
  include_children = true # captures logs from all projects under the org

  destination = "bigquery.googleapis.com/projects/${google_project.logging.project_id}/datasets/${google_bigquery_dataset.audit_logs.dataset_id}"

  # Filter: Admin Activity only. Remove filter to include Data Access (high volume).
  filter = "logName:\"cloudaudit.googleapis.com%2Factivity\""

  bigquery_options {
    use_partitioned_tables = true # partition by date for cost-efficient queries
  }
}

# ── Org-Level Log Sink → GCS ─────────────────────────────────────────────────
# All audit log types → cold storage for long-term compliance.

resource "google_logging_organization_sink" "audit_gcs" {
  name             = "${var.org_prefix}-audit-sink-gcs"
  org_id           = var.org_id
  include_children = true

  destination = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"

  filter = "logName:(\"cloudaudit.googleapis.com%2Factivity\" OR \"cloudaudit.googleapis.com%2Fdata_access\")"
}

# ── Grant Sink Writers IAM on Destinations ───────────────────────────────────
# Each sink creates a service account (writer_identity) that must be granted
# write access to the destination. GCP creates the SA; we grant the role.

resource "google_bigquery_dataset_iam_member" "sink_bq_writer" {
  project    = google_project.logging.project_id
  dataset_id = google_bigquery_dataset.audit_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_organization_sink.audit_bq.writer_identity
}

resource "google_storage_bucket_iam_member" "sink_gcs_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.audit_gcs.writer_identity
}

# ── Data Access Audit Log Config ─────────────────────────────────────────────
# Explicitly enable Data Access logs for high-value services.
# Disabled by default because they generate significant volume (and cost).

resource "google_organization_iam_audit_config" "data_access" {
  org_id = var.org_id

  # Enable for BigQuery (most important for data governance).
  service = "bigquery.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
