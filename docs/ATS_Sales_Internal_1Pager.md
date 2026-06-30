# Agentic Transformation Skill — Internal Sales Guide
### How to Position It, What to Promise, and What to Avoid

---

## What ATS Actually Is

ATS is a **PS productivity accelerator** — not a product. It is an agentic framework that PS uses internally to deliver Bronze → Silver data pipeline transformations faster and with higher quality than traditional methods.

**The customer does not buy ATS. PS uses ATS to deliver an engagement.**

The customer receives the *outputs* of the engagement: Silver tables, data contracts, transformation directives, pipeline documentation, and optionally the deployed framework itself.

---

## The Right Way to Position It

| ✅ Say This | ❌ Not This |
|---|---|
| "We use an AI-accelerated delivery methodology that compresses pipeline development from weeks to days" | "We're delivering a product called the Agentic Transformation Skill" |
| "You'll receive clean Silver tables, documented business rules, and a reusable framework your team can extend" | "ATS will automate your data pipelines going forward" |
| "Our agents plan, execute, and validate transformations — your team reviews and approves the output" | "This is a no-code solution your team can run themselves without DE expertise" |
| "The framework is yours post-engagement — we'll train your team to operate it" | "Snowflake will support and maintain ATS after the engagement" |
| "Every run gets smarter — learnings are captured and reused across future pipeline runs" | "ATS guarantees production-quality output out of the box" |

---

## What Is and Isn't in Scope

### In Scope
- Discovery and analysis of Bronze-layer tables
- AI-generated and validated Silver-layer DDL
- Schema contracts and transformation directives
- Workflow execution history and lineage
- AI-proposed Gold/Analytics DDL — agent proposes, human reviews and approves before execution
- DCM project export for production handoff of Gold objects
- Deployment of the ATS framework in the customer's account
- Knowledge transfer to the customer DE team

### Out of Scope
- Data ingestion / Bronze layer build (that's a separate engagement)
- BI and reporting tooling (Power BI, Sigma, Tableau — downstream of what ATS covers)
- Production pipeline operations (ATS authors pipelines; customers operationalize them)
- Ongoing Snowflake support or SLA for the deployed framework
- Custom agent development beyond the standard five phases
- Production hardening, DR, or enterprise change management

---

## Brownfield Safeguards — Existing Data is Protected

ATS is designed to run safely against environments that already have data and schema objects. Three built-in safeguards prevent accidental overwrites:

| Safeguard | Default | What It Does |
|---|---|---|
| **Dry Run** | `TRUE` | Generates and logs all DDL but **never executes**. Customer reviews every statement before anything runs. Must be explicitly set to `FALSE` to execute. |
| **No Overwrite** | `FALSE` | If a target Silver table already has rows, the Executor **skips that table, logs `TARGET_EXISTS_NO_OVERWRITE`, and continues processing the remaining tables**. Existing data is untouched. Other tables in the same run are unaffected. |
| **Brownfield Mode** | `FALSE` | When enabled, the Executor **skips** existing Silver tables entirely (logs them as `EXISTING`, not failures) and only processes gaps. Use this when some Silver tables are already built and only new tables need to be processed. |

**Two-key interlock:** Enabling overwrite requires *both* `dry_run=FALSE` **and** `overwrite_existing=TRUE` set simultaneously. Setting one without the other returns an error. This prevents accidental data loss from a single misconfigured flag.

**Practical brownfield workflow:**
1. Set `brownfield_mode=TRUE` in pipeline context — existing Silver tables are silently skipped (logged as `EXISTING`, not failures)
2. Run with `dry_run=TRUE` first — review proposed DDL for net-new tables only
3. Set `dry_run=FALSE` to execute against the gaps only

No existing Silver table is ever touched without an explicit two-step opt-in. A run with existing tables present will always complete — it will not halt midway.

### ⚠️ Important Limitation: Existing Pipeline Coexistence

The row-count check protects **populated** tables only. It does **not** protect against:

- **Empty tables** at the target location — if an existing pipeline's output table exists but has no rows yet (e.g. a freshly created dbt model), ATS will overwrite it
- **Dynamic Tables or Views** — `CREATE OR REPLACE TABLE` will replace them with a static table, silently breaking the existing pipeline object
- **Schema ownership** — ATS has no awareness of whether a schema is managed by dbt, Snowflake Tasks, or any other tool

**ATS now handles this automatically via built-in conflict redirect** — for both Silver and Gold layers. When a conflict is detected, output is redirected to a configurable fallback schema rather than failing or overwriting. The pipeline run completes end-to-end regardless of conflicts encountered.

| Conflict detected | Redirect behaviour |
|---|---|
| Target is a **VIEW** | Always redirected to fallback schema |
| Target is a **DYNAMIC TABLE** | Always redirected to fallback schema |
| Target is an **empty regular table** | Redirected (may be owned by another pipeline) |
| Target is a **populated regular table** | Skipped via existing row-count check |

Every redirect is logged with the conflict reason. The DE team reviews redirected output in the staging schema and promotes when ready.

Fallback schema defaults to `{output_schema}_STAGING` (Silver) and `GOLD_STAGING` (Gold). Configure explicitly with:
```sql
CALL AGENT_FRAMEWORK.SET_CONFLICT_FALLBACK_SCHEMA('MY_DB.SILVER_REVIEW');
```

---

## Engagement Model

ATS is a **PS productivity tool**. The engagement is scoped around the *deliverables* (Silver tables, contracts, directives) — not around the tool itself.

**Correct SOW framing:**
> "Snowflake PS will deliver a production-validated Silver data layer for [N] source tables, including schema contracts, transformation directives, and pipeline documentation. The delivery will be accelerated using Snowflake's internal agentic delivery methodology."

**Do not SOW:**
> "Snowflake PS will deliver and implement the Agentic Transformation Skill platform."

The distinction matters for customer expectations, support obligations, and what happens when the engagement ends.

---

## The Critical Distinction: Pipeline Authoring vs. Pipeline Execution

This is the single most important concept to communicate clearly — and the source of most customer expectation misalignment.

**ATS authors the pipeline. It is not the pipeline.**

When a customer asks *"will ATS automatically transform new Bronze data every night?"* — the answer is no, and it shouldn't. Here's why:

ATS uses AI agents to answer the hardest question in data engineering: *given raw tables I've never seen before, what should my Silver layer look like and how do I build it?* Once that question is answered, running the LLM pipeline nightly to re-make decisions that are already made is wasteful, slow, and introduces unnecessary variability.

The correct post-ATS path is:
1. **ATS authors** the Silver DDL and transformation logic during the PS engagement
2. **The customer operationalizes** that logic into scheduled Snowflake pipelines (Dynamic Tables, Snowflake Tasks, or dbt models) that run on a schedule — without AI involvement

Think of ATS like an architect using AI-assisted design software. The software dramatically accelerates how fast the architect produces blueprints — but you don't leave the design software running in your building after construction is done. You follow the blueprints.

---

## Example Scenario — Multi-BU Platform Migration

**The situation** *(a pattern we see frequently in FSI and enterprise migrations)*
A specialty insurance carrier is migrating 15 business units from on-premises SQL Server and SSIS to Snowflake. Each BU runs its own book of business — mortgage, specialty lines, reinsurance, casualty — with its own raw tables, legacy schemas, and transformation logic buried in SSIS packages nobody fully understands anymore. The data platform team is tasked with delivering a clean Silver layer across all 15 BUs by year-end. Manually, that's 6–8 weeks per BU. Impossible at that timeline.

**Why ATS fits**
- Each BU migration produces a new set of Bronze tables with undocumented SQL Server schemas and SSIS business logic embedded in code
- ATS is built precisely for this: unknown schemas, complex rules buried in legacy pipelines, multiple independent BUs with overlapping but distinct data models
- The Reflector captures learnings from BU 1 — dedup keys, type-casting patterns, known edge cases — and applies them to BU 2 through 15, compressing delivery time with each successive BU

**The right pilot scope**
Start with one BU — the highest-priority line of business. Full ATS deployment, Silver tables delivered, transformation directives documented, pattern validated. That pilot becomes the blueprint for the remaining BUs. Cost and timeline for subsequent BUs drop materially because the framework is already configured and the domain knowledge is already encoded.

**What to say**
> *"We can compress your per-BU pipeline development from 6–8 weeks to under 2 weeks. Your team gets validated Silver tables, documented business rules, and transformation directives that encode the institutional knowledge your legacy pipelines currently carry. Once a BU is done, we operationalize into native Snowflake pipelines — ATS is the authoring accelerator, not the runtime engine."*

**The expectation to set explicitly**
ATS is not an autonomous data engineer that runs continuously. It is the tool PS uses to rapidly produce the Silver layer for each BU. After the engagement, the customer's DE team operates the resulting pipelines — not ATS itself.

**The upsell path**
- Pilot: 1 BU → validates the methodology, produces reusable patterns, de-risks the program
- Phase 2: Remaining BUs at accelerated pace using learnings from Phase 1
- Enablement add-on: Train customer DE team to run ATS for future BU onboards independently

---

## Handling Common Sales Conversations

**"Can we include ATS as a line item in the SOW?"**
No. ATS is how PS delivers — not what PS delivers. The line items are the pipeline outputs. You can reference the methodology in the SOW narrative without scoping it as a deliverable.

**"The customer wants to see a demo of ATS."**
Yes, absolutely — the Streamlit app is designed for this. Demo the pipeline running, the agents working, the observability. Just frame it as "this is how we build pipelines" not "this is what you're buying."

**"The customer wants to own ATS and extend it after the engagement."**
This is fully supported — and a great upsell to a follow-on enablement engagement. The framework is deployed in their account and they can extend it. But set the expectation: their team needs DE expertise to operate it, and Snowflake PS support ends with the engagement.

**"Can we productize ATS and sell it on the Marketplace?"**
Not at this time. ATS is an internal PS accelerator. Any Marketplace or product conversation needs to involve the PS leadership team.

---

## The One-Sentence Positioning Statement

> **"Snowflake Professional Services uses an AI-powered delivery framework to transform your raw Bronze data into validated, analytics-ready Silver tables — in days instead of weeks — leaving you with clean data, documented business rules, and a reusable pipeline framework your team can own."**

---

*Internal use only — Snowflake Professional Services*
