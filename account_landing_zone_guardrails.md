# Account Landing Zone Guardrails
*The infrastructure layer underneath the Snowflake control plane — AWS + GCP | July 2026*
*Diagrams: `gcp_landing_zone_hld.svg` / `aws_landing_zone_hld.svg`*

---

## Purpose

The [Snowflake data security guardrails doc](./snowflake_data_security_guardrails.md) covers what Snowflake itself enforces — RBAC/ABAC, masking, Tri-Secret Secure, Horizon, Cortex agent controls. None of that happens in a vacuum. Snowflake's private connectivity endpoint has to land in *something* — a VPC, a subnet, a project or account with its own IAM boundary, its own org policies, its own audit logging. That's the landing zone: the account-level guardrails that exist whether or not Snowflake is even in the picture, and that everything else — including the Snowflake integration points — attaches to.

This is the "traditional HLD" layer: org → folders/OUs → projects/accounts → network → IAM, in the style of a hyperscaler reference landing zone. Both sides below are grounded in actual working Terraform (`terraform/gcp-lz/` and `terraform/aws-lz/`), not invented examples — every control described here is a real resource in one of those two codebases, and `terraform validate` passes clean on both. Native parity: the two aren't a lift-and-shift of each other — each uses its cloud's native isolation primitive (GCP project, AWS account) — but they reach parity on every control that matters, which is what the mapping table at the end of this doc is for.

---

## GCP Landing Zone (built)

### Resource Hierarchy

```
organizations/ORG_ID
├── bootstrap/              Terraform state bucket + Cloud Build service account
├── common/
│   ├── {prefix}-logging    Org-wide audit log sinks (BigQuery + GCS)
│   └── {prefix}-security   Security Command Center exports/notifications
└── environments/
    ├── dev/
    │   ├── {prefix}-dev-host    Shared VPC host — owns network, firewall, NAT, DNS
    │   └── {prefix}-dev-svc     Workloads attach here; no network of their own
    ├── staging/  (same host/svc pattern)
    └── prod/     (same host/svc pattern)
```

**Why Shared VPC, not VPC-per-project:** the host project owns the network — subnets, firewall rules, Cloud NAT, Cloud DNS. Service projects attach to it but cannot create their own networks. This centralizes network control with the platform/security team; app teams get compute and IAM, not network authority. It also means there's exactly one network per environment to reason about when someone asks "where can this data actually go."

### Network

- One Shared VPC per environment, `auto_create_subnetworks = false` — subnets are explicit, never implicit
- Primary subnet per environment with secondary IP ranges reserved for GKE pods/services (alias IPs)
- `private_ip_google_access = true` — workloads reach Google APIs (including Cloud Storage, which matters for Snowflake external stages) without a public IP
- Cloud NAT for outbound — enforced by org policy denying external IPs on VMs (below), so NAT is the only egress path. Cloud NAT is a fully managed regional service, already spread across zones by Google — there's no AWS-style per-AZ NAT resource to add for prod. The equivalent prod-specific hardening is static reserved NAT IPs (avoiding ephemeral IP churn) plus explicit dynamic port allocation sized for production connection volume, instead of the `AUTO_ONLY` default dev/staging use (`shared_vpc.tf`)
- Private DNS zone per environment — internal service resolution never leaves the VPC
- Firewall: deny-all ingress by default (GCP default), explicit allow rules only for internal VPC traffic and Google Cloud Load Balancer health check ranges
- VPC Flow Logs enabled at 5-second aggregation, 50% sampling, full metadata — this is what actually shows up in an incident investigation

### Org Policy Constraints (deny-by-default at the root)

| Policy | Effect | Why it matters for the Snowflake integration |
|--------|--------|------------------------------------------------|
| `compute.skipDefaultNetworkCreation` | No auto-created default VPC on new projects | Removes the most common accidental-exposure path |
| `compute.vmExternalIpAccess` | Deny public IPs on VMs org-wide | Forces all egress through Cloud NAT — no workload can reach the internet directly, including anything moving data toward an external stage |
| `iam.disableServiceAccountKeyCreation` | No long-lived SA JSON keys | Storage Integration objects (how Snowflake authenticates to GCS) use short-lived, role-assumption-based access instead — this policy is *why* that pattern is enforced, not just recommended |
| `storage.uniformBucketLevelAccess` | No per-object ACLs on GCS | Required for VPC Service Controls compatibility; also the correct posture for a bucket acting as a Snowflake external stage — access is IAM-only, auditable, no ACL sprawl |
| `iam.allowedPolicyMemberDomains` | IAM grants restricted to the verified Cloud Identity domain | No accidental grants to personal accounts |
| `gcp.resourceLocations` | Resources restricted to approved regions | Data residency control — directly relevant if any tier of data has a residency requirement |
| `compute.requireOsLogin`, `compute.disableSerialPortAccess`, `compute.requireShieldedVm` | Host-level hardening | Baseline compute integrity — lower priority for the Snowflake conversation specifically, but part of the same deny-by-default posture |
| `compute.restrictSharedVpcHostProjects` | Only designated host projects can accept service project attachments | Prevents a rogue Shared VPC from appearing outside the sanctioned hierarchy |

### IAM

Access control is driven by an AD group → role mapping, exported from Active Directory as JSON and consumed via `for_each` — the JSON file is the single source of truth, not hand-edited Terraform. Three binding scopes:

- **Org-level** — kept deliberately small; only cross-cutting admin roles
- **Folder-level** — environment-scoped (dev gets edit access, staging/prod get deploy-only)
- **Project-level** — fine-grained roles on service projects (e.g., BigQuery Data Editor for the data team)

Workload Identity Federation maps Kubernetes service accounts to GCP service accounts directly — no key files, consistent with the org-wide key-creation ban above.

### Logging

Org-level log sinks (`include_children = true`, so every project under the org is captured, no opt-in required) fan out to two destinations:

- **BigQuery** — Admin Activity logs, partitioned by date, queryable — this is the "an auditor asks a question and I run a SQL query" store
- **GCS** — Admin Activity + Data Access logs, lifecycle-tiered Nearline (30d) → Coldline (90d) → deleted at 7 years — the cold compliance archive

Data Access audit logging is explicitly enabled for BigQuery (`DATA_READ` + `DATA_WRITE`) — off by default everywhere else because of volume/cost, turned on specifically where data governance visibility matters most. That's a deliberate scope decision, not an oversight, and it's a good example of the same right-sizing logic from the Snowflake doc applied at the infrastructure layer.

### Cost Guardrails

Per-project billing budgets (host and services projects separately) with threshold-based Pub/Sub alerts. Production is alert-only by design — nothing auto-disables billing on a prod environment. That distinction (alert vs. auto-cap) is itself a guardrail decision worth being able to explain: sandbox/dev environments can be capped automatically because breaking them is cheap; prod cannot, because an auto-disabled production billing account is a worse outcome than an overspend.

---

## AWS Landing Zone (built)

`terraform/aws-lz/` — same environments, same naming convention, same right-sizing logic as the GCP side, expressed through AWS's native primitives rather than translated literally.

### Resource Hierarchy

```
AWS Organization
├── Security OU
│   ├── {prefix}-log-archive       Org CloudTrail destination (S3 + KMS + Glue/Athena)
│   └── {prefix}-audit-security    Security tooling account
├── Infrastructure OU
│   └── {prefix}-network            Owns the VPC(s) — mirrors the host-project role
└── Workloads OU
    ├── {prefix}-dev
    ├── {prefix}-staging
    └── {prefix}-prod
```

AWS's natural unit of isolation is the **account**, not the project — so where GCP uses one host project + Shared VPC per environment, this uses a dedicated Network account owning a VPC per environment, with subnets shared out to the corresponding workload account via **AWS RAM** (Resource Access Manager). Same centralizing principle as Shared VPC — one team owns the network, workload accounts attach to it but can't create their own — expressed through AWS's account boundary instead of GCP's project boundary.

### Network

- One VPC per environment in the Network account, private subnets only, spread across 2 AZs — no public subnets by default, mirroring the GCP LZ's no-external-IP posture
- Subnets shared to the matching workload account via RAM (`aws_ram_resource_share` + `aws_ram_principal_association`) — the workload account launches into them but doesn't own them
- Single NAT Gateway per environment for dev/staging — the cost-conscious default, same right-sizing call as the Snowflake doc's control-intensity table applied to infrastructure spend. **Prod gets one NAT Gateway per AZ**, each with its own EIP, with each AZ's route table pointed at the NAT Gateway in that same AZ — a single NAT Gateway is a real single point of failure for prod outbound connectivity specifically, so this is where the extra spend is justified (`networking.tf`)
- Security groups: deny-by-default, explicit allow only for internal VPC CIDR traffic
- Private Route 53 hosted zone per environment, associated to that environment's VPC — internal resolution never leaves the VPC, same as GCP's private DNS zone
- VPC Flow Logs to CloudWatch Logs, retention tiered 90 days (dev/staging) / 365 days (prod) — AWS Flow Logs don't have a sampling knob like GCP's 50%, so cost control here is retention-based instead

### Service Control Policies (deny-by-default at the org root or Workloads OU)

| SCP | Effect | Why it matters for the Snowflake integration |
|---|---|---|
| `deny-access-key-creation` | Denies `iam:CreateAccessKey` org-wide except tagged break-glass principals | Direct mirror of `disableServiceAccountKeyCreation` — Storage Integration equivalent (STS role assumption) becomes the only path, not just the recommended one |
| `deny-s3-public-access-changes` | Denies disabling S3 Block Public Access or granting public bucket ACLs/policies | Mirrors `uniformBucketLevelAccess` in intent — a bucket acting as a Snowflake external stage can't be accidentally made public |
| `restrict-regions` | Denies actions outside `allowed_regions`, applied at the Workloads OU | Direct mirror of `gcp.resourceLocations` — same data residency lever |
| `deny-root-user` | Denies all root-user actions in member accounts | No GCP equivalent — AWS-specific, since GCP has no root-user concept. Worth naming as a genuine AWS-side addition, not a translated control |
| `require-s3-encryption` | Denies unencrypted `PutObject` and denies non-TLS S3 access org-wide | Directly relevant to any bucket serving as a Snowflake external stage |
| `deny-leave-org` | Denies `organizations:LeaveOrganization` | Prevents a compromised/misconfigured account from detaching itself from org-level guardrails |
| `require-imdsv2` | Denies EC2 launch without IMDSv2 enforced | Mirrors the intent of `requireShieldedVm` — baseline instance metadata hardening |

### IAM

AWS IAM Identity Center (successor to AWS SSO), driven by the **same AD group export** referenced in the Snowflake guardrails doc — same source of truth, one more layer of indirection than GCP: a group is assigned a **Permission Set** on a specific target account, rather than getting an IAM role bound directly. That indirection is what buys federated, short-lived credentials per account with no static keys — consistent with the access-key-creation SCP above. The CI/CD identity that runs this Terraform assumes a role via GitHub OIDC federation, never a stored access key.

### Logging

An **organization CloudTrail trail** (`is_organization_trail = true`) captures every account automatically, current and future — the direct equivalent of `include_children = true` on the GCP org sink, no per-account opt-in possible. Two destinations, same shape as the GCP side:

- **S3 (Log Archive account)**, KMS-encrypted, lifecycle-tiered Standard-IA (30d) → Glacier (90d) → expired at 7 years — matches the GCP Nearline→Coldline→7-year pattern exactly
- **Glue + Athena** over that same S3 data — the queryable compliance store, direct equivalent of the BigQuery `audit_logs` dataset

Data-event logging (S3 object-level) is scoped specifically to buckets tagged as Snowflake external stages, rather than turned on globally — the same deliberate volume/cost scoping as the GCP side's `DATA_READ`/`DATA_WRITE` audit config limited to BigQuery.

### Cost Guardrails

Per-account AWS Budgets (Network account + each workload account) with SNS-based threshold alerts at 50/75/90/100% — same alert-only posture for every environment including prod, same reasoning as the GCP side: an auto-capped production account is a worse failure mode than a monitored overspend.

### Control Mapping (GCP ↔ AWS)

| GCP control | AWS equivalent | Status |
|---|---|---|
| Org Policy constraints | Service Control Policies at the OU level | Built, both sides |
| Shared VPC host/service project | Network account + RAM-shared VPC subnets | Built, both sides |
| `compute.vmExternalIpAccess` deny | No public subnets by default; NAT Gateway is the only egress path | Built, both sides |
| `iam.disableServiceAccountKeyCreation` | SCP denying `iam:CreateAccessKey` | Built, both sides |
| AD group → IAM binding JSON | IAM Identity Center permission sets from the same AD export | Built, both sides |
| Org-level log sink → BigQuery/GCS | Organization CloudTrail trail → S3 + Glue/Athena | Built, both sides |
| Per-project budget alerts | AWS Budgets + SNS, scoped per account | Built, both sides |
| — | `deny-root-user` SCP | AWS-only — no GCP equivalent exists |

`terraform validate` passes on both modules. Neither has been applied against a live org/account — this is reference-grade IaC for future real deployment, not something that's been run against production billing.

---

## Where Snowflake Attaches

This is the seam between the two documents:

| Snowflake integration point | Lands in (GCP) | Lands in (AWS) |
|---|---|---|
| Private Service Connect / PrivateLink endpoint | Host project's Shared VPC, dedicated subnet | Network account's VPC, private subnet (RAM-shared to the workload account) |
| External stage (GCS/S3) | Services project bucket, uniform bucket-level access, IAM-only | Workload account S3 bucket, SCP-enforced encryption + Block Public Access |
| Storage Integration role assumption | Workload Identity–style short-lived credentials (SA key creation is org-denied) | IAM role assumption (STS), no long-lived access keys (SCP-denied) |
| Tri-Secret Secure customer-managed key | Cloud KMS key in the security project, not the workload project | KMS key in the Log Archive/Audit-Security account, not the workload account |
| Audit trail for Snowflake account activity | Correlated with org-level Cloud Audit Logs in the logging project's BigQuery dataset | Correlated with the organization CloudTrail trail in the Log Archive account's Athena tables |

None of Snowflake's own controls (masking, row access, Tri-Secret Secure) matter if the account/project hosting the private endpoint has a permissive network policy, a default VPC nobody locked down, or a service account with a long-lived exportable key. The landing zone is the floor Snowflake's controls stand on — this doc is what establishes that floor is solid, not assumed.

---

## Sources

- Internal: `terraform/gcp-lz/*.tf` — org_structure.tf, shared_vpc.tf, org_policies.tf, iam_bindings.tf, logging.tf, budget_alerts.tf
- Internal: `terraform/aws-lz/*.tf` — org_structure.tf, scps.tf, networking.tf, iam.tf, logging.tf, budgets.tf (validated with `terraform validate`, July 2026)
- [Google Cloud landing zone design — reference architecture](https://cloud.google.com/architecture/landing-zones)
