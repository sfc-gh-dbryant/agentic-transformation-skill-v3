# ATS v4 — Cortex Agents Architecture

**Status:** Implemented and Tested  
**Date:** June 2026  
**Author:** Danny Bryant  
**Database:** `ATS_V4.AGENT_FRAMEWORK`  
**Test Run:** 5/5 Silver tables built, retries=0, 5/5 Validator passes (2026-06-30)

---

## What Changed from v3

v3 is a pipeline of stored procedures — each phase makes one LLM call, executes, and moves on. v4 adds a Cortex Agents layer sitting alongside the SP pipeline, with two key changes:

1. **34 `ATS_TOOL_*` stored procedures** — each tool wraps a specific data operation (schema discovery, contract lookup, DDL execution, decision persistence). These become the callable tools for Cortex Agents.

2. **6 Cortex Agents** — each phase has a corresponding agent that can invoke tools, reason across multiple steps, and use the knowledge base before committing to an action.

The v3 SP pipeline remains the **primary batch execution path**. The Cortex Agents are available as an **interactive/agentic execution path** via the Agent Hub and Orchestrate tabs in the Streamlit app.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        STREAMLIT APP (ATS_V4)                       │
│                                                                     │
│  Pipeline Tab                      Agent Hub / Orchestrate Tab      │
│  ─────────────────                 ─────────────────────────────    │
│  Workflow SP Pipeline              Cortex Agents API                │
│  (batch, reliable)                 (interactive, agentic)           │
└──────────┬──────────────────────────────────┬───────────────────────┘
           │                                  │
           ▼                                  ▼
┌──────────────────────┐           ┌──────────────────────────────────┐
│   SP Pipeline (v3+)  │           │   Cortex Agents Layer (v4)       │
│                      │           │                                  │
│  WORKFLOW_SCHEMA_     │           │  ATS_SCHEMA_ANALYST_AGENT        │
│  ANALYST             │           │  ATS_PLANNER_AGENT               │
│  WORKFLOW_PLANNER    │           │  ATS_EXECUTOR_AGENT              │
│  WORKFLOW_EXECUTOR   │           │  ATS_VALIDATOR_AGENT             │
│  WORKFLOW_VALIDATOR  │           │  ATS_REFLECTOR_AGENT             │
│  WORKFLOW_REFLECTOR  │           │  ATS_ORCHESTRATOR_AGENT          │
└──────────┬───────────┘           └──────────────┬───────────────────┘
           │                                       │
           └───────────────────┬───────────────────┘
                               │ Both paths read/write
                               ▼
           ┌─────────────────────────────────────────┐
           │           Shared Data Layer              │
           │                                         │
           │  WORKFLOW_EXECUTIONS  WORKFLOW_LOG       │
           │  TABLE_LINEAGE_MAP    PLANNER_DECISIONS  │
           │  SCHEMA_RELATIONSHIPS WORKFLOW_LEARNINGS │
           │  SCHEMA_CONTRACTS     TRANSFORMATION_    │
           │  PIPELINE_CONTEXT     DIRECTIVES         │
           │  WORKFLOW_COST_ATTRIBUTION               │
           └─────────────────────────────────────────┘
                               │
                    ┌──────────┴──────────┐
                    ▼                     ▼
           ATS_KNOWLEDGE_SEARCH    ATS_PIPELINE_SEMANTICS
           (Cortex Search)         (Semantic View)
```

---

## The 34 ATS_TOOL_* Stored Procedures

Tools are defined as stored procedures in `AGENT_FRAMEWORK`. Each tool is a Python or SQL SP callable by both the Cortex Agents and directly from the SP pipeline.

| Category | Tool | What it does |
|----------|------|-------------|
| **Schema** | `ATS_TOOL_DISCOVER_SCHEMA` | Returns columns + types for a table from INFORMATION_SCHEMA |
| | `ATS_TOOL_SAMPLE_DATA` | Returns N sample rows from any table |
| | `ATS_TOOL_GET_COLUMNS` | Returns authoritative column list for DDL generation |
| | `ATS_TOOL_LIST_TABLES` | Lists all tables in a schema |
| | `ATS_TOOL_GET_SCHEMA_RELATIONSHIPS` | Returns discovered FK relationships for an execution |
| **Planning** | `ATS_TOOL_GET_PIPELINE_CONTEXT` | Returns business description, domain, goals, constraints |
| | `ATS_TOOL_GET_CONTRACTS` | Returns active Schema Contracts for a layer |
| | `ATS_TOOL_GET_DIRECTIVES` | Returns matching Transformation Directives for a table pattern |
| | `ATS_TOOL_SAVE_PLANNER_DECISION` | Persists a Planner decision to `PLANNER_DECISIONS` |
| | `ATS_TOOL_GET_PLANNER_DECISION` | Retrieves a Planner decision for a specific table |
| **Execution** | `ATS_TOOL_EXECUTE_SQL` | Executes DDL against the output schema |
| | `ATS_TOOL_CHECK_TABLE_EXISTS` | Checks if a target table has rows (overwrite guard) |
| | `ATS_TOOL_VALIDATE_COLUMNS` | Cross-checks a column list against source schema |
| | `ATS_TOOL_QUERY_SAMPLE` | Samples rows with a WHERE clause |
| **Validation** | `ATS_TOOL_COUNT_ROWS` | Returns row count for source and target comparison |
| | `ATS_TOOL_CHECK_PK_UNIQUENESS` | Returns duplicate count on PK columns |
| **Knowledge** | `ATS_TOOL_SEARCH_KNOWLEDGE` | Searches ATS_KNOWLEDGE_SEARCH (Cortex Search) |
| | `ATS_TOOL_SAVE_LEARNING` | Merges a learning into `WORKFLOW_LEARNINGS` |
| | `ATS_TOOL_GET_WORKFLOW_LOG` | Returns log entries for an execution |
| | `ATS_TOOL_GET_EXECUTOR_OUTPUT` | Returns DDL and success status per table |

---

## The 6 Cortex Agents

Each agent is defined using `CREATE AGENT` in Snowflake. Agents use `llama3.3-70b` and are scoped to `ATS_V4.AGENT_FRAMEWORK`.

### 1. ATS_SCHEMA_ANALYST_AGENT

**Purpose:** Discover entity relationships across all Bronze tables before planning begins.

**Key tools:** `DISCOVER_SCHEMA`, `SAMPLE_DATA`, `LIST_TABLES`, `SEARCH_KNOWLEDGE`

**What it does that the SP can't:** Iteratively confirms FK hypotheses by sampling actual column values. Rather than declaring "PROVINCE in RENSPETS looks like a FK", it samples both columns and verifies overlap before recording the relationship. Confidence scores reflect actual evidence, not LLM guesswork.

**Output:** `SCHEMA_RELATIONSHIPS` table — relationship type, source/target table+column, confidence score, LLM reasoning.

---

### 2. ATS_PLANNER_AGENT

**Purpose:** Decide transformation strategy and primary key columns for each table.

**Key tools:** `GET_PIPELINE_CONTEXT`, `GET_CONTRACTS`, `GET_DIRECTIVES`, `GET_SCHEMA_RELATIONSHIPS`, `SEARCH_KNOWLEDGE`, `SAVE_PLANNER_DECISION`

**What it does that the SP can't:** Looks up prior decisions for similar tables before planning, adapts strategy based on FK relationships discovered by Schema Analyst, and validates its PK selection against actual data before committing.

**Output:** `PLANNER_DECISIONS` table — strategy, PK columns, recommended actions, LLM reasoning, confidence score.

---

### 3. ATS_EXECUTOR_AGENT

**Purpose:** Generate and execute Silver-layer DDL for each table with zero column hallucination.

**Key tools:** `GET_COLUMNS`, `GET_PLANNER_DECISION`, `GET_DIRECTIVES`, `GET_CONTRACTS`, `VALIDATE_COLUMNS`, `EXECUTE_SQL`

**Key guardrails implemented:**
- `ATS_TOOL_GET_COLUMNS` called before any DDL generation — agent only knows columns that exist
- Pre-execution `SELECT INTO` guard catches hallucinated column names before hitting Snowflake
- `CONFLICT_REDIRECTED` and `EFFECTIVE_TARGET_FQN` are internal variables — blocked from appearing in generated DDL
- 3-attempt self-correcting loop: if DDL fails, the error is fed back to the agent with the authoritative column list

**Result from testing:** 5/5 tables built, **retries=0** on clean run after guardrails deployed.

---

### 4. ATS_VALIDATOR_AGENT

**Purpose:** Verify each Silver table meets quality expectations against its Bronze source.

**Key tools:** `COUNT_ROWS`, `CHECK_PK_UNIQUENESS`, `QUERY_SAMPLE`, `GET_PLANNER_DECISION`

**Key fixes vs original design:**
- Reads `output_schema` from `PIPELINE_CONTEXT` to construct fully qualified Silver table references (cross-database)
- Uses `EXECUTE IMMEDIATE` for cross-database `INFORMATION_SCHEMA` lookups (SCD2 detection)
- Validates against actual Planner PK columns, not schema-inferred columns

**Validation checks per table:**
1. Row count comparison (Bronze vs Silver) — variance tolerance: 1%
2. SCD2 detection via `IS_CURRENT` column existence
3. PK uniqueness check using Planner-specified key columns

---

### 5. ATS_REFLECTOR_AGENT

**Purpose:** Extract learnings from the run and merge them into the persistent knowledge base.

**Key tools:** `GET_WORKFLOW_LOG`, `GET_EXECUTOR_OUTPUT`, `SEARCH_KNOWLEDGE`, `SAVE_LEARNING`

**Deduplication:** Agent calls `SEARCH_KNOWLEDGE` before saving — if a similar learning exists with high confidence, it increments `times_observed` rather than creating a duplicate.

**Learning types captured:**
- Type casting patterns (e.g., which columns need `TIMESTAMP_NTZ`)
- Dedup key selection patterns (e.g., prefer `_KEY` suffix over timestamp columns)
- Table-specific anomalies (e.g., SCD2 pattern detected in specific tables)

---

### 6. ATS_ORCHESTRATOR_AGENT

**Purpose:** Coordinate the five agents in sequence, manage the Schema Analyst approval gate, and surface results to the Streamlit UI.

**Key tools:** All phase tools + `GET_WORKFLOW_STATUS`, `UPDATE_WORKFLOW_STATUS`, `LOG_WORKFLOW_EVENT`

**Approval gate:** After Schema Analyst completes, the Orchestrator pauses and surfaces the discovered relationships for human review. Low/medium confidence relationships are highlighted. The user approves or rejects before Planner proceeds.

---

## What v4 Resolved vs v4 Design Goals

| Design Goal | Status | Notes |
|-------------|--------|-------|
| Column hallucination eliminated | ✅ | GET_COLUMNS tool + pre-exec guard → retries=0 |
| Tool-grounded FK confirmation | ✅ | Schema Analyst samples data before recording relationships |
| Knowledge base deduplication | ✅ | Reflector searches before saving |
| Approval gate UX | ✅ | Pause after Schema Analyst, review table in Streamlit |
| Cost attribution | ✅ | `CAPTURE_WORKFLOW_COST` SP + Observe tab cost section |
| Cross-database output support | ✅ | Validator reads output_db from PIPELINE_CONTEXT |
| Parallel execution | ❌ | Still sequential — Cortex Agents parallel calling not in scope |
| Gold awareness in Planner | 🔶 | Tool defined, not yet wired into default Planner prompt |

---

## Deployment

**Database:** `ATS_V4` | **Schema:** `AGENT_FRAMEWORK`  
**Model:** `llama3.3-70b` (all agents)  
**Warehouse:** `COMPUTE_WH` (Streamlit), `DBRYANT_COCO_WH_S` (testing)

**Setup files (in order):**
```
00_bootstrap.sql              — Schema, warehouse, model config
01_transformation_registry.sql — WORKFLOW_EXECUTIONS, TABLE_LINEAGE_MAP, WORKFLOW_LOG
02_schema_contracts.sql       — SCHEMA_CONTRACTS table + seed data
03_directives.sql             — TRANSFORMATION_DIRECTIVES table + seed data
04a_discover_schema.sql       — WORKFLOW_SCHEMA_ANALYST SP
04b_planner.sql               — WORKFLOW_PLANNER SP
04c_executor.sql              — WORKFLOW_EXECUTOR SP (with guardrails)
04d_validator.sql             — WORKFLOW_VALIDATOR SP (cross-database aware)
04e_reflector.sql             — WORKFLOW_REFLECTOR SP
04f_orchestrator.sql          — WORKFLOW_ORCHESTRATOR SP
05_gold_builder.sql           — WORKFLOW_GOLD_BUILDER SP
07_pipeline_context.sql       — PIPELINE_CONTEXT table
08_cost_attribution.sql       — WORKFLOW_COST_ATTRIBUTION table + CAPTURE_WORKFLOW_COST SP
v4_tools.sql                  — All 34 ATS_TOOL_* stored procedures
v4_agents.sql                 — All 6 Cortex Agent definitions
10_cortex_search.sql          — ATS_KNOWLEDGE_SEARCH Cortex Search service
11_semantic_view.sql          — ATS_PIPELINE_SEMANTICS semantic view
```

**Deploy command:**
```bash
./setup/deploy.sh --connection CoCo-Green --database ATS_V4 --bronze-schema BRONZE
```

---

## Known Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| `snow sql -f` fails on `$$` blocks with `\|\|` inside | Cannot deploy SQL Scripting SPs via CLI | Use Python connector with explicit key auth |
| `CORTEX_FUNCTIONS_USAGE_HISTORY` has 45-min delay | Cost attribution shows 0 Cortex credits immediately after run | Re-capture costs 45 min after run completes |
| Cortex Agent parallel calls not implemented | Pipeline still sequential | Acceptable for current scale |
| `CONFLICT_REDIRECTED` hallucination (mitigated) | First attempt generates invalid column name | Pre-execution `SELECT INTO` guard catches and blocks before execute |
