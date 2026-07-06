# Agentic Transformation Skill — Internal Sales Guide
### How to Position It, What to Promise, and What to Avoid

---

## What ATS Actually Is

ATS is a **PS productivity accelerator** — not a product. It is an agentic framework that PS uses internally to deliver Bronze → Silver data pipeline transformations faster and with higher quality than traditional methods.

**The customer does not buy ATS. PS uses ATS to deliver an engagement.**

The customer receives the *outputs* of the engagement: Silver tables, data contracts, transformation directives, pipeline documentation, and a DCM export package for production handoff.

---

## The Right Way to Position It

| ✅ Say This | ❌ Not This |
|---|---|
| "We use an AI-accelerated delivery methodology that compresses pipeline development from weeks to days" | "We're delivering a product called the Agentic Transformation Skill" |
| "You'll receive clean Silver tables, documented business rules, and validated pipeline artifacts" | "ATS will automate your data pipelines going forward" |
| "Our agents plan, execute, and validate transformations — your team reviews and approves the output" | "This is a no-code solution your team can run themselves without DE expertise" |
| "Every run gets smarter — learnings are captured and reused across future pipeline runs during the engagement" | "Snowflake will support and maintain ATS after the engagement" |
| "The engagement delivers validated Silver tables and a DCM export ready for your deployment workflow" | "ATS guarantees production-quality output out of the box" |

---

## What Is and Isn't in Scope

### In Scope
- Discovery and analysis of Bronze-layer tables
- AI-generated and validated Silver-layer DDL
- Schema contracts and transformation directives
- Workflow execution history and lineage
- AI-proposed Gold/Analytics DDL — agent proposes, human reviews and approves before execution
- DCM project export for production handoff of Gold and Silver objects
- Knowledge transfer to the customer DE team on how to interpret and operationalize outputs

### Out of Scope
- Data ingestion / Bronze layer build (separate engagement)
- BI and reporting tooling (Power BI, Sigma, Tableau — downstream of what ATS covers)
- Production pipeline operations (ATS authors pipelines; customers operationalize them)
- Ongoing Snowflake support or SLA for any framework components
- Custom agent development beyond the standard five phases
- Production hardening, DR, or enterprise change management

---

## Brownfield Safeguards — Existing Data is Protected

ATS is designed to run safely against environments that already have data and schema objects. Three built-in safeguards prevent accidental overwrites:

| Safeguard | Default | What It Does |
|---|---|---|
| **Dry Run** | `TRUE` | Generates and logs all DDL but **never executes**. Customer reviews every statement before anything runs. Must be explicitly set to `FALSE` to execute. |
| **No Overwrite** | `FALSE` | If a target Silver table already has rows, the Executor **skips that table, logs `TARGET_EXISTS_NO_OVERWRITE`, and continues processing the remaining tables**. Existing data is untouched. |
| **Brownfield Mode** | `FALSE` | When enabled, the Executor **skips** existing Silver tables entirely and only processes gaps. Use this when some Silver tables are already built. |

**Two-key interlock:** Enabling overwrite requires *both* `dry_run=FALSE` **and** `overwrite_existing=TRUE` set simultaneously. Setting one without the other returns an error.

**Conflict redirect:** When a conflict is detected (empty table, view, or dynamic table at the target path), output is redirected to a configurable fallback schema rather than failing or overwriting. Every redirect is logged for DE team review.

---

## Engagement Model

ATS is a **PS productivity tool**. The engagement is scoped around the *deliverables* — not around the tool itself.

**Correct SOW framing:**
> "Snowflake PS will deliver a production-validated Silver data layer for [N] source tables, including schema contracts, transformation directives, and pipeline documentation. The delivery will be accelerated using Snowflake's internal agentic delivery methodology."

**Do not SOW:**
> "Snowflake PS will deliver and implement the Agentic Transformation Skill platform."

The distinction matters for customer expectations, support obligations, and what happens when the engagement ends.

---

## The Critical Distinction: Pipeline Authoring vs. Pipeline Execution

**ATS authors the pipeline. It is not the pipeline.**

When a customer asks *"will ATS automatically transform new Bronze data every night?"* — the answer is no. ATS uses AI agents to answer the hardest question in data engineering: *given raw tables I've never seen before, what should my Silver layer look like and how do I build it?* Once that question is answered, running the LLM pipeline nightly to re-make decisions that are already made is wasteful and introduces unnecessary variability.

The correct post-ATS path:
1. **ATS authors** the Silver DDL and transformation logic during the PS engagement
2. **The customer operationalizes** that logic into scheduled Snowflake pipelines (Dynamic Tables, Tasks, or dbt models) that run on a schedule — without AI involvement

Think of ATS like an architect using AI-assisted design software. The software dramatically accelerates how fast the architect produces blueprints — but you don't leave the design software running in the building after construction is done.

---

## Example Scenario — Multi-BU Platform Migration

**The situation:** A specialty insurance carrier is migrating 15 business units from on-premises SQL Server and SSIS to Snowflake. Each BU has its own raw tables, legacy schemas, and transformation logic buried in SSIS packages. The data platform team must deliver a clean Silver layer across all 15 BUs by year-end. Manually, that's 6–8 weeks per BU.

**Why ATS fits:**
- Unknown schemas with complex rules buried in legacy pipelines
- Multiple independent BUs with overlapping but distinct data models
- Reflector captures learnings from BU 1 and applies them to BU 2 through 15, compressing delivery time with each successive BU

**The right pilot scope:** Start with one BU. Full ATS deployment, Silver tables delivered, transformation directives documented. That pilot becomes the blueprint for remaining BUs.

**What to say:**
> *"We can compress per-BU pipeline development from 6–8 weeks to under 2 weeks. Your team gets validated Silver tables, documented business rules, and transformation directives that encode the institutional knowledge your legacy pipelines currently carry. Once a BU is done, we operationalize into native Snowflake pipelines — ATS is the authoring accelerator, not the runtime engine."*

**The upsell path:**
- Pilot: 1 BU → validates the methodology, produces reusable patterns
- Phase 2: Remaining BUs at accelerated pace using learnings from Phase 1
- Enablement: Training on how to interpret and extend the delivered artifacts

---

## Handling Common Sales Conversations

**"Can we include ATS as a line item in the SOW?"**
No. ATS is how PS delivers — not what PS delivers. The line items are the pipeline outputs.

**"The customer wants to see a demo of ATS."**
Yes — the Streamlit app is designed for this. Demo the pipeline running, the agents working, the observability. Frame it as "this is how we build pipelines" not "this is what you're buying."

**"The customer wants to continue using ATS after the engagement."**
What happens to the deployed framework post-engagement is still being aligned internally. Do not make commitments in either direction. Escalate to PS leadership.

**"Can we productize ATS and sell it on the Marketplace?"**
Not at this time. ATS is an internal PS accelerator. Any Marketplace or product conversation needs to involve the PS leadership team.

---

## The One-Sentence Positioning Statement

> **"Snowflake Professional Services uses an AI-powered delivery framework to transform your raw Bronze data into validated, analytics-ready Silver tables — in days instead of weeks — with fully documented business rules and production-ready deployment artifacts."**

---

*Internal use only — Snowflake Professional Services*
