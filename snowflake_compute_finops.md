# Snowflake Compute FinOps
*Meridian Analytics — where the money actually goes | July 2026*

---

## Purpose

Every FinOps note elsewhere in this project has been about storage or security overhead — KMS costs, Time Travel retention, NAT Gateway sizing. That's real, but it's not where a Snowflake bill actually concentrates. **Compute — warehouses — is the dominant line item on almost every Snowflake account**, and this project didn't have a single document about it until now. For a role whose differentiator is supposed to be FinOps judgment, that was the most consequential gap on the punch list, not the least.

---

## The Credit Model, Briefly

Warehouses are billed per-second of running time, with a **60-second minimum** charged every time a suspended warehouse resumes. Size steps from X-Small through 6X-Large roughly double credit consumption at each step up. The two numbers that actually matter for cost control aren't the size — they're **how long it sits idle before suspending**, and **how often it gets woken up for tiny amounts of work**.

**Gen2 warehouses** (current generation, roughly 2x faster than Gen1 on core analytics workloads) resume faster than Gen1, which changes the right answer on suspend timing — a warehouse that resumes quickly can afford to suspend sooner without a user-visible latency penalty.

---

## Auto-Suspend / Auto-Resume: The Single Highest-Leverage Setting

**Default auto-suspend on a new warehouse is 600 seconds (10 minutes). That default is wrong for almost every production workload**, and leaving it unchanged is the single most common way Snowflake accounts overspend — a warehouse can sit idle for 9 minutes and 59 seconds after the last query, burning credits the whole time, before it ever suspends.

**Right answer: 60 seconds, not lower.** It's tempting to go lower — 30 seconds, even 15 — but the 60-second minimum resume charge means a warehouse that suspends too aggressively against bursty, short-interval query patterns ends up *paying for two 60-second resumes* to serve two 5-second queries five minutes apart, instead of one continuous 10-minute session. 60 seconds is the practical floor where suspend-then-resume overhead stops fighting the workload pattern.

**`AUTO_RESUME = TRUE`, always**, paired with the tightened suspend timeout — the point is aggressive suspension with instant, invisible resume, not making users wait.

---

## Warehouse Strategy by Workload Type

Meridian's own scenario (from `snowflake_data_security_guardrails.md`) has two workload types sharing the same data: BI/analytics and AI/Cortex. They should not share a warehouse — separate warehouses per workload type is both a performance isolation decision and a cost-visibility decision.

| Warehouse | Workload | Size guidance | Auto-suspend | Why separate |
|---|---|---|---|---|
| `BI_WH` | Dashboards, ad hoc SQL, embedded analytics | Small–Medium, sized to concurrency not data volume | 60s | Interactive — users are waiting, latency matters, but idle time between sessions is common and expensive if not suspended aggressively |
| `ETL_WH` | Batch transformation, scheduled ingestion pipelines | Medium–Large, sized to job duration | 60–120s | Sustained runs; suspend timing matters less than right-sizing the warehouse to actually finish jobs faster rather than running a smaller warehouse longer (a bigger warehouse for less total time is often cheaper, not more expensive — this is the single most counterintuitive FinOps lesson on Snowflake) |
| `CORTEX_WH` | Cortex Analyst / Cortex Search warehouse compute | Small–Medium | 60s | Isolates AI workload cost from BI cost for attribution purposes — **note the honest caveat below** |

**Honest caveat on Cortex cost:** some Cortex functions bill on their own consumption model (per-token or per-function-call pricing) separate from warehouse compute, not purely as warehouse-second consumption. Treating all Cortex cost as "just another warehouse" would understate the real bill. This doc's `CORTEX_WH` guidance covers the warehouse-compute portion of Cortex workloads (e.g., the SQL warehouse backing a Cortex Analyst session); the token/function-level billing needs to be tracked separately in Snowflake's own usage views, not assumed away.

---

## Multi-Cluster Warehouses: A Concurrency Tool, Not a Speed Tool

Multi-cluster warehousing scales out additional clusters of the *same size* to absorb concurrent query load — it does not make individual queries faster (that's what warehouse size does). Two scaling policies:

- **Standard** — adds clusters aggressively to minimize queuing, scales back down conservatively. Optimizes for user experience over cost.
- **Economy** — waits longer before adding a cluster, willing to let some queuing happen. Optimizes for cost over instant responsiveness.

**Right-sizing call:** `BI_WH` serving customer-facing embedded analytics is a Standard-policy candidate — a queued dashboard is a bad customer experience, and this is exactly the kind of case where spending more is the correct call, not over-engineering. `ETL_WH` running scheduled batch jobs is almost always Economy — a few minutes of queuing on an overnight job costs nothing that matters. Applying Standard policy everywhere "to be safe" is the same reflexive-max-security-everywhere mistake this project has flagged repeatedly, just on the cost axis instead of the risk axis.

---

## Resource Monitors: Graduated, Not Binary

A resource monitor tracks credit consumption against a quota and fires an action at defined thresholds — this is the actual circuit breaker, and it should be graduated rather than a single hard stop:

| Threshold | Action | Reasoning |
|---|---|---|
| 60% | Notify FinOps/platform team | Early signal, no disruption — time to investigate before it's urgent |
| 80% | Notify warehouse owner | Escalates ownership of the response to whoever's workload is actually driving spend |
| 95% | Notify + **suspend at completion** | Lets in-flight queries finish rather than killing them mid-execution — the disruptive failure mode to avoid |
| 100% | Suspend + notify leadership | Hard stop, but by this point it's the third alert, not a surprise |

**Suspend-at-completion vs. suspend-immediately is itself a right-sizing decision.** `BI_WH` — customer-facing — should default to suspend-at-completion even at the hard 100% threshold, because killing an in-flight customer dashboard query is a worse outcome than a brief credit overage. A `dev`/sandbox warehouse can use suspend-immediately without real consequence. Same tiering logic used for data classification, applied to blast radius of a cost control instead.

**Complementary, account-level layer: Snowflake Budgets.** Where resource monitors are warehouse/credit-quota-scoped circuit breakers, Snowflake's native Budgets feature operates at the account or object level with spend forecasting and email/notification alerts — a longer-horizon "are we tracking to plan this month" view rather than a hard-stop mechanism. Use both: resource monitors for the operational circuit breaker, Budgets for the finance-facing forecast.

---

## Per-Tenant Cost Attribution

Meridian is multi-tenant. Without attribution, "our Snowflake bill went up" is a statement with no next action. With it, "tenant X's usage grew 40% this month, and here's what that costs us to serve them" is a statement that drives actual pricing and packaging decisions — which is exactly the kind of insight a Technical Account Manager should be able to bring to a client conversation, not just an engineering team.

**Mechanism:** query tags (`ALTER SESSION SET QUERY_TAG = '{"tenant_id": "..."}'`) set at the session or role level, correlated against `ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY` for actual credit cost per query. This is the same tagging discipline already established for data classification (Data Classification section, Snowflake doc) — reused here for a cost-attribution purpose instead of a security purpose, which is a good example of governance infrastructure paying for itself twice.

**The security connection, worth stating explicitly:** `incident_response_runbook.md`'s Detection Sources section already notes that a cost spike alert is sometimes the first visible symptom of a compromised credential being used for something like bulk data transfer or unauthorized compute. Per-tenant cost attribution turns that from a vague possibility into an actual detection signal — an unexplained spike in one tenant's attributed compute cost is now a specific, actionable anomaly, not a mystery on the aggregate bill.

---

## What This Closes

Adds the missing half of the FinOps story to `snowflake_data_security_guardrails.md`'s Right-Sizing Summary, which previously covered only storage/security cost tradeoffs. Does not change anything in `soc2_csf_compliance_crosswalk.md` directly — this is operational cost governance, not a compliance control — but strengthens the credibility of every "we don't over-engineer, we right-size" claim made elsewhere in this project by making it concrete: specific thresholds, specific settings, specific reasoning for each one.

---

## Sources

- [FinOps on Snowflake: Built-In Cost and Performance Control — Snowflake](https://www.snowflake.com/en/pricing-options/cost-and-performance-optimization/)
- [Snowflake Gen2 warehouse 101: Performance and cost breakdown (2026)](https://www.flexera.com/blog/finops/snowflake-gen2-warehouse/)
- [Snowflake Resource Monitor Best Practices Guide](https://www.anavsan.com/blog/snowflake-resource-monitor-best-practices-guide/)
- Internal: `snowflake_data_security_guardrails.md`, `incident_response_runbook.md`
