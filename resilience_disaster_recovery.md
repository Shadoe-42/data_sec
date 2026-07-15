# Resilience & Disaster Recovery
*Meridian Analytics — Time Travel, Fail-safe, tiered RTO/RPO | July 2026*

---

## Purpose

Closes the last open gap in `soc2_csf_compliance_crosswalk.md`: Recover (A1.3/CC7.5). It's also the doc that `privacy_consent_management.md` explicitly deferred to — that doc's deletion/erasure story wasn't complete without an honest account of how long deleted data actually persists in Snowflake and what makes it truly unrecoverable rather than just inaccessible through normal SQL.

Two things live in this doc that are easy to conflate but aren't the same: Snowflake's own native resilience mechanics (Time Travel, Fail-safe — how Snowflake protects data from accidental loss), and Meridian's formal disaster recovery posture (RTO/RPO targets, what "recovered" actually means, and how the AWS/GCP landing zone infrastructure itself holds up). Snowflake's mechanics are a piece of the DR story, not the whole thing.

---

## Time Travel

**What it is:** the ability to query, clone, or restore data as it existed at a point in the past — `SELECT ... AT(TIMESTAMP => ...)`, `UNDROP TABLE`, cloning a table as of yesterday. This is the first line of defense against the most common real-world data loss event: someone ran a bad `DELETE`, `UPDATE`, or `DROP` and needs it back, not a catastrophic infrastructure failure.

**Retention window:**

| Edition | Default | Configurable range |
|---|---|---|
| Standard | 1 day (24 hours) | Not adjustable beyond 1 day |
| Enterprise and above | 1 day | 0–90 days, set via `DATA_RETENTION_TIME_IN_DAYS` at account, database, schema, or table level |

**Cost implication — this is also a FinOps decision, not just a resilience one:** every day of Time Travel retention is additional storage Snowflake bills for, on every change to the data. Setting a 90-day retention window account-wide because "more recovery time is safer" is the same over-engineering instinct already flagged elsewhere in this project (Tri-Secret Secure applied everywhere instead of where it's justified). The right move is tiering retention to the data classification scheme already established, not a single global number.

### Recommended Time Travel retention, by classification tier

| Tier | Retention | Reasoning |
|---|---|---|
| Public / Internal | 1 day (Standard default) | Low value in extended history; cost isn't justified |
| Customer Confidential | 7 days | Enough window to catch a bad batch job or accidental mutation discovered a few days later, without paying for months of storage on data that changes frequently |
| Regulated | 30 days | Balances recovery capability against the reality that this is also the highest-cost tier to retain; 90 days is available but not the default — would need a specific business or contractual reason to justify tripling the storage cost over 30 |
| AI Context (tag) | Inherits source tier | Same reasoning as everywhere else this tag appears — it doesn't get its own resilience posture, it inherits the underlying data's |

---

## Fail-safe

**What it is:** a fixed, non-configurable 7-day period immediately following the end of the Time Travel window, during which Snowflake — not the customer — can potentially recover data from a permanent table that's been dropped or corrupted. It is not self-service: there's no `SELECT ... AT()` into Fail-safe. Recovery requires contacting Snowflake Support, and it's positioned as a last resort for disaster recovery, not a routine operation.

**What doesn't get Fail-safe:** transient and temporary tables skip it entirely — no extra storage charge, no 7-day tail. That's a deliberate tradeoff already worth naming explicitly in an architecture conversation: staging tables, intermediate transformation steps, and other non-permanent working data should often be transient specifically to avoid carrying Fail-safe cost for data that was never meant to be durable in the first place.

**The combined worst-case data lifecycle**, for a permanent table with 30-day Time Travel (Regulated tier): up to 30 days of self-service recovery, then up to 7 more days where only Snowflake can potentially recover it, then gone. **37 days total**, worst case, before data is genuinely unrecoverable through normal means — this is the number that matters for the privacy doc's erasure claim, below.

---

## Closing the Privacy Doc's Erasure Dependency

`privacy_consent_management.md` couldn't honestly claim instant, true erasure, because a `DELETE` in Snowflake doesn't mean the data is gone — it means it's moved into Time Travel, then Fail-safe, per the table above. Waiting out up to 37 days isn't an acceptable answer to a data subject exercising a deletion right.

**The resolution is crypto-shredding, not waiting out the retention window.** For any subject whose data needs genuine, immediate-effect erasure:

- Regulated-tier data that's subject to individual-level erasure requests should be encrypted at the column or row level with a per-subject or per-tenant data encryption key, not relying solely on Tri-Secret Secure's account-wide key.
- On a valid deletion request, the specific key is destroyed. The ciphertext still physically exists in Time Travel and Fail-safe for the remainder of the retention window, but it's unreadable — cryptographically equivalent to deleted, immediately, without waiting on Snowflake's storage lifecycle.
- This requires the encryption to happen at the application/pipeline layer before data lands in Snowflake (client-side or pipeline-side envelope encryption keyed per subject), since Snowflake's native Tri-Secret Secure operates at the account level, not per-row — the two mechanisms are complementary, not substitutes for each other.

**Updates `privacy_consent_management.md`:** the deletion/erasure row in the Data Subject Rights table should be read as "row deletion + consent revocation (immediate, self-service) plus per-subject key destruction for Regulated-tier data (immediate cryptographic erasure), with residual ciphertext aging out of Time Travel/Fail-safe over the following weeks" — not a claim that all traces vanish instantly, but an honest one that the data becomes unreadable immediately, which is what actually matters for a genuine erasure obligation.

---

## Tiered RTO/RPO

Formal recovery targets, illustrative and tiered to the classification scheme rather than a single organization-wide number — the same right-sizing logic used throughout this project. These are example targets to validate against Meridian's actual business requirements, not numbers derived from a real business impact analysis (that analysis doesn't exist in this project and shouldn't be invented as if it does).

| Tier | RTO (time to restore service) | RPO (acceptable data loss) | Mechanism |
|---|---|---|---|
| Regulated / Customer Confidential | 4 hours | 15 minutes | Time Travel for logical recovery; Snowflake's own cross-region replication (if enabled) for account-level DR; landing zone infra restored from Terraform |
| Internal | 24 hours | 4 hours | Time Travel; standard infra restore priority |
| Public | Best effort | Best effort | Regenerable from source systems in most cases; not worth engineering tight targets around |

**The gap between these numbers is a deliberate tradeoff, not an oversight.** A Regulated-tier RTO of 4 hours instead of, say, 15 minutes is a legitimate business decision if a 15-minute target would require infrastructure spend (multi-region active-active, for instance) that isn't justified by Meridian's actual risk tolerance — this table exists to make that tradeoff visible, not to promise the tightest number possible.

---

## Landing Zone Infrastructure Resilience

Snowflake's own resilience mechanics don't cover the AWS/GCP landing zone infrastructure underneath it — that was a separate, thinner part of the story when this doc was first written. All three gaps flagged below are now closed; keeping the reasoning in place since it's still the honest explanation of *why* each one mattered, not just a status flag:

- **Terraform state** — neither `terraform/gcp-lz/` (GCS backend) nor `terraform/aws-lz/` (S3 backend) had versioning enabled on the state bucket, meaning a bad `apply` or state corruption had no rollback path. **Closed** — `terraform/gcp-lz/bootstrap_state.tf` and `terraform/aws-lz/bootstrap_state.tf` (one-time manual bootstrap configs, both `terraform validate` clean).
- **NAT Gateway / Cloud NAT** — both landing zones provisioned a single NAT Gateway/Cloud NAT per environment as a cost-conscious default; for prod specifically that's a single point of failure for outbound connectivity. **Closed** — AWS gets per-AZ NAT Gateways for prod only (`networking.tf`); GCP's Cloud NAT is already zone-redundant by design, so the equivalent prod hardening is static reserved NAT IPs plus explicit port-allocation sizing (`shared_vpc.tf`). Dev/staging intentionally unchanged on both clouds.
- **Cross-region audit log replication** — the audit log buckets were single-region on both clouds, a resilience gap specifically for Regulated-tier audit evidence. **Closed** — AWS via S3 CRR to a secondary-region replica bucket (`logging.tf`); GCP by converting the archive bucket to a custom dual-region, which replicates synchronously with no separate replication rule needed (`logging.tf`).

Current status of these three, and everything else in the project, lives in `TRACKING.md` — treat that as the source of truth rather than this doc's own status language, which will go stale the next time something changes elsewhere.

---

## What This Closes

Updates `soc2_csf_compliance_crosswalk.md`: **Recover (A1.3/CC7.5)** moves from Partial to **Built** — Time Travel/Fail-safe mechanics, tiered retention, tiered RTO/RPO targets, and the crypto-shredding resolution to the erasure dependency are all now documented. The landing zone infrastructure hardening items above (state bucket versioning, multi-AZ NAT for prod, cross-region audit replication) started as honestly-flagged gaps and are now closed — see `TRACKING.md` for current status rather than treating this line as live.

**With this doc, every section of the SOC 2/CSF crosswalk is Built, and the infrastructure hardening items above are closed too.** The honest remainder isn't a list of undone tasks anymore — it's that none of this, including the hardening work, has ever been applied against a live org. Reference architecture, not an operational track record. That distinction doesn't go away just because the punch list is empty.

---

## Sources

- [Understanding & using Time Travel — Snowflake Documentation](https://docs.snowflake.com/en/user-guide/data-time-travel)
- [Understanding and viewing Fail-safe — Snowflake Documentation](https://docs.snowflake.com/en/user-guide/data-failsafe)
- [Storage costs for Time Travel and Fail-safe — Snowflake Documentation](https://docs.snowflake.com/en/user-guide/data-cdp-storage-costs)
- Internal: `snowflake_data_security_guardrails.md`, `privacy_consent_management.md`, `account_landing_zone_guardrails.md`
