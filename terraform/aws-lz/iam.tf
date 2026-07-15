##############################################################################
# iam.tf — AWS Landing Zone
# Access control via IAM Identity Center (successor to AWS SSO), driven by
# the same AD group export pattern as iam_bindings.tf in gcp-lz — same JSON
# source of truth, different consumption model.
#
# Key difference from GCP: GCP grants IAM roles directly to a group at
# org/folder/project scope. AWS Identity Center works through Permission
# Sets — a group gets ASSIGNED a Permission Set on a specific account, and
# the Permission Set carries the actual IAM policy. One more layer of
# indirection, but it's what gives AWS federated, short-lived credentials
# per account without static keys.
##############################################################################

locals {
  ad_groups = jsondecode(file(var.ad_groups_file))

  # Flatten permission-set definitions into a keyed map.
  permission_set_map = {
    for ps in local.ad_groups.permission_sets :
    ps.name => ps
  }

  # Flatten account assignments: group + permission set + target account(s).
  assignment_map = {
    for a in local.ad_groups.assignments :
    "${a.group}/${a.permission_set}/${a.account}" => a
    if contains(concat(var.environments, ["network", "log-archive", "audit-security"]), a.account)
  }

  account_id_by_name = merge(
    { for k, v in aws_organizations_account.workloads : k => v.id },
    {
      network        = aws_organizations_account.network.id
      log-archive    = aws_organizations_account.log_archive.id
      audit-security = aws_organizations_account.audit_security.id
    }
  )
}

# ── Permission Sets ───────────────────────────────────────────────────────
# One Permission Set per role defined in the AD export. Mirrors the
# variety of GCP roles (organizationAdmin, editor, bigquery.dataEditor, etc.)
# with AWS managed policies where there's a direct equivalent.

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_set_map

  name             = each.value.name
  instance_arn     = var.identity_center_instance_arn
  description      = each.value.description
  session_duration = each.value.session_duration
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.permission_set_map

  instance_arn       = var.identity_center_instance_arn
  managed_policy_arn = each.value.managed_policy_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
}

# ── Group → Permission Set → Account Assignments ────────────────────────────
# Requires the AD group to already exist as a group in the Identity Store
# (synced via SCIM from Entra ID/Okta — same identity source referenced in
# the Snowflake guardrails doc).

data "aws_identitystore_group" "ad_groups" {
  for_each = toset([for a in local.ad_groups.assignments : a.group])

  identity_store_id = var.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.value
    }
  }
}

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.assignment_map

  instance_arn       = var.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn

  principal_id   = data.aws_identitystore_group.ad_groups[each.value.group].group_id
  principal_type = "GROUP"

  target_id   = local.account_id_by_name[each.value.account]
  target_type = "AWS_ACCOUNT"
}

# ── Org-Level Provisioning Identity ─────────────────────────────────────────
# Mirrors the Cloud Build SA org-level roles in iam_bindings.tf — the CI/CD
# identity that runs this Terraform needs scoped org permissions, not
# blanket admin. Assumed via OIDC federation from the CI provider, not a
# long-lived access key (consistent with the deny-access-key-creation SCP).

resource "aws_iam_role" "terraform_ci" {
  name = "${var.org_prefix}-terraform-ci-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.org_prefix}/*:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = local.common_tags
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "terraform_ci_org_scope" {
  name = "${var.org_prefix}-terraform-ci-org-scope"
  role = aws_iam_role.terraform_ci.id

  # Scoped tightly — provisioning-only, mirrors the specific role list
  # granted to the Cloud Build SA on the GCP side.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "organizations:CreateAccount",
        "organizations:CreateOrganizationalUnit",
        "organizations:AttachPolicy",
        "organizations:CreatePolicy",
        "ram:CreateResourceShare",
        "ram:AssociateResourceShare",
        "sso:CreatePermissionSet",
        "sso:CreateAccountAssignment",
      ]
      Resource = "*"
    }]
  })
}
