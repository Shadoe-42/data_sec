# Multi-Tenancy Isolation Model
*Meridian Analytics — making an assumed decision explicit | July 2026*

---

## Purpose

Row access policies keyed on `tenant_id` have been used throughout this project since the original Snowflake guardrails doc, and the consent registry in `privacy_consent_management.md` is built the same way. That's a real architectural decision — single-account, shared-schema, tenant isolation enforced entirely by policy — and it was never actually stated as a decision or weighed against the alternatives. An assumption that's never been defended is a weak point the moment someone asks "why not just give every tenant their own database." This doc answers that.

---

## Three Models

### Single-account, shared-schema (what's been built)

All tenants' data lives in the same tables; a Row Access Policy filtering on `tenant_id` is the isolation boundary, not physical separation. Consent-gated secondary use (AI training/embeddings) is a second, independent layer on top of that boundary, not folded into the same policy — see `privacy_consent_management.md`'s `CUSTOMER_EVENTS_AI_TRAINING_SCOPE` secure view for the pattern, and why it's a separate object from the tenant isolation policy rather than an extra condition bolted onto it.

- **Strengths:** lowest operational overhead by a wide margin — one schema to evolve, one place to apply masking/row access/consent policies, and it's the model that makes Secure Data Sharing and Data Clean Rooms (already in the Data Security section of the Snowflake doc) straightforward, since cross-tenant benchmarking features assume the data is already colocated.
- **Weaknesses:** blast radius on a policy bug is large — a misconfigured or accidentally-dropped Row Access Policy exposes every tenant at once, not one. "Noisy neighbor" risk on shared compute (addressed by the workload-separated warehouse strategy in `snowflake_compute_finops.md`, not eliminated by the isolation model itself). Per-tenant data residency (a specific tenant needing their data pinned to a specific region) is awkward to support cleanly.

### Database-per-tenant, same account

Each tenant gets a dedicated database within one Snowflake account; schema and policies are templated and deployed per tenant via CI, not hand-maintained.

- **Strengths:** blast radius on a bug is contained to one tenant's database, not all of them. Per-tenant deletion (a genuine right-to-erasure request) is architecturally cleaner — drop the database, rather than surgically deleting rows out of shared tables. Easier story for a specific enterprise customer who contractually demands "our data is never in the same table as anyone else's."
- **Weaknesses:** schema drift risk the moment templating discipline lapses — thousands of near-identical databases are only safe if they're genuinely identical, which requires real CI rigor to guarantee. Cross-tenant features (the benchmarking/clean-room use cases) require deliberate cross-database sharing rather than being free by default. Higher operational overhead than shared-schema, though Snowflake handles large numbers of databases within an account reasonably well — this isn't a hard scaling wall, just a real cost.

### Account-per-tenant

Each tenant gets an entirely separate Snowflake account — separate control plane, separate encryption keys, separate compliance boundary.

- **Strengths:** the strongest isolation available, full stop. The right answer for a tenant that needs genuine infrastructure separation for contractual, regulatory, or trust reasons — a large enterprise or public-sector customer who won't accept shared infrastructure at any level, or a case where the tenant's own compliance obligations require an isolated environment they can independently audit.
- **Weaknesses:** the landing zone work in this project (private connectivity, IAM, consent registry, resource monitors) would need to be replicated per tenant account, not just per environment. Doesn't scale to hundreds or thousands of SMB tenants — the per-account overhead (minimum compute, duplicated governance objects, duplicated IAM) makes this the most expensive model by a wide margin, and it forecloses the cross-tenant features that are part of Meridian's actual product.

---

## The Decision: Hybrid, Tiered to the Customer, Not a Single Global Answer

Applying one isolation model uniformly across a customer base that ranges from small businesses to large enterprises is the same mistake flagged everywhere else in this project — uniform because it's simpler to explain, not because it's right-sized to where the actual risk and value sit.

**Recommended model:**

| Tenant tier | Isolation model | Rationale |
|---|---|---|
| Standard (majority of tenants — SMB/mid-market) | Single-account, shared-schema (as built) | Lowest overhead, enables the cross-tenant product features, and the existing Row Access Policy + consent registry + masking stack is real defense-in-depth, not a single point of failure — see below |
| Enterprise / contractually isolated | Database-per-tenant, same account | For customers whose contracts specifically require logical separation beyond policy enforcement, without the full overhead of a separate account |
| Regulated / sovereign requirement | Account-per-tenant | Reserved for the rare case — a specific regulatory regime, a public-sector customer, or a contractual demand for genuinely separate infrastructure — where nothing less satisfies the requirement |

This mirrors how multi-tenant SaaS companies built on Snowflake commonly operate in practice: a shared tier for most of the customer base, with an escalating isolation offering for the accounts large or sensitive enough to need it and willing to pay the operational cost of providing it.

**What this means for the landing zone, concretely:** the account-per-tenant tier reuses the same pattern already established for dev/staging/prod in `terraform/aws-lz/` and `terraform/gcp-lz/` — a dedicated workload account/project per major tenant, inheriting the same SCP/org-policy guardrail set rather than a bespoke one. This isn't new infrastructure design, it's applying the existing per-environment pattern to a per-large-tenant axis instead.

---

## Defense in Depth Within the Shared Tier

The honest answer to "what if a Row Access Policy gets misconfigured" for the Standard tier isn't "that can't happen" — it's that RAP is one layer among several, not the sole isolation mechanism:

- **Row Access Policy** — the primary boundary, filtering every query on `tenant_id`
- **Dynamic Data Masking** — even within a tenant's own visible rows, PII columns are masked by role, limiting exposure from an over-broad grant
- **Consent registry enforcement** — a second, independent policy layer gating AI/secondary use specifically, not just general row visibility
- **Object tagging and classification** — makes a misconfiguration more likely to be caught by governance tooling/audit rather than silently persisting
- **Per-tenant cost attribution** (`snowflake_compute_finops.md`) — an unexpected cross-tenant data volume anomaly is also a cost anomaly, giving a second, independent detection signal beyond the security tooling alone

No single layer is being trusted to carry all the isolation risk on its own — that's the actual answer to the "what if RAP breaks" question, not a claim that it won't.

---

## What This Strengthens

No new rows in `soc2_csf_compliance_crosswalk.md` — this doc doesn't introduce a new control, it documents the reasoning behind controls already mapped there (CC6.1, CC6.6, Confidentiality C1.1–C1.2), specifically the "why this isolation model in the first place" question the crosswalk's evidence pointer doesn't answer on its own.

---

## Sources

- Internal: `snowflake_data_security_guardrails.md`, `privacy_consent_management.md`, `snowflake_compute_finops.md`, `terraform/gcp-lz/org_structure.tf`, `terraform/aws-lz/org_structure.tf`
