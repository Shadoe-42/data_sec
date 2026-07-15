# Privacy & Consent Management
*Meridian Analytics — closing the biggest gap in the SOC 2/CSF crosswalk | July 2026*

---

## Purpose

`soc2_csf_compliance_crosswalk.md` flagged Privacy — specifically P2.1 (Choice and Consent) and P8.1 (Monitoring and Enforcement) — as the single biggest hole in the whole project: the AI Context tag in `snowflake_data_security_guardrails.md` correctly identifies *that* a consent question exists before customer data feeds embeddings, agent context, or product-enhancement mining, but nothing enforces it. A tag that flags a question without a mechanism to answer it isn't a control — it's a comment. This doc is the mechanism.

Consistent with everything else in this project: a policy statement without an enforceable control behind it doesn't hold up under scrutiny. So this isn't just a consent policy — it's a consent policy plus the specific Snowflake objects that make violating it structurally difficult, not just against the rules.

---

## Legal Basis, Not Just "Consent for Everything"

Not every use of customer data requires fresh consent, and treating it that way would be both wrong and impractical. The relevant distinction:

- **Contract-basis processing** — using a tenant's data to deliver the analytics service they signed up for (dashboards, BI, standard reporting) is covered by the underlying service agreement. No separate consent action needed; this is what Meridian was hired to do.
- **Consent-basis processing** — anything that goes beyond delivering the contracted service: using tenant or end-user data to train or fine-tune AI features, build embeddings for cross-tenant benchmarking, or feed marketing/product-enhancement analytics. This is exactly the "AI Context" category from the classification doc, and it's the category this doc's enforcement mechanism gates.

Over-rotating into "we get consent for everything" creates its own problem: it obscures the difference between a controller processing data to fulfill a contract and a controller using data for a secondary purpose the customer didn't necessarily anticipate, and makes the actual consent-gated uses harder to find in a sea of boilerplate.

---

## Consent Capture

- **Tenant-level consent** is captured at onboarding and revisable at any time from an admin console — a toggle per purpose (`AI_TRAINING`, `PRODUCT_ANALYTICS`, `MARKETING`), not a single blanket checkbox. Granularity matters: a tenant that's fine with product-analytics use of their data may not want it used for cross-tenant AI training.
- **End-user-level consent**, where individual end users within a tenant's organization have their own accounts, is captured at first login and re-surfaced whenever the notice version changes materially.
- **Every consent record carries a notice version** — what the customer actually agreed to, at the time they agreed to it. Privacy notices change; being able to show what was in effect when consent was granted is the difference between a defensible record and an assertion.

---

## Enforcement Design

This is illustrative Snowflake SQL demonstrating the enforcement pattern — consistent with the rest of this project, it hasn't been executed against a live Snowflake account, the same honesty standard applied to the Terraform (`validate` passes, never `apply`'d).

### Consent registry

```sql
CREATE TABLE GOVERNANCE.CONSENT_REGISTRY (
    consent_id      STRING DEFAULT UUID_STRING(),
    tenant_id       STRING NOT NULL,
    subject_scope   STRING NOT NULL,   -- 'TENANT' | 'END_USER'
    subject_id      STRING,            -- NULL when subject_scope = 'TENANT'
    purpose         STRING NOT NULL,   -- 'AI_TRAINING' | 'PRODUCT_ANALYTICS' | 'MARKETING'
    consent_status  BOOLEAN NOT NULL,
    notice_version  STRING NOT NULL,
    granted_at      TIMESTAMP_NTZ,
    revoked_at      TIMESTAMP_NTZ,
    source          STRING             -- 'ONBOARDING_UI' | 'ADMIN_CONSOLE' | 'API'
);
```

This table is itself Regulated-tier under the classification scheme — it's a record of what PII processing was authorized, which is sensitive in its own right. Same masking/row access posture as any other Regulated data applies to it.

### Gating AI/secondary use — a scoped view, not a policy on the base table

An earlier version of this doc attached the consent check directly to `ANALYTICS.CUSTOMER_EVENTS` as a row access policy on `(tenant_id)`. That was wrong: a Row Access Policy applies to *every* query against the table it's attached to, regardless of who's asking. Filtering on AI-training consent status at the base-table level doesn't just block the training pipeline from a non-consenting tenant's data — it makes that tenant's own contract-basis BI dashboards return empty, since those dashboards query the same table. `multi_tenancy_isolation_model.md` already establishes the correct layering (tenant isolation RAP as the primary boundary, consent enforcement as an independent second layer) — the SQL below is what actually implements that separation instead of collapsing the two into one policy.

The tenant isolation row access policy already established in the Snowflake doc's Data Security section stays exactly as-is on `ANALYTICS.CUSTOMER_EVENTS` — every caller, BI or Cortex, still only sees their own tenant's rows, unaffected by anything below. Consent gating for the AI-training path is layered on top through a **secure view**, not a second policy on the base table:

```sql
CREATE SECURE VIEW GOVERNANCE.CUSTOMER_EVENTS_AI_TRAINING_SCOPE AS
SELECT ce.*
FROM ANALYTICS.CUSTOMER_EVENTS ce
WHERE EXISTS (
    SELECT 1 FROM GOVERNANCE.CONSENT_REGISTRY cr
    WHERE cr.tenant_id      = ce.tenant_id
      AND cr.purpose        = 'AI_TRAINING'
      AND cr.consent_status = TRUE
      AND cr.revoked_at IS NULL
);

-- The Cortex training/embedding pipeline reads through this view only —
-- it never has a grant on the base table directly.
GRANT SELECT ON VIEW GOVERNANCE.CUSTOMER_EVENTS_AI_TRAINING_SCOPE TO ROLE AI_TRAINING_PIPELINE_ROLE;
```

`CREATE SECURE VIEW`, not a plain view, so a holder of `AI_TRAINING_PIPELINE_ROLE` can't inspect the view definition or query plan to infer which tenants were filtered out — the fact that a tenant withheld consent isn't itself something the training pipeline's operators should be able to observe.

**Why this is the right enforcement point, not a Data Movement Policy alone:** Data Movement Policies (covered in the Snowflake doc) stop data from *leaving* — blocking `COPY INTO`. That's necessary but not sufficient here, because embeddings and agent context don't require data to leave Snowflake at all; Cortex reads it in place. Pointing Cortex Search indexing and any training/fine-tuning job at `CUSTOMER_EVENTS_AI_TRAINING_SCOPE` instead of the base table means a tenant that hasn't consented is invisible to the AI training pipeline at the query layer, before the question of data movement even comes up. The two controls are complementary: the scoped view prevents the read, the Data Movement Policy prevents the export, and revoking consent (`revoked_at` populated) takes effect on the next query against the view — no batch job, no propagation delay, and no impact on that tenant's own BI access, which never touches this view at all.

### Revocation is immediate, not eventually-consistent

Because the view's filter checks `CONSENT_REGISTRY` live at query time rather than a cached or batch-synced flag, a tenant revoking consent takes effect on their very next query against the AI-training scope — this is a materially stronger claim than "we'll stop using your data in our next processing cycle," which is what a lot of consent implementations actually deliver despite what the privacy notice says.

---

## Data Subject Rights (Access, Correction, Deletion)

| Right | Mechanism | Owner |
|---|---|---|
| Access | Query `CONSENT_REGISTRY` plus the tenant's own data via existing RBAC — a subject can be shown exactly what's on file and what purposes it's authorized for | Legal/Privacy, per the IR runbook's role definition |
| Correction | Standard update path through the admin console or API; writes a new `CONSENT_REGISTRY` row rather than mutating history, preserving the audit trail | Legal/Privacy + Cloud/Platform Engineer |
| Deletion / erasure | Row deletion plus consent revocation — **with an honest caveat** | Legal/Privacy + Cloud/Platform Engineer |

**The erasure caveat, resolved in `resilience_disaster_recovery.md`:** a `DELETE` in Snowflake doesn't make data unrecoverable immediately — it persists through the Time Travel retention window (up to 30 days for Regulated-tier data, per the tiered retention table in that doc) and then Fail-safe on top of that (a further fixed 7 days), up to 37 days worst case. The resolution isn't waiting out that window — it's crypto-shredding: Regulated-tier data subject to individual erasure requests is encrypted with a per-tenant key by default (escalating to per-subject where a specific end user needs independent erasure) at the application/pipeline layer before it lands in Snowflake, and a deletion request destroys that key via HCP Vault's Transit engine. The ciphertext ages out of Time Travel/Fail-safe over the following weeks, but it's unreadable from the moment the key is destroyed — cryptographically equivalent to erased, immediately. See `resilience_disaster_recovery.md` — Closing the Privacy Doc's Erasure Dependency — and `secrets_management.md` for the key management design itself.

**Fulfillment timing:** left as "per contractual/regulatory obligation, to be confirmed" rather than a hardcoded number — the same honest approach taken with breach notification timing in the IR runbook, and for the same reason: the real answer depends on jurisdiction and contract terms not yet fixed in this project.

---

## Third-Party Disclosure and the MSP Case

`incident_response_runbook.md`'s Managed Services section flagged that an MSP with standing access to Regulated-tier data is a subprocessor, and needs a Data Processing Agreement — not a nice-to-have. This is where that requirement actually lands: any subprocessor with access to data governed by `CONSENT_REGISTRY` needs to be reflected in what a tenant is told during consent capture ("your data may be processed by our operational partner X for purpose Y"), not disclosed only in a separate legal document the tenant never sees. Consent notice and subprocessor disclosure are the same conversation, not two.

---

## What This Closes

Updates `soc2_csf_compliance_crosswalk.md`:

- **P2.1 (Choice and Consent)** — Partial → **Built**. Tenant- and end-user-level consent capture, per-purpose granularity, notice versioning.
- **P8.1 (Monitoring and Enforcement)** — Partial → **Built**. `CONSENT_REGISTRY` plus the row access policy is the monitoring/enforcement mechanism; data subject rights table above is the complaint/request-handling process.
- **P3.1, P4.1–P4.3, P6.1** — already control-mapped, now reinforced with a concrete enforcement mechanism rather than resting on the classification scheme alone.

**Privacy section overall status: Built.** The deletion/erasure forward dependency flagged in the original version of this doc is now resolved in `resilience_disaster_recovery.md`.

---

## Sources

- Internal: `snowflake_data_security_guardrails.md`, `soc2_csf_compliance_crosswalk.md`, `incident_response_runbook.md`
