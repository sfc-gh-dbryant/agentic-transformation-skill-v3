# Agentic Transformation Skill — v4

**Branch:** `v4` (stable v3 on `main`)  
**Version:** 4.0  
**Date:** June 2026  
**Status:** Production-ready — 5/5 tables, retries=0, 5/5 Validator passes  
**Database:** `ATS_V4.AGENT_FRAMEWORK` (reference deploy)

A Snowflake-native framework that transforms Bronze tables into validated Silver and Gold layers using a five-phase agentic pipeline. v4 adds a full Cortex Agents layer on top of the v3 SP pipeline — each phase has both a stored procedure (fast, batch) and a Cortex Agent (interactive, tool-grounded).

> **Prerequisites:** Bronze tables must already exist. Cortex-enabled Snowflake account. `ACCOUNTADMIN` or equivalent. No ingestion tooling included.

---

## Branch Strategy

| Branch | Version | Use |
|--------|---------|-----|
| `main` | v3 | Stable. SA delivery today. |
| `v4` | v4 | This branch. Active development. Cortex Agents layer. |

---

## What's New in v4

| Change | Detail |
|--------|--------|
| **6 Cortex Agents** | One agent per phase (Schema Analyst, Planner, Executor, Validator, Reflector) + Orchestrator. Each agent uses tools instead of a single LLM call. |
| **35 `ATS_TOOL_*` SPs** | One SP per agent tool. Callable by both Cortex Agents and the SP pipeline. JSON in/out contract. |
| **Column hallucination = 0** | `ATS_TOOL_GET_COLUMNS` grounds every DDL generation call against exact `INFORMATION_SCHEMA` output. `CONFLICT_REDIRECTED` variable name guard added. |
| **Cost attribution** | `CAPTURE_WORKFLOW_COST` SP + `WORKFLOW_COST_ATTRIBUTION` table. Warehouse credits (real-time) + Cortex credits (45-min delay). Observe tab cost section. |
| **Observe tab redesign** | Per-table retry counts, run selector, color-coded results, cost KPIs, phase duration bar chart. |
| **Conflict redirect — Gold** | Gold Builder now applies same VIEW/DT/empty-table redirect logic as Executor. |
| **Cross-database Validator** | Reads `output_db` from `PIPELINE_CONTEXT`; uses `EXECUTE IMMEDIATE` for cross-DB `INFORMATION_SCHEMA` SCD2 detection. |

## What's New in v3 (from v2)

| Fix | Problem in v2 | v3 Behaviour |
|-----|--------------|-------------|
| Safe output schema | Wrote directly to `SILVER` by default — destroyed live data in one test | All output goes to `AGENT_FRAMEWORK_OUTPUT`; never touches `SILVER` or `GOLD` |
| Dry Run mode | No preview — LLM output executed immediately | `dry_run=TRUE` by default; DDL logged to `WORKFLOW_LOG`, nothing executed |
| Overwrite protection | Silently overwrote existing tables | Aborts with row count if target table has data; requires explicit `overwrite_existing=TRUE` |
| Column hallucination | LLM invented column names (`INGEST_DATE`, etc.) | Exact column list from `INFORMATION_SCHEMA` injected into every prompt |
| Multi-banner partners | Assumed 1 Bronze → 1 Silver → 1 Gold | `PARTNER_BANNER_CONFIG` + `VALIDATE_MULTI_BANNER` supports any 1-to-many routing |
| Schema Analyst | Hardcoded to single database, financial services domain | Python SP — cross-database `INFORMATION_SCHEMA`, domain-agnostic prompt |
| Cross-DB Bootstrap | Framework DB had to match data DB | `BOOTSTRAP` accepts `DB.SCHEMA` or comma-separated multi-source |

---

## Deployment

### Option A — Snow CLI (~3 min)

```bash
git clone <repo> -b v4
cd agentic-transformation-skill-v3

./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   YOUR_DB         \
  --bronze-schema BRONZE

snow streamlit deploy app/ -c YOUR_CONNECTION --replace
```

`deploy.sh` runs all 21 files in dependency order and calls `BOOTSTRAP` automatically.

> **SQL Scripting limitation:** `snow sql -f` fails on `||` concatenation inside `$$...$$` blocks. If `04a`–`04f` fail, deploy them via Python connector. See `docs/v4_architecture.md § Known Limitations`.

### Option B — Snowsight (no CLI)

Run each file individually in order. At the top of each file, add:
```sql
SET TARGET_DB = 'YOUR_DB';
```

Order: `00` → `01` → ... → `12` → `v4_tools.sql` → `v4_agents.sql`

Then call Bootstrap:
```sql
CALL AGENT_FRAMEWORK.BOOTSTRAP('YOUR_DB.BRONZE');
```

### Bootstrap Pattern

```sql
-- Framework DB separate from data DB (standard pattern)
CALL AGENT_FRAMEWORK.BOOTSTRAP('CUSTOMER_DB.BRONZE');

-- Multiple Bronze sources
CALL AGENT_FRAMEWORK.BOOTSTRAP('DB1.BRONZE,DB2.RAW,DB3.STAGE');
```

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     STREAMLIT APP (v4)                         │
│  Pipeline Tab                    Agent Hub / Orchestrate Tab   │
│  ─────────────────                ─────────────────────────    │
│  SP Pipeline (batch, reliable)    Cortex Agents (interactive)  │
└──────────┬────────────────────────────────┬───────────────────┘
           │                                │
           ▼                                ▼
┌──────────────────────┐      ┌─────────────────────────────────┐
│   SP Pipeline (v3+)  │      │   Cortex Agents Layer (v4)      │
│  WORKFLOW_SCHEMA_     │      │  ATS_SCHEMA_ANALYST_AGENT       │
│  ANALYST             │      │  ATS_PLANNER_AGENT              │
│  WORKFLOW_PLANNER    │      │  ATS_EXECUTOR_AGENT             │
│  WORKFLOW_EXECUTOR   │      │  ATS_VALIDATOR_AGENT            │
│  WORKFLOW_VALIDATOR  │      │  ATS_REFLECTOR_AGENT            │
│  WORKFLOW_REFLECTOR  │      │  ATS_ORCHESTRATOR_AGENT         │
└──────────┬───────────┘      └──────────────┬──────────────────┘
           └──────────────────┬──────────────┘
                              │ Both paths read/write
                              ▼
           ┌──────────────────────────────────────┐
           │           Shared Data Layer           │
           │  WORKFLOW_EXECUTIONS  WORKFLOW_LOG    │
           │  TABLE_LINEAGE_MAP    PLANNER_DECISIONS│
           │  SCHEMA_RELATIONSHIPS WORKFLOW_LEARNINGS│
           │  SCHEMA_CONTRACTS     TRANSFORMATION_ │
           │  PIPELINE_CONTEXT     DIRECTIVES      │
           │  WORKFLOW_COST_ATTRIBUTION             │
           └──────────────────────────────────────┘
```

---

## Five-Phase Pipeline

```
Schema Analyst → Planner → Executor → Validator → Reflector
```

| Phase | SP | Agent | What it does |
|-------|----|-------|-------------|
| **Schema Analyst** | `WORKFLOW_SCHEMA_ANALYST` | `ATS_SCHEMA_ANALYST_AGENT` | Cross-DB FK discovery; samples data to verify hypotheses before recording |
| **Planner** | `WORKFLOW_PLANNER` | `ATS_PLANNER_AGENT` | Decides transformation strategy, PK columns, SCD type per table; queries Cortex Search for prior decisions |
| **Executor** | `WORKFLOW_EXECUTOR` | `ATS_EXECUTOR_AGENT` | Generates Silver DDL; GET_COLUMNS tool grounds every generation; 3-retry self-correcting loop |
| **Validator** | `WORKFLOW_VALIDATOR` | `ATS_VALIDATOR_AGENT` | Row count parity, PK uniqueness, SCD2-aware; uses Planner PK columns — never guesses |
| **Reflector** | `WORKFLOW_REFLECTOR` | `ATS_REFLECTOR_AGENT` | Post-mortem learnings; deduplicates via Cortex Search before saving |

---

## Streamlit App

| Tab | Purpose |
|-----|---------|
| **⚙️ Setup** | Bootstrap, model validation, table discovery, Reset |
| **💡 Context** | Business description, domain, goals, dry run / overwrite / brownfield / conflict redirect toggles |
| **📐 Contracts** | Structural rules injected into every LLM prompt |
| **🎯 Directives** | Per-table business intent matched via SQL LIKE pattern |
| **🤖 Workflow** | Run the 5-phase SP pipeline; live phase diagram; Schema Analyst approval gate |
| **🤖 Agent Hub** | Interact directly with any of the 6 Cortex Agents |
| **🎼 Orchestrate** | Run the full pipeline via `ATS_ORCHESTRATOR_AGENT` |
| **🏆 Analytics Builder** | LLM proposes Gold DDL; dry-run review before execute |
| **🗂️ Registry** | Bronze → Silver → Gold lineage map; FK relationships by execution |
| **📊 Observe** | Run selector, per-table retry counts, cost attribution, learnings loop |
| **🏷️ Partner Routing** | Configure and validate 1-Silver → many-Gold routing rules |
| **📦 DCM Export** | Generate deployable DCM project |
| **📄 Documents** | Upload PDFs/text; chunk into `ATS_KNOWLEDGE_CORPUS`; Planner RAG retrieves automatically |

---

## Cortex Intelligence

| Component | Object | Purpose |
|-----------|--------|---------|
| Cortex Search | `ATS_KNOWLEDGE_SEARCH` | Planner RAG — retrieves prior decisions, learnings, relationships, documents |
| Semantic View | `ATS_PIPELINE_SEMANTICS` | Natural language queries over pipeline state via Cortex Analyst |
| Knowledge Corpus | `ATS_KNOWLEDGE_CORPUS` | UNION ALL over `WORKFLOW_LEARNINGS`, `PLANNER_DECISIONS`, `SCHEMA_RELATIONSHIPS`, `DOCUMENT_CONTEXT_ITEMS` |

---

## Safety & Brownfield

| Safeguard | Default | Behaviour |
|-----------|---------|-----------|
| **Dry Run** | `TRUE` | Generates DDL, logs it, never executes. Must opt-in to execute. |
| **No Overwrite** | `FALSE` | If target has rows, aborts with row count logged. Two-key interlock required. |
| **Brownfield Mode** | `FALSE` | Skips existing Silver tables (logs as `EXISTING`, not failure). Only processes gaps. |
| **Conflict Redirect** | Auto | VIEW, Dynamic Table, or empty table at target → redirected to fallback schema. Default: `{output_schema}_STAGING`. |

---

## Model Configuration

No model names are hardcoded. All SPs read from `AGENT_FRAMEWORK.MODEL_CONFIG` at runtime.

```
1. llama3.3-70b  ← recommended
2. llama3.1-70b
3. mistral-large2
4. claude-3-7-sonnet
```

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('llama3.3-70b');
```

---

## Deployed Objects

**62 Stored Procedures** (27 framework SPs + 35 `ATS_TOOL_*` tool SPs)  
**13 Tables** · **5 Views** · **1 Semantic View** · **1 Cortex Search Service** · **6 Cortex Agents**

Full inventory with purpose, parameters, and setup file mapping: **`docs/v4_design_reference.md`**

### Key Framework SPs

| SP | Purpose |
|----|---------|
| `BOOTSTRAP(sources)` | Cross-DB Bronze discovery, model validation, seeds defaults |
| `SET_PIPELINE_CONTEXT(...)` | Named-parameter context setter (output schema, dry run, brownfield, conflict redirect) |
| `RUN_AGENTIC_WORKFLOW()` | Chains all 5 phases — CLI/Task entry point |
| `CAPTURE_WORKFLOW_COST(eid)` | Standalone cost attribution — warehouse + Cortex credits per run |
| `CLEAR_WORKFLOW_HISTORY()` | Soft reset between runs — preserves contracts, directives, learnings |
| `RESET_FRAMEWORK('YES')` | Full wipe of runtime data — preserves config |

---

## Setup Files

| File | Contents |
|------|---------|
| `00_bootstrap.sql` | Schema, MODEL_CONFIG, BOOTSTRAP, RESET_FRAMEWORK, CLEAR_WORKFLOW_HISTORY |
| `01_transformation_registry.sql` | TABLE_LINEAGE_MAP, WORKFLOW_EXECUTIONS, WORKFLOW_LOG, WORKFLOW_LEARNINGS, PLANNER_DECISIONS + views |
| `02_schema_contracts.sql` | SCHEMA_CONTRACTS + SEED_DEFAULT_CONTRACTS |
| `03_directives.sql` | TRANSFORMATION_DIRECTIVES + ACTIVE_DIRECTIVES view + SEED_DEFAULT_DIRECTIVES |
| `04a_discover_schema.sql` | DISCOVER_SCHEMA SP |
| `04b_planner.sql` | WORKFLOW_PLANNER SP |
| `04c_executor.sql` | WORKFLOW_EXECUTOR SP — dry_run, conflict redirect, CONFLICT_REDIRECTED guard |
| `04d_validator.sql` | WORKFLOW_VALIDATOR SP — cross-DB aware, SCD2, Planner PK columns |
| `04e_reflector.sql` | WORKFLOW_REFLECTOR SP |
| `04f_orchestrator.sql` | RUN_AGENTIC_WORKFLOW SP |
| `05_gold_builder.sql` | GOLD_AGENTIC_EXECUTOR, BUILD_GOLD_FOR_NEW_TABLES, EXPORT_DCM_PROJECT |
| `06_schema_analyst.sql` | WORKFLOW_SCHEMA_ANALYST SP + SCHEMA_RELATIONSHIPS table |
| `07_pipeline_context.sql` | PIPELINE_CONTEXT table + SET_PIPELINE_CONTEXT + helper UDFs |
| `08_cost_attribution.sql` | WORKFLOW_COST_ATTRIBUTION table + CAPTURE_WORKFLOW_COST SP |
| `08_dcm_export.sql` | GENERATE_DCM_PROJECT SP + DCM_OUTPUT stage |
| `09_banner_config.sql` | PARTNER_BANNER_CONFIG + VALIDATE_MULTI_BANNER + SEED_LCL_BANNER_CONFIG |
| `10_cortex_search.sql` | ATS_KNOWLEDGE_CORPUS view + ATS_KNOWLEDGE_SEARCH service |
| `11_semantic_view.sql` | ATS_PIPELINE_SEMANTICS semantic view |
| `12_document_ingestion.sql` | DOCUMENT_STAGE, DOCUMENT_CONTEXT_ITEMS, INGEST/LIST/REMOVE SPs, updated ATS_KNOWLEDGE_CORPUS |
| `v4_tools.sql` | All 35 `ATS_TOOL_*` stored procedures — deploy before v4_agents.sql |
| `v4_agents.sql` | All 6 Cortex Agent definitions — deploy last |

---

## Repository Structure

```
agentic-transformation-skill-v3/
├── README.md                         This file
├── SKILL.md                          CoCo skill descriptor
├── app/
│   ├── streamlit_app_v4.py           v4 Streamlit app (Cortex Agents + SP pipeline)
│   ├── streamlit_app.py              v3 Streamlit app
│   ├── requirements.txt              Additional pip packages for container runtime
│   ├── environment.yml               Conda deps for v3 app
│   └── snowflake.yml                 Snow CLI app config (both v3 and v4 entities)
├── setup/
│   ├── deploy.sh                     Full deploy script — runs all 21 files in order
│   ├── SETUP_ALL.sql                 Snowsight fallback (run files individually)
│   ├── 00_bootstrap.sql
│   ├── 01_transformation_registry.sql
│   ├── 02_schema_contracts.sql
│   ├── 03_directives.sql
│   ├── 04a_discover_schema.sql
│   ├── 04b_planner.sql
│   ├── 04c_executor.sql
│   ├── 04d_validator.sql
│   ├── 04e_reflector.sql
│   ├── 04f_orchestrator.sql
│   ├── 05_gold_builder.sql
│   ├── 06_schema_analyst.sql
│   ├── 07_pipeline_context.sql
│   ├── 08_cost_attribution.sql
│   ├── 08_dcm_export.sql
│   ├── 09_banner_config.sql
│   ├── 10_cortex_search.sql
│   ├── 11_semantic_view.sql
│   ├── 12_document_ingestion.sql
│   ├── v4_tools.sql                  35 ATS_TOOL_* SPs — Cortex Agent tool layer
│   ├── v4_agents.sql                 6 Cortex Agent definitions
│   └── ats_pipeline_semantics.yaml   Semantic view source YAML
├── docs/
│   ├── v4_architecture.md            Implemented architecture spec (v4)
│   ├── v4_design_reference.md        Full object inventory — every table, view, SP, agent
│   ├── v4_backlog.md                 Product backlog — v1→v4 status + Jeremy's review findings
│   ├── v3_release_notes.md           v3 changelog vs v2
│   ├── v3_testing_guide.md           SA testing guide
│   ├── ATS_Sales_Internal_1Pager.md  Internal sales positioning guide
│   ├── ATS_Customer_1Pager.md        Customer-facing one-pager
│   ├── demo_walkthrough.md           Full demo guide with validation SQL
│   ├── customer_engagement_guide.md  Engagement delivery guide
│   └── decisions/
│       ├── 001-model-configuration.md
│       └── 002-dcm-integration.md
├── tests/
│   └── ats_v3_test_suite.py          End-to-end test suite
└── demo/
    ├── test_data_full.sql            3-partner test dataset (Ren's Pets, DashMart, LCL V2)
    ├── test_v3_data.sql
    └── test_v3_scenarios.sql
```

---

## Known Limitations

| Limitation | Workaround |
|------------|-----------|
| `snow sql -f` fails on `\|\|` inside `$$` blocks | Deploy `04a`–`04f` via Python connector with key auth |
| Cortex credit data has 45-min delay | Re-run `CAPTURE_WORKFLOW_COST` 45 min after pipeline completes |
| Cortex Search refreshes ~hourly | New documents/learnings not immediately searchable |
| Parallel execution not implemented | Pipeline processes tables sequentially |

---

## Documentation

| Doc | Purpose |
|-----|---------|
| `docs/v4_architecture.md` | Architecture overview, agent descriptions, design decisions |
| `docs/v4_design_reference.md` | Full itemized object inventory — every SP, table, view, agent |
| `docs/v4_backlog.md` | Backlog — what's done, what's pending, Jeremy's review findings |
| `docs/v3_testing_guide.md` | Step-by-step SA testing guide |
| `docs/decisions/` | Architecture Decision Records |
