##############################################################################
# logging.tf — AWS Landing Zone
# Org-wide audit log aggregation. Mirrors logging.tf in gcp-lz:
#   queryable store  — Athena over CloudTrail-in-S3 (≈ BigQuery audit_logs)
#   cold archive     — S3 lifecycle tiering (≈ GCS Nearline/Coldline)
#
# CloudTrail organization trail captures management + data events across
# every account in the org, delivered to a single S3 bucket in the
# Log Archive account — the org can't opt out account-by-account.
##############################################################################

# ── S3 Bucket — CloudTrail Destination (Log Archive account) ────────────────

resource "aws_s3_bucket" "cloudtrail" {
  provider = aws.log_archive_account

  bucket = "${var.org_prefix}-cloudtrail-org-logs"

  # Mirrors force_destroy = false in the GCS bucket — audit logs are not
  # something an errant `terraform destroy` should be able to delete.
  lifecycle {
    prevent_destroy = true
  }

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  provider = aws.log_archive_account
  bucket   = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  provider = aws.log_archive_account
  bucket   = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
  }
}

resource "aws_kms_key" "cloudtrail" {
  provider                = aws.log_archive_account
  description             = "CMK for CloudTrail log encryption — Log Archive account."
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = local.common_tags
}

# ── Lifecycle Tiering — mirrors Nearline (30d) → Coldline (90d) → delete (7y) ─

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  provider = aws.log_archive_account
  bucket   = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA" # ≈ Nearline
    }

    transition {
      days          = 90
      storage_class = "GLACIER" # ≈ Coldline
    }

    expiration {
      days = 2555 # 7 years — same compliance retention as the GCP LZ
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  provider = aws.log_archive_account
  bucket   = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_organizations_organization.this.id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# ── Organization Trail ───────────────────────────────────────────────────────
# is_organization_trail = true means this is created once, in the management
# account, and automatically applies to every current and future member
# account — direct equivalent of include_children = true on the GCP org sink.

resource "aws_cloudtrail" "org_trail" {
  name                       = "${var.org_prefix}-org-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail.id
  is_organization_trail      = true
  is_multi_region_trail      = true
  enable_log_file_validation = true
  kms_key_id                 = aws_kms_key.cloudtrail.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Data events (S3 object-level, Lambda invocations) are opt-in because
    # of volume/cost — same deliberate scoping as the GCP LZ's
    # DATA_READ/DATA_WRITE audit config limited to BigQuery. Here it's
    # scoped to S3 buckets tagged as Snowflake external stages.
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::${var.org_prefix}-*-snowflake-stage/*"]
    }
  }

  tags = local.common_tags
}

# ── Glue Catalog + Athena — queryable compliance store ──────────────────────
# Mirrors the BigQuery audit_logs dataset: "an auditor asks a question, I
# run a query" rather than grepping raw CloudTrail JSON in S3.

resource "aws_glue_catalog_database" "audit_logs" {
  provider = aws.log_archive_account
  name     = "${replace(var.org_prefix, "-", "_")}_audit_logs"
}

resource "aws_athena_workgroup" "audit_logs" {
  provider = aws.log_archive_account
  name     = "${var.org_prefix}-audit-logs"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.cloudtrail.id}/athena-results/"
    }
  }

  tags = local.common_tags
}

##############################################################################
# Cross-Region Replication — Regulated-tier audit evidence
# Flagged in resilience_disaster_recovery.md: the CloudTrail bucket above is
# single-region. A regional S3 outage — rare, but 2017/2020 both happened —
# would mean the org's audit trail is unreadable exactly when an incident
# response or auditor request needs it most. CRR to a second region closes
# that gap. Mirrors the GCS dual-region equivalent in gcp-lz/logging.tf.
##############################################################################

resource "aws_s3_bucket" "cloudtrail_replica" {
  provider = aws.log_archive_account_secondary
  bucket   = "${var.org_prefix}-cloudtrail-org-logs-replica"

  lifecycle {
    prevent_destroy = true
  }

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "cloudtrail_replica" {
  provider = aws.log_archive_account_secondary
  bucket   = aws_s3_bucket.cloudtrail_replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Source bucket must also be versioned — CRR is a versioning-dependent
# feature. The primary bucket above had no explicit versioning resource
# before this; adding it here alongside the replica is the minimum
# prerequisite for replication to be possible at all.
resource "aws_s3_bucket_versioning" "cloudtrail" {
  provider = aws.log_archive_account
  bucket   = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_replica" {
  provider = aws.log_archive_account_secondary
  bucket   = aws_s3_bucket.cloudtrail_replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_kms_key" "cloudtrail_replica" {
  provider                = aws.log_archive_account_secondary
  description             = "CMK for CloudTrail replica bucket — secondary region. Cross-region KMS keys can't be shared, so this is a distinct key from the primary."
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = local.common_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_replica" {
  provider = aws.log_archive_account_secondary
  bucket   = aws_s3_bucket.cloudtrail_replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail_replica.arn
    }
  }
}

resource "aws_iam_role" "cloudtrail_replication" {
  provider = aws.log_archive_account
  name     = "${var.org_prefix}-cloudtrail-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cloudtrail_replication" {
  provider = aws.log_archive_account
  name     = "${var.org_prefix}-cloudtrail-replication-policy"
  role     = aws_iam_role.cloudtrail_replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = "${aws_s3_bucket.cloudtrail.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = "${aws_s3_bucket.cloudtrail_replica.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.cloudtrail.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt"]
        Resource = aws_kms_key.cloudtrail_replica.arn
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "cloudtrail" {
  provider = aws.log_archive_account
  # Replication configuration requires the source bucket's versioning to be
  # enabled first, not just requested in the same apply.
  depends_on = [aws_s3_bucket_versioning.cloudtrail]

  role   = aws_iam_role.cloudtrail_replication.arn
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "replicate-to-secondary-region"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.cloudtrail_replica.arn
      storage_class = "STANDARD_IA"

      encryption_configuration {
        replica_kms_key_id = aws_kms_key.cloudtrail_replica.arn
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}
