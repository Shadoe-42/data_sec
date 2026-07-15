##############################################################################
# variables.tf — GCP Landing Zone
# All input variables. Sensitive values (org_id, billing_account_id) should
# be passed via environment variables or a secrets manager, not checked in.
#
#   export TF_VAR_org_id="123456789012"
#   export TF_VAR_billing_account_id="XXXXXX-XXXXXX-XXXXXX"
##############################################################################

# ── Organization ────────────────────────────────────────────────────────────

variable "org_id" {
  description = "GCP Organization ID (numeric string, e.g. '123456789012')."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.org_id))
    error_message = "org_id must be a numeric string."
  }
}

variable "org_prefix" {
  description = "Short lowercase prefix for resource naming (e.g. 'acme'). Max 8 chars."
  type        = string

  validation {
    condition     = length(var.org_prefix) <= 8 && can(regex("^[a-z][a-z0-9-]+$", var.org_prefix))
    error_message = "org_prefix must be lowercase alphanumeric, start with a letter, max 8 chars."
  }
}

variable "org_domain" {
  description = "Primary domain verified in Cloud Identity (e.g. 'example.com')."
  type        = string
}

# ── Billing ─────────────────────────────────────────────────────────────────

variable "billing_account_id" {
  description = "Billing account ID (format: XXXXXX-XXXXXX-XXXXXX)."
  type        = string
  sensitive   = true
}

# ── Bootstrap ───────────────────────────────────────────────────────────────

variable "bootstrap_project_id" {
  description = "Project ID of the bootstrap project that holds Terraform state and the Cloud Build SA."
  type        = string
}

# ── Regions ─────────────────────────────────────────────────────────────────

variable "primary_region" {
  description = "Primary GCP region for resources."
  type        = string
  default     = "us-east4"
}

variable "secondary_region" {
  description = "Secondary GCP region for HA / DR resources."
  type        = string
  default     = "us-central1"
}

# ── Network ──────────────────────────────────────────────────────────────────

variable "subnet_cidr_primary" {
  description = "Primary subnet CIDR for the shared VPC (per environment)."
  type        = string
  # Override per env in envs/*.tfvars:
  #   dev:     10.10.0.0/20
  #   staging: 10.20.0.0/20
  #   prod:    10.30.0.0/20
  default = "10.10.0.0/20"
}

variable "subnet_cidr_secondary_pods" {
  description = "Secondary CIDR range for GKE pods (alias IP range)."
  type        = string
  default     = "10.10.64.0/20"
}

variable "subnet_cidr_secondary_services" {
  description = "Secondary CIDR range for GKE services."
  type        = string
  default     = "10.10.80.0/20"
}

# ── IAM ──────────────────────────────────────────────────────────────────────

variable "ad_groups_file" {
  description = "Path to JSON file containing AD group → IAM role mappings (exported from AD team)."
  type        = string
  default     = "data/ad-groups.json"
}

# ── Budget ───────────────────────────────────────────────────────────────────

variable "budget_amount_usd" {
  description = "Monthly budget threshold in USD per project."
  type        = number
  default     = 5000
}

variable "budget_alert_thresholds" {
  description = "List of spend percentages at which budget alerts fire (0.5 = 50%)."
  type        = list(number)
  default     = [0.5, 0.75, 0.9, 1.0]
}

# ── Environments ─────────────────────────────────────────────────────────────

variable "environments" {
  description = "List of environment names that get sub-folders and projects."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}
