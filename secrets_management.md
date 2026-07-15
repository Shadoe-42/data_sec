# Secrets Management
*Meridian Analytics — a tiered model, and where it closes an open dependency | July 2026*

---

## Purpose

`resilience_disaster_recovery.md` resolved the privacy doc's erasure dependency with crypto-shredding — destroy a per-subject or per-tenant key, and the ciphertext becomes unreadable immediately, independent of Time Travel/Fail-safe retention. What that doc didn't do is design the key management service the whole mechanism depends on. This doc is that design, set inside a broader tiered secrets model that also covers the ordinary application secrets every environment needs regardless of the crypto-shredding story.

The organizing principle, borrowed directly from how this project already talks about infrastructure: everything Terraform builds is disposable and rebuildable from source. Secrets aren't — a leaked or lost secret has consequences Terraform can't regenerate away, which is exactly why they get a tiered, deliberate model instead of one uniform answer.

---

## Three Tiers

| Tier | Mechanism | Used for |
|---|---|---|
| 1 — Cloud-managed | AWS Secrets Manager (AWS-managed KMS key) / GCP Secret Manager (Google-managed encryption) | Ordinary operational secrets — API keys for non-regulated integrations, service credentials touching Internal-tier data |
| 2 — Customer-managed key | AWS Secrets Manager backed by a customer-managed KMS key / GCP Secret Manager with CMEK via Cloud KMS | Secrets touching Customer Confidential-tier data — the org controls the encryption key's policy and rotation, even though the storage service itself is still fully managed |
| 3 — Joint control (Vault Transit) | HCP Vault's Transit secrets engine | The per-subject/per-tenant data encryption keys behind crypto-shredding, specifically — Regulated-tier only |

Tiers 1 and 2 are deliberately native cloud services, not Vault — consistent with the managed-service-first posture everywhere else in this project. Self-hosting a Vault cluster for ordinary secrets would introduce the first piece of hand-operated infrastructure into an architecture that has otherwise avoided that entirely.

---

## Why Tier 3 Needs Vault, Specifically

Neither AWS Secrets Manager nor GCP Secret Manager performs cryptographic operations on a caller's behalf while keeping the key material inaccessible — they store and retrieve secrets. Vault's Transit engine is a different primitive: encryption-as-a-service. The calling pipeline sends plaintext, gets ciphertext back, and never holds, caches, or transmits the actual key.

That distinction is exactly what crypto-shredding needs. The ingest pipeline encrypting a new record and the erasure workflow destroying a key later both call Vault's API; neither one ever needs the key material itself. Destroying a named key is a single, clean, audited action — and once deleted, decrypting anything encrypted under that key becomes permanently impossible. That's the actual mechanism "destroy the key = immediate cryptographic erasure" depends on, not just an assertion.

---

## Key Granularity — Tenant Default, Subject-Level Escalation

`resilience_disaster_recovery.md` left this open as "per-subject or per-tenant." Resolving it: **per-tenant keys by default**, with **per-subject keys reserved for a specific end user exercising an individual erasure right without the tenant relationship ending.**

Per-subject keys for every individual end user by default would mean tens of thousands to millions of Transit keys across Meridian's customer base — technically supportable by Vault, but real operational and audit overhead for a case that mostly doesn't need that granularity. Most erasure events are tenant-initiated (an end user leaves an organization, a tenant offboards entirely) and a tenant-level key handles that cleanly. The escalation path exists specifically for the GDPR-style case of one end user within a continuing tenant relationship exercising their own right to erasure — this mirrors the same tiered-escalation logic already used in `multi_tenancy_isolation_model.md` rather than introducing a new pattern.

```
# Standard case: tenant-level key, created once per tenant at onboarding
vault write -f transit-crypto-shred/keys/tenant-<tenant_id>

# Escalation case: subject-level key, created only when a specific end user
# needs independent erasure without affecting the rest of their tenant's data
vault write -f transit-crypto-shred/keys/tenant-<tenant_id>-subject-<subject_id>

# Ingest pipeline encrypts under the appropriate key
vault write transit-crypto-shred/encrypt/tenant-<tenant_id> \
  plaintext=$(base64 <<< "<sensitive field value>")

# Genuine erasure: deletion must be explicitly enabled before it's possible --
# a deliberate two-step guard against an accidental single delete call
vault write transit-crypto-shred/keys/tenant-<tenant_id>/config deletion_allowed=true
vault delete transit-crypto-shred/keys/tenant-<tenant_id>
# Every ciphertext ever encrypted under this key is now permanently unreadable.
```

**Access control to Vault itself follows the same RBAC/AD-group model already established elsewhere in this project** — the ingest pipeline's service identity gets an `encrypt`-only policy; the erasure workflow's service identity gets a narrowly scoped policy permitting the `config` update and `delete` call and nothing else. No human operator has standing access to encrypt or decrypt Regulated-tier data through Vault as a matter of course.

```hcl
# ingest-pipeline-policy.hcl -- encrypt only, no decrypt, no key management
path "transit-crypto-shred/encrypt/*" {
  capabilities = ["update"]
}

# erasure-workflow-policy.hcl -- key destruction only
path "transit-crypto-shred/keys/*/config" {
  capabilities = ["update"]
}
path "transit-crypto-shred/keys/*" {
  capabilities = ["delete"]
}
```

**Rotation is a separate concern from erasure.** Vault Transit supports key rotation — creating a new key version while retaining old versions for decrypting historical ciphertext — paired with `min_decryption_version` to retire old versions from active use. Rotation cadence for Regulated-tier keys should be more frequent than Tier 1/2 secrets, but rotating a key and destroying a key are different operations serving different purposes; conflating them would blur the erasure guarantee this whole design exists to make precise.

---

## Vendor Risk — HCP Vault as a Named Subprocessor

The moment Vault holds Regulated-tier key material, HashiCorp becomes a named subprocessor, requiring the same treatment already established for an MSP in `incident_response_runbook.md`: a specific agreement, not an assumption. Two facts worth weighing in that review, stated plainly rather than glossed over: HCP Vault carries its own SOC 2 Type II attestation — a subprocessor holding the same assurance level Meridian is targeting for itself is a coherent vendor-risk posture, not just a trust exercise. HashiCorp is now owned by IBM (announced 2024, closed 2025), which generally supports lower vendor risk — a larger, better-capitalized, more risk-averse parent than an independent company of HashiCorp's prior size. The one honest caveat: M&A integration periods can introduce short-term roadmap or support uncertainty even when the acquirer is stable. Worth a line in a real vendor risk review, not a reason to reconsider the choice.

---

## Explicitly Out of Scope: Dynamic Secrets

Vault can also mint short-lived, dynamically-provisioned credentials on demand — a database credential generated per session that expires automatically, for instance — which would extend the "no long-lived exportable keys" posture already built into this project (STS assumption instead of stored AWS access keys, no service account key creation in GCP, GitHub OIDC federation for the CI role). It's a genuinely good fit philosophically. It's also a distinct capability from the crypto-shredding use case, and bundling it in now just because it's the same product would be scope creep, not a right-sized decision. Flagged as a strong candidate for a later phase, not built here.

---

## What This Closes

Resolves the one open dependency `resilience_disaster_recovery.md` explicitly flagged: the per-subject/per-tenant key management service behind crypto-shredding is no longer asserted, it's designed — mechanism, granularity decision, access control, and vendor-risk treatment all specified. `resilience_disaster_recovery.md`'s erasure section should be read as pointing here for the "how," not treating the key service as a black box.

---

## Sources

- [Transit secrets engine | Vault | HashiCorp Developer](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Transit secrets engine (API) | Vault | HashiCorp Developer](https://developer.hashicorp.com/vault/api-docs/secret/transit)
- Internal: `resilience_disaster_recovery.md`, `privacy_consent_management.md`, `multi_tenancy_isolation_model.md`, `incident_response_runbook.md`
