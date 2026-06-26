# Agentic Transformation Skill — v3

**Version:** 3.0  
**Date:** June 2026  
**Status:** Production-ready — fully tested end-to-end

A deployable Snowflake-native framework for building agentic Silver and Gold data layers on top of existing Bronze tables. Deploy in any Snowflake account, point it at a Bronze schema, and a five-phase agentic pipeline (Schema Analyst → Planner → Executor → Validator → Reflector) builds and validates your transformation layer — with a human review gate at every critical step.

> **Prerequisites:** Bronze tables must already exist. Cortex-enabled Snowflake account. No ingestion tooling included.

---

## What's New in v3

| Fix | Problem in v2 | v3 Behaviour |
|-----|--------------|-------------|
| Safe output schema | Wrote directly to `SILVER` by default — destroyed live data in one test | All output goes to `AGENT_FRAMEWORK_OUTPUT`; never touches `SILVER` or `GOLD` |
| Dry Run mode | No preview — LLM output executed immediately | `dry_run=TRUE` by default; DDL logged to `WORKFLOW_LOG`, nothing executed |
| Overwrite protection | Silently overwrote existing tables | Aborts with row count if target table has data; requires explicit `overwrite_existing=TRUE` |
| Column hallucination | LLM invented column names (`INGEST_DATE`, etc.) | Exact column list from `INFORMATION_SCHEMA` injected into every prompt |
| Multi-banner partners | Assumed 1 Bronze → 1 Silver → 1 Gold | `PARTNER_BANNER_CONFIG` + `VALIDATE_MULTI_BANNER` supports any 1-to-many routing pattern |
| Schema Analyst | Hardcoded to single database, financial services domain | Python SP — cross-database `INFORMATION_SCHEMA`, domain-agnostic prompt |
| Cross-DB Bootstrap | Framework DB had to match data DB | `BOOTSTRAP` accepts `DB.SCHEMA` or comma-separated `DB1.SCHEMA1,DB2.SCHEMA2` |

---

## Deployment

### Option A — Snow CLI (~2 min)

```bash
git clone <repo> && cd agentic-transformation-skill-v3

./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   YOUR_DB         \
  --bronze-schema BRONZE

snow streamlit deploy app/ -c YOUR_CONNECTION
```

### Option B — Snowsight (no CLI)

`SETUP_ALL.sql` uses `!source` directives that **do not work in Snowsight**. Run each file individually instead:

1. Open Snowsight → Worksheets → New Worksheet
2. At the top of each file, add `SET TARGET_DB = 'YOUR_DB';` before running
3. Run each file in order: `00_bootstrap.sql` → `01_transformation_registry.sql` → ... → `12_document_ingestion.sql`
4. After all files run, call Bootstrap: `CALL AGENT_FRAMEWORK.BOOTSTRAP('YOUR_DB.BRONZE');`
5. Snowsight → Streamlit → **+ Streamlit App** → paste `app/streamlit_app.py`

### Bootstrap Pattern

The framework database never needs to match the data database — the real-world pattern:

```sql
-- Framework in ATS_V3, Bronze data in customer's own DB
CALL AGENT_FRAMEWORK.BOOTSTRAP('CUSTOMER_DB.BRONZE');

-- Multiple Bronze sources
CALL AGENT_FRAMEWORK.BOOTSTRAP('DB1.BRONZE,DB2.RAW,DB3.STAGE');
```

---

## The 11-Tab App

| Tab | Purpose |
|-----|---------|
| **⚙️ Setup** | Bootstrap, model validation, Foundation table discovery, Reset |
| **💡 Context** | Business description, data domain, analytics goals, constraints, Gold output model, dry run / overwrite / brownfield toggles |
| **📐 Contracts** | Structural rules injected into every LLM prompt (naming, types, CDC columns, dedup strategy) |
| **🎯 Directives** | Per-table business intent matched via SQL LIKE pattern — tell the agent what each table is FOR |
| **🤖 Workflow** | Run the 5-phase pipeline; live phase diagram; Schema Analyst approval gate; resume from failure |
| **🏆 Analytics Builder** | LLM proposes Gold DDL for SA review; execute directly or export as DCM project |
| **🗂️ Registry** | Bronze → Silver → Gold lineage map; discovered FK relationships by execution |
| **📊 Observe** | KPI metrics, executor results, learning intelligence loop, workflow log with color-coded status |
| **🏷️ Partner Routing** | Configure and validate 1-Silver → many-Gold routing rules per partner (banner, region, format) |
| **📦 DCM Export** | Generate deployable DCM project (manifest + DEFINE TABLE statements + access grants) |
| **📄 Documents** | Upload PDFs/text docs to `@DOCUMENT_STAGE`; chunk into `ATS_KNOWLEDGE_CORPUS`; Planner RAG retrieves automatically |

---

## Five-Phase Pipeline

```
Schema Analyst → Planner → Executor → Validator → Reflector
```

| Phase | What it does |
|-------|-------------|
| **Schema Analyst** | Cross-database FK discovery across all tables in scope; optional human approval gate |
| **Planner** | LLM analyzes schemas + directives + prior learnings → decides transformation strategy and PK columns |
| **Executor** | Generates DDL, executes (or logs for dry run), self-corrects up to 3 retries on SQL errors |
| **Validator** | Row count validation using Planner-identified PK columns; not a guess |
| **Reflector** | Captures learnings (success patterns, failure patterns, optimizations) into `WORKFLOW_LEARNINGS` for future runs |

The Reflector feeds `ATS_KNOWLEDGE_CORPUS`, which is indexed by a **Cortex Search service** (`ATS_KNOWLEDGE_SEARCH`). The Planner queries this service before each run — the system gets smarter with use.

---

## Cortex Intelligence

| Component | Object | Purpose |
|-----------|--------|---------|
| Cortex Search | `ATS_KNOWLEDGE_SEARCH` service | Planner RAG — retrieves prior decisions, learnings, and document context |
| Semantic View | `ATS_PIPELINE_SEMANTICS` | Cortex Analyst / Snowflake Intelligence interface over pipeline metadata |
| Knowledge Corpus | `ATS_KNOWLEDGE_CORPUS` (view) | UNION ALL over `WORKFLOW_LEARNINGS`, `PLANNER_DECISIONS`, `SCHEMA_RELATIONSHIPS`, `DOCUMENT_CONTEXT_ITEMS` |

---

## Partner Routing

Supports any industry pattern where one Silver table fans out to multiple Gold tables based on a dimension value:

| Industry | Routing dimension | Example |
|----------|------------------|---------|
| Grocery | Store banner | 14 banners → 13 Gold tables |
| Retail | Store format | Express / Standard / Premium → 3 Gold tables |
| Media | Content type | Categories → separate analytics tables |
| Financial | Product line | Segments → separate reporting tables |

Key capabilities: per-rule exclusion filters, merge targets (routes rows from one value into another rule's Gold table), variance tolerance per partner.

---

## Gold Output Models

Set in **Tab 2 → Gold Output Model**:

| Model | Output |
|-------|--------|
| `FLAT` | Denormalized Silver CTAS (default) |
| `STAR_SCHEMA` | `FACT_` + `DIM_` tables with surrogate keys |
| `DATA_VAULT` | HUBs + LINKs + SATs with hash keys |
| `ONE_BIG_TABLE` | Single wide table per domain — best for Cortex Analyst |

---

## Model Configuration

No model names are hardcoded anywhere. All SPs read from `AGENT_FRAMEWORK.MODEL_CONFIG` at runtime. Bootstrap auto-selects from a priority-ordered list:

```
1. llama3.3-70b  ← recommended (clean DDL, no backtick fences)
2. llama3.1-70b
3. mistral-large2
4. claude-3-7-sonnet
```

Switch at any time from Tab 1 or via SQL:

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('llama3.3-70b');
```

---

## DCM Production Handoff

Once Gold DDLs are approved in Tab 6, click **⚡ Generate DCM Project**. The `GENERATE_DCM_PROJECT` SP produces 6 files written to `@AGENT_FRAMEWORK.DCM_OUTPUT`:

| File | Contents |
|------|---------|
| `manifest.yml` | DCM project manifest with DEV/PROD targets |
| `infrastructure.sql` | `DEFINE SCHEMA` for all output schemas |
| `tables.sql` | `DEFINE TABLE` for all Silver/enriched tables |
| `analytics.sql` | `DEFINE TABLE` for all Gold/analytics tables |
| `access.sql` | `GRANT` statements for Data Engineer + Analyst roles |
| `expectations.sql` | `ATTACH DATA METRIC FUNCTION` for PK null checks |

Deploy to production:
```bash
snow stage get @AGENT_FRAMEWORK.DCM_OUTPUT ./dcm_project -c <connection>
snow dcm deploy <DB.SCHEMA.PROJECT_NAME> -c <connection> --alias initial-deploy
```

---

## Deployed Objects

**27 Stored Procedures:**

| SP | Purpose |
|----|---------|
| `BOOTSTRAP(sources)` | Cross-DB Bronze discovery, model validation, seeds defaults; detects existing Silver when brownfield_mode=TRUE |
| `VALIDATE_MODEL(model)` | Tests a Cortex model and updates `MODEL_CONFIG` |
| `SET_PIPELINE_CONTEXT(...)` | 10-parameter named-arg context setter |
| `SET_BROWNFIELD_MODE(mode)` | Toggles brownfield_mode on PIPELINE_CONTEXT; separate SP to avoid default-overload ambiguity |
| `RESET_FRAMEWORK('YES')` | Full truncate of all runtime tables (preserves config) |
| `CLEAR_WORKFLOW_HISTORY()` | Clears run history without touching lineage map or config |
| `WORKFLOW_SCHEMA_ANALYST(eid)` | Phase 1 — cross-DB FK discovery |
| `WORKFLOW_PLANNER(eid)` | Phase 2 — LLM transformation planning |
| `WORKFLOW_EXECUTOR(eid)` | Phase 3 — DDL generation and execution; brownfield skip logic |
| `WORKFLOW_VALIDATOR(eid)` | Phase 4 — row count and PK validation |
| `WORKFLOW_REFLECTOR(eid)` | Phase 5 — learning capture |
| `RUN_AGENTIC_WORKFLOW(trigger, tables, trigger_type)` | Orchestrator — chains all 5 phases |
| `BUILD_GOLD_FOR_NEW_TABLES(dry_run, max)` | Gold DDL proposal loop |
| `GOLD_AGENTIC_EXECUTOR(ddl)` | Executes a single approved Gold DDL |
| `GENERATE_DCM_PROJECT(name, de_role, analyst_role)` | Produces 6-file DCM project |
| `VALIDATE_MULTI_BANNER(partner, db)` | Partner routing row count validation |
| `SEED_LCL_BANNER_CONFIG(silver_schema, gold_schema)` | Seeds LCL V2 14-banner example config |
| `SEED_DEFAULT_CONTRACTS()` | MERGE-safe reseed of default Schema Contracts |
| `SEED_DEFAULT_DIRECTIVES()` | MERGE-safe reseed of default Directives |
| `SEARCH_ATS_KNOWLEDGE(query, limit)` | Cortex Search over `ATS_KNOWLEDGE_CORPUS` |
| `DISCOVER_SCHEMA(fqn)` | Returns column metadata for a fully-qualified table |
| `DEBUG_BANNER_FQN(partner, db)` | Debug helper for banner FQN resolution |
| `GET_BANNER_CONFIG(partner)` | Returns active banner config as VARIANT |
| `INGEST_DOCUMENT_FROM_STAGE(path, name, type)` | PDF on `@DOCUMENT_STAGE` → PARSE_DOCUMENT → chunk → `DOCUMENT_CONTEXT_ITEMS` |
| `INGEST_DOCUMENT_TEXT(name, type, text)` | Raw text → chunk → `DOCUMENT_CONTEXT_ITEMS` |
| `LIST_DOCUMENTS()` | Lists all indexed documents with chunk and character counts (JSON) |
| `REMOVE_DOCUMENT(name)` | Deletes all chunks for a named document from `DOCUMENT_CONTEXT_ITEMS` |

**17 Tables / Views:**

`TABLE_LINEAGE_MAP`, `WORKFLOW_EXECUTIONS`, `WORKFLOW_LOG`, `WORKFLOW_LEARNINGS`, `PLANNER_DECISIONS`, `SCHEMA_RELATIONSHIPS`, `SCHEMA_CONTRACTS`, `TRANSFORMATION_DIRECTIVES`, `PIPELINE_CONTEXT`, `MODEL_CONFIG`, `PARTNER_BANNER_CONFIG`, `DOCUMENT_CONTEXT_ITEMS` + views: `ATS_KNOWLEDGE_CORPUS` (UNION ALL over 4 sources including documents), `ACTIVE_DIRECTIVES`, `COVERAGE_SUMMARY`, `GOLD_GAPS`, `SILVER_GAPS`

---

## Setup Files

| File | Contents |
|------|---------|
| `00_bootstrap.sql` | Schema, MODEL_CONFIG, BOOTSTRAP, RESET_FRAMEWORK, CLEAR_WORKFLOW_HISTORY |
| `01_transformation_registry.sql` | TABLE_LINEAGE_MAP, WORKFLOW_EXECUTIONS, WORKFLOW_LOG, WORKFLOW_LEARNINGS, PLANNER_DECISIONS |
| `02_schema_contracts.sql` | SCHEMA_CONTRACTS table + SEED_DEFAULT_CONTRACTS SP |
| `03_directives.sql` | TRANSFORMATION_DIRECTIVES table + SEED_DEFAULT_DIRECTIVES SP |
| `04a_discover_schema.sql` | DISCOVER_SCHEMA SP |
| `04b_planner.sql` | WORKFLOW_PLANNER SP |
| `04c_executor.sql` | WORKFLOW_EXECUTOR SP |
| `04d_validator.sql` | WORKFLOW_VALIDATOR SP |
| `04e_reflector.sql` | WORKFLOW_REFLECTOR SP |
| `04f_orchestrator.sql` | RUN_AGENTIC_WORKFLOW SP |
| `05_gold_builder.sql` | BUILD_GOLD_FOR_NEW_TABLES, GOLD_AGENTIC_EXECUTOR SPs |
| `06_schema_analyst.sql` | WORKFLOW_SCHEMA_ANALYST SP + SCHEMA_RELATIONSHIPS table |
| `07_pipeline_context.sql` | PIPELINE_CONTEXT table + SET_PIPELINE_CONTEXT SP + SET_BROWNFIELD_MODE SP |
| `08_dcm_export.sql` | GENERATE_DCM_PROJECT SP + DCM_OUTPUT stage |
| `09_banner_config.sql` | PARTNER_BANNER_CONFIG table + VALIDATE_MULTI_BANNER + SEED_LCL_BANNER_CONFIG |
| `10_cortex_search.sql` | ATS_KNOWLEDGE_SEARCH Cortex Search service (initial ATS_KNOWLEDGE_CORPUS view) |
| `11_semantic_view.sql` | ATS_PIPELINE_SEMANTICS semantic view |
| `12_document_ingestion.sql` | `@DOCUMENT_STAGE`, `DOCUMENT_CONTEXT_ITEMS` table, updated `ATS_KNOWLEDGE_CORPUS` view, INGEST/LIST/REMOVE SPs |
| `SETUP_ALL.sql` | Single-file Snowsight deployment (runs 00–12 in order) |

---

## Repository Structure

```
agentic-transformation-skill-v3/
├── README.md
├── SKILL.md                          CoCo skill descriptor
├── app/
│   ├── streamlit_app.py              11-tab Streamlit in Snowflake app
│   ├── environment.yml               Conda dependencies
│   └── snowflake.yml                 Snow CLI app config
├── setup/
│   ├── SETUP_ALL.sql                 Single-file Snowsight deployment
│   ├── deploy.sh                     Parameterized Snow CLI deploy script
│   ├── 00_bootstrap.sql – 12_document_ingestion.sql
│   └── ats_pipeline_semantics.yaml   Semantic view source YAML
├── docs/
│   ├── architecture.md               Component architecture
│   ├── demo_walkthrough.md           Full 10-tab demo guide with validation SQL
│   ├── v3_release_notes.md           P0/P1 fixes vs v2
│   ├── v4_architecture.md            Cortex Agents architecture proposal
│   ├── talk_track.md                 SA delivery narrative
│   └── decisions/
│       ├── 001-model-configuration.md  ADR: MODEL_CONFIG pattern
│       └── 002-dcm-integration.md      ADR: DCM as production exit ramp
└── demo/
    └── test_data_full.sql            3-partner test dataset (Ren's Pets, DashMart, LCL V2)
```

---

## Cortex Code Skill

Install globally:
```bash
ln -s "$(pwd)" ~/.snowflake/cortex/skills/agentic-transformation-skill-v3
```

Auto-triggered by keywords: *silver layer*, *bronze to silver*, *agentic workflow*, *schema contracts*, *data foundry*, *partner routing*.

---

## References

- `docs/demo_walkthrough.md` — step-by-step demo with exact validation SQL for every tab
- `docs/v3_release_notes.md` — full changelog vs v2
- `docs/v4_architecture.md` — Cortex Agents design for v4
- `docs/decisions/` — Architecture Decision Records
