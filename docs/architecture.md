# Agentic Transformation Skill — Architecture

**Version:** 1.0  
**Date:** April 2026  
**Owner:** Danny Bryant (Snowflake Solutions Development)

---

## Purpose

A deployable Snowflake-native skill (Streamlit in Snowflake + SQL framework) that guides an SA or
customer through building agentic Silver and Gold layers on top of existing raw/Bronze data.

### Personas

| Persona | Use Case |
|---|---|
| SA delivery | Deploy against a customer's existing raw tables, demonstrate live, leave behind as working accelerator |
| Customer self-serve | Data engineer picks it up post-demo and runs against their own schemas |

### What It Is NOT

- Not an ingestion tool — Bronze tables must already exist
- Not a semantic layer builder — no Cortex Analyst / VQRs
- Not a full data platform — scoped to the transformation layer only

---

## Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        STREAMLIT APP                         │
│  Setup │ Contracts │ Directives │ Workflow │ Gold │ Registry │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   AGENT_FRAMEWORK SCHEMA                     │
│                                                              │
│  ┌──────────────────┐       ┌─────────────────────────────┐ │
│  │  SCHEMA CONTRACTS│       │   TRANSFORMATION DIRECTIVES  │ │
│  │  - naming rules  │       │   - per-table intent         │ │
│  │  - type rules    │       │   - transformation hints     │ │
│  │  - CDC columns   │       │   - priority + patterns      │ │
│  └────────┬─────────┘       └──────────────┬──────────────┘ │
│           │                                │                 │
│  ┌────────▼────────────────────────────────▼──────────────┐ │
│  │               AGENTIC WORKFLOW ENGINE                   │ │
│  │       PLANNER → EXECUTOR → VALIDATOR → REFLECTOR       │ │
│  └──────────────────────────┬──────────────────────────────┘ │
│                             │                                │
│  ┌──────────────────────────▼──────────────────────────────┐ │
│  │                TRANSFORMATION REGISTRY                   │ │
│  │   TABLE_LINEAGE_MAP    │   WORKFLOW_LEARNINGS            │ │
│  │   WORKFLOW_EXECUTIONS  │   PLANNER_DECISIONS             │ │
│  └──────────────────────────┬──────────────────────────────┘ │
│                             │                                │
│  ┌──────────────────────────▼──────────────────────────────┐ │
│  │                     GOLD BUILDER                         │ │
│  │       GOLD_AGENTIC_EXECUTOR + BUILD_FOR_NEW_TABLES       │ │
│  │           ↓ Export as DCM Project (optional)             │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                   MODEL_CONFIG                          │ │
│  │   primary_model + fallback_model (no hardcoded names)   │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
          │
          │  Exit ramp: finalized Gold schemas
          ▼
┌──────────────────────────────────────────────────────────────┐
│                     DCM PROJECT (optional)                    │
│  DEFINE TABLE statements + grants + data quality expectations │
│  Customer checks into git, deploys to production via DCM CLI  │
└──────────────────────────────────────────────────────────────┘
```

---

## Database Objects

All objects deploy into a single dedicated schema:

```
<TARGET_DB>.AGENT_FRAMEWORK.*
```

### Transformation Registry

| Table | Purpose |
|---|---|
| `TABLE_LINEAGE_MAP` | Bronze → Silver → Gold mapping, single source of truth |
| `WORKFLOW_LEARNINGS` | Reflector scar tissue — learnings that persist across runs |
| `WORKFLOW_EXECUTIONS` | Run history, phases, status, timing |
| `PLANNER_DECISIONS` | Per-table LLM decisions with confidence scores |

### Control Layer

| Table | Purpose |
|---|---|
| `SCHEMA_CONTRACTS` | Structural rules — CDC columns, naming, type conventions |
| `TRANSFORMATION_DIRECTIVES` | Per-table transformation intent, priority, active flag |
| `ACTIVE_DIRECTIVES` | View — filters to active, ordered by priority |

### Configuration

| Table | Purpose |
|---|---|
| `MODEL_CONFIG` | Single-row table — primary + fallback Cortex model names |

See [decisions/001-model-configuration.md](decisions/001-model-configuration.md) for rationale.

### Stored Procedures

| Procedure | Source | Notes |
|---|---|---|
| `BOOTSTRAP(bronze_schema)` | New | One-call setup + discovery |
| `VALIDATE_MODEL(model_name)` | New | Tests active model, updates MODEL_CONFIG |
| `DISCOVER_SCHEMA(table_fqn)` | Adapted from ADF | Returns column metadata for a table via INFORMATION_SCHEMA |
| `WORKFLOW_PLANNER(execution_id)` | Reuse `07c` | Parameterized |
| `WORKFLOW_EXECUTOR(execution_id)` | Reuse `07d` | Parameterized |
| `WORKFLOW_VALIDATOR(execution_id)` | Reuse `07e` | Parameterized |
| `WORKFLOW_REFLECTOR(execution_id)` | Reuse `07f` | Parameterized |
| `RUN_AGENTIC_WORKFLOW(trigger)` | Adapted `07g` | Chains all 4 phases |
| `GOLD_AGENTIC_EXECUTOR(ddl)` | Reuse `17` | Parameterized |
| `BUILD_GOLD_FOR_NEW_TABLES()` | Reuse `18` | Parameterized |
| `EXPORT_DCM_PROJECT(output_stage)` | New | Generates DCM DEFINE files |

---

## Streamlit — Tab Structure

### Tab 1: Setup
- Input: Target Database, Bronze Schema (dropdowns from INFORMATION_SCHEMA)
- Runs `BOOTSTRAP()` — deploys AGENT_FRAMEWORK schema + all SPs
- Shows discovered Bronze tables with row counts and column counts
- Displays current active model (from MODEL_CONFIG) + "Re-validate Model" button
- Status indicators: Registry ✓ | Contracts ✓ | Directives ✓ | Model ✓
- *SA demo starting point — run this live in front of the customer*

### Tab 2: Schema Contracts
- Editable table of structural rules (seeded with sensible defaults on bootstrap)
- Rules: CDC column naming, timestamp conventions, NULL handling preference, dedup key patterns
- "Apply to all Silver targets" button
- *Before the LLM plans anything, it knows the rules it must follow*

### Tab 3: Directives
- Table of active directives with CRUD UI
- Pre-seeded from bootstrap: `ddl_validation`, `null_handling`, `type_casting`
- SA/customer adds per-table directives (e.g., "for ORDERS, deduplicate on order_id + updated_at")
- Priority ordering + active/inactive toggle per directive
- *The human-in-the-middle control layer*

### Tab 4: Agentic Workflow
- Multi-select Bronze tables to transform (defaults to all with no Silver coverage)
- "Run Workflow" button → `RUN_AGENTIC_WORKFLOW('manual')`
- Live phase progress: PLANNER → EXECUTOR → VALIDATOR → REFLECTOR with status badges
- Expandable per-table detail: LLM plan, generated SQL, validation result, learnings written
- Run history table (from WORKFLOW_EXECUTIONS)
- *The demo centerpiece*

### Tab 5: Gold Builder
- Shows Silver tables with no Gold coverage (from TABLE_LINEAGE_MAP gaps)
- "Propose Gold DDLs" → `BUILD_GOLD_FOR_NEW_TABLES(dry_run=TRUE)`
- Review panel: SA reviews each proposed DDL before execution
- Two execution paths:
  - **Execute directly** — `GOLD_AGENTIC_EXECUTOR(ddl)` for dev/exploration
  - **Export as DCM Project** → `EXPORT_DCM_PROJECT(stage)` for production handoff
- *Review gate prevents hallucinated DDL from reaching production*

### Tab 6: Registry
- Two sub-sections: Lineage Map (TABLE_LINEAGE_MAP) and Learnings (WORKFLOW_LEARNINGS)
- Learnings show: observation, recommendation, confidence, times applied
- "Clear low-confidence learnings" button (< 0.6 confidence threshold)
- *System getting smarter — SA talking point*

---

## Repo Structure

```
agentic-transformation-skill/
├── README.md                           # Overview + quick start
├── docs/
│   ├── architecture.md                 # This file
│   ├── talk_track.md                   # SA delivery guide + demo script
│   └── decisions/
│       ├── 001-model-configuration.md  # ADR: model config pattern
│       └── 002-dcm-integration.md      # ADR: DCM as exit ramp
├── setup/
│   ├── 00_bootstrap.sql                # Schema + MODEL_CONFIG + BOOTSTRAP SP
│   ├── 01_transformation_registry.sql  # Lineage + learning tables
│   ├── 02_schema_contracts.sql         # Contract tables + defaults
│   ├── 03_directives.sql               # Directive tables + seed
│   ├── 04_workflow_engine.sql          # Planner/Executor/Validator/Reflector
│   ├── 05_gold_builder.sql             # Gold executor + DCM export SP
│   └── deploy.sh                       # Parameterized deploy script
├── app/
│   ├── streamlit_app.py                # 6-tab Streamlit app
│   └── environment.yml                 # Conda deps
└── dcm/
    ├── manifest.yml.j2                 # DCM project manifest template
    └── templates/
        ├── gold_table.sql.j2           # DEFINE TABLE template
        └── access.sql.j2               # GRANT template
```

---

## Setup / Deployment

```bash
./setup/deploy.sh --connection CUSTOMER_CONN --database CUSTOMER_DB --bronze-schema RAW
```

Or via Snowsight — run `00_bootstrap.sql` with `TARGET_DB` and `BRONZE_SCHEMA` set.

Bootstrap sequence:
1. Creates `<TARGET_DB>.AGENT_FRAMEWORK` schema
2. Deploys `MODEL_CONFIG` table, auto-discovers + validates available Cortex model
3. Deploys all SPs
4. Discovers Bronze tables, populates `TABLE_LINEAGE_MAP` with Bronze entries
5. Seeds default Schema Contracts
6. Seeds default Transformation Directives
7. Reports setup summary

---

## What's Reused vs New

| Component | From ADF | Action |
|---|---|---|
| Planner SP | `07c_planner.sql` | Parameterize hardcoded DB refs; read model from MODEL_CONFIG |
| Executor SP | `07d_executor.sql` | Same |
| Validator SP | `07e_executor.sql` | Same |
| Reflector SP | `07f_reflector.sql` | Same |
| Orchestrator SP | `07g_orchestrator.sql` | Remove Openflow trigger logic |
| Directives tables | `13_transformation_directives.sql` | Add better seed data |
| TABLE_LINEAGE_MAP | `15_table_lineage_map.sql` | Reuse as-is |
| Gold executor | `17_gold_agentic_executor.sql` | Parameterize |
| Gold builder | `18_build_gold_for_new_tables.sql` | Parameterize |
| Streamlit UI | `streamlit_app.py` | Full rebuild — new tab structure |
| Bootstrap SP | — | New |
| VALIDATE_MODEL SP | — | New |
| Schema Contracts | Partial from ADF | Rebuild with editable Streamlit UI |
| EXPORT_DCM_PROJECT SP | — | New |
| DCM templates | — | New |
| talk_track.md | ADF talk track | New, scoped to this skill |
