##############################################################################
# bootstrap_state.tf — AWS Landing Zone
# ONE-TIME MANUAL BOOTSTRAP — not part of the main workspace-driven config.
#
# Resolves TRACKING.md Open Item 8: the S3 backend bucket + DynamoDB lock
# table referenced in main.tf ("YOUR_ORG_PREFIX-tf-state" / "-tf-locks")
# were previously created out-of-band with no versioning on the state
# bucket — meaning a bad state write or accidental corruption had no
# rollback path.
#
# Usage: apply this file ONCE, using local state (comment out the "s3"
# backend block in main.tf temporarily, or run from a throwaway directory
# with no backend configured), before ever running `terraform init` against
# the real backend. Standard chicken-and-egg bootstrap problem — the bucket
# and table the backend depends on cannot be created by that same backend.
# Mirrors terraform/gcp-lz/bootstrap_state.tf.
##############################################################################

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.org_prefix}-tf-state"

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Keep the last 30 noncurrent (superseded) versions per object — same
# rollback headroom as the GCP bucket's num_newer_versions rule, enough to
# recover from a bad apply discovered days later without unbounded growth.
resource "aws_s3_bucket_lifecycle_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      newer_noncurrent_versions = 30
      noncurrent_days           = 1
    }
  }
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = "${var.org_prefix}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = local.common_tags
}

output "tf_state_bucket_name" {
  description = "Name of the bootstrapped Terraform state bucket. Use this value in main.tf's backend block after this file has been applied once."
  value       = aws_s3_bucket.tf_state.bucket
}

output "tf_locks_table_name" {
  description = "Name of the bootstrapped DynamoDB lock table. Use this value in main.tf's backend block after this file has been applied once."
  value       = aws_dynamodb_table.tf_locks.name
}
