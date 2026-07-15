# Network Security Foundations
*Meridian Analytics — the workhorse layer underneath everything else | July 2026*

---

## Purpose

Every other doc in this project reasons about Snowflake's own controls, or the account/network boundary Snowflake's private endpoint lands in. This doc is the layer underneath both: egress control, sensitive-data discovery before Snowflake ever sees the data, workload runtime protection, and how a human actually gets administrative access to any of it. None of this is new architecture — it's the foundational, unglamorous plumbing that everything else depends on being solid.

**Design philosophy, stated explicitly:** everything Terraform builds in this project is disposable and rebuildable from source — cattle, not pets. The data is the one exception, which is exactly why `resilience_disaster_recovery.md` and `secrets_management.md` treat it with a level of care nothing in this doc gets. A compute instance, a firewall rule, a DNS record: replaced without ceremony. That asymmetry is deliberate, not an oversight.

---

## Egress Control — Closing the Gap Below Data Movement Policies

`snowflake_data_security_guardrails.md` covers Data Movement Policies blocking `COPY INTO` at the platform layer — Snowflake's answer to agentic AI changing the exfiltration threat model. Nothing in the landing zone currently backs that up at the network layer: NAT Gateway/Cloud NAT lets outbound traffic reach anywhere by default. A compromised workload with network access but no Snowflake privileges could still exfiltrate data through a channel Data Movement Policies were never designed to see.

- **AWS:** Network Firewall's stateful domain-list rule groups, deployed inline with the NAT path, allowlisting only approved destinations (Snowflake's own endpoints, approved SaaS APIs, package repositories) rather than defaulting to open egress.
- **GCP:** Secure Web Proxy, which is default-deny by design — all outbound HTTP/S traffic is blocked until explicitly allowed by hostname, URL pattern, or wildcard, with policies scoped by service account or secure tag rather than applied uniformly.

Both are policy layers on top of the existing NAT Gateway/Cloud NAT from `account_landing_zone_guardrails.md`, not a replacement for it — NAT still handles address translation, egress control decides what's allowed to leave in the first place.

---

## DLP at the Landing Layer — Catching PII Before It's Classified

The data classification scheme (Public / Internal / Customer Confidential / Regulated / AI Context) starts once data is inside Snowflake and has been tagged. Nothing today scans the raw landing zone — the external stage buckets data lands in before ingestion — for sensitive data arriving from a new or misconfigured source before a human has classified it. That's a real gap between "data is classified" and "data that should be classified actually gets there already known to be sensitive."

- **AWS:** Macie, scanning S3 external stage buckets for PII, credentials, and financial data patterns via built-in ML classification, before that data is loaded into a Regulated-tier Snowflake table.
- **GCP:** Sensitive Data Protection (formerly Cloud DLP), same role against GCS external stage buckets, using built-in infoType detectors.

A finding here is a signal, not a control by itself — it feeds back into the classification and consent workflows already built in `privacy_consent_management.md`, flagging data that arrived without the provenance tracking the AI Context tag assumes exists.

---

## Workload Runtime Protection — Not Classic Endpoint Protection

The AWS landing zone diagram already shows real compute in workload accounts (`EC2/ECS/RDS`), which is where runtime protection actually matters — Snowflake itself needs none of this. Worth being precise about the *kind* of protection rather than defaulting to a traditional third-party EPP agent fleet with its own management console and licensing:

- **AWS:** GuardDuty Runtime Monitoring — a lightweight, AWS-managed security agent (not a separate third-party product) providing file access, process execution, and network connection visibility for EC2, ECS, and EKS workloads, surfaced in the same GuardDuty console already generating findings elsewhere.
- **GCP:** Security Command Center's Virtual Machine Threat Detection and Container Threat Detection — genuinely agentless on the VM side (short-lived clones of the persistent disk are scanned externally, nothing runs inside the guest), and kernel-level instrumentation rather than a customer-deployed agent on the GKE container side.

Worth naming this divergence specifically, the same way the original Snowflake doc names the three places AWS and GCP diverge on platform security: AWS's runtime monitoring runs an agent inside the workload; GCP's does not. Neither is wrong, but a client asking "does this agent see my data" deserves the accurate answer for whichever cloud is in play.

---

## Access: Retiring the Bastion

Jump hosts and bastion servers are not current best practice — a standing, internet-facing (or even internally-facing) host with SSH/RDP access to a private subnet is itself an asset that needs patching, monitoring, and access control, and a compromise of it is a compromise of everything behind it. The modern answer removes the host entirely:

- **AWS:** Systems Manager Session Manager — browser- or CLI-based shell access to an instance through the SSM agent, no open inbound port, no bastion host to maintain, and every session is logged to CloudTrail by default.
- **GCP:** Identity-Aware Proxy (IAP) TCP forwarding — the same principle, brokered through IAM rather than a network path, so access is a role grant, not a network rule.

No new access control model needed — both broker through the same IAM Identity Center / AD-group-driven permission model already established in `account_landing_zone_guardrails.md`. This is a configuration decision on top of existing identity plumbing, not a new system.

---

## Compute Lifecycle: Immutable Infrastructure

"Patch management" is the wrong frame for compute in this architecture. The right one: nothing gets patched in place, it gets replaced with a newer build from the same source — golden images built once (in `shared_services_layer.md`'s artifact/image registry), promoted through environments, and rolled out via Auto Scaling Group / Managed Instance Group replacement rather than an in-place update. A workload account never patches an instance; it retires one and launches its replacement from a newer image. Terraform already treats infrastructure this way by definition — this extends the same posture to what runs *on* that infrastructure, not just the infrastructure itself.

---

## What This Strengthens

No new crosswalk rows — this doc backs CC6.6 (logical and physical access controls) and CC6.1 (logical access security measures) with the network-layer half of controls the crosswalk already cites at the Snowflake-platform level. It also closes the actual gap between "Data Movement Policies prevent exfiltration" and "nothing else in the stack backs that claim up," which was true until this doc existed.

---

## Sources

- [Stateful domain list rule groups in AWS Network Firewall](https://docs.aws.amazon.com/network-firewall/latest/developerguide/stateful-rule-groups-domain-names.html)
- [Secure Web Proxy overview | Google Cloud Documentation](https://docs.cloud.google.com/secure-web-proxy/docs/overview)
- [GuardDuty Runtime Monitoring | Amazon GuardDuty](https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring.html)
- [Virtual Machine Threat Detection overview | Security Command Center](https://docs.cloud.google.com/security-command-center/docs/concepts-vm-threat-detection-overview)
- [Container Threat Detection overview | Security Command Center](https://docs.cloud.google.com/security-command-center/docs/concepts-container-threat-detection-overview)
- Internal: `snowflake_data_security_guardrails.md`, `account_landing_zone_guardrails.md`, `privacy_consent_management.md`, `shared_services_layer.md`
