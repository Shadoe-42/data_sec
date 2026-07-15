# Hybrid and Multi-Cloud Connectivity
*Meridian Analytics — two different problems, not one | July 2026*

---

## Purpose

"Hybrid" and "multi-cloud" get used interchangeably often enough that it's worth being precise: hybrid is on-premises-to-cloud connectivity, multi-cloud is cloud-to-cloud connectivity, and this project has had a real gap in the first and an intentional design decision in the second that was never stated as such. Both deserve an explicit answer rather than a silent absence.

---

## Hybrid Connectivity — On-Premises to Cloud

Nothing in the landing zone today accounts for a corporate network, an on-prem data source, or a legacy system needing a path into the cloud. That's fine if Meridian is cloud-only end to end, but most real enterprises aren't, and the absence should be a decision, not an oversight.

**Baseline: Site-to-Site VPN.** IPsec VPN between Meridian's corporate network and the Network account's VPC (AWS Virtual Private Gateway / Customer Gateway, or GCP Cloud VPN with a Cloud Router for dynamic routing). Encrypted by default, provisioned in hours rather than weeks, and adequate for moderate, bursty traffic — corporate user access to internal tooling, occasional file transfers, administrative connectivity.

**Escalation: Direct Connect / Cloud Interconnect.** A dedicated, private, non-internet-routed connection, justified specifically when there's a demonstrated sustained-bandwidth or latency need — a large nightly batch load from an on-prem source feeding Snowflake external stages, for instance, where VPN's internet-dependent path and bandwidth ceiling would actually bottleneck the workload. Not a default; a response to a specific, demonstrated requirement, consistent with the right-sizing logic used everywhere else in this project.

Either option lands in the Network account (Infrastructure OU) already established in `account_landing_zone_guardrails.md` — the same account that owns the VPC and NAT, not a new network boundary.

---

## Multi-Cloud Connectivity — Cloud to Cloud

**Current state: AWS and GCP are not connected to each other, and that's the right-sized answer, not a gap.** The original scenario in `snowflake_data_security_guardrails.md` splits workloads across AWS and GCP specifically so neither cloud is a single point of failure — but that design works because Snowflake itself is the integration point. A workload on AWS and a workload on GCP don't need to talk to each other directly; they both land data in Snowflake, which is the governed, shared plane either side reaches independently. Building a direct AWS-to-GCP network tunnel would solve a problem this architecture was specifically designed not to have.

**When that would actually change:** if a genuine requirement emerged for direct cross-cloud data movement that bypasses Snowflake — a specific DR/failover scenario involving a non-Snowflake resource replicated across clouds, for instance. Nothing in this project's scenario currently drives that. If it ever does, the answer is a cloud-neutral interconnect provider (colocation-based cross-connects, or a service like Megaport) for a sustained need, or simply encrypted traffic over the public internet for something infrequent and low-volume — not a standing, always-on tunnel provisioned speculatively.

**The honest version of this section, stated directly:** this doc isn't recommending a build. It's the reasoning for why one isn't there, so the absence reads as a decision if anyone asks, not a blind spot.

---

## What This Doesn't Include

No hybrid connectivity is actually provisioned in the Terraform — this is the reasoning and the decision point, not new resources. If a real on-prem connectivity requirement emerges, this doc is where that Terraform would get added, scoped to whichever tier (VPN vs. Direct Connect/Interconnect) the actual bandwidth and latency requirement justifies.

---

## Sources

- Internal: `account_landing_zone_guardrails.md`, `snowflake_data_security_guardrails.md`
