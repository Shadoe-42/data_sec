##############################################################################
# bootstrap_state.tf — GCP Landing Zone
# ONE-TIME MANUAL BOOTSTRAP — not part of the main workspace-driven config.
#
# Resolves TRACKING.md Open Item 8: the GCS backend bucket referenced in
# main.tf ("bucket = YOUR_ORG_PREFIX-tf-state") was previously created
# out-of-band with no versioning enabled — meaning a bad state write or
# accidental corruption had no rollback path.
#
# Usage: apply this file ONCE, using local state (comment out the "gcs"
# backend block in main.tf temporarily, or run from a throwaway directory
# with no backend configured), before ever running `terraform init` against
# the real backend. This is the standard chicken-and-egg pattern for
# self-hosted Terraform state — the bucket the backend depends on cannot be
# created by that same backend.
##############################################################################

resource "google_storage_bucket" "tf_state" {
  project                     = var.bootstrap_project_id
  name                        = "${var.org_prefix}-tf-state"
  location                    = var.primary_region
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # Keep the last 30 noncurrent (superseded) versions per object — enough
  # rollback headroom to recover from a bad apply discovered days later,
  # without unbounded storage growth from every single terraform apply.
  lifecycle_rule {
    condition {
      num_newer_versions = 30
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = local.common_labels
}

output "tf_state_bucket_name" {
  description = "Name of the bootstrapped Terraform state bucket. Use this value in main.tf's backend block after this file has been applied once."
  value       = google_storage_bucket.tf_state.name
}
