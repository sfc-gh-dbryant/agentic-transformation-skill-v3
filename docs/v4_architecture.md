# ATS v4 — Cortex Agents Architecture Proposal

**Status:** Design  
**Date:** June 2026  
**Author:** Danny Bryant  
**Context:** Based on v3 testing session — natural evolution from stored procedure pipeline to agent-based pipeline

---

## Problem with v3 Architecture

v3 is a pipeline of stored procedures. Each phase makes **one LLM call**, gets a response, and moves on. There is no ability to:

- Reason between steps within a phase
- Use tools dynamically based on what the LLM discovers
- Recover intelligently from bad output (v3 retries blindly 3 times)
- Run phases in parallel
- Ask a follow-up question before committing to an action

The result is that the Executor hallucinates columns because it can't check `INFORMATION_SCHEMA` mid-generation. The Planner can't confirm its FK assumptions by sampling data. The Reflector saves duplicate learnings because it can't check what already exists before writing.

---

## v4 Design: Five Agents + One Orchestrator

Each v3 stored procedure phase becomes a **Cortex Agent** with its own tool set. The agent can make multiple LLM calls, invoke tools between them, and reason about results before concluding.

```
┌─────────────────────────────────────────────────────────────┐
│                    ORCHESTRATOR AGENT                       │
│  Coordinates phases, manages approval gate, handles errors  │
└──────┬──────────┬──────────┬──────────┬──────────┬──────────┘
       │          │          │          │          │
       ▼          ▼          ▼          ▼          ▼
  SCHEMA      PLANNER    EXECUTOR   VALIDATOR  REFLECTOR
  ANALYST     AGENT      AGENT      AGENT      AGENT
  AGENT
```

---

## Agent Definitions

### 1. Schema Analyst Agent

**Purpose:** Discover FK and entity-reference relationships across all tables in scope.

**Tools:**
| Tool | What it does |
|------|-------------|
| `discover_schema(fqn)` | Returns columns + types for a fully-qualified table from INFORMATION_SCHEMA |
| `sample_data(fqn, n)` | Returns N sample rows — lets the agent confirm relationships by checking actual values |
| `search_prior_relationships(query)` | Queries ATS_KNOWLEDGE_SEARCH for previously discovered relationships on similar tables |
| `list_tables_in_schema(db, schema)` | Returns all tables in a schema — useful for discovering lookup/dimension tables |

**What it gains over v3:**  
v3 makes one LLM call with all schemas concatenated. The agent can iteratively confirm: "I think PROVINCE in RENSPETS_PRODUCTS references a PROVINCES table — let me check if that table exists, then sample both columns to confirm before declaring a FK."

---

### 2. Planner Agent

**Purpose:** Decide transformation strategy, primary key columns, and output DDL intent for each table.

**Tools:**
| Tool | What it does |
|------|-------------|
| `get_pipeline_context()` | Returns business description, domain, goals, constraints |
| `get_contracts(layer)` | Returns active Schema Contracts for SILVER or GOLD |
| `get_directives(table_pattern)` | Returns matching Transformation Directives for a table |
| `get_schema_relationships(execution_id)` | Returns approved FK relationships from Schema Analyst |
| `search_prior_decisions(query)` | Queries ATS_KNOWLEDGE_SEARCH for prior Planner decisions on similar tables |
| `get_existing_gold_schemas()` | Returns existing Gold table definitions for gap analysis (B-06) |

**What it gains over v3:**  
The Planner can reason: "Search says we tried deduplicate on this table last time and it failed due to NULL primary keys — let me adjust the strategy to use a composite key instead." Multiple LLM calls within one planning phase.

---

### 3. Executor Agent

**Purpose:** Generate and execute the Silver-layer DDL for each table.

**Tools:**
| Tool | What it does |
|------|-------------|
| `get_columns(fqn)` | Returns exact column list from INFORMATION_SCHEMA before generating DDL |
| `execute_sql(ddl)` | Executes DDL against the output schema, returns success/error |
| `validate_column_exists(table, column)` | Checks a specific column exists before referencing it |
| `check_table_exists(fqn)` | Checks if target table already has rows (overwrite protection) |
| `get_sample_rows(fqn, n)` | Samples source data to understand actual values before transformation |

**What it gains over v3:**  
Today the Executor hallucinates column names because column injection happens once in the prompt. With tools, the agent calls `get_columns()` before writing any DDL, then `validate_column_exists()` for each column it plans to reference. Retry means: "The column INGEST_DATE doesn't exist — let me call get_columns() again and regenerate with only columns that actually exist." Zero hallucination with tool-grounded generation.

---

### 4. Validator Agent

**Purpose:** Verify the generated Silver table meets quality expectations.

**Tools:**
| Tool | What it does |
|------|-------------|
| `count_rows(fqn)` | Returns row count for source and target comparison |
| `check_pk_uniqueness(fqn, pk_cols)` | Returns duplicate count on specified PK columns |
| `compare_counts(source, target)` | Returns variance between source and target row counts |
| `query_sample(fqn, where_clause)` | Samples rows matching a condition — useful for investigating failures |
| `get_planner_decision(table)` | Retrieves the Planner's strategy and PK columns for this table |

**What it gains over v3:**  
v3 Validator inferred the PK column from schema. The agent calls `get_planner_decision()` to get the authoritative PK from the Planner, then calls `check_pk_uniqueness()` with the correct column. If variance is unexpected, it can call `query_sample()` to investigate why before logging FAIL.

---

### 5. Reflector Agent

**Purpose:** Extract learnings from the run and merge them into the knowledge base.

**Tools:**
| Tool | What it does |
|------|-------------|
| `search_similar_learnings(query)` | Searches ATS_KNOWLEDGE_SEARCH before saving — avoids duplicates |
| `save_learning(observation, recommendation, confidence)` | Merges a new learning into WORKFLOW_LEARNINGS |
| `get_workflow_log(execution_id)` | Returns all ABORTED, FAILED, and PASS entries for this run |
| `get_executor_output(execution_id)` | Returns DDL generated and success/failure status per table |

**What it gains over v3:**  
v3 Reflector saves learnings without checking for duplicates. The agent calls `search_similar_learnings()` first — if a learning already exists with high confidence, it increments `times_observed` instead of creating a duplicate. Higher knowledge base quality over time.

---

### 6. Orchestrator Agent

**Purpose:** Coordinate the five agents in sequence, manage the approval gate, handle failures, and surface results to the Streamlit UI.

**Tools:**
| Tool | What it does |
|------|-------------|
| `call_agent(agent_name, params)` | Invokes a sub-agent and returns its result |
| `get_workflow_status(execution_id)` | Returns current phase and status |
| `update_workflow_status(execution_id, phase, status)` | Writes phase transitions to WORKFLOW_EXECUTIONS |
| `notify_approval_gate(execution_id, relationships)` | Pauses execution and surfaces Schema Analyst results for human review |
| `log_workflow_event(execution_id, phase, message)` | Writes to WORKFLOW_LOG |

---

## What This Unlocks

| Capability | v3 | v4 |
|-----------|----|----|
| Column hallucination | Mitigated by pre-injecting column list | Eliminated — agent validates before generating |
| Retry logic | 3 blind retries | Reasoned retry with tool-grounded diagnosis |
| FK confirmation | LLM guesses from column names | Agent samples actual data to confirm |
| Duplicate learnings | Can occur | Agent deduplicates before saving |
| Parallel execution | Sequential only | Orchestrator can run Schema Analyst on all tables in parallel |
| Gold awareness | None | Planner agent calls `get_existing_gold_schemas()` before planning |
| Document ingestion (B-01) | Not implemented | Reflector or Planner agent calls `parse_document()` tool |
| Mid-phase reasoning | Single LLM call per phase | Multiple calls, tool-informed decisions |

---

## Infrastructure Already in Place (from v3)

These v3 components become the tool backends for v4 agents with no changes:

| v3 Component | v4 Role |
|-------------|---------|
| `ATS_KNOWLEDGE_SEARCH` (Cortex Search) | Tool backend for `search_prior_decisions()`, `search_similar_learnings()`, `search_prior_relationships()` |
| `ATS_PIPELINE_SEMANTICS` (Semantic View) | Tool backend for natural language queries about pipeline state |
| `AGENT_FRAMEWORK.DISCOVER_SCHEMA` SP | Tool backend for `discover_schema()` |
| `AGENT_FRAMEWORK.WORKFLOW_LOG` | Tool backend for `get_workflow_log()` |
| `AGENT_FRAMEWORK.SCHEMA_CONTRACTS` | Tool backend for `get_contracts()` |
| `AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES` | Tool backend for `get_directives()` |

The v3 → v4 migration is primarily **wrapping existing SPs as Cortex Agent tools** and replacing single-call LLM prompts with agent reasoning loops. The data model, Streamlit app, and knowledge base are unchanged.

---

## Deployment Model

Each agent is defined as a **Cortex Agent** in Snowflake:

```sql
CREATE AGENT AGENT_FRAMEWORK.ATS_EXECUTOR_AGENT
    MODEL = 'llama3.3-70b'
    TOOLS = (
        ATS_GET_COLUMNS_TOOL,
        ATS_EXECUTE_SQL_TOOL,
        ATS_VALIDATE_COLUMN_TOOL,
        ATS_CHECK_TABLE_EXISTS_TOOL,
        ATS_GET_SAMPLE_ROWS_TOOL
    )
    SYSTEM_PROMPT = '...';
```

The Orchestrator Agent calls each sub-agent via the Cortex Agents API, passing the execution context as the conversation input.

---

## Migration Path from v3

| Step | Action |
|------|--------|
| 1 | Wrap each SP's core logic as a Cortex Agent tool (Python function + tool definition) |
| 2 | Replace each SP's LLM call with an agent invocation (Orchestrator calls sub-agent) |
| 3 | Retire `WORKFLOW_SCHEMA_ANALYST`, `WORKFLOW_PLANNER`, `WORKFLOW_EXECUTOR`, `WORKFLOW_VALIDATOR`, `WORKFLOW_REFLECTOR` SPs |
| 4 | Keep `WORKFLOW_EXECUTIONS`, `WORKFLOW_LOG`, `TABLE_LINEAGE_MAP` — data model is unchanged |
| 5 | Streamlit app requires minimal changes — phases still emit to WORKFLOW_LOG, same display logic |

v3 and v4 can coexist in the same database during migration. The Orchestrator SP simply routes to either the SP-based or agent-based implementation based on a config flag.

---

## Open Questions for v4 Design

1. **Approval gate UX** — with agents, the Orchestrator can surface the Schema Analyst result via a structured message. How does this integrate with the Streamlit approval gate UI?

2. **Token budget per agent** — each agent now has its own context window. How do we manage cost for large schemas (LCL V2's 39 columns × 14 banners)?

3. **Agent-to-agent communication** — does the Planner agent receive a structured JSON output from the Schema Analyst agent, or a natural language summary?

4. **Parallelism model** — the Orchestrator could run Schema Analyst on all 5 tables simultaneously. Does Snowflake Cortex Agents support parallel agent calls today?
