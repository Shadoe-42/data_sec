# Compliance Crosswalk — SOC 2 Type II + NIST CSF 2.0
*Standard → control → evidence, for Meridian Analytics | July 2026*

---

## Purpose

The other docs in this project are control-first: "here's what we built and why." This one runs the direction an auditor or a client's compliance team actually asks it — "you claim X standard, show me the specific control and where I'd find evidence it's operating." Everything else in `d_s/` documents the controls; this maps them to the specific standards they satisfy and where the evidence for each one lives.

**Why these two frameworks, together, not separately:** SOC 2 Type II is the real-world target — it's what Meridian's enterprise customers will actually demand before they'll sign a contract, and "operating effectively over a period" (Type II) is a materially higher bar than "designed correctly" (Type I). NIST CSF 2.0 isn't a competing framework here — it's cross-referencing language: vocabulary that lets a security team, a compliance team, and a cloud team talk about the same control without three different dialects. The crosswalk uses CSF's six functions as the spine and maps each one to the relevant SOC 2 Trust Service Criteria.

**Scope note:** Meridian is a B2B SaaS company handling customer business data, including a Regulated tier with PII and billing information. That puts **Security (the mandatory Common Criteria, CC-series)**, **Confidentiality**, **Availability**, and **Privacy** Trust Service Criteria in scope. Privacy specifically: it's a mistake to assume a B2B analytics platform is exempt from Privacy criteria just because its direct customers are businesses, not consumers — billing contacts and end-user accounts are individual PII, and the AI/Cortex features in this project's own scenario (embeddings, agent context, product-enhancement data mining) are exactly the kind of secondary use of collected data that Privacy criteria (consent, collection limitation, use limitation) exist to govern. Most SaaS companies that build derivative datasets for product or marketing purposes are in scope for this whether they've acknowledged it or not. **Processing Integrity** is the one left out — it applies most directly to transaction-processing correctness (was this payment processed completely, accurately, on time), and the common SaaS pattern of routing payments through a third-party processor (Stripe or similar) keeps that specific criteria off Meridian's plate. If Meridian processed billing in-house instead of through a processor, Processing Integrity would need to come into scope too.

**Honesty note:** every function-level section below is Built, including the landing zone infrastructure hardening items (Terraform state bucket versioning, multi-AZ NAT for prod, cross-region audit log replication) — see `TRACKING.md` for current status of each. The RTO/RPO targets in `resilience_disaster_recovery.md` are illustrative, tiered numbers to validate against a real business impact analysis that doesn't exist in this project, not numbers derived from one. None of this — including the infrastructure hardening — has been applied against a live org.

---

## Govern (GV)

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| CC1.1–CC1.5 (Control Environment) | Organization demonstrates commitment to integrity, competence, and accountability structures | Org-level IAM kept deliberately small (org admin, billing admin, security admin, network admin roles only); AD group JSON as the single source of truth for access, not ad hoc grants | `terraform/gcp-lz/iam_bindings.tf`, `terraform/aws-lz/iam.tf`, `terraform/{gcp-lz,aws-lz}/data/ad-groups.json` |
| CC9.1–CC9.2 (Risk Mitigation, incl. vendor/third-party) | Organization identifies and manages risk from vendors and business partners | Snowflake itself is a "critical vendor" under this lens; Storage Integration objects use scoped role assumption rather than static credentials shared with a third party, minimizing blast radius of the Snowflake↔cloud trust relationship | `account_landing_zone_guardrails.md` — "Where Snowflake Attaches" table; Storage Integration config in both landing zones |
| Maps to CSF GV.SC (Supply Chain Risk Management) | — | Explicit inventory of what crosses the Snowflake/cloud boundary (private endpoint, external stage, storage integration, CMK) rather than an undocumented trust relationship | `account_landing_zone_guardrails.md` integration table |

---

## Identify (ID)

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| CC3.1–CC3.4 (Risk Assessment) | Organization identifies risk to objectives and analyzes it as a basis for determining how to manage it | Data classification scheme (Public/Internal/Customer Confidential/Regulated + AI Context tag) is the risk-assessment artifact — controls are explicitly tiered to where risk concentrates, not applied uniformly | `snowflake_data_security_guardrails.md` — Data Classification and Right-Sizing Summary sections |
| Maps to CSF ID.AM (Asset Management) | — | Terraform-defined resource hierarchy means every project/account, VPC, and bucket is enumerable from source, not tribal knowledge | `terraform/gcp-lz/org_structure.tf`, `terraform/aws-lz/org_structure.tf` |

---

## Protect (PR)

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| CC6.1 (Logical Access — provisioning) | Logical access to systems is restricted to authorized users via defined roles | Snowflake RBAC/ABAC; AD group → IAM Identity Center permission sets (AWS) / IAM bindings (GCP), sourced from one JSON file, not manual grants | Snowflake `ACCOUNT_USAGE.GRANTS_TO_ROLES`; `aws_ssoadmin_account_assignment` resources; `google_project_iam_binding` resources |
| CC6.2 (Logical Access — deprovisioning) | Access is removed when no longer needed | AD-group-driven bindings mean access changes when the source-of-truth JSON changes — no orphaned manual grants to track down separately | Same `ad-groups.json` source in both modules; diffing it against current state is the deprovisioning check |
| CC6.6 (Boundary Protection / Encryption) | Logical access is restricted via network segmentation and encryption | Private connectivity only (PrivateLink/PSC, no public endpoints); Tri-Secret Secure with customer-managed key for Regulated-tier data; SCP/org-policy-enforced S3/GCS encryption | `networking.tf` (both modules), `require-s3-encryption` SCP, `uniformBucketLevelAccess` org policy, Snowflake Tri-Secret Secure config |
| CC6.7 (Data Transmission/Movement Controls) | Movement of data is restricted and monitored | Data Movement Policies blocking unauthorized `COPY INTO`, specifically scoped to agent-initiated exfiltration paths | `snowflake_data_security_guardrails.md` — Data Security section |
| CC6.8 (Malicious Software Prevention) | Controls to prevent/detect unauthorized or malicious software | IMDSv2 enforcement (AWS), Shielded VM requirement (GCP) — baseline instance integrity | `require-imdsv2` SCP, `requireShieldedVm` org policy |
| C1.1–C1.2 (Confidentiality) | Confidential information is protected during collection, use, retention, and disposal | Dynamic Data Masking + Row Access Policies enforced at query time regardless of access path (BI or Cortex); classification tags drive masking policy assignment automatically | Snowflake masking policy + row access policy definitions; `Data Classification` table |
| A1.2 (Availability — environmental protections & capacity) | Environmental threats and capacity are managed to meet availability commitments | Per-AZ NAT redundancy for prod (AWS NAT Gateway per AZ; GCP Cloud NAT hardened with static IPs and sized port allocation), multi-AZ private subnets, cross-region audit log replication; note: this is capacity/redundancy at the infrastructure layer — a client-specific business continuity plan, validated against a real business impact analysis, is out of scope for this reference architecture (see Recover, below, for the logical-recovery layer this doc does cover) | `networking.tf` / `shared_vpc.tf` / `logging.tf` (both modules) |

---

## Detect (DE)

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| CC7.1 (Detection of Security Events) | Organization uses detection procedures to identify anomalies and security events | Snowflake Horizon AI Guardrails (prompt injection defense); VPC Flow Logs / VPC Flow Logs equivalent on both clouds | `snowflake_data_security_guardrails.md` — Agent Security section; `aws_flow_log` / GCS flow log config in both networking files |
| CC7.2 (Monitoring for Anomalies) | System components are monitored for anomalies indicative of malicious acts, errors, or unauthorized changes | Organization-wide audit trail with no opt-out: org-level Cloud Audit Log sinks (`include_children = true`) / organization CloudTrail trail (`is_organization_trail = true`) | `logging.tf` (both modules) |
| Maps to CSF DE.CM (Continuous Monitoring) | — | Queryable compliance stores (BigQuery `audit_logs` dataset / Glue+Athena over CloudTrail) mean "was this account touched" is a query, not a support ticket to the cloud provider | `logging.tf` (both modules) |

---

## Respond (RS) — Built

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| CC7.3–CC7.4 (Incident Response) | Organization identifies, develops, and implements activities to respond to security incidents | Scenario-driven IR runbook covering three concrete incident types (unauthorized Regulated-tier access, compromised credentials, AI agent security events), severity classification, defined roles including a dedicated partner/TAM escalation role, and a breach notification framework | `incident_response_runbook.md` |

---

## Recover (RC) — Built

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| A1.3 (Recovery) / CC7.5 | Environmental and system failures are anticipated, and recovery procedures are tested | Snowflake Time Travel (tiered retention by classification) + Fail-safe mechanics documented; tiered RTO/RPO targets by classification tier; landing zone infrastructure hardening gaps (state bucket versioning, multi-AZ NAT for prod, cross-region audit replication) honestly flagged as not-yet-built rather than silently assumed | `resilience_disaster_recovery.md` |

---

## Privacy — Built

Scoped in per the note above: billing contacts and end-user PII exist in this system, and the AI/Cortex features described in the Snowflake doc constitute secondary use of collected data (product enhancement, potential marketing/mining use cases) — exactly what these criteria govern.

| SOC 2 Criteria | Requirement | Our Control | Evidence |
|---|---|---|---|
| P3.1 (Collection) | Personal information is collected consistent with the entity's objectives related to privacy | Data classification scheme identifies PII at the Regulated tier at the point of ingestion, not after the fact | `snowflake_data_security_guardrails.md` — Data Classification section |
| P4.1–P4.3 (Use, Retention, Disposal) | Personal information is used, retained, and disposed of consistent with the entity's objectives | GCS/S3 lifecycle policies enforce disposal timelines; the AI Context tag requires provenance tracking before PII-derived data feeds embeddings or agent context; deletion/erasure workflow resolved via crypto-shredding — see `resilience_disaster_recovery.md` for the mechanism | `logging.tf` lifecycle rules (both modules); `privacy_consent_management.md` — Data Subject Rights; `resilience_disaster_recovery.md` — Closing the Privacy Doc's Erasure Dependency |
| P6.1 (Disclosure to Third Parties) | Personal information is disclosed to third parties only for identified purposes and with consent | Secure Data Sharing / Data Clean Rooms restrict cross-boundary data disclosure; subprocessor disclosure (including an MSP, if engaged) is now folded into consent notice rather than a separate legal-only document | `snowflake_data_security_guardrails.md` — Data Security section; `privacy_consent_management.md` — Third-Party Disclosure and the MSP Case |
| P2.1 (Choice and Consent) | The entity communicates choices about collection, use, and disclosure, and obtains consent | Tenant- and end-user-level consent capture, per-purpose granularity (`AI_TRAINING` / `PRODUCT_ANALYTICS` / `MARKETING`), notice versioning | `privacy_consent_management.md` — Consent Capture |
| P8.1 (Monitoring and Enforcement) | The entity monitors compliance with its privacy commitments and procedures for handling complaints | `CONSENT_REGISTRY` table plus a consent-gated secure view that the AI training pipeline reads through instead of the base table — kept separate from the tenant isolation row access policy so consent enforcement never affects contract-basis BI access; revocation takes effect on the next query, not a batch cycle; data subject rights (access/correction/deletion) workflow defined | `privacy_consent_management.md` — Enforcement Design |

---

## What This Table Is Actually For

This isn't a document meant to be read line by line — it's what answers "how do you know your Tri-Secret Secure implementation actually satisfies your SOC 2 requirements": point to CC6.6, point to the Terraform resource, point to the Snowflake config view that would show up in an evidence request. Every function is Built, but the honest answer to "is this production-ready" is still "no — this is reference architecture and reasoning, and none of it has been applied against a live org." Every infrastructure hardening item that was previously open is now closed (see `TRACKING.md` for current status — that file, not this paragraph, is the source of truth going forward). That distinction — architecturally complete, operationally unproven — is worth being precise about rather than blurring.

---

## Sources

- Internal: `snowflake_data_security_guardrails.md`, `account_landing_zone_guardrails.md`, `terraform/gcp-lz/*.tf`, `terraform/aws-lz/*.tf`
- [The NIST Cybersecurity Framework (CSF) 2.0](https://nvlpubs.nist.gov/nistpubs/CSWP/NIST.CSWP.29.pdf)
- SOC 2 Trust Services Criteria (AICPA) — Common Criteria (CC1–CC9), Availability (A1), Confidentiality (C1), Privacy (P1–P8, based on the Generally Accepted Privacy Principles framework)
