##############################################################################
# org_policies.tf — GCP Landing Zone
# Organization policy constraints applied at the org root.
# All policies inherit down to folders and projects.
# Child resources CANNOT override a deny set here.
#
# Key principle: deny by default at org level, selectively relax at
# folder/project level where genuinely needed.
##############################################################################

# ── Locals ───────────────────────────────────────────────────────────────────

locals {
  org_parent = "organizations/${var.org_id}"
}

# ── 1. Skip Default Network Creation ────────────────────────────────────────
# Every new project auto-creates a "default" VPC with permissive firewall rules.
# We use Shared VPC — the default network is a security liability.

resource "google_org_policy_policy" "skip_default_network" {
  name   = "${local.org_parent}/policies/compute.skipDefaultNetworkCreation"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# ── 2. Restrict Resource Locations ──────────────────────────────────────────
# Prevent resources from being created outside approved regions.
# Adjust allowed_values for your compliance requirements.

resource "google_org_policy_policy" "resource_locations" {
  name   = "${local.org_parent}/policies/gcp.resourceLocations"
  parent = local.org_parent

  spec {
    rules {
      values {
        allowed_values = [
          "in:us-locations", # all US regions
          # "in:us-east4-locations",  # tighten to specific region if needed
        ]
      }
    }
  }
}

# ── 3. Restrict External IP on VMs ──────────────────────────────────────────
# Deny public IPs on compute instances. Use Cloud NAT for outbound.
# Exceptions can be granted at project level for bastion hosts.

resource "google_org_policy_policy" "no_external_ip" {
  name   = "${local.org_parent}/policies/compute.vmExternalIpAccess"
  parent = local.org_parent

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}

# ── 4. Require OS Login ──────────────────────────────────────────────────────
# Enforces IAM-based SSH auth for GCE instances.
# Replaces per-instance SSH key management — audit trail in Cloud Audit Logs.

resource "google_org_policy_policy" "require_os_login" {
  name   = "${local.org_parent}/policies/compute.requireOsLogin"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# ── 5. Restrict IAM Member Domains ──────────────────────────────────────────
# Only allow IAM bindings for identities in your verified Cloud Identity domain.
# Prevents accidental grants to personal Gmail accounts.

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "${local.org_parent}/policies/iam.allowedPolicyMemberDomains"
  parent = local.org_parent

  spec {
    rules {
      values {
        # Use the Cloud Identity customer ID (starts with "C"), not the domain string.
        # Find it: gcloud organizations describe ORG_ID --format='value(owner.directoryCustomerId)'
        allowed_values = [
          "principalSet://iam.googleapis.com/organizations/${var.org_id}",
        ]
      }
    }
  }
}

# ── 6. Disable Service Account Key Creation ──────────────────────────────────
# SA JSON keys are long-lived credentials — a significant exfil risk.
# Use Workload Identity Federation or short-lived tokens instead.

resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "${local.org_parent}/policies/iam.disableServiceAccountKeyCreation"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# ── 7. Uniform Bucket-Level Access on GCS ───────────────────────────────────
# Disables per-object ACLs on Cloud Storage.
# Enforces IAM-only access — required for VPC Service Controls compatibility.

resource "google_org_policy_policy" "uniform_bucket_access" {
  name   = "${local.org_parent}/policies/storage.uniformBucketLevelAccess"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# ── 8. Restrict Shared VPC Host Projects ────────────────────────────────────
# Only allow designated host projects to attach service projects.
# Prevents rogue Shared VPC configurations.

resource "google_org_policy_policy" "restrict_shared_vpc_host" {
  name   = "${local.org_parent}/policies/compute.restrictSharedVpcHostProjects"
  parent = local.org_parent

  spec {
    rules {
      values {
        # Allow only our known host projects.
        allowed_values = [
          for env, proj in google_project.host : "projects/${proj.project_id}"
        ]
      }
    }
  }

  depends_on = [google_project.host]
}

# ── 9. Disable Serial Port Access ───────────────────────────────────────────
# Serial console on GCE bypasses SSH key controls — disable org-wide.

resource "google_org_policy_policy" "disable_serial_port" {
  name   = "${local.org_parent}/policies/compute.disableSerialPortAccess"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# ── 10. Require Shielded VMs ─────────────────────────────────────────────────
# Shielded VMs protect against rootkits and boot-level malware.
# Secure Boot + vTPM + Integrity Monitoring.

resource "google_org_policy_policy" "require_shielded_vm" {
  name   = "${local.org_parent}/policies/compute.requireShieldedVm"
  parent = local.org_parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
