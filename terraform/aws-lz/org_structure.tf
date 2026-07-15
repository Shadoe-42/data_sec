##############################################################################
# org_structure.tf — AWS Landing Zone
# OU hierarchy and member accounts. Mirrors org_structure.tf in gcp-lz —
# GCP's folder/project split becomes AWS's OU/account split. AWS's natural
# isolation boundary is the ACCOUNT, not a project inside a shared account,
# so this is a deliberate re-mapping, not a literal translation.
#
# OU tree:
#   Root
#   ├── Security OU
#   │   ├── log-archive       (mirrors {prefix}-logging project)
#   │   └── audit-security    (mirrors {prefix}-security project)
#   ├── Infrastructure OU
#   │   └── network           (mirrors the host-project role — owns the VPC)
#   └── Workloads OU
#       ├── dev
#       ├── staging
#       └── prod
##############################################################################

# ── Root Org Data ─────────────────────────────────────────────────────────
# The organization itself must already exist — Terraform doesn't bootstrap
# a brand-new AWS Organization from nothing in a way that's safe to automate
# blind. Same posture as GCP LZ assuming org_id is already provisioned.

data "aws_organizations_organization" "this" {}

# ── Top-Level OUs ────────────────────────────────────────────────────────────

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

# ── Security OU: Log Archive + Audit Accounts ───────────────────────────────

resource "aws_organizations_account" "log_archive" {
  name      = "${var.org_prefix}-log-archive"
  email     = "aws-log-archive+${var.org_prefix}@${var.root_email_domain}"
  parent_id = aws_organizations_organizational_unit.security.id

  # Member accounts should NOT leave the org on destroy by accident.
  lifecycle {
    prevent_destroy = true
  }

  tags = { role = "log-archive" }
}

resource "aws_organizations_account" "audit_security" {
  name      = "${var.org_prefix}-audit-security"
  email     = "aws-audit-security+${var.org_prefix}@${var.root_email_domain}"
  parent_id = aws_organizations_organizational_unit.security.id

  lifecycle {
    prevent_destroy = true
  }

  tags = { role = "audit-security" }
}

# ── Infrastructure OU: Network Account ───────────────────────────────────────
# Mirrors the GCP host project — owns the VPC(s), shares subnets out via RAM.

resource "aws_organizations_account" "network" {
  name      = "${var.org_prefix}-network"
  email     = "aws-network+${var.org_prefix}@${var.root_email_domain}"
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  lifecycle {
    prevent_destroy = true
  }

  tags = { role = "network" }
}

# ── Workloads OU: Per-Environment Accounts ──────────────────────────────────
# Mirrors GCP's services projects — one account per environment, attaches to
# the Network account's shared subnets rather than owning its own VPC.

resource "aws_organizations_account" "workloads" {
  for_each = toset(var.environments)

  name      = "${var.org_prefix}-${each.key}"
  email     = "aws-${each.key}+${var.org_prefix}@${var.root_email_domain}"
  parent_id = aws_organizations_organizational_unit.workloads.id

  lifecycle {
    prevent_destroy = true
  }

  tags = { role = "workload", environment = each.key }
}

# ── Outputs (used by other files) ───────────────────────────────────────────

output "log_archive_account_id" {
  description = "Account ID of the Log Archive account."
  value       = aws_organizations_account.log_archive.id
}

output "audit_security_account_id" {
  description = "Account ID of the Audit/Security account."
  value       = aws_organizations_account.audit_security.id
}

output "network_account_id" {
  description = "Account ID of the centralized Network account."
  value       = aws_organizations_account.network.id
}

output "workload_account_ids" {
  description = "Map of environment name → workload account ID."
  value       = { for k, v in aws_organizations_account.workloads : k => v.id }
}
