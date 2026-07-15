##############################################################################
# iam_bindings.tf — GCP Landing Zone
# IAM bindings driven by AD group → role mappings exported from Active Directory.
#
# The AD team exports group-role data as JSON (we taught them this format after
# they initially delivered LDIF, which Terraform can't parse natively).
#
# Pattern: jsondecode(file(...)) + for_each
#   — one binding resource created per entry in the JSON file
#   — no manual editing of .tf files when groups or roles change
#   — the JSON file becomes the single source of truth for access control
#
# File: data/ad-groups.json
##############################################################################

# ── Load AD Group Data ───────────────────────────────────────────────────────

locals {
  ad_groups = jsondecode(file(var.ad_groups_file))

  # ── Org-level bindings ────────────────────────────────────────────────────
  # Flatten the list into a keyed map for for_each.
  # Key format: "group/role" — must be unique.
  org_binding_map = {
    for b in local.ad_groups.org_bindings :
    "${b.group}/${b.role}" => b
  }

  # ── Folder-level bindings ─────────────────────────────────────────────────
  # Only apply bindings for the current workspace environment.
  folder_binding_map = {
    for b in local.ad_groups.folder_bindings :
    "${b.group}/${b.role}/${b.folder}" => b
    if contains(var.environments, b.folder)
  }

  # ── Project-level bindings ────────────────────────────────────────────────
  project_binding_map = {
    for b in local.ad_groups.project_bindings :
    "${b.group}/${b.role}/${b.project}" => b
    if contains(var.environments, b.project)
  }
}

# ── Org-Level IAM Bindings ───────────────────────────────────────────────────
# Applied at the organization root — inherited by all folders and projects.
# Keep this list small: only cross-cutting admin roles belong here.

resource "google_organization_iam_binding" "org_bindings" {
  for_each = local.org_binding_map

  org_id  = var.org_id
  role    = each.value.role
  members = ["group:${each.value.group}"]

  # Note: google_organization_iam_binding is AUTHORITATIVE for the role.
  # Any manually added member for this role will be removed on next apply.
  # Use google_organization_iam_member if you need additive (non-authoritative).
}

# ── Folder-Level IAM Bindings ────────────────────────────────────────────────
# Scoped to environment folders (dev/staging/prod).
# Eng teams get edit access in dev, deploy-only in staging/prod.

resource "google_folder_iam_binding" "folder_bindings" {
  for_each = local.folder_binding_map

  folder  = google_folder.envs[each.value.folder].name
  role    = each.value.role
  members = ["group:${each.value.group}"]
}

# ── Project-Level IAM Bindings ───────────────────────────────────────────────
# Fine-grained roles on service projects (e.g. BQ data editor for data team).

resource "google_project_iam_binding" "project_bindings" {
  for_each = local.project_binding_map

  project = google_project.services[each.value.project].project_id
  role    = each.value.role
  members = ["group:${each.value.group}"]
}

# ── Cloud Build Service Account — Org-Level Permissions ─────────────────────
# The SA that runs Terraform in Cloud Build needs elevated org permissions.
# Scoped tightly — only the roles it actually needs to provision LZ resources.

data "google_project" "bootstrap" {
  project_id = var.bootstrap_project_id
}

locals {
  build_sa = "serviceAccount:${data.google_project.bootstrap.number}@cloudbuild.gserviceaccount.com"
}

resource "google_organization_iam_member" "build_sa_org_roles" {
  for_each = toset([
    "roles/resourcemanager.organizationAdmin",
    "roles/resourcemanager.folderAdmin",
    "roles/resourcemanager.projectCreator",
    "roles/billing.projectManager",
    "roles/orgpolicy.policyAdmin",
    "roles/iam.organizationRoleAdmin",
    "roles/logging.configWriter",
  ])

  org_id = var.org_id
  role   = each.key
  member = local.build_sa
}

# ── Workload Identity — Example Pattern ──────────────────────────────────────
# Map a Kubernetes Service Account (K8s SA) to a GCP Service Account (GCP SA).
# The GKE pod gets GCP permissions without needing a JSON key file.

resource "google_service_account" "workload_sa" {
  for_each = toset(var.environments)

  project      = google_project.services[each.key].project_id
  account_id   = "workload-sa"
  display_name = "Workload Identity SA — ${each.key}"
  description  = "GCP SA bound to K8s SA via Workload Identity. No key files."
}

resource "google_service_account_iam_binding" "workload_identity_binding" {
  for_each = toset(var.environments)

  service_account_id = google_service_account.workload_sa[each.key].name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    # Format: principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/...
    # Simplified: the K8s namespace/SA that will impersonate this GCP SA.
    "serviceAccount:${google_project.services[each.key].project_id}.svc.id.goog[default/workload-ksa]",
  ]
}
