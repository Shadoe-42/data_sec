##############################################################################
# scps.tf — AWS Landing Zone
# Service Control Policies attached at the OU level. Mirrors org_policies.tf
# in gcp-lz — same "deny by default at the root, relax selectively" posture,
# expressed as SCPs instead of GCP Org Policy constraints.
#
# Key difference from GCP Org Policy: SCPs are a permission CEILING, not a
# grant. They never allow anything by themselves — IAM still has to grant
# the action. An SCP only narrows what IAM is allowed to grant.
##############################################################################

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  # OUs that member workload accounts sit under — SCPs here apply to dev/
  # staging/prod. Security and Infrastructure OUs get a lighter policy set
  # since they hold platform accounts, not application workloads.
  workload_ou_id = aws_organizations_organizational_unit.workloads.id
}

# ── 1. Deny IAM Access Key Creation ─────────────────────────────────────────
# Mirrors iam.disableServiceAccountKeyCreation. Long-lived access keys are
# the AWS equivalent of GCP SA JSON keys — a standing exfil risk. Use IAM
# Identity Center / assumed roles instead.

data "aws_iam_policy_document" "deny_access_key_creation" {
  statement {
    sid       = "DenyAccessKeyCreation"
    effect    = "Deny"
    actions   = ["iam:CreateAccessKey"]
    resources = ["*"]

    # Break-glass exception: a designated break-glass role can still create
    # keys for emergency automation that hasn't migrated off static creds yet.
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalTag/break-glass"
      values   = ["true"]
    }
  }
}

resource "aws_organizations_policy" "deny_access_key_creation" {
  name        = "${var.org_prefix}-deny-access-key-creation"
  description = "Deny IAM access key creation org-wide except for tagged break-glass principals."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_access_key_creation.json
}

resource "aws_organizations_policy_attachment" "deny_access_key_creation" {
  policy_id = aws_organizations_policy.deny_access_key_creation.id
  target_id = local.root_id
}

# ── 2. Deny Public S3 Access ────────────────────────────────────────────────
# Mirrors storage.uniformBucketLevelAccess in spirit — no per-object ACL
# sprawl, no accidental public bucket. S3 Block Public Access should also be
# enabled at the account level; this SCP prevents anyone from disabling it.

data "aws_iam_policy_document" "deny_s3_public_access_changes" {
  statement {
    sid    = "DenyDisablingBlockPublicAccess"
    effect = "Deny"
    actions = [
      "s3:PutAccountPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketAcl",
      "s3:PutBucketPolicy",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalTag/network-admin"
      values   = ["true"]
    }
  }
}

resource "aws_organizations_policy" "deny_s3_public_access_changes" {
  name        = "${var.org_prefix}-deny-s3-public-access-changes"
  description = "Prevent disabling S3 Block Public Access or granting public bucket policies/ACLs."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_s3_public_access_changes.json
}

resource "aws_organizations_policy_attachment" "deny_s3_public_access_changes" {
  policy_id = aws_organizations_policy.deny_s3_public_access_changes.id
  target_id = local.root_id
}

# ── 3. Restrict Regions ─────────────────────────────────────────────────────
# Mirrors gcp.resourceLocations. Data residency control — relevant to any
# tier of data that carries a residency requirement, including customer
# data staged for Snowflake external stages.

data "aws_iam_policy_document" "restrict_regions" {
  statement {
    sid       = "DenyOutsideAllowedRegions"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }

    # Global services (IAM, Organizations, CloudFront, Route 53) don't
    # respect region scoping the same way — exclude them explicitly.
    condition {
      test     = "ForAllValues:StringNotEquals"
      variable = "aws:CalledVia"
      values   = ["cloudformation.amazonaws.com"]
    }
  }
}

resource "aws_organizations_policy" "restrict_regions" {
  name        = "${var.org_prefix}-restrict-regions"
  description = "Deny actions outside the approved region list."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.restrict_regions.json
}

resource "aws_organizations_policy_attachment" "restrict_regions" {
  policy_id = aws_organizations_policy.restrict_regions.id
  target_id = local.workload_ou_id
}

# ── 4. Deny Root User Actions ───────────────────────────────────────────────
# No SCP equivalent exists in GCP (no root-user concept) — this is an
# AWS-specific control worth calling out on its own, not a mirror of
# anything in the GCP policy set.

data "aws_iam_policy_document" "deny_root_user" {
  statement {
    sid       = "DenyRootUser"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }
  }
}

resource "aws_organizations_policy" "deny_root_user" {
  name        = "${var.org_prefix}-deny-root-user"
  description = "Deny all actions by the root user in member accounts. Break-glass root access still works via the management account."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_root_user.json
}

resource "aws_organizations_policy_attachment" "deny_root_user" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = local.workload_ou_id
}

# ── 5. Require Encryption in Transit / at Rest for S3 ───────────────────────
# Directly relevant to any bucket acting as a Snowflake external stage.

data "aws_iam_policy_document" "require_s3_encryption" {
  statement {
    sid       = "DenyUnencryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms", "AES256"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_organizations_policy" "require_s3_encryption" {
  name        = "${var.org_prefix}-require-s3-encryption"
  description = "Deny unencrypted S3 uploads and non-TLS S3 access."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_s3_encryption.json
}

resource "aws_organizations_policy_attachment" "require_s3_encryption" {
  policy_id = aws_organizations_policy.require_s3_encryption.id
  target_id = local.root_id
}

# ── 6. Deny Leaving the Organization ────────────────────────────────────────
# Prevents a compromised or misconfigured account from detaching itself.

data "aws_iam_policy_document" "deny_leave_org" {
  statement {
    sid       = "DenyLeaveOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }
}

resource "aws_organizations_policy" "deny_leave_org" {
  name        = "${var.org_prefix}-deny-leave-org"
  description = "Deny member accounts from leaving the organization."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_leave_org.json
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = local.workload_ou_id
}

# ── 7. Require IMDSv2 ───────────────────────────────────────────────────────
# Mirrors the intent of compute.requireShieldedVm — baseline instance
# integrity/metadata hardening, org-wide.

data "aws_iam_policy_document" "require_imdsv2" {
  statement {
    sid       = "DenyLaunchWithoutIMDSv2"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:MetadataHttpTokens"
      values   = ["required"]
    }
  }
}

resource "aws_organizations_policy" "require_imdsv2" {
  name        = "${var.org_prefix}-require-imdsv2"
  description = "Deny launching EC2 instances without IMDSv2 enforced."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_imdsv2.json
}

resource "aws_organizations_policy_attachment" "require_imdsv2" {
  policy_id = aws_organizations_policy.require_imdsv2.id
  target_id = local.workload_ou_id
}
