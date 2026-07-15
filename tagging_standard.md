# Tagging & Labeling Standard
*Meridian Analytics — one standard, two syntaxes | July 2026*

---

## Purpose

Every Terraform module in this project already carries a `common_tags` (AWS) or `common_labels` (GCP) local — `environment`, `org_prefix`, `managed_by` — but nothing has documented what the actual standard is or why those specific dimensions were chosen. `snowflake_compute_finops.md`'s per-tenant cost attribution and any real FinOps chargeback model both depend on consistent tagging existing before the fact, not reconstructed after a bill arrives with no way to attribute it.

---

## Semantic Dimensions

| Dimension | Purpose | Example value |
|---|---|---|
| `environment` | Already established — dev/staging/prod | `prod` |
| `cost_center` | Which business function owns this spend, for chargeback | `data-platform` |
| `data_classification` | Ties directly to the tiers in `snowflake_data_security_guardrails.md` — makes classification visible on the infrastructure itself, not just inside Snowflake | `regulated` |
| `owner_team` | Who to page, not just who to bill | `platform-engineering` |
| `workload` | Which application or pipeline this resource serves | `ingestion-pipeline` |
| `managed_by` | Already established — always `terraform`, the one value that should never vary | `terraform` |

`data_classification` is the dimension worth calling out specifically — most tagging standards stop at cost and ownership. Tagging infrastructure with the same classification tier used inside Snowflake means a resource inventory query can answer "what infrastructure touches Regulated-tier data" without cross-referencing a separate document.

---

## One Standard, Two Syntaxes

AWS tags and GCP labels aren't the same format, and a standard that ignores that produces broken values the moment it's applied to both clouds:

| | AWS tags | GCP labels |
|---|---|---|
| Case | Mixed case allowed | Lowercase only |
| Character set | Letters, numbers, spaces, and `+ - = . _ : / @` | Lowercase letters, numbers, underscores, hyphens only |
| Max length | 128 chars (key) / 256 chars (value) | 63 chars (key and value) |
| Start character | No restriction | Key must start with a lowercase letter |

Practical effect: the same semantic dimension gets the same key name on both clouds (already lowercase-with-underscores works natively on both, which is why the dimension names above are written that way), but a value like `Data-Platform` would need to become `data-platform` on GCP even if AWS would accept the mixed case — the standard should specify lowercase values everywhere by default, not just where GCP requires it, so the same value is valid on both clouds without a translation step.

| Dimension | AWS tag key | GCP label key | Example (both clouds) |
|---|---|---|---|
| Environment | `environment` | `environment` | `prod` |
| Cost center | `cost_center` | `cost_center` | `data-platform` |
| Data classification | `data_classification` | `data_classification` | `regulated` |
| Owner team | `owner_team` | `owner_team` | `platform-engineering` |
| Workload | `workload` | `workload` | `ingestion-pipeline` |
| Managed by | `managed_by` | `managed_by` | `terraform` |

---

## Enforcement, Not Just Convention

A documented standard nobody enforces decays the first time someone's in a hurry. Two mechanisms, both native to what's already built:

- **AWS:** Organizations Tag Policies, attached at the OU level, can require specific tag keys and constrain allowed values — enforced at the point of resource creation, not caught later in an audit.
- **GCP:** an Org Policy constraint requiring labels on resource creation, paired with a documented convention (GCP doesn't have a direct label-policy equivalent to AWS Tag Policies as of this writing, so enforcement here leans more on Terraform module design — the `common_labels` local already being mandatory in every resource block — than on a platform-level policy).

Worth being honest about that asymmetry rather than implying both clouds enforce this identically: AWS has a policy-layer mechanism for this, GCP's answer today is closer to "make it structurally hard to skip in the Terraform module," which is a real difference in enforcement strength, not just syntax.

---

## Sources

- Internal: `snowflake_compute_finops.md`, `snowflake_data_security_guardrails.md`, `terraform/gcp-lz/main.tf`, `terraform/aws-lz/main.tf`
