# Cortex AI Implementation
*Meridian Analytics — from architecture reasoning to a working AI feature stack | July 2026*

---

## Purpose

`snowflake_data_security_guardrails.md`'s Agent Security section makes the architectural argument for Cortex — an agent is just another principal subject to the same RBAC, masking, and row access policies as a person. This doc is where that argument gets tested against actual objects: a real semantic view, a real Cortex Search service, and a real Cortex Agent definition, built specifically so that none of them require a parallel security model. The governance was already designed in `privacy_consent_management.md`; this doc is what actually points AI features at it instead of around it.

Same honesty standard as everywhere else in this project: illustrative, current as of Snowflake's July 2026 documentation, never run against a live account.

---

## Cortex Analyst — a Semantic View Over Meridian's Analytics Schema

Semantic views are the current recommended approach (superseding the legacy YAML-file-on-a-stage pattern) — tables, relationships, facts, dimensions, and metrics are stored as native Snowflake objects rather than an external file Cortex Analyst has to parse at query time.

```sql
CREATE OR REPLACE SEMANTIC VIEW ANALYTICS.MERIDIAN_USAGE_ANALYST
  TABLES (
    tenants   AS ANALYTICS.TENANTS       PRIMARY KEY (tenant_id),
    events    AS ANALYTICS.CUSTOMER_EVENTS PRIMARY KEY (event_id)
  )
  RELATIONSHIPS (
    events (tenant_id) REFERENCES tenants
  )
  FACTS (
    events.event_id AS event_id,
    events.event_type AS event_type
  )
  DIMENSIONS (
    tenants.tenant_id AS tenant_id,
    tenants.plan_tier AS plan_tier,
    events.event_type AS event_category
  )
  METRICS (
    events.event_count AS COUNT(events.event_id),
    tenants.active_tenant_count AS COUNT(DISTINCT tenants.tenant_id)
  )
  COMMENT = 'Semantic layer for Cortex Analyst over tenant usage analytics.';
```

**Why this doesn't need a separate security layer:** a semantic view is a governed metadata layer, not a bypass — the SQL Cortex Analyst generates still executes against `ANALYTICS.CUSTOMER_EVENTS` under the querying user's own role. The tenant-isolation row access policy already established in the Snowflake guardrails doc still filters every row, exactly as it would for a hand-written query or a BI dashboard. Cortex Analyst inherits governance; it doesn't need its own copy of it.

---

## Cortex Search — Pointed at the Consent-Gated View, Not the Base Table

Support ticket text is a natural fit for semantic search, and it's also exactly the kind of free-text customer data that shouldn't feed an AI feature without the same consent check already built for `CUSTOMER_EVENTS`. Same pattern as `privacy_consent_management.md`'s `CUSTOMER_EVENTS_AI_TRAINING_SCOPE`, applied to a second table:

```sql
CREATE SECURE VIEW GOVERNANCE.SUPPORT_TICKETS_AI_TRAINING_SCOPE AS
SELECT st.*
FROM SUPPORT.TICKETS st
WHERE EXISTS (
    SELECT 1 FROM GOVERNANCE.CONSENT_REGISTRY cr
    WHERE cr.tenant_id      = st.tenant_id
      AND cr.purpose        = 'AI_TRAINING'
      AND cr.consent_status = TRUE
      AND cr.revoked_at IS NULL
);

CREATE OR REPLACE CORTEX SEARCH SERVICE GOVERNANCE.SUPPORT_TICKET_SEARCH
  ON ticket_text
  ATTRIBUTES tenant_id, plan_tier
  WAREHOUSE = CORTEX_WH
  TARGET_LAG = '1 hour'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  AUTO_SUSPEND = 1800
AS (
  SELECT ticket_text, tenant_id, plan_tier
  FROM GOVERNANCE.SUPPORT_TICKETS_AI_TRAINING_SCOPE
);
```

A tenant that revokes AI training consent disappears from this service's next refresh cycle (bounded by `TARGET_LAG`), the same way they disappear from the training pipeline's next query against the equivalent secured view — consistent revocation behavior across every AI-facing object, not just the one covered in the original privacy doc.

**`ticket_text` is free text, which raises a scope question this doc doesn't answer on its own:** is it in `secrets_management.md`'s crypto-shredding scope, or outside it? Answered there, not here — `secrets_management.md`'s Scope section covers how DLP scanning promotes regulated content found inside free text into shred scope without blanket-encrypting the whole column, and the same bounded-staleness caveat above (consent revocation lags by `TARGET_LAG`) applies identically to key-destruction erasure: a derived embedding computed before a key is destroyed doesn't vanish from the index until the next refresh. For most erasure events that's immaterial; for one with a hard regulatory deadline, it's a real constraint on this service's `TARGET_LAG`, not a detail to assume away.

**FinOps note, distinct from the compute doc's guidance:** Cortex Search's `AUTO_SUSPEND` has a 1,800-second (30-minute) floor — a materially coarser knob than the 60-second warehouse auto-suspend recommended in `snowflake_compute_finops.md`. Search services also get their own dedicated warehouse by Snowflake's own recommendation, sized no larger than Medium, so they don't compete with `BI_WH`/`ETL_WH` for capacity. Budgeting for a Cortex Search service is closer to budgeting for a small always-on service than for a bursty interactive warehouse — a different mental model than the rest of the compute doc, worth stating explicitly rather than assuming the same right-sizing logic transfers unchanged.

---

## Cortex Agent — Composing Both, Plus What It Doesn't Need to Re-Check

```sql
CREATE OR REPLACE AGENT ANALYTICS.MERIDIAN_INSIGHTS_AGENT
  COMMENT = 'Composes usage analytics and support ticket search for account-health questions.'
  FROM SPECIFICATION
  $$
  orchestration:
    budget:
      seconds: 30
      tokens: 16000

  instructions:
    response: "Be concise. Cite the tenant_id and plan_tier backing any claim."
    orchestration: "For usage/volume/metric questions use the Analyst tool. For anything about ticket content or sentiment, use the Search tool. Never combine results across tenants in a single answer unless the user's own role has cross-tenant visibility."
    sample_questions:
      - question: "Which tenants had unusual usage spikes this month?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "UsageAnalyst"
        description: "Answers usage volume and metric questions from the tenant analytics semantic view"
    - tool_spec:
        type: "cortex_search"
        name: "TicketSearch"
        description: "Searches support ticket text for AI-training-consented tenants only"

  tool_resources:
    UsageAnalyst:
      semantic_view: "ANALYTICS.MERIDIAN_USAGE_ANALYST"
    TicketSearch:
      name: "GOVERNANCE.SUPPORT_TICKET_SEARCH"
      max_results: "5"
      title_column: "tenant_id"
      columns_and_descriptions:
        TICKET_TEXT:
          description: "Full text of the support ticket"
          type: "string"
          searchable: true
          filterable: false
        TENANT_ID:
          description: "Tenant identifier"
          type: "string"
          searchable: false
          filterable: true
  $$;
```

**The point worth making explicit:** this agent definition contains no consent logic, no tenant-filtering logic, and no masking logic of its own — and that absence is the actual proof of the architectural claim, not a gap in it. Both tools point at objects (`MERIDIAN_USAGE_ANALYST`'s underlying tables, `SUPPORT_TICKET_SEARCH`'s consent-gated source view) that already carry row access policies and consent checks. The agent inherits governance by construction; a shadow pipeline that queried `SUPPORT.TICKETS` directly instead of the consent-gated view would be the actual security gap, not anything about the agent object itself. Reviewing an agent's security posture is a question about which objects its tools resolve to, not about the agent definition in isolation.

**Model governance note:** Cortex Analyst does not have access to open-source LLM models when invoked by an agent — only the models on Snowflake's own service consumption table are available in that path. Worth knowing precisely, since "which model touched this data" is a real question a client's security team will ask, and the answer differs depending on whether Cortex Analyst is called directly or through an agent.

---

## What This Strengthens

No new rows in `soc2_csf_compliance_crosswalk.md` — the controls were already mapped (CC6.1, CC6.6, P8.1) when `privacy_consent_management.md` closed Privacy. This doc is the concrete evidence that those controls extend to a second AI surface (search, not just the training pipeline) using the identical pattern, rather than a one-off. It's also the working-SQL backing for the Agent Security section of `snowflake_data_security_guardrails.md` — the architecture reasoning there and the objects here should read as one continuous claim, not two separate documents that happen to agree.

---

## Sources

- [Cortex Analyst | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [CREATE SEMANTIC VIEW | Snowflake Documentation](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view)
- [Overview of semantic views | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/views-semantic/overview)
- [CREATE CORTEX SEARCH SERVICE | Snowflake Documentation](https://docs.snowflake.com/en/sql-reference/sql/create-cortex-search)
- [Cortex Search | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search/cortex-search-overview)
- [Create and manage agents | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-manage)
- [Cortex Agents | Snowflake Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents)
- Internal: `snowflake_data_security_guardrails.md`, `privacy_consent_management.md`, `snowflake_compute_finops.md`
