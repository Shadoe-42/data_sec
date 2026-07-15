# Incident Response Runbook
*Meridian Analytics — Snowflake + AWS/GCP | scenario-driven | July 2026*

---

## Purpose

This closes the Respond gap flagged in `soc2_csf_compliance_crosswalk.md` (CC7.3–CC7.4, CSF's Respond function). The other docs in this project describe detection and prevention controls in depth; none of them answer "what actually happens when one of those controls fires." This does — for three concrete scenarios, not as an abstract policy.

It's also written from a specific angle the other docs aren't: this isn't purely Meridian's internal SecOps runbook. A Technical Account Manager at a Snowflake implementation partner has a defined role during a client's incident — distinct from running the response — and that role gets its own section rather than being an afterthought.

---

## Severity Classification

| Severity | Definition | Example | Response clock starts |
|---|---|---|---|
| **SEV1** | Confirmed unauthorized access to Regulated-tier data, or active data exfiltration | Successful `COPY INTO` of PII outside an authorized workflow | Immediately, 24/7 |
| **SEV2** | Suspicious activity blocked by a control, or anomalous access pattern under investigation | A Data Movement Policy blocks an agent-initiated `COPY INTO`; unusual query volume against Customer Confidential data | Within 1 hour |
| **SEV3** | Policy violation with no evidence of data exposure | A blocked access-key creation attempt (SCP denial), a failed login pattern within normal noise | Next business day, logged for trend analysis |

Severity is assigned at triage, not at detection — the alert firing is not the same thing as the incident being real. Getting that distinction wrong in either direction (treating every SCP denial as a SEV1, or sitting on a real exfiltration attempt because it "looked like noise") is itself a finding an auditor will ask about.

---

## Roles

Who holds each role depends on the engagement model — see **Engagement Model: Advisory vs. Managed Services**, below, for the full reasoning. This table shows both.

| Role | Advisory engagement | Managed Services engagement | Notes |
|---|---|---|---|
| Incident Commander | Meridian | Joint — MSP runs technical IC, Meridian retains executive IC | Under MSP, expect a two-tier IC structure defined in the services agreement, not a single owner |
| Detection/SecOps | Meridian | MSP (Responsible) | Under MSP, the partner's own monitoring may detect and triage before Meridian ever sees a raw alert |
| Cloud/Platform Engineer | Meridian | MSP (Responsible) | Containment actions (revoke roles, rotate keys, adjust policy) are executed by MSP staff operating inside Meridian's environment |
| Legal/Privacy | Meridian | **Meridian, always** | Does not shift under any engagement model — see below |
| Communications | Meridian | Meridian (Accountable), MSP may draft/support | Customer- and board-facing messaging stays Meridian's voice regardless of who ran containment |
| **Technical Account Manager / partner** | Client-facing liaison — see dedicated section below | Service owner — see dedicated section below | The TAM's actual job changes materially between the two models; this is not the same role wearing two hats |

---

## Engagement Model: Advisory vs. Managed Services

A Snowflake implementation and AI delivery partner commonly operates under two different engagement models with a client, and they are not interchangeable for incident response purposes — the material differences below aren't stylistic, they change who is legally and operationally on the hook when something goes wrong.

**Advisory / Consultancy model.** Meridian owns and operates its own environment. The partner's staff (architects, TAMs) advise, review, and are engaged for specific projects or as an escalation path — but Meridian's own SecOps and platform engineers hold the keys and execute containment. The partner shows up during an incident because Meridian calls them in, not because they're staffed to respond by default.

**Managed Services (MSP) model.** The partner operates Meridian's Snowflake/data/AI environment on an ongoing basis under a services agreement — meaning the partner's own staff, not Meridian's, are the ones with standing access, standing monitoring, and standing responsibility for day-to-day operations. Detection and containment shift from "Meridian does this, the partner advises" to "the partner does this, under SLA."

**What doesn't change between the two models:** Legal/Privacy accountability stays with Meridian regardless of who's operating the environment. This isn't a stylistic choice — under most privacy and data protection frameworks, the entity that determines *why* data is processed (the controller) retains accountability even when a service provider (a processor, or in this case an MSP) handles the *how*. An MSP can be Responsible for executing a response; it cannot absorb Meridian's Accountability for deciding whether a breach notification is legally required.

**Severity timers become contractual, not just internal, under MSP.** The Severity Classification table above defines target response times. Under an Advisory model those are Meridian's own internal targets. Under a Managed Services model, they're typically SLA commitments in the services agreement — acknowledgment time, containment time, sometimes with financial penalties attached. Conflating "our target" with "our contractual obligation" is the kind of imprecision that reads as inexperience to a client's legal team reviewing the agreement.

**The MSP itself becomes a second vendor-risk line, not just Snowflake.** This connects directly to `soc2_csf_compliance_crosswalk.md` — specifically the Govern section's CC9.1–CC9.2 (vendor/third-party risk) and the Privacy section's P6.1 (disclosure to third parties), both already in that doc. If MSP staff have hands-on access to Regulated-tier PII as a normal part of daily operations, the MSP is a subprocessor, not just a service vendor, and Meridian's privacy program needs to account for a second party with standing access, not only Snowflake — see `privacy_consent_management.md`'s Third-Party Disclosure section, which folds subprocessor disclosure into consent notice rather than treating it as a separate legal-only document. A Data Processing Agreement (or equivalent subprocessor terms) with the MSP becomes a real requirement under this model, not a nice-to-have.

**Access architecture is a genuine design question under MSP, not just a paperwork one.** Every IAM/Identity Center binding in this project's landing zones is currently driven by Meridian's own AD group JSON — there's no model yet for a second organization's staff needing standing access. The right pattern is federating the MSP's own IdP into Meridian's environment with tightly scoped, time-bound permission sets — not creating individually named Meridian accounts for MSP staff, and not handing out shared credentials. Worth noting explicitly: the `break-glass` tag exception in `terraform/aws-lz/scps.tf` was designed around an internal actor bypassing a control in an emergency. Under an MSP model, that exception needs a second look — an external party with a standing break-glass exception is a materially different risk than an internal one, even if the Terraform resource looks identical.

---

## Detection Sources (what actually fires)

Every source referenced here is a control that already exists in this project — this table is not aspirational.

- **Snowflake Horizon AI Guardrails** — prompt injection attempts against Cortex agents
- **Snowflake Data Movement Policies** — blocked `COPY INTO` / exfiltration-path attempts, especially agent-initiated
- **Snowflake `ACCOUNT_USAGE.LOGIN_HISTORY` / `ACCESS_HISTORY`** — anomalous authentication or query patterns
- **Organization CloudTrail trail (AWS)** / **org-level Cloud Audit Log sinks (GCP)** — SCP/org-policy denials, IAM changes, any action across any account/project, no opt-out
- **VPC Flow Logs (both clouds)** — anomalous network activity within the landing zone
- **AWS Budgets / GCP Billing Budget alerts** — not security controls per se, but a cost spike is sometimes the first visible symptom of a compromised credential being used for something like crypto-mining or bulk data transfer

---

## Scenario 1 — Unauthorized Access to Regulated-Tier Data

**Trigger:** Snowflake `ACCESS_HISTORY` shows a role querying Regulated-tier (PII) columns outside its normal pattern, or a Data Movement Policy blocks an unexpected `COPY INTO` against a Regulated-tagged table.

| Phase | Action |
|---|---|
| Detect | Alert from Data Movement Policy block, or anomaly in `ACCESS_HISTORY` query patterns |
| Triage | SecOps confirms: was this a legitimate role performing an unusual-but-valid query, or unauthorized access? Check whether the querying principal's access was recently modified (cross-reference AD group JSON / IAM Identity Center assignment history) |
| Contain | Suspend the implicated Snowflake role or IAM Identity Center permission set assignment immediately — this is a revoke, not a discussion. If credential compromise suspected, force-rotate any associated keys (though access-key creation is SCP-denied org-wide, so this is almost always a role/session revocation, not a key rotation) |
| Eradicate | Determine how the principal obtained inappropriate access — misconfigured Row Access Policy, over-broad Permission Set assignment, or a genuine compromise. Fix the underlying grant, not just the symptom |
| Recover | Restore correct access for legitimate users affected by containment; verify masking/row access policies are enforcing correctly post-fix |
| Post-incident | Document in the audit trail (this itself becomes SOC 2 evidence for CC7.3–CC7.4); update the AD group JSON / Terraform if the root cause was an over-broad grant, so the fix is in source control, not a manual one-off |

---

## Scenario 2 — Compromised Credential / Anomalous IAM Activity

**Trigger:** CloudTrail or Cloud Audit Logs show an SCP/org-policy denial for a sensitive action (e.g., `iam:CreateAccessKey` blocked by the `deny-access-key-creation` SCP) from a principal that shouldn't be attempting it, or an unusual pattern of IAM Identity Center / Cloud Identity login activity.

| Phase | Action |
|---|---|
| Detect | SCP/org-policy denial event in the org-level audit trail; the denial itself is the detection — this is the value of deny-by-default: the attempt is visible even though it failed |
| Triage | Was this a legitimate engineer hitting a guardrail by mistake, or a sign of compromise (e.g., unfamiliar source IP, off-hours activity, a service account behaving like a human)? |
| Contain | Suspend the principal's session/credentials; if a human account, force re-authentication with MFA; if a workload identity, rotate the underlying trust relationship (GitHub OIDC claim, Workload Identity binding) |
| Eradicate | Identify how the credential was obtained if compromise is confirmed — phishing, leaked credential, over-permissioned break-glass tag left active longer than intended |
| Recover | Restore normal access for the legitimate principal; confirm the SCP/org-policy that caught the attempt is still correctly attached (verify it wasn't the thing that got tampered with) |
| Post-incident | This is the scenario most worth walking a client through as a *positive* story — "our guardrails caught this before it succeeded" is a stronger narrative than most companies get to tell, precisely because deny-by-default turns a near-miss into a visible, auditable event instead of a silent failure |

---

## Scenario 3 — AI Agent Security Event

**Trigger:** Horizon AI Guardrails flags a prompt injection attempt against a Cortex agent, or a Data Movement Policy specifically blocks an agent-initiated (not human-initiated) `COPY INTO`.

| Phase | Action |
|---|---|
| Detect | Horizon Guardrails alert, or Data Movement Policy block attributed to an agent principal rather than a human role |
| Triage | Was this an external prompt injection attempt (a user trying to manipulate the agent into exposing data outside its scope), or an internal misconfiguration (an agent given broader RBAC/ABAC scope than intended)? These have very different follow-ups |
| Contain | Suspend the agent's access (same RBAC/ABAC revocation mechanism as a human principal — this is the payoff of Snowflake's "agent is just another principal" model referenced in the Snowflake doc's Agent Security section) |
| Eradicate | If prompt injection: confirm Horizon Guardrails held the line and no data actually moved — the control working as designed is not the same thing as no incident occurred, it still gets logged and reviewed. If misconfiguration: correct the agent's RBAC/ABAC scope, don't just re-enable it |
| Recover | Re-enable the agent only after scope is confirmed correct; consider whether the incident reveals a class of agents (not just one) that need the same review |
| Post-incident | This is the scenario a Snowflake-fluent AI-data audience will care about most — walking through it cleanly, with the "bring the model to the data" architecture point (data never left Snowflake's boundary even during the attempted injection) is a stronger answer than generic "we have AI guardrails" language |

---

## The TAM's Role During a Client Incident

This is the section that doesn't exist in a typical internal IR runbook, because it isn't Meridian's own document in a real engagement — it's the partner's. The specifics depend heavily on which of the two engagement models above is in play; treating them as the same job is the mistake to avoid.

### Under an Advisory engagement

A Technical Account Manager isn't running Meridian's response here. The value is elsewhere:

- **Client-facing liaison, not incident commander.** The TAM's job is to be the calm, informed point of contact the client's leadership can call, not to personally revoke roles or rotate keys — that's the client's own SecOps/platform team, per the roles table above.
- **Escalation path into the platform vendor.** If the incident implicates a Snowflake platform behavior (not a misconfiguration on the client's side), the TAM is the one who knows how to escalate into Snowflake Support at the right severity, and has the relationship to get it prioritized — that's the actual leverage a partner provides that the client doesn't have on their own.
- **Translating technical detail upward.** During an active incident, a client's VP or CTO wants a coherent five-minute summary, not a raw CloudTrail export. The TAM is often the one who takes what SecOps found and makes it legible to the stakeholder who has to decide whether to notify customers or the board.
- **Post-incident retro, as a participant not a bystander.** Showing up to the post-mortem with a specific "here's what I'd change in the guardrails" recommendation — not just attending — is what turns an incident into a stronger long-term relationship instead of a moment of doubt about the partnership.
- **Knowing what NOT to do.** A TAM overstepping into hands-on remediation during a live incident, without being asked, is a trust violation, not a value-add — the instinct to help has to be channeled through the client's own incident commander, not around them.

### Under a Managed Services engagement

The job changes shape. The TAM is no longer the exception that gets called in — they're accountable for a service that's already running, and that's a fundamentally different posture during a live incident:

- **Service owner, not outside advisor.** The TAM is accountable for the MSP's own SecOps and platform engineering staff performing to the SLA committed in the services agreement — that's a standing operational responsibility, not something activated by a phone call.
- **SLA compliance is now part of the incident itself.** Whether the MSP hit its contracted acknowledgment and containment times is a fact the client's leadership will ask about, often before they ask about root cause. The TAM needs to know that answer in real time, not reconstruct it after the fact.
- **Coordinating the MSP's internal response, in addition to the client relationship.** There's now an internal chain (the MSP's own detection/containment staff) that the TAM has to manage alongside the external one (Meridian's executive IC and leadership) — genuinely two audiences, not one.
- **Owns the subprocessor conversation, not just the technical one.** If the incident raises questions about what data the MSP's own staff could access, the TAM is the one who has to speak credibly to the Data Processing Agreement terms and the vendor-risk posture described above — this is where the job overlaps with what would otherwise be Legal's territory, without actually replacing Legal's accountability.
- **The same restraint principle still applies, just at a different altitude.** Under Advisory, the discipline is "don't do hands-on remediation you weren't asked to do." Under Managed Services, the equivalent discipline is "don't let operational firefighting substitute for the executive communication Meridian's leadership actually needs" — being deep in the technical response doesn't excuse under-communicating upward.

---

## Breach Notification (framework, not a hardcoded number)

Meridian's actual notification obligations depend on facts not fixed in this project — what data was actually exposed, which jurisdictions its customers and their end users are in, and what's in Meridian's own customer contracts. Rather than hardcode a single timeline (the temptation is to just say "72 hours" because GDPR made that number famous), the honest framework is:

- **Regulatory timelines**, if triggered, are jurisdiction-specific (GDPR's 72-hour supervisory authority notification is the most well-known, but it only applies if EU/EEA personal data is in scope — not yet established for Meridian's actual customer base in this project).
- **Contractual timelines** with enterprise customers are frequently tighter than regulatory minimums and are the ones that actually get enforced first in practice.
- **Legal/Privacy owns this determination** — it is explicitly not a call the Incident Commander or the TAM makes unilaterally, which is why it's a distinct role in the table above.
- **Under a Managed Services engagement specifically**, the notification analysis has one more layer: whether the MSP's own access to the affected data triggers subprocessor breach-notification terms in the Data Processing Agreement, separate from Meridian's obligations to its own customers. Two notification chains, not one — worth stating plainly rather than assuming the MSP relationship is invisible to the analysis.

---

## What This Closes

Updates the SOC 2/CSF crosswalk: **Respond (CC7.3–CC7.4)** moves from Partial to Built, evidenced by this document plus the audit-trail requirement in each scenario's Post-incident step. **Recover (A1.3/CC7.5)** was Partial at the time this runbook was written — this runbook covers incident response, not disaster recovery/Time Travel/Fail-safe — and was later closed by `resilience_disaster_recovery.md`. Current status of every crosswalk function lives in `TRACKING.md`, not in this paragraph.

The Advisory vs. Managed Services section also strengthens two rows that were already in the crosswalk but thinly evidenced: **Govern CC9.1–CC9.2** (vendor/third-party risk) now explicitly covers the MSP as a second vendor-risk line, not just Snowflake; and it sharpened what was, at the time, a Partial **Privacy** section — a Data Processing Agreement with the MSP was a named, concrete requirement rather than an abstract gap, and Privacy was subsequently closed by `privacy_consent_management.md`.

---

## Sources

- Internal: `snowflake_data_security_guardrails.md`, `account_landing_zone_guardrails.md`, `soc2_csf_compliance_crosswalk.md`
