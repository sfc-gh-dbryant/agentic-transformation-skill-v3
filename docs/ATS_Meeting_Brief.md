# Agentic Transformation Skill
### Motivation, Capability Summary & Proposed Delivery Methodology
*Danny Bryant — April 2026 | Internal — PS Leadership*

---

## Why This Exists

Every PS engagement involving data in Snowflake runs into the same back-of-house problem: raw data lands in a Bronze layer and stays there. Customers struggle to transform it into analytics-ready Silver and Gold — not because the problem is conceptually hard, but because the execution is:

- **Time-consuming.** Writing, testing, and maintaining transformation pipelines for 20–200+ tables is weeks of engineering effort.
- **Brittle.** Every schema change upstream breaks hand-written SQL downstream.
- **Undocumented.** Transformation logic lives in engineers' heads or in disparate scripts with no lineage or governance.
- **Blocking.** Until the data is transformed, no analytics, no AI, no value — the platform investment stalls.

This is not a niche problem. It is the universal back-of-house gap that precedes every analytics, BI, and AI activation conversation. The Agentic Transformation Skill was built to close it.

---

## What We Built

The Agentic Transformation Skill is a Snowflake-native delivery accelerator that deploys directly into a customer's Snowflake account and autonomously drives the Bronze → Silver → Gold transformation lifecycle using Cortex AI + Cortex Code.

### Core Capabilities

| Capability | Description |
|---|---|
| **Schema Analyst** | Discovers non-obvious FK relationships across Bronze tables using LLM inference |
| **Planner** | Analyzes each table's schema and generates a transformation strategy (SCD2, dedup, enrichment) with per-column actions |
| **Executor** | Generates and executes Silver DDL with a 3-attempt self-correction loop — outputs static CTAS or auto-refreshing **Dynamic Tables** |
| **Validator** | Row-count parity checks with SCD2 awareness; flags deviations > 1% tolerance |
| **Reflector** | Captures learnings from every run — successes, failures, corrections — into a compounding knowledge base |
| **Analytics Builder** | LLM-generated Gold aggregation tables with derived metrics, clustering, and directives |
| **DCM Export** | Generates a full DCM project (manifest, table definitions, access controls, data quality expectations) for production handoff via Git/CI |

### The Interface

A 9-tab Streamlit management console deployed natively in Snowsight. A PS consultant can configure, run, monitor, and iterate the full pipeline without writing SQL. The 9 tabs are:

1. **Setup** — Bootstrap, model management, framework reset
2. **Context** — Business description, data domain, analytics goals, constraints, pipeline output type (CTAS / Dynamic Table)
3. **Contracts** — Schema contracts: structural rules injected into every LLM prompt
4. **Directives** — Per-table transformation intent (SCD2, masking, enrichment rules)
5. **Workflow** — Run the agentic pipeline with live phase display and resume-from-failure capability
6. **Analytics Builder** — Propose and execute Gold DDL
7. **Registry** — Pipeline lineage and FK relationship map
8. **Observe** — Execution history, learnings, metrics
9. **DCM Export** — Generate and download the DCM production handoff project

### The Demo Environment

23-table financial services Bronze schema (~95M rows) with intentionally aliased FK column names — designed to test the Schema Analyst's relationship discovery capability under realistic, non-obvious conditions. Tables span reference, dimension, fact, compliance, and support domains across a regional bank data model.

---

## What Makes This Different

Three architectural decisions set this apart from prior-generation tooling:

**1. Self-improving.** Every execution writes to `WORKFLOW_LEARNINGS`. Successful transformation patterns are retained; failed patterns are stored as anti-patterns. The agent improves with every table it processes. Repeat engagements in the same vertical accumulate domain-specific IP that reduces Phase 0 workshop time on subsequent engagements.

**2. Human-in-the-loop by design.** The Schema Analyst includes a mandatory approval gate — the PS consultant reviews and curates discovered FK relationships before the Planner runs. This is not a fire-and-forget tool; it is an agentic co-pilot where the consultant remains the decision authority at every critical juncture.

**3. Production-ready output.** The DCM Export generates a version-controlled, auditable, Git-deployable DCM project with Planner-sourced data quality expectations attached to each table's primary key columns. The customer owns the output as governed production infrastructure, not a PS consulting artifact.

---

## Proposed Delivery Methodology

The Skill maps to a four-phase PS engagement model.

### Phase 0 — Design *(1–2 weeks)*
**Deliverable:** Schema Contracts, Transformation Directives, Pipeline Context

The PS consultant works with the customer to define:
- Business description and data domain (injected into every LLM call to ground decisions in customer context)
- Analytics goals for the Gold layer
- Compliance and architectural constraints (e.g., HIPAA, no PII in Gold, full audit trail in Silver)
- Per-table transformation directives (SCD2, dedup strategy, masking rules, enrichment intent)

This is equivalent to a data modeling engagement — but the output is metadata that drives automated execution, not hand-written SQL. It is a billable, high-value PS activity that unlocks everything downstream.

### Phase 1 — Foundation *(2–4 weeks)*
**Deliverable:** Agentic engine deployed; Silver built for priority source tables; Schema Analyst approval baseline established

- Deploy the Agentic Transformation Skill into the customer's Snowflake account (single SQL file, ~15 min)
- Run Bootstrap against the Bronze schema to register source tables and validate the Cortex model
- Execute Schema Analyst → Planner → Executor → Validator for the first 5–10 tables with full consultant oversight
- Review Learnings output; curate and promote first patterns to the template registry

### Phase 2 — Scale *(2–4 weeks)*
**Deliverable:** Full Silver coverage; Gold aggregations; Dynamic Tables in production

- Expand agentic workflow to remaining Bronze tables (increasingly autonomous as Learnings compound)
- Build the Gold analytics layer via the Analytics Builder
- Enable Dynamic Table output mode for continuous auto-refresh pipelines
- Run DCM Export to generate the production handoff package

### Phase 3 — Activation *(1–2 weeks)*
**Deliverable:** Production DCM project deployed; customer team enabled; optional Semantic View layer activated

- Deploy the DCM project to the customer's production environment via Git/CI
- Optional: build Semantic Views over Gold for Cortex Analyst / Snowflake Intelligence activation
- Enablement session for the customer's data engineering team
- Learnings handoff — the compiled Knowledge Base becomes durable customer IP

---

## Engagement Sizing

| Scope | Source Tables | Est. Duration | Est. ACV |
|---|---|---|---|
| Starter | 5–20 tables | 6–8 weeks | ~$50–75K |
| Standard | 20–100 tables | 8–14 weeks | ~$75–120K |
| Enterprise | 100+ tables | 14–20 weeks | $120K+ |

**Assumptions:** Bronze data already in Snowflake; customer SME available for directive workshops and approval gates; add-ons (OpenFlow ingestion, Snowflake Intelligence) scoped and priced separately.

---

## Connection to the Migration Conversation

The Agentic Transformation Skill changes the migration deliverable. Today, a migration engagement delivers converted SQL pipelines — legacy logic in a new location. With the Skill, the deliverable becomes governed metadata (Schema Contracts + Transformation Directives) that drives autonomous re-generation of transformation logic natively on Snowflake. The customer doesn't migrate pipelines — they retire them and replace them with something self-healing.

This reframes migration from "lift and shift" to "build forward" — a more defensible, higher-value engagement with a built-in rationale for ongoing PS involvement through Learnings curation, template promotion, and new source onboarding.

---

## Recommended Discussion Points

1. **Pilot customer** — One customer with 20–50 Bronze tables and limited DE capacity to run a full Phase 0–3 engagement and document outcomes (time-to-first-Silver, agent accuracy, hours saved vs. manual approach)
2. **Practice ownership** — Which team owns the Skill? Proposed: AI/ML SA team builds and maintains the accelerator; Delivery Directors scope and run customer engagements
3. **Industry Knowledge Base** — FSI and Healthcare are the highest-priority verticals. Defining standard Contracts and Directives per vertical reduces Phase 0 time on repeat engagements from weeks to days
4. **SnowWork / Snowflake Intelligence alignment** — Position the Skill as the mandatory back-of-house prerequisite before any SnowWork or Snowflake Intelligence activation conversation. Every AI query layer conversation should include a back-of-house readiness question

---

## Appendix: Technical Stack

| Component | Snowflake Feature |
|---|---|
| LLM inference (Planner, Executor, Schema Analyst) | Cortex AI — `SNOWFLAKE.CORTEX.COMPLETE` |
| Pipeline management UI | Streamlit in Snowflake |
| Transformation execution | Stored Procedures (SQL + Python) |
| Silver/Gold pipelines | CTAS or Dynamic Tables (customer-configurable) |
| Data quality enforcement | Snowflake Data Metric Functions (DMFs) |
| Production handoff | Database Change Management (DCM) |
| Skill development & deployment | Cortex Code |

---

*For questions, access to the reference implementation, or to schedule a live demo — contact Danny Bryant (danny.bryant@snowflake.com).*
