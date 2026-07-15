##############################################################################
# main.tf — GCP Landing Zone
# Provider config, GCS backend, and workspace-driven locals.
#
# Usage:
#   terraform workspace new dev
#   terraform workspace select dev
#   terraform init -backend-config="bucket=YOUR_ORG_PREFIX-tf-state"
#   terraform plan -var-file="envs/dev.tfvars"
#   terraform apply -var-file="envs/dev.tfvars"
##############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # GCS backend — bucket created by bootstrap project (see org_structure.tf).
  # State files are isolated per workspace:
  #   gs://YOUR_ORG_PREFIX-tf-state/lz/dev.tfstate
  #   gs://YOUR_ORG_PREFIX-tf-state/lz/staging.tfstate
  #   gs://YOUR_ORG_PREFIX-tf-state/lz/prod.tfstate
  backend "gcs" {
    bucket = "YOUR_ORG_PREFIX-tf-state" # replace at init time
    prefix = "lz"
  }
}

# ── Providers ──────────────────────────────────────────────────────────────

provider "google" {
  # Credentials: use Application Default Credentials (ADC) in CI/CD.
  # Cloud Build service account must have org-level roles:
  #   roles/resourcemanager.organizationAdmin
  #   roles/billing.user
  #   roles/iam.organizationRoleAdmin
  project = var.bootstrap_project_id
  region  = var.primary_region
}

provider "google-beta" {
  project = var.bootstrap_project_id
  region  = var.primary_region
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  # terraform.workspace drives environment context.
  # Valid values: dev | staging | prod
  # Default workspace maps to dev to avoid accidents.
  env = terraform.workspace == "default" ? "dev" : terraform.workspace

  # Short prefix for all resource names — keeps things consistent.
  prefix = "${var.org_prefix}-${local.env}"

  # Environments that get a full prod-grade config (stricter policies, HA).
  is_prod = local.env == "prod"

  # Common labels applied to all resources.
  common_labels = {
    managed_by  = "terraform"
    environment = local.env
    org_prefix  = var.org_prefix
  }
}
