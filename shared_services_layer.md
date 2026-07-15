# Shared Services Layer
*Meridian Analytics — a fourth OU/folder, and the line between it and what's already built | July 2026*

---

## Purpose

`account_landing_zone_guardrails.md` established three account/project groupings: Security (log archive, audit tooling), Infrastructure (the Network account/host project), and Workloads (per-environment). Nothing in that structure has a home for the operational, engineering-facing shared capabilities every environment needs without duplicating — a place to reach HCP Vault privately, a centralized artifact registry, delegated DNS. This doc adds that fourth grouping and draws an explicit line against the Security OU's shared infrastructure, since both are "shared" in a way that invites confusion if left implicit.

**The line:** Security OU/folder is compliance- and audit-facing shared infrastructure — the org's evidence trail. Shared Services OU/folder is operations- and engineering-facing shared infrastructure — the org's toolchain. Different consumers, different access models, different reasons to exist. Collapsing them into one "shared stuff" bucket would blur exactly the kind of distinction this project has been careful about everywhere else.

---

## Structure

A new OU (AWS) / folder (GCP), sibling to Security and Infrastructure, containing a single new account/project: `{prefix}-shared-services`. Workload accounts consume from it; they don't own resources inside it — the same centralizing pattern already established for the Network account and Shared VPC, applied to a different category of shared capability.

| What lives here | Why it's centralized instead of per-environment |
|---|---|
| Private connectivity to HCP Vault | One egress path to a third-party SaaS subprocessor (see `secrets_management.md`), not three — easier to monitor, easier to restrict, consistent with the egress-control posture in `network_security_foundations.md` |
| Artifact/container registry (GCP Artifact Registry / AWS ECR) | Images built once, promoted through dev → staging → prod rather than rebuilt per environment — the actual mechanism behind the immutable-infrastructure principle in `network_security_foundations.md`: an environment doesn't get a patched image, it gets promoted a newer one from the same source |
| Delegated DNS apex | Each environment's private DNS zone (already built, per-environment) becomes a delegated subdomain of a zone owned here, rather than three unrelated private zones with no common parent |
| Future CI/CD execution environment | Not built in this project — GitHub Actions in `.github/workflows/` covers `fmt`/`validate` today. If this ever moves to actually applying infrastructure, that execution environment (whether self-hosted runners or HCP Terraform) belongs here, not in an environment account, for the same reason the Network account isn't duplicated per environment |

---

## Why Not Just Put This in the Existing Infrastructure OU

The Infrastructure OU's Network account is specifically about the network layer — VPCs, subnets, NAT, private connectivity to Snowflake. Artifact registries, DNS delegation, and third-party SaaS connectivity aren't network-layer concerns in the same sense, and folding them into the Network account would make that account's blast radius and access model harder to reason about — exactly the kind of scope creep the account-boundary design in `account_landing_zone_guardrails.md` was built to avoid in the first place. A dedicated account with its own SCPs and its own narrower set of consumers is more consistent with the rest of the landing zone's philosophy than convenience-driven consolidation.

---

## Access Model

Same AD-group-driven IAM pattern as everywhere else — no new access control mechanism invented for this OU. What's different is *who* typically holds those groups: shared services consumers are usually platform/DevOps roles and CI identities, not the analytics or application engineers who hold access into workload accounts. Worth stating explicitly in the AD group JSON's role descriptions rather than assuming it's obvious from the account name.

---

## What This Doesn't Include

No compute of consequence lives in this account by default — a registry and a DNS zone are managed services, not servers to run. If a future need introduces real shared compute here (a self-hosted CI runner fleet, for instance), the immutable-infrastructure principle in `network_security_foundations.md` applies to it exactly as it would anywhere else — replaced, not patched.

---

## Sources

- Internal: `account_landing_zone_guardrails.md`, `secrets_management.md`, `network_security_foundations.md`
