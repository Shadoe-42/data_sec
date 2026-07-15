# Snowflake Data Security & AI Governance Guardrails
*Meridian Analytics — Scenario-grounded, AWS + GCP | July 2026*

---

## Purpose

Snowflake's data security and AI governance model for a multi-tenant SaaS platform, deployed consistently across AWS and GCP. This isn't a build spec — it's the architecture reasoning and control vocabulary behind the choices, plus a FinOps lens that a purely security-postured review typically skips.

The spine here is **Snowflake's own current security architecture** (as presented at Snowflake Summit 2026), not a generic external compliance framework, because Snowflake-native controls — RBAC/ABAC, network policies, Tri-Secret Secure, Horizon, Cortex agent governance — are what actually determine the security posture here, regardless of which hyperscaler sits underneath:

- **Platform security** — identity, RBAC/ABAC, network policies, private connectivity, key management
- **Data security** — sensitive data protection, exfiltration prevention, ransomware resilience
- **Agent security** — AI agent identity, prompt injection defense, governance over what agents can touch

---

## Scenario

**Meridian Analytics** — a B2B SaaS company running multi-tenant customer analytics, standardized on Snowflake as the AI Data Cloud. Ingestion and application workloads are split across **AWS and GCP** deliberately (not by accident of history) — parity by design, so either cloud can be scaled independently and neither becomes a single point of failure for a client relationship. Snowflake itself runs as a SaaS control plane on top of both.

Two workload types sit on the same data:
- **BI/analytics** — dashboards, ad hoc SQL, embedded analytics for Meridian's own customers
- **AI/Cortex** — natural-language querying (Cortex Analyst), semantic search (Cortex Search), and agentic workflows querying customer data directly inside Snowflake's boundary

That second workload type is why this can't just be a lift of a generic cloud security doc — agents asking questions of regulated customer data is a materially different risk than a dashboard rendering a chart.

---

## Data Classification

| Tier | Examples | Multi-tenant concern |
|------|----------|----------------------|
| **Public** | Product usage benchmarks, marketing data | None |
| **Internal** | Operational metrics, cost/usage telemetry | Low |
| **Customer Confidential** | Raw customer-uploaded data, business metrics | High — tenant isolation is the whole game |
| **Regulated** | PII, payment data, health data subsets within customer data | High + regulatory |
| **AI Context** (cross-cutting tag, not a tier) | Any of the above when used for embeddings, Cortex Search indexing, or agent context | Inherits source tier + adds provenance/consent questions |

**Why AI Context is a tag, not a tier:** a customer's PII doesn't become less sensitive because an agent is reading it instead of a person — it inherits the classification of its source. What's new is the question of *provenance*: can this data be used to build an embedding index, does a fine-tune or a vector store constitute a new copy that needs its own access control, and did the tenant actually consent to their data feeding a feature they didn't explicitly ask for. That provenance question — not just "is it encrypted" — is the actual governance gap this doc and `privacy_consent_management.md` address.

---

## Platform Security

| Control | Snowflake-native | AWS implementation | GCP implementation |
|---------|------------------|---------------------|---------------------|
| Identity federation | SCIM provisioning + SAML/OIDC SSO from Okta/Entra ID into Snowflake roles | N/A — identity federates directly to Snowflake, not through AWS IAM | N/A — same; Snowflake is the control plane regardless of underlying cloud |
| Authorization | RBAC + ABAC (tag-based access policies) | — | — |
| Private connectivity | Snowflake account private endpoint | AWS PrivateLink | GCP Private Service Connect |
| Network policy | Snowflake network policies (IP allow-listing at the account/user level) | Applies identically — cloud-agnostic layer | Applies identically |
| Key management (Tri-Secret Secure) | Snowflake-managed key + customer-managed key, combined; multi-party approval for key operations (2026) | Customer-managed half in AWS KMS | Customer-managed half in GCP Cloud KMS |
| Session/auth policy | MFA enforcement, session timeout policies, Trust Center posture scoring | — | — |

**The cloud boundary, precisely stated:** most of Platform security is Snowflake-native and cloud-agnostic — RBAC, network policies, SSO all work the same regardless of which hyperscaler the account sits on. The AWS/GCP divergence shows up in exactly three places: private connectivity mechanism, the customer-managed key backend, and where the client's *other* workloads (ingestion, orchestration) live. Treating "cloud security" as one undifferentiated blob obscures that the actual boundary is narrow and specific.

**FinOps note:** Tri-Secret Secure with a customer-managed key adds real operational cost — HSM-backed key management, key rotation workflows, the 2026 multi-party approval overhead. That's justified for the Regulated tier. Applying it account-wide because it sounds more secure is the kind of over-engineering a cost-aware architect should flag, not default to.

---

## Data Security

| Control | What it does | Applies to |
|---------|--------------|------------|
| Dynamic Data Masking | Column-level masking policies evaluated at query time based on role | Regulated tier (PII columns), enforced regardless of BI or Cortex access path |
| Row Access Policies | Row-level filtering by tenant_id — the core multi-tenant isolation mechanism | Customer Confidential and above |
| Object tagging + classification | Auto-classification tags drive masking policy assignment | All tiers, for governance visibility |
| Data Movement Policies (2026) | Declarative blocks on `COPY INTO` and similar exfiltration paths — explicitly designed to stop unauthorized data movement by AI agents | Regulated tier, AI Context-tagged data |
| Storage integrations (external stages) | Snowflake assumes a scoped role to read/write cloud storage without static credentials | AWS: IAM role assumption into S3 buckets. GCP: service account binding into GCS buckets |
| Secure Data Sharing / Data Clean Rooms | Query across tenant or company boundaries without copying data | Cross-tenant benchmarking features, partner data exchange |

**Why this control matters:** Data Movement Policies exist specifically because agentic AI changed the exfiltration threat model. A human analyst copying data out is a slow, auditable event. An agent with broad read access and a `COPY INTO` path is a fast, automatable one — Data Movement Policies are Snowflake's direct response to that shift, not a generic exfiltration control retrofitted for AI.

**FinOps note:** Secure Data Sharing/Clean Rooms are a rare case where the security control *reduces* cost — no duplicated ETL pipelines, no redundant storage, no separate governance regime for a shared copy. A genuine case where the security-correct answer and the cost-correct answer are the same answer, not a tradeoff between them.

---

## Agent Security

| Control | What it does |
|---------|---------------|
| Agent identity | Cortex agents authenticate and authorize through the same RBAC/ABAC model as human users — no separate, weaker identity plane for AI |
| Horizon AI Guardrails | Prompt injection defense integrated into Horizon Catalog |
| Data Movement Policies | Explicitly restrict agent-initiated data movement (see Data Security above) |
| "Bring the model to the data" | Cortex inference happens inside Snowflake's governance boundary rather than exporting data to an external model endpoint — this avoids a whole category of exfiltration risk by architecture, not policy |

**The core argument:** Snowflake's AI approach doesn't require a *new* security model for AI — an agent is just another principal subject to the same RBAC, masking, and row access policies as a person. The risk isn't "AI is insecure," it's whether existing governance was actually extended to cover the new principal type, or whether a shadow pipeline copies data out to a model that doesn't respect any of it.

---

## Right-Sizing Summary (the FinOps thread)

| Tier | Control intensity | Reasoning |
|------|--------------------|-----------|
| Public / Internal | Baseline RBAC, standard encryption, no masking | Low blast radius — spending more here buys no real risk reduction |
| Customer Confidential | Row access policies, tagging, standard key management | Tenant isolation is mandatory; customer-managed keys are not, yet |
| Regulated | Full stack — masking, row access, Tri-Secret Secure with CMK, Data Movement Policies, tightened network policy | Where regulatory and reputational risk actually concentrates |
| AI Context | Inherits source tier controls + provenance tracking + Data Movement Policy enforcement | The tag adds governance overhead, not a parallel security stack |

The pitch to the room: controls should be proportionate to where the risk actually sits, not applied uniformly because uniform is easier to explain. That's a harder argument to make than "encrypt everything, mask everything" — and it's exactly the kind of judgment a Technical Account Manager needs to defend to a client's finance stakeholders, not just their security team.

**This table is the security/storage half of the FinOps story only.** The larger half — warehouse sizing, auto-suspend/resume, multi-cluster scaling policy, resource monitors, per-tenant cost attribution — is its own document: `snowflake_compute_finops.md`. Compute is the dominant line item on almost every Snowflake bill; treating this table as the whole cost conversation would undersell the point.

---

## Sources

- [Defending Your Enterprise at the Speed of AI — Snowflake](https://www.snowflake.com/en/blog/enterprise-ai-security/)
- [Snowflake Security and Trust Center](https://www.snowflake.com/en/why-snowflake/snowflake-security-hub/)
- [Snowflake Advances Trusted AI with Horizon Catalog](https://www.snowflake.com/en/news/press-releases/snowflake-advances-trusted-ai-with-snowflake-horizon-catalog-centralizing-governance-context-and-security-across-the-enterprise/)
- [Tri-Secret Secure in Snowflake — Snowflake Documentation](https://docs.snowflake.com/en/user-guide/security-encryption-tss)
- [Key Takeaways from Snowflake Summit 2026](https://www.sdggroup.com/en-us/insights/blog/key-takeaways-from-snowflake-summit-2026)
