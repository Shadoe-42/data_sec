##############################################################################
# shared_vpc.tf — GCP Landing Zone
# Shared VPC: host project owns the network, service projects attach.
# One Shared VPC per environment (dev/staging/prod).
#
# Architecture:
#   host project    → owns VPC, subnets, firewall rules, Cloud NAT, Cloud DNS
#   service project → attaches to host VPC; workloads use host subnets
#
# This centralizes network control — security team owns firewall rules,
# app teams can't create rogue networks.
##############################################################################

# ── Enable Shared VPC on Host Projects ──────────────────────────────────────

resource "google_compute_shared_vpc_host_project" "host" {
  for_each = toset(var.environments)
  project  = google_project.host[each.key].project_id

  depends_on = [google_project_service.host_apis]
}

# ── Attach Service Projects to Host VPC ─────────────────────────────────────

resource "google_compute_shared_vpc_service_project" "svc" {
  for_each        = toset(var.environments)
  host_project    = google_project.host[each.key].project_id
  service_project = google_project.services[each.key].project_id

  depends_on = [google_compute_shared_vpc_host_project.host]
}

# ── VPC Network ──────────────────────────────────────────────────────────────

resource "google_compute_network" "shared_vpc" {
  for_each = toset(var.environments)

  project                 = google_project.host[each.key].project_id
  name                    = "${var.org_prefix}-${each.key}-vpc"
  auto_create_subnetworks = false # never auto; we define subnets explicitly
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.host_apis]
}

# ── Subnets ───────────────────────────────────────────────────────────────────
# Primary subnet in primary region.
# Secondary ranges for GKE pods and services (alias IPs).

resource "google_compute_subnetwork" "primary" {
  for_each = toset(var.environments)

  project                  = google_project.host[each.key].project_id
  network                  = google_compute_network.shared_vpc[each.key].id
  name                     = "${var.org_prefix}-${each.key}-subnet-${var.primary_region}"
  region                   = var.primary_region
  ip_cidr_range            = var.subnet_cidr_primary
  private_ip_google_access = true # reach Google APIs without public IP

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = var.subnet_cidr_secondary_pods
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = var.subnet_cidr_secondary_services
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── Cloud Router ─────────────────────────────────────────────────────────────
# Required by Cloud NAT and (optionally) Cloud Interconnect BGP sessions.

resource "google_compute_router" "router" {
  for_each = toset(var.environments)

  project = google_project.host[each.key].project_id
  network = google_compute_network.shared_vpc[each.key].id
  name    = "${var.org_prefix}-${each.key}-router"
  region  = var.primary_region
}

# ── Cloud NAT ────────────────────────────────────────────────────────────────
# Outbound internet for private VMs without public IPs.
# Org policy (compute.vmExternalIpAccess = deny) forces all traffic through NAT.
#
# Cloud NAT resilience note: unlike AWS NAT Gateway, Cloud NAT is a fully
# managed regional service — Google spreads it across zones automatically,
# so there's no per-AZ NAT resource to multiply the way there is on the AWS
# side (see aws-lz/networking.tf's per-AZ NAT Gateway change for that
# equivalent hardening). The genuine prod-specific hardening knob on Cloud
# NAT is IP allocation and port sizing, not zone count: AUTO_ONLY allocation
# gives ephemeral NAT IPs that can churn on recreation, and the default port
# allocation can hit SNAT exhaustion under real production connection volume
# from a shared VPC. Prod gets static reserved NAT IPs (multiple, for
# throughput headroom) and explicit dynamic port allocation; dev/staging
# keep the simpler AUTO_ONLY default since neither carries production
# traffic volume.

locals {
  # Two static NAT IPs for prod — throughput/port headroom, and IPs that
  # survive a NAT config recreation instead of being reassigned. Keyed as
  # "prod-0", "prod-1" so it composes cleanly with for_each below.
  nat_prod_ip_keys = toset([for i in range(2) : "prod-${i}"])
}

resource "google_compute_address" "nat_prod" {
  for_each = local.nat_prod_ip_keys

  project = google_project.host["prod"].project_id
  region  = var.primary_region
  name    = "${var.org_prefix}-${each.value}-ip"
}

resource "google_compute_router_nat" "nat" {
  for_each = { for env in var.environments : env => env if env != "prod" }

  project                            = google_project.host[each.key].project_id
  router                             = google_compute_router.router[each.key].name
  region                             = var.primary_region
  name                               = "${var.org_prefix}-${each.key}-nat"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router_nat" "nat_prod" {
  project                            = google_project.host["prod"].project_id
  router                             = google_compute_router.router["prod"].name
  region                             = var.primary_region
  name                               = "${var.org_prefix}-prod-nat"
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [for k in local.nat_prod_ip_keys : google_compute_address.nat_prod[k].self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_dynamic_port_allocation     = true
  min_ports_per_vm                   = 256
  max_ports_per_vm                   = 32768

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Private DNS Zone ─────────────────────────────────────────────────────────
# Internal DNS for workloads — resolves service names without leaving VPC.

resource "google_dns_managed_zone" "private" {
  for_each = toset(var.environments)

  project     = google_project.host[each.key].project_id
  name        = "${var.org_prefix}-${each.key}-internal"
  dns_name    = "${each.key}.${var.org_domain}."
  description = "Private DNS zone for ${each.key} environment."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.shared_vpc[each.key].id
    }
  }
}

# ── Firewall Rules ────────────────────────────────────────────────────────────
# Deny all ingress by default; allow only what's needed.
# GCP default is deny-all ingress, allow-all egress.

# Allow internal VPC traffic (same subnet).
resource "google_compute_firewall" "allow_internal" {
  for_each = toset(var.environments)

  project   = google_project.host[each.key].project_id
  network   = google_compute_network.shared_vpc[each.key].id
  name      = "${var.org_prefix}-${each.key}-allow-internal"
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr_primary]
}

# Allow Google health check probes (required for load balancers).
resource "google_compute_firewall" "allow_health_checks" {
  for_each = toset(var.environments)

  project   = google_project.host[each.key].project_id
  network   = google_compute_network.shared_vpc[each.key].id
  name      = "${var.org_prefix}-${each.key}-allow-hc"
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # Google Load Balancer health check source ranges (documented, static).
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}
