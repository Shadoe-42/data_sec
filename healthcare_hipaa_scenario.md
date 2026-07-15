# Second Scenario: Healthcare Data Stewardship (HIPAA)
*Meridian Health — same architecture, different regulatory driver | July 2026*

---

## Purpose

Every other doc in this project proves the architecture works for one regulatory driver: SOC 2 and NIST CSF, built around a B2B SaaS company's own customer data. That's not the same as proving the underlying judgment generalizes. Healthcare data stewardship is a specific, growing case worth testing that against directly — the entities handling clinical and claims data are no longer just hospitals and insurers; a widening set of outside analytics and AI companies now ingest healthcare data under contract to build products, benchmarks, and models on top of it. That's a materially different compliance posture than the one already built, and it's worth reasoning through deliberately rather than treating it as a smaller version of the same problem.

This doc doesn't rebuild the project. It reuses the exact same AWS/GCP landing zone, the exact same Snowflake security model, and points at what changes and what doesn't when the regulatory driver is HIPAA instead of SOC 2.

**Not legal advice.** HIPAA has real legal complexity — this doc reasons about the architecture and control implications at a level appropriate for a technical conversation, not a substitute for counsel reviewing an actual BAA or breach response.

---

## Scenario

**Meridian Health** — a sibling scenario to Meridian Analytics, built on the identical technology stack, but with a different customer base: hospital systems, health plans, and clinical research organizations that contract with Meridian Health to run population health analytics, risk modeling, and (increasingly) AI-driven insights on their data. Meridian Health doesn't provide direct patient care and doesn't bill insurance — it's a vendor that healthcare organizations grant access to their data.

That single fact changes the entire compliance frame.

---

## Covered Entity vs. Business Associate — Why This Distinction Drives Everything Else

HIPAA's Privacy and Security Rules are built around two roles:

- **Covered Entities** — health plans, healthcare clearinghouses, and healthcare providers who transmit health information electronically in connection with certain transactions. Meridian Health's hospital and payer clients are Covered Entities.
- **Business Associates** — any person or organization that performs a function or activity involving the use or disclosure of Protected Health Information (PHI) on behalf of a Covered Entity. **Meridian Health is a Business Associate, not a Covered Entity.**

This is the load-bearing distinction the rest of this doc hangs on. A Business Associate Agreement (BAA) between Meridian Health and each client is the legal instrument that makes any of this permissible at all — it's the healthcare-specific equivalent of the Data Processing Agreement already established as an MSP requirement in `incident_response_runbook.md`, except HIPAA makes the BAA a specific, named, statutorily-required document rather than a general best practice. No BAA, no lawful access to PHI, regardless of how good the technical controls are.

---

## What Stays Exactly the Same

Everything at the infrastructure and platform layer transfers unchanged — this is the actual point of the exercise:

- `account_landing_zone_guardrails.md` — the AWS/GCP landing zone, SCPs, org policies, private connectivity pattern. HIPAA doesn't require different network architecture; it requires the same architecture applied with documented rigor.
- `snowflake_data_security_guardrails.md` — RBAC/ABAC, Tri-Secret Secure, Dynamic Data Masking, Row Access Policies, Data Movement Policies. All directly applicable; PHI is simply a Regulated-tier classification, not a new control category.
- `resilience_disaster_recovery.md` — Time Travel/Fail-safe mechanics and tiered RTO/RPO reasoning apply unchanged.
- `multi_tenancy_isolation_model.md` — if Meridian Health serves multiple health system clients on shared infrastructure, the same tiered isolation decision (shared-schema vs. database-per-tenant vs. account-per-tenant) applies, and a hospital system client demanding physical separation is exactly the kind of tenant this doc's escalation path already accounts for.
- `snowflake_compute_finops.md` — warehouse sizing and cost attribution reasoning is domain-agnostic.

---

## What's Different

**Business Associate Agreement, not just a DPA.** A BAA is a specific, HIPAA-mandated contract (45 CFR § 164.504(e)) — it must name permitted uses of PHI, require appropriate safeguards, mandate breach reporting to the Covered Entity, and flow down the same obligations to any subcontractor Meridian Health itself uses (an MSP or cloud provider handling PHI is a subcontracted Business Associate, one more link in the same chain already reasoned through in the IR runbook's MSP section).

**The Minimum Necessary Standard.** HIPAA requires reasonable efforts to limit PHI use and disclosure to the minimum necessary to accomplish the intended purpose (45 CFR § 164.502(b)). This isn't a new control — it's a review lens applied to the RBAC design already built. Every role grant against PHI-classified data needs an answer to "why does this role need this specific field," not just "does this role have a legitimate business reason to touch this table."

**De-identification as the actual secondary-use enabler — and where the AI Context tag gets sharper.** The AI Context tag in `snowflake_data_security_guardrails.md` flags that using data for a secondary purpose (embeddings, benchmarking, model training) raises a provenance and consent question. HIPAA gives that question a formal resolution path that the original SaaS scenario doesn't have: properly de-identified data falls entirely outside HIPAA's regulatory scope and can be used far more freely, including for the kind of cross-client benchmarking or model training that would otherwise require per-client, per-purpose authorization.

Two accepted de-identification methods:
- **Safe Harbor** (45 CFR § 164.514(b)(2)) — remove all 18 specified identifier categories (names, geographic subdivisions smaller than a state, all dates directly tied to an individual except year, phone/fax/email, medical record and account numbers, biometric identifiers, full-face photos, and others), with no actual knowledge that the remaining data could still identify someone.
- **Expert Determination** (45 CFR § 164.514(b)(1)) — a qualified expert applies accepted statistical or scientific methods to determine re-identification risk is very small, and documents the analysis.

The architectural implication: Meridian Health's data pipeline needs a genuine de-identification stage — not just masking at query time — before data is eligible for the AI Context tier's secondary-use cases. Dynamic Data Masking (already built) controls *who sees* an identifier; it doesn't remove HIPAA's regulatory interest in the underlying data, because the identifier still exists in the table. Safe Harbor / Expert Determination de-identification is a different, stronger claim: the data stops being PHI at all. Worth being precise about that difference rather than assuming masking alone gets Meridian Health to the same place.

**Breach Notification Rule — the one framework in this project with an actual hard number.** Every other doc in this project deliberately leaves breach notification timing as "jurisdiction-specific, contractual" rather than inventing a number. HIPAA doesn't leave it open: the Breach Notification Rule (45 CFR §§ 164.400–414) requires notification without unreasonable delay and no later than **60 days** following discovery. As a Business Associate, Meridian Health's specific obligation is to notify the affected Covered Entity within that 60-day window — the Covered Entity, in turn, notifies the individuals (and HHS, and media if 500+ residents of a state are affected). This is a direct extension of the controller/processor accountability distinction already established in `incident_response_runbook.md`: the Business Associate can detect and report, but notifying patients and HHS is the Covered Entity's obligation, not Meridian Health's, unless the BAA specifically delegates it.

**Retention — two different clocks, not one.** HIPAA does not itself set a retention period for PHI/medical records — that's governed by state law and varies widely. What HIPAA does mandate (45 CFR § 164.316(b)(2)) is retention of *HIPAA compliance documentation* — policies, risk assessments, BAAs, training records — for **6 years** from creation or last effective date, whichever is later. Two different retention clocks, commonly conflated; worth keeping them explicitly separate in any real implementation.

**Right of Access — a different mechanism than the SaaS consent model.** `privacy_consent_management.md`'s Data Subject Rights table is built on a contract/consent framework suited to a SaaS product with its own end users. HIPAA's Right of Access (45 CFR § 164.524) is a regulatory right an individual holds against the *Covered Entity* — generally a 30-day response window, extendable once by 30 more days with notice. As a Business Associate, Meridian Health doesn't typically hold that obligation directly; it flows through the BAA as an obligation to support the Covered Entity's response, not to field patient requests itself. A genuinely different rights structure from the GDPR/CCPA-style consent model built for Meridian Analytics, not a rename of the same mechanism.

---

## HIPAA Security Rule, Mapped to the Same CSF Functions

The point of reusing NIST CSF 2.0's six functions as the crosswalk's spine in `soc2_csf_compliance_crosswalk.md` was that it's cross-referencing vocabulary, not SOC-2-specific. Proof of that:

| CSF Function | HIPAA Security Rule Safeguard | Meridian Health Control |
|---|---|---|
| Govern | Administrative safeguards — designated security official, workforce training | Same Snowflake RBAC governance model; add HIPAA-specific role training and a designated Security Official role, distinct from the existing platform admin roles |
| Identify | Risk analysis requirement (45 CFR § 164.308(a)(1)) | Data classification scheme already built, with PHI mapped to Regulated tier and the BAA scope defining what's actually in play per client |
| Protect | Technical safeguards — access control, encryption, transmission security | RBAC/ABAC, Tri-Secret Secure, Dynamic Data Masking, private connectivity — all directly reused |
| Detect | Audit controls (45 CFR § 164.312(b)) | Existing audit logging (CloudTrail/Cloud Audit Logs, both cross-region replicated) — the same evidence pattern as the SOC 2 crosswalk, pointed at PHI access specifically |
| Respond | Breach Notification Rule | `incident_response_runbook.md`'s scenarios apply; the 60-day Business-Associate-to-Covered-Entity notification clock is the HIPAA-specific addition |
| Recover | Contingency plan requirement (45 CFR § 164.308(a)(7)) | `resilience_disaster_recovery.md`'s tiered RTO/RPO reasoning applies; HIPAA additionally expects a documented, tested contingency plan specifically, not just a general DR posture |

---

## What This Doesn't Change

This is still reference architecture and reasoning — no real BAA exists, no real Covered Entity client exists, and the de-identification pipeline described above is a design, not something implemented against real data. The same "architecturally complete, operationally unproven" honesty standard from `soc2_csf_compliance_crosswalk.md` applies here too.

---

## Sources

- [HHS: Business Associates](https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/business-associates/index.html)
- [HHS: Minimum Necessary Requirement](https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/minimum-necessary-requirement/index.html)
- [HHS: Methods for De-identification of PHI](https://www.hhs.gov/hipaa/for-professionals/privacy/special-topics/de-identification/index.html)
- [HHS: Breach Notification Rule](https://www.hhs.gov/hipaa/for-professionals/breach-notification/index.html)
- [HHS: Summary of the HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/laws-regulations/index.html)
- Internal: `account_landing_zone_guardrails.md`, `snowflake_data_security_guardrails.md`, `soc2_csf_compliance_crosswalk.md`, `incident_response_runbook.md`, `privacy_consent_management.md`, `resilience_disaster_recovery.md`, `multi_tenancy_isolation_model.md`
