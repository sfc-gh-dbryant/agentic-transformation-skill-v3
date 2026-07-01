---
name: agentic-transformation-skill-v4
description: "Deploy and operate the Agentic Transformation Skill v4 — a Cortex Agents-based data engineering framework on Snowflake. Use when: building a Silver layer from raw/Bronze tables using Cortex Agents, deploying the 6-agent pipeline (Schema Analyst, Planner, Executor, Validator, Reflector, Orchestrator), managing ATS_TOOL_* stored procedure tools, running multi-agent agentic workflows, setting schema contracts, transformation directives, partner routing, or handing off a Cortex Agents-powered transformation framework to a customer. Triggers: agentic transformation skill v4, ATS v4, cortex agents pipeline, agent-based transformation, ATS_SCHEMA_ANALYST_AGENT, ATS_PLANNER_AGENT, ATS_EXECUTOR_AGENT, ATS_VALIDATOR_AGENT, ATS_REFLECTOR_AGENT, ATS_ORCHESTRATOR_AGENT, ATS_TOOL, agent tools, multi-agent, agentic data foundry v4, silver layer, gold layer, bronze to silver, transformation pipeline, schema contracts, transformation directives, partner routing, cortex search, semantic view, data foundry."
---

# Agentic Transformation Skill v4

A Snowflake-native SA delivery accelerator powered by **Cortex Agents**. Deploys
an AGENT_FRAMEWORK schema with 6 Cortex Agents + 35 ATS_TOOL_* stored procedures
into any Snowflake database. Provides a 15-tab Streamlit app (container runtime)
for full pipeline management plus direct Agent Hub chat interface.

## v4 vs v3

| Capability | v3 | v4 |
|---|---|---|
| Execution engine | SQL Scripting SPs | Cortex Agents |
| LLM calls | Direct CORTEX.COMPLETE | Agent tool calls |
| Agent count | 0 | 6 named agents |
| Tool SPs | 0 | 35 ATS_TOOL_* SPs |
| Cost attribution | No | Yes (CAPTURE_WORKFLOW_COST) |
| Streamlit runtime | Warehouse | Container (SPCS) |
| Multi-agent | No | Optional (v4_multi_agent.sql) |

## Tab Reference

| # | Tab | Purpose |
|---|-----|---------|
| 1 | ⚙️ Setup | Bootstrap, model management, Reset Framework |
| 2 | 🏠 Agent Hub | View and chat with all 6 Cortex Agents |
| 3 | 🎯 Orchestrate | Run full pipeline via ATS_ORCHESTRATOR_AGENT |
| 4 | 💬 Agent Chat | Direct chat with any individual agent |
| 5 | 🔧 Tool Inspector | Browse and test ATS_TOOL_* SPs |
| 6 | 💡 Context | Pipeline Context (business desc, domain, goals, constraints) |
| 7 | 📐 Contracts | Schema Contracts — structural rules |
| 8 | 🎯 Directives | Transformation Directives — per-table intent |
| 9 | 🤖 Workflow | Run agentic workflow (SP-based fallback path) |
| 10 | 🏆 Analytics Builder | Propose and execute Gold DDLs |
| 11 | 🗂️ Registry | Pipeline lineage and FK relationships |
| 12 | 📊 Observe | Execution history, cost attribution, learnings |
| 13 | 🏷️ Partner Routing | Banner config and multi-banner validation |
| 14 | 📦 DCM Export | Generate and download DCM project files |
| 15 | 📄 Documents | Upload PDFs/text docs to enrich agent context |

## Architecture

```
ATS_ORCHESTRATOR_AGENT
    ├── ATS_SCHEMA_ANALYST_AGENT  → ATS_TOOL_DISCOVER_SCHEMA, ATS_TOOL_GET_FK_RELATIONSHIPS
    ├── ATS_PLANNER_AGENT         → ATS_TOOL_GET_CONTRACTS, ATS_TOOL_GET_DIRECTIVES,
    │                               ATS_TOOL_SEARCH_KNOWLEDGE, ATS_TOOL_GET_PIPELINE_CONTEXT
    ├── ATS_EXECUTOR_AGENT        → ATS_TOOL_GET_COLUMN_LIST, ATS_TOOL_EXECUTE_DDL,
    │                               ATS_TOOL_LOG_EXECUTION
    ├── ATS_VALIDATOR_AGENT       → ATS_TOOL_COUNT_ROWS, ATS_TOOL_CHECK_SCHEMA,
    │                               ATS_TOOL_LOG_VALIDATION
    └── ATS_REFLECTOR_AGENT       → ATS_TOOL_GET_WORKFLOW_LOG, ATS_TOOL_SAVE_LEARNING
```

## Package Location

```
agentic-transformation-skill-v3/   (repo — v4 branch)
├── SKILL.md
├── sync_skill.sh                  <- run after any change
├── setup/
│   ├── 00_bootstrap.sql … 12_document_ingestion.sql  <- v3 foundation (required)
│   ├── v4_tools.sql               <- 35 ATS_TOOL_* SPs
│   ├── v4_agents.sql              <- 6 Cortex Agents
│   ├── v4_multi_agent.sql         <- optional, deploy separately
│   ├── 08_cost_attribution.sql    <- CAPTURE_WORKFLOW_COST SP
│   └── deploy.sh                  <- deploys 00-12 + v4_tools + v4_agents
├── app/
│   ├── streamlit_app_v4.py        <- container runtime app
│   ├── requirements.txt
│   └── snowflake.yml              <- SPCS compute pool config
└── docs/
    ├── v4_architecture.md
    ├── v4_design_reference.md
    └── v3_to_v4_shift.md
```

## Prerequisites

1. **v3 foundation deployed first** — `deploy.sh` handles this automatically
2. **SPCS compute pool** `ATS_STREAMLIT_POOL` must exist for the v4 Streamlit
3. **Cortex Agents enabled** on the account
4. User has `CREATE AGENT`, `INVOKE AGENT`, `CREATE PROCEDURE` on target database
5. For `v4_multi_agent.sql`: External Access Integration + PAT secret required

```sql
-- Quick privilege check
SELECT CURRENT_ROLE(), CURRENT_DATABASE(), CURRENT_WAREHOUSE();
SHOW GRANTS TO ROLE IDENTIFIER(CURRENT_ROLE());
```

---

## Workflow 1: Deploy

```bash
./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   ATS_V4 \
  --bronze-schema ATS_V3_TEST.BRONZE \
  --warehouse  YOUR_WAREHOUSE
```

deploy.sh runs in order:
1. Scripts `00`–`12` (v3 foundation — all SPs, tables, views, stages)
2. `08_cost_attribution.sql` (CAPTURE_WORKFLOW_COST SP)
3. `v4_tools.sql` (35 ATS_TOOL_* SPs)
4. `v4_agents.sql` (6 Cortex Agents)
5. `BOOTSTRAP(bronze_schema)` (model validation + table discovery)

Then deploy the Streamlit app:

```bash
cd app && snow streamlit deploy -c YOUR_CONNECTION --replace
```

### Verify Deploy

```sql
SHOW AGENTS IN SCHEMA ATS_V4.AGENT_FRAMEWORK;
SELECT procedure_name FROM ATS_V4.INFORMATION_SCHEMA.PROCEDURES
WHERE procedure_schema = 'AGENT_FRAMEWORK' AND procedure_name LIKE 'ATS_TOOL%'
ORDER BY 1;
SELECT * FROM ATS_V4.AGENT_FRAMEWORK.MODEL_CONFIG;
```

---

## Workflow 2: Run Pipeline via Orchestrator Agent

### Via Streamlit (Tab 3 — Orchestrate)

1. Set Pipeline Context in **Tab 6**
2. Upload business rule docs in **Tab 15**
3. Set Contracts (Tab 7) and Directives (Tab 8)
4. Go to **Tab 3 → Orchestrate**
5. Click **Run Full Pipeline** — the Orchestrator delegates to all 5 agents

### Via SQL

```sql
USE DATABASE ATS_V4;

-- Run full pipeline via Orchestrator Agent
SELECT SNOWFLAKE.CORTEX.COMPLETE_AGENT(
    'AGENT_FRAMEWORK.ATS_ORCHESTRATOR_AGENT',
    'Run the full agentic transformation pipeline for all Bronze tables in ATS_V3_TEST.BRONZE.
     Output Silver to ATS_V3_TEST.SILVER. dry_run=FALSE.'
);
```

### Via SP fallback (same as v3)

```sql
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW('manual', NULL, 'MANUAL');
```

---

## Workflow 3: Direct Agent Chat (Tab 4)

Chat with any individual agent for targeted operations:

```
ATS_SCHEMA_ANALYST_AGENT:
  "Discover FK relationships in ATS_V3_TEST.BRONZE and summarize confidence tiers"

ATS_PLANNER_AGENT:
  "Plan transformations for DASHMART_PRODUCTS — it has high duplicate rate and multi-banner data"

ATS_EXECUTOR_AGENT:
  "Build Silver for MARKETBASKET_PRODUCTS excluding IS_DELETED rows"

ATS_VALIDATOR_AGENT:
  "Validate Silver coverage vs Bronze for execution_id <id>"

ATS_REFLECTOR_AGENT:
  "Summarize learnings from the last 5 workflow runs"
```

---

## Workflow 4: Tool Inspector (Tab 5)

Browse all 35 `ATS_TOOL_*` SPs, view signatures, and test individual tools:

```sql
-- List all tools
SELECT procedure_name, argument_signature
FROM ATS_V4.INFORMATION_SCHEMA.PROCEDURES
WHERE procedure_schema = 'AGENT_FRAMEWORK' AND procedure_name LIKE 'ATS_TOOL%'
ORDER BY procedure_name;
```

---

## Workflow 5: Cost Attribution (Tab 12 — Observe)

After each completed run:

```sql
CALL AGENT_FRAMEWORK.CAPTURE_WORKFLOW_COST('YOUR_EXECUTION_ID');
```

View in Tab 12 → Observe → Cost tab. Shows credits consumed per phase.

---

## Workflows 6–10

Same as v3: Contracts & Directives, Analytics Builder, DCM Export, Brownfield Mode, Document Ingestion.
See v3 SKILL.md for full workflow details — all v3 capabilities are available in v4.

---

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| `AGENT_FRAMEWORK.ATS_*_AGENT not found` | v4_agents.sql not deployed | Run `deploy.sh` again |
| Agent returns generic response | No Pipeline Context set | Set context via Tab 6 |
| Streamlit won't start | SPCS compute pool not running | `ALTER COMPUTE POOL ATS_STREAMLIT_POOL RESUME` |
| Tool call fails | ATS_TOOL_* SP error | Check Tab 5 Tool Inspector for SP signature |
| v4_multi_agent.sql errors | Missing External Access Integration | Deploy EAI separately per file header instructions |
| Same errors as v3 | v3 foundation bug | Check v3 SKILL.md troubleshooting section |
