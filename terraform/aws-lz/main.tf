##############################################################################
# main.tf — AWS Landing Zone
# Provider config, S3+DynamoDB backend, and workspace-driven locals.
# Mirrors terraform/gcp-lz/main.tf — same environments, same naming
# convention, different cloud primitives.
#
# Usage:
#   terraform workspace new dev
#   terraform workspace select dev
#   terraform init -backend-config="bucket=YOUR_ORG_PREFIX-tf-state"
#   terraform plan -var-file="envs/dev.tfvars"
#   terraform apply -var-file="envs/dev.tfvars"
#
# NOTE: This must be run from the AWS Organizations MANAGEMENT account (or a
# role delegated organization-admin permissions) — account creation, SCPs,
# and OU management are management-account-only operations.
##############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3 + DynamoDB backend — bucket/table created by the bootstrap account.
  # State files isolated per workspace:
  #   s3://YOUR_ORG_PREFIX-tf-state/lz/dev.tfstate
  #   s3://YOUR_ORG_PREFIX-tf-state/lz/staging.tfstate
  #   s3://YOUR_ORG_PREFIX-tf-state/lz/prod.tfstate
  backend "s3" {
    bucket         = "YOUR_ORG_PREFIX-tf-state" # replace at init time
    key            = "lz/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "YOUR_ORG_PREFIX-tf-locks"
    encrypt        = true
  }
}

# ── Providers ──────────────────────────────────────────────────────────────
# Management account provider — used for Organizations, SCPs, IAM Identity Center.

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      managed_by = "terraform"
      org_prefix = var.org_prefix
    }
  }
}

# Aliased provider for the Network account — resources that must be created
# inside the centralized network account (VPCs, TGW) assume a role there.
provider "aws" {
  alias  = "network_account"
  region = var.primary_region

  assume_role {
    role_arn = "arn:aws:iam::${local.network_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      managed_by = "terraform"
      org_prefix = var.org_prefix
    }
  }
}

# Aliased provider for the Log Archive account.
provider "aws" {
  alias  = "log_archive_account"
  region = var.primary_region

  assume_role {
    role_arn = "arn:aws:iam::${local.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      managed_by = "terraform"
      org_prefix = var.org_prefix
    }
  }
}

# Log Archive account, secondary region — needed because an AWS provider
# instance is pinned to one region, and the CloudTrail replica bucket in
# logging.tf must live in var.secondary_region, not var.primary_region.
provider "aws" {
  alias  = "log_archive_account_secondary"
  region = var.secondary_region

  assume_role {
    role_arn = "arn:aws:iam::${local.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      managed_by = "terraform"
      org_prefix = var.org_prefix
    }
  }
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  # terraform.workspace drives environment context — same pattern as GCP LZ.
  env = terraform.workspace == "default" ? "dev" : terraform.workspace

  prefix  = "${var.org_prefix}-${local.env}"
  is_prod = local.env == "prod"

  common_tags = {
    managed_by  = "terraform"
    environment = local.env
    org_prefix  = var.org_prefix
  }

  # Account IDs resolved after org_structure.tf creates the accounts —
  # referenced here so the aliased providers above can assume into them.
  network_account_id     = aws_organizations_account.network.id
  log_archive_account_id = aws_organizations_account.log_archive.id
}
