# Data Security & AI Governance — Reference Architecture

A data security and AI governance reference architecture for a multi-tenant SaaS company running on Snowflake, deployed with native parity across AWS and GCP. Covers the account/network landing zone, Snowflake's own security model, a SOC 2 Type II + NIST CSF 2.0 compliance crosswalk, incident response, privacy/consent enforcement, disaster recovery, compute FinOps, and the multi-tenancy isolation model tying it together.

## What this is, and isn't

**Meridian Analytics is a fictional company**, built specifically for this project — a stand-in the way `example.com` stands in for a real domain, not a disguised version of any real business. Every technology named here (Snowflake, AWS, GCP) is real and current; the company, its data, and its customers are not.

This is **reference architecture and reasoning**, not a production system. The Terraform in `terraform/` is real, working code — `terraform validate` passes clean on both the AWS and GCP modules, and CI (see `.github/workflows/`) enforces that on every change — but none of it has ever been run against a live cloud organization. Treat it as a solid starting point for a real landing zone build, not as something that's already been operated in production.

## Structure

| Path | What's there |
|---|---|
| `snowflake_data_security_guardrails.md` | Snowflake's own security model — Platform/Data/Agent security pillars, data classification tiers, AI Context provenance tagging — mapped across AWS and GCP |
| `meridian_snowflake_security_hld.svg` / `.png` | Architecture diagram for the above |
| `account_landing_zone_guardrails.md` | The account/network layer underneath Snowflake — org/folder/project and OU/account structure, Shared VPC vs. RAM-shared subnets, SCPs and org policies |
| `gcp_landing_zone_hld.svg` / `.png`, `aws_landing_zone_hld.svg` / `.png` | Landing zone architecture diagrams, one per cloud |
| `soc2_csf_compliance_crosswalk.md` | Every control in this project mapped to SOC 2 Type II Trust Service Criteria and NIST CSF 2.0 — standard → control → evidence |
| `incident_response_runbook.md` | Scenario-driven IR runbook, including a dedicated section on how incident response changes under an advisory engagement versus a managed services (MSP) engagement |
| `privacy_consent_management.md` | Consent capture and enforcement design — legal basis (contract vs. consent), a consent-gated view for AI training use, data subject rights |
| `resilience_disaster_recovery.md` | Time Travel / Fail-safe mechanics, tiered RTO/RPO targets, crypto-shredding for genuine data erasure |
| `snowflake_compute_finops.md` | Warehouse sizing, auto-suspend strategy, multi-cluster scaling policy, resource monitors, per-tenant cost attribution |
| `multi_tenancy_isolation_model.md` | Why shared-schema, database-per-tenant, and account-per-tenant are each right for different tenant tiers, rather than one model applied uniformly |
| `cortex_ai_implementation.md` | Working Cortex Analyst semantic view, Cortex Search pointed at a consent-gated view instead of the base table, and a Cortex Agent composing both — AI features inheriting governance rather than needing a parallel security model |
| `healthcare_hipaa_scenario.md` | A second scenario (Meridian Health) on the identical architecture, testing the same judgment against HIPAA instead of SOC 2 — Covered Entity vs. Business Associate, de-identification, HIPAA's own breach notification timeline |
| `secrets_management.md` | A tiered secrets model — native cloud secrets managers for ordinary secrets, HCP Vault's Transit engine specifically for the crypto-shredding key tier |
| `shared_services_layer.md` | The operational shared-infrastructure account/project — artifact registry, delegated DNS, private connectivity to third-party services — kept distinct from the compliance-facing shared infrastructure |
| `network_security_foundations.md` | Egress control, data-loss-prevention scanning before Snowflake classification, workload runtime protection, bastion retirement, and an explicit immutable-infrastructure stance for compute |
| `hybrid_multicloud_connectivity.md` | On-premises and cloud-to-cloud connectivity treated as separate problems, including the reasoning for why AWS and GCP aren't directly connected to each other |
| `tagging_standard.md` | A tagging/labeling standard mapped to both AWS's and GCP's actual syntax, not just a shared convention in name only |
| `terraform/gcp-lz/`, `terraform/aws-lz/` | Working Terraform for both landing zones — org structure, networking, IAM, logging, budgets, bootstrap state buckets |
| `.github/workflows/` | CI: `terraform fmt` + `terraform validate` on every change, for both modules |

## The throughline

Every control in this project is sized to where risk actually concentrates, not applied uniformly because uniform is easier to explain — Tri-Secret Secure and 90-day Time Travel retention are justified for regulated-tier data, not defensible as a blanket default. That reasoning is made explicit throughout rather than left implicit, including where the reasoning cuts against adding more security or more spend.

## License

MIT — see `LICENSE`. Use the Terraform, the diagrams, or the reasoning for your own landing zone work.
