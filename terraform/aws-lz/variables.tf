##############################################################################
# variables.tf — AWS Landing Zone
# Mirrors terraform/gcp-lz/variables.tf — same shape, AWS-specific values
# where the primitives differ (account emails vs. project IDs, CIDR ranges
# sized for VPC/subnet instead of GCP alias ranges).
#
# Sensitive values should be passed via environment variables, not checked in.
#   export TF_VAR_root_email_domain="example.com"
##############################################################################

# ── Organization ────────────────────────────────────────────────────────────

variable "org_prefix" {
  description = "Short lowercase prefix for resource naming (e.g. 'acme'). Max 8 chars."
  type        = string

  validation {
    condition     = length(var.org_prefix) <= 8 && can(regex("^[a-z][a-z0-9-]+$", var.org_prefix))
    error_message = "org_prefix must be lowercase alphanumeric, start with a letter, max 8 chars."
  }
}

variable "root_email_domain" {
  description = "Domain used to generate unique root email addresses for new member accounts (AWS requires a unique email per account)."
  type        = string
}

# ── IAM Identity Center ──────────────────────────────────────────────────────

variable "identity_center_instance_arn" {
  description = "ARN of the IAM Identity Center instance (must be enabled at the org level first — not creatable via this Terraform)."
  type        = string
}

variable "identity_store_id" {
  description = "Identity Store ID backing IAM Identity Center."
  type        = string
}

# ── Regions ─────────────────────────────────────────────────────────────────

variable "primary_region" {
  description = "Primary AWS region for resources."
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary AWS region for HA / DR resources."
  type        = string
  default     = "us-west-2"
}

variable "allowed_regions" {
  description = "Regions permitted by the region-restriction SCP. Mirrors gcp.resourceLocations."
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}

# ── Network ──────────────────────────────────────────────────────────────────

variable "vpc_cidr_primary" {
  description = "Primary VPC CIDR, per environment (owned by the Network account, shared via RAM)."
  type        = string
  # Override per env in envs/*.tfvars — mirrors GCP subnet CIDR layout:
  #   dev:     10.10.0.0/20
  #   staging: 10.20.0.0/20
  #   prod:    10.30.0.0/20
  default = "10.10.0.0/20"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across."
  type        = number
  default     = 2
}

# ── IAM ──────────────────────────────────────────────────────────────────────

variable "ad_groups_file" {
  description = "Path to JSON file mapping AD groups to IAM Identity Center permission sets (exported from AD team, same source as the GCP mapping)."
  type        = string
  default     = "data/ad-groups.json"
}

# ── Budget ───────────────────────────────────────────────────────────────────

variable "budget_amount_usd" {
  description = "Monthly budget threshold in USD per account."
  type        = number
  default     = 5000
}

variable "budget_alert_thresholds" {
  description = "List of spend percentages at which budget alerts fire (50 = 50%). AWS Budgets uses whole-number percentages, not fractions."
  type        = list(number)
  default     = [50, 75, 90, 100]
}

variable "budget_notification_email" {
  description = "Email address (or distribution list) that receives SNS budget alert subscriptions."
  type        = string
}

# ── Environments ─────────────────────────────────────────────────────────────

variable "environments" {
  description = "List of environment names that get member accounts under the Workloads OU."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}
