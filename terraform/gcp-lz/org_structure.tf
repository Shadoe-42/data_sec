##############################################################################
# org_structure.tf — GCP Landing Zone
# Folder hierarchy, projects, billing linkage, and API enablement.
#
# Folder tree:
#   organizations/ORG_ID
#   ├── bootstrap/          (Terraform state + build SA — created once manually)
#   ├── common/             (Shared services: logging, security, DNS)
#   └── environments/
#       ├── dev/
#       ├── staging/
#       └── prod/
#
# Each env folder gets:
#   - A host project   (owns the Shared VPC)
#   - A services project (workloads attach to host VPC)
##############################################################################

# ── Top-Level Folders ───────────────────────────────────────────────────────

resource "google_folder" "root" {
  for_each     = toset(["bootstrap", "common", "environments"])
  display_name = each.key
  parent       = "organizations/${var.org_id}"
}

# ── Environment Sub-Folders ─────────────────────────────────────────────────

resource "google_folder" "envs" {
  for_each     = toset(var.environments)
  display_name = each.key
  parent       = google_folder.root["environments"].name
}

# ── Common Projects ─────────────────────────────────────────────────────────

# Logging project — receives org-wide audit log sinks.
resource "google_project" "logging" {
  name            = "${var.org_prefix}-logging"
  project_id      = "${var.org_prefix}-logging"
  folder_id       = google_folder.root["common"].id
  billing_account = var.billing_account_id

  labels = local.common_labels
}

# Security project — hosts Security Command Center exports, SCC notifications.
resource "google_project" "security" {
  name            = "${var.org_prefix}-security"
  project_id      = "${var.org_prefix}-security"
  folder_id       = google_folder.root["common"].id
  billing_account = var.billing_account_id

  labels = local.common_labels
}

# ── Per-Environment: Host Project (Shared VPC owner) ────────────────────────

resource "google_project" "host" {
  for_each = toset(var.environments)

  name            = "${var.org_prefix}-${each.key}-host"
  project_id      = "${var.org_prefix}-${each.key}-host"
  folder_id       = google_folder.envs[each.key].id
  billing_account = var.billing_account_id

  labels = merge(local.common_labels, { role = "host" })
}

# ── Per-Environment: Services Project (workloads) ───────────────────────────

resource "google_project" "services" {
  for_each = toset(var.environments)

  name            = "${var.org_prefix}-${each.key}-svc"
  project_id      = "${var.org_prefix}-${each.key}-svc"
  folder_id       = google_folder.envs[each.key].id
  billing_account = var.billing_account_id

  labels = merge(local.common_labels, { role = "services" })
}

# ── API Enablement — Host Projects ──────────────────────────────────────────
# Enable required APIs on each host project.

locals {
  host_project_apis = [
    "compute.googleapis.com",           # Shared VPC, GCE
    "container.googleapis.com",         # GKE
    "servicenetworking.googleapis.com", # Private service access (Cloud SQL, etc.)
    "dns.googleapis.com",               # Cloud DNS
    "logging.googleapis.com",           # Cloud Logging
    "monitoring.googleapis.com",        # Cloud Monitoring
  ]

  # Cartesian product: environment × API
  host_api_map = {
    for pair in setproduct(var.environments, local.host_project_apis) :
    "${pair[0]}/${pair[1]}" => { env = pair[0], api = pair[1] }
  }
}

resource "google_project_service" "host_apis" {
  for_each = local.host_api_map

  project                    = google_project.host[each.value.env].project_id
  service                    = each.value.api
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ── API Enablement — Services Projects ──────────────────────────────────────

locals {
  svc_project_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "run.googleapis.com",            # Cloud Run
    "cloudfunctions.googleapis.com", # Cloud Functions
    "sqladmin.googleapis.com",       # Cloud SQL
    "redis.googleapis.com",          # Memorystore
    "pubsub.googleapis.com",         # Pub/Sub
    "secretmanager.googleapis.com",  # Secret Manager
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com", # Cloud Trace
  ]

  svc_api_map = {
    for pair in setproduct(var.environments, local.svc_project_apis) :
    "${pair[0]}/${pair[1]}" => { env = pair[0], api = pair[1] }
  }
}

resource "google_project_service" "svc_apis" {
  for_each = local.svc_api_map

  project                    = google_project.services[each.value.env].project_id
  service                    = each.value.api
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ── Outputs (used by other files) ───────────────────────────────────────────

output "env_folder_ids" {
  description = "Map of environment name → folder ID."
  value       = { for k, v in google_folder.envs : k => v.id }
}

output "host_project_ids" {
  description = "Map of environment name → host project ID."
  value       = { for k, v in google_project.host : k => v.project_id }
}

output "svc_project_ids" {
  description = "Map of environment name → services project ID."
  value       = { for k, v in google_project.services : k => v.project_id }
}
