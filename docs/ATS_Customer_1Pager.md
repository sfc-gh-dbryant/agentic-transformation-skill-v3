# Agentic Transformation Skill
### AI-Accelerated Data Pipeline Development on Snowflake

---

## What It Is

The **Agentic Transformation Skill (ATS)** is an AI-powered framework that dramatically accelerates the most time-consuming phase of data engineering: transforming raw, messy Bronze-layer data into clean, analytics-ready Silver tables.

Where traditional pipeline development requires weeks of manual SQL authoring, schema discovery, and validation scripting, ATS uses a coordinated team of Cortex Agents to plan, execute, validate, and learn from each transformation — automatically.

---

## How It Works

ATS runs a five-phase agentic pipeline inside your Snowflake account:

| Phase | Agent | What It Does |
|---|---|---|
| 1 | **Schema Analyst** | Discovers relationships between your raw tables — foreign keys, entity references, data patterns |
| 2 | **Planner** | Decides the right transformation strategy for each table (deduplicate, flatten, type-cast, etc.) |
| 3 | **Executor** | Generates and runs the Silver-layer DDL — with self-correction on failure |
| 4 | **Validator** | Checks row counts, primary key uniqueness, and data quality thresholds |
| 5 | **Reflector** | Captures learnings from the run to improve every future execution |

Each agent uses your business context — schema contracts, transformation directives, and institutional knowledge — to make decisions that align with your data standards.

---

## What You Receive

A Snowflake Professional Services engagement using ATS delivers:

- **Silver tables** — transformed, validated, analytics-ready data in your Snowflake account
- **Schema contracts** — structural rules that define how your Silver layer must look
- **Transformation directives** — reusable business rules encoded as instructions for future pipeline runs
- **The ATS framework** — deployed in your account so your team can run, extend, and adapt it
- **Pipeline documentation** — full lineage, audit logs, and workflow history for every run

---

## What It Is Not

| | |
|---|---|
| **Not a product** | ATS is delivered as part of a Snowflake PS engagement. There are no support contracts, versioned releases, or SLAs beyond the engagement terms. |
| **Not a no-code tool** | ATS accelerates data engineers — it does not replace them. Your team will validate outputs, tune directives, and adapt the framework to your environment. |
| **Not production-hardened out of the box** | The framework is deployed and tested during the engagement. Your team owns testing, validation, and hardening for production workloads. |
| **Not a full ETL replacement** | ATS focuses on Bronze → Silver transformation and AI-proposed Gold/Analytics DDL. It does not replace your ingestion layer or BI tooling (Power BI, Sigma, Tableau). |

---

## Existing Data Is Protected

ATS is designed to run safely in environments that already have Silver tables, schemas, or partial pipeline coverage. Three built-in safeguards prevent accidental data loss:

- **Dry Run (default ON)** — Every pipeline run generates and logs DDL but executes nothing. You review every statement before a single table is touched. Execution requires an explicit opt-in.
- **No Overwrite (default OFF)** — If a target table already has rows, the Executor skips that table, logs it, and continues processing the remaining tables. Existing data is never overwritten unless you explicitly permit it — and only after dry run is also explicitly disabled.
- **Brownfield Mode** — For environments where some Silver tables already exist, Brownfield Mode skips those tables entirely and only processes the gaps. Existing tables are logged as `EXISTING` and left untouched.

These defaults mean a first run against any environment — greenfield or brownfield — produces no side effects until your team has reviewed and approved the proposed DDL.

---

## Why It Matters

> Traditional Bronze → Silver pipeline development averages **4–8 weeks** for a mid-sized dataset portfolio. ATS reduces this to **days**, while producing documented, repeatable, and extensible pipelines your team can own.

The agents don't just run faster — they get smarter. Every run produces learnings that are stored in a searchable knowledge corpus, so the second pipeline run is better than the first, and the tenth is better than the fifth.

---

## Real-World Scenario: Multi-Business-Unit Migration

A specialty insurance company is migrating 12–20 business units from on-premises SQL Server and SSIS to Snowflake. Each business unit brings its own raw Bronze tables — claims, premiums, policy data, reinsurance treaties — with legacy schemas, inconsistent nulls, undocumented primary keys, and SSIS transformation logic embedded in code nobody fully understands.

**The traditional approach** would have a data engineer manually reverse-engineering each BU's schema, writing Silver DDL by hand, and building validation scripts — repeating this process for each of the 12–20 business units over months.

**With ATS**, a PS engineer configures the pipeline context once ("insurance carrier, regulatory reporting and actuarial analytics goals"), writes schema contracts ("Silver claims tables must have no null policy IDs, dedup on claim_number + effective_date"), and adds directives for the known edge cases ("reinsurance_treaties uses a composite business key"). The agents then plan and execute the Silver transformation for that BU's tables in days — not weeks.

When the next business unit onboards, the framework already knows the domain. The Reflector's learnings from BU 1 inform BU 2's execution. The pattern repeats across all 12–20 units at a fraction of the cost and time of manual development.

**Important:** ATS produces the Silver transformation logic for each business unit. Once validated, that logic is operationalized into scheduled Snowflake pipelines (Dynamic Tables, Tasks, or dbt models) that run independently. ATS is not the nightly pipeline — it is the accelerator that authors it.

---

## Built on Snowflake

ATS runs entirely within your Snowflake account using:
- **Cortex Agents** for agentic reasoning and tool orchestration
- **Cortex LLMs** for SQL generation and schema analysis
- **Snowflake Stored Procedures** as deterministic guardrails
- **Streamlit in Snowflake** for pipeline management and observability

No external services. No data leaves your account.

---

*Delivered by Snowflake Professional Services*
