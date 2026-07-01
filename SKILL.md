---
name: agentic-transformation-skill
description: "Deploy and operate an Agentic Data Foundry on Snowflake. Use when: building a Silver layer from raw/Bronze tables, building Gold analytical tables, deploying agentic SQL pipelines, setting up schema contracts, transformation directives, running Planner/Executor/Validator/Reflector workflows, or handing off a data transformation framework to a customer. Triggers: agentic data foundry, silver layer, gold layer, bronze to silver, transformation pipeline, schema contracts, transformation directives, agentic workflow, model config, deploy transformation skill, data foundry."
---

# Agentic Transformation Skill (v3)

A Snowflake-native SA delivery accelerator. Deploys an AGENT_FRAMEWORK schema
into any Snowflake database and gives the SA (or customer) an 11-tab Streamlit
app to drive Schema Analyst → Planner → Executor → Validator → Reflector
Silver/Gold pipeline with zero hardcoded model names, brownfield support,
document-enriched context, Cortex Search knowledge base, and a DCM production handoff.

## Tab Reference

| # | Tab | Purpose |
|---|-----|---------|
| 1 | ⚙️ Setup | Bootstrap, model management, Reset Framework |
| 2 | 💡 Context | Pipeline Context (business desc, domain, goals, constraints, output schema, dry_run, brownfield) |
| 3 | 📄 Documents | Upload PDFs/text docs to enrich agent context **before running the workflow** |
| 4 | 📐 Contracts | Schema Contracts — structural rules |
| 5 | 🎯 Directives | Transformation Directives — per-table intent |
| 6 | 🤖 Workflow | Run agentic workflow, Schema Analyst approval gate |
| 7 | 🏆 Analytics Builder | Propose and execute Gold DDLs |
| 8 | 🗂️ Registry | Pipeline lineage and FK relationships |
| 9 | 📊 Observe | Execution history, learnings, metrics |
| 10 | 🏷️ Partner Routing | Banner config and multi-banner validation |
| 11 | 📦 DCM Export | Generate and download DCM project files |

## Package Location

```
agentic-transformation-skill/
├── SKILL.md
├── setup/
│   ├── SETUP_ALL.sql             <- single-file Snowsight deploy
│   ├── deploy.sh                 <- Snow CLI deploy (scripts 00-12 + BOOTSTRAP)
│   ├── ats_pipeline_semantics.yaml  <- semantic model for Cortex Analyst
│   ├── 00_bootstrap.sql
│   ├── 01_transformation_registry.sql
│   ├── 02_schema_contracts.sql
│   ├── 03_directives.sql
│   ├── 04a_discover_schema.sql
│   ├── 04b_planner.sql           <- dynamic batching + schema-hash cache
│   ├── 04c_executor.sql          <- CTAS/Dynamic Table, dry_run, output_schema
│   ├── 04d_validator.sql         <- cross-db INFORMATION_SCHEMA via EXECUTE IMMEDIATE
│   ├── 04e_reflector.sql
│   ├── 04f_orchestrator.sql
│   ├── 05_gold_builder.sql
│   ├── 06_schema_analyst.sql
│   ├── 07_pipeline_context.sql   <- 10-param SET_PIPELINE_CONTEXT
│   ├── 08_dcm_export.sql
│   ├── 09_banner_config.sql      <- multi-banner, VALIDATE_MULTI_BANNER
│   ├── 10_cortex_search.sql      <- ATS_KNOWLEDGE_CORPUS + ATS_KNOWLEDGE_SEARCH
│   ├── 11_semantic_view.sql      <- ATS_PIPELINE_SEMANTICS semantic view
│   └── 12_document_ingestion.sql <- PDF/text doc ingest, DOCUMENT_CONTEXT_ITEMS
├── app/
│   ├── streamlit_app.py
│   └── environment.yml
└── docs/
    ├── architecture.md
    └── decisions/
```

## Intent Detection

| Intent | Trigger phrases | Workflow |
|--------|----------------|----------|
| **Intake / Context** | "new customer", "first time", "set context", "describe the business" | [Workflow 0: Intake](#workflow-0-intake--pipeline-context) |
| **Deploy** | "deploy this", "set this up", "install", "clean account" | [Workflow 1: Deploy](#workflow-1-deploy) |
| **Bootstrap** | "run bootstrap", "discover tables", "initialize" | [Workflow 2: Bootstrap](#workflow-2-bootstrap--first-run) |
| **Run workflow** | "run the pipeline", "build silver", "transform tables" | [Workflow 3: Agentic Workflow](#workflow-3-run-the-agentic-workflow) |
| **Gold** | "build gold", "propose gold", "analytical tables" | [Workflow 4: Gold Builder](#workflow-4-gold-builder) |
| **Model** | "switch model", "validate model", "model deprecated" | [Workflow 5: Model Rotation](#workflow-5-model-rotation) |
| **Documents** | "add context doc", "upload PDF", "ingest document", "business rules" | [Workflow 9: Document Ingestion](#workflow-9-document-ingestion) |
| **Contracts/Directives** | "add directive", "edit contracts", "schema rules" | [Workflow 6: Contracts & Directives](#workflow-6-contracts--directives) |
| **Brownfield** | "existing Silver tables", "brownfield", "don't overwrite" | [Workflow 8: Brownfield Mode](#workflow-8-brownfield-mode) |
| **DCM export** | "export to dcm", "production handoff", "dcm project" | [Workflow 7: DCM Export](#workflow-7-dcm-export) |

---

## Prerequisites

Before any workflow, verify:

1. **Bronze tables exist** — this skill does NOT ingest data
2. **Cortex is enabled** on the account
3. User has `CREATE SCHEMA`, `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE STAGE`,
   `CREATE STREAMLIT`, `CREATE CORTEX SEARCH SERVICE` privileges on the target database
4. Snow CLI installed (Option A only) — verify with `snow --version`

```sql
-- Quick privilege check
SELECT CURRENT_ROLE(), CURRENT_DATABASE(), CURRENT_WAREHOUSE();
SHOW GRANTS TO ROLE IDENTIFIER(CURRENT_ROLE());
```

---

## Workflow 0: Intake / Pipeline Context

Run this at the start of **every new customer engagement** before bootstrap.
Context is injected into every Planner, Executor, and Gold Builder LLM call.

Ask the customer these questions conversationally:

```
1. "Describe your business in 2-3 sentences."
   -> p_business_desc

2. "What industry and data type are we working with?"
   -> p_data_domain  (e.g. "Healthcare / Insurance Claims")

3. "What business questions must your analytics layer answer?"
   -> p_gold_goals   (e.g. "Fraud detection, cost-per-encounter, provider KPIs")

4. "Any compliance, privacy, or architectural constraints?"
   -> p_constraints  (e.g. "HIPAA -- no PII in Gold. Full audit trail in Silver.")

5. "Where should Silver tables land? (default: AGENT_FRAMEWORK_OUTPUT schema)"
   -> p_output_schema

6. "Should we run in dry_run mode first? (recommended: yes)"
   -> p_dry_run (TRUE = generate DDL but don't execute)

7. "Are there existing Silver tables we should keep and not overwrite?"
   -> enable brownfield mode (see Workflow 8)
```

Write context to Snowflake:

```sql
USE DATABASE YOUR_DATABASE;
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    'We are a healthcare payer processing insurance claims for 2M members.',  -- p_business_desc
    'Healthcare / Insurance Claims',                                           -- p_data_domain
    'Fraud detection, cost-per-encounter analytics, provider performance KPIs.',-- p_gold_goals
    'HIPAA compliant -- no PII in Gold layer. Full audit trail in Silver.',    -- p_constraints
    'CTAS',                       -- p_pipeline_type: 'CTAS' or 'DYNAMIC_TABLE'
    '1 hour',                     -- p_target_lag: only for DYNAMIC_TABLE
    'YOUR_DATABASE.SILVER',       -- p_output_schema: where Silver tables land
    TRUE,                         -- p_dry_run: TRUE = safe preview mode
    FALSE,                        -- p_overwrite_existing: FALSE = skip existing Silver tables
    'FLAT'                        -- p_gold_output_mode: 'FLAT' or 'NESTED'
);
```

Via Streamlit: **Tab 2 → Context** — fill the form and click **Save Context**.

Verify:

```sql
SELECT AGENT_FRAMEWORK.PIPELINE_CONTEXT_AS_PROMPT();
```

---

## Workflow 1: Deploy

### Option A — Snow CLI (~2 min)

```bash
./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   YOUR_DATABASE  \
  --bronze-schema RAW
```

Cross-database pattern (framework DB ≠ data DB):

```bash
./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   ATS_FRAMEWORK_DB \
  --bronze-schema CUSTOMER_DB.BRONZE
```

Multi-source:

```bash
./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   ATS_FRAMEWORK_DB \
  --bronze-schema "DB1.BRONZE,DB2.RAW"
```

Then deploy the Streamlit app:

```bash
cd app && snow streamlit deploy -c YOUR_CONNECTION \
  --database YOUR_DATABASE \
  --schema AGENT_FRAMEWORK \
  --replace
```

### Option B — Snowsight Only (no CLI)

1. Snowsight → Worksheets → New Worksheet
2. Paste contents of `setup/SETUP_ALL.sql`
3. Edit the two variables at the top:
   ```sql
   SET TARGET_DB     = 'YOUR_DATABASE';
   SET BRONZE_SCHEMA = 'RAW';
   ```
4. Click **Run All**
5. Snowsight → **Streamlit** → **+ Streamlit App**
6. Set Database = YOUR_DATABASE, Schema = AGENT_FRAMEWORK
7. Paste `app/streamlit_app.py` and click **Run**

### Verify Deploy

```sql
SHOW SCHEMAS IN DATABASE YOUR_DATABASE LIKE 'AGENT_FRAMEWORK';
SHOW PROCEDURES IN SCHEMA YOUR_DATABASE.AGENT_FRAMEWORK;
SELECT * FROM YOUR_DATABASE.AGENT_FRAMEWORK.MODEL_CONFIG;
```

---

## Workflow 2: Bootstrap / First Run

Bootstrap is idempotent — safe to rerun after deploy or when adding new Bronze tables.

```sql
USE DATABASE YOUR_DATABASE;
CALL AGENT_FRAMEWORK.BOOTSTRAP('RAW');
```

Cross-database:

```sql
CALL AGENT_FRAMEWORK.BOOTSTRAP('CUSTOMER_DB.BRONZE');
```

Bootstrap does:
1. Runs `VALIDATE_MODEL` — auto-discovers best available Cortex model
2. Creates SILVER and GOLD schemas if missing
3. Scans `INFORMATION_SCHEMA` for Bronze tables → seeds `TABLE_LINEAGE_MAP`
4. Seeds default Schema Contracts (if empty)
5. Seeds default Transformation Directives (if empty)
6. Returns a JSON summary with table count, model, contract/directive counts

Via Streamlit: **Tab 1 → Run Bootstrap**.

---

## Workflow 3: Run the Agentic Workflow

```
Schema Analyst → [Approval Gate] → Planner → Executor → Validator → Reflector
```

### Phase: Schema Analyst

Single LLM call across ALL Bronze tables. Discovers FK relationships, stores
them in `SCHEMA_RELATIONSHIPS`. Results feed the Planner as additional context.

### Phase: Approval Gate

After Schema Analyst, workflow **pauses**. Streamlit shows FK relationships
grouped by confidence tier (HIGH/MEDIUM/LOW).

- Review and remove incorrect relationships
- Check **Auto-approve** to skip on future runs
- Click **Approve & Continue to Planner**

### Phase: Planner (v3)

- Groups tables into token-budget batches (~6000 tokens per LLM call)
- Skips tables whose schema MD5 fingerprint matches a prior COMPLETED run
- Writes one row to `PLANNER_DECISIONS` per table with strategy, transformations, confidence

### Phase: Executor

Reads `PLANNER_DECISIONS`, generates DDL via LLM, executes `CREATE TABLE AS SELECT`
into the output schema. One LLM call per table.

**Dry run mode:** When `p_dry_run = TRUE`, DDL is generated and logged to
`WORKFLOW_LOG` but **not executed**. Review in Tab 9 → Observe before disabling.

### Phase: Validator

Counts rows in Bronze vs Silver. Flags variance > 1%. Writes to `WORKFLOW_LOG`.
Cross-database Silver schemas are fully supported via qualified FQNs.

### Phase: Reflector

Reviews failures and variances. Writes learnings to `WORKFLOW_LEARNINGS` for
use on the next run.

### Via SQL

```sql
-- All Bronze tables with no Silver coverage:
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW('manual', NULL, 'MANUAL');

-- Specific tables only:
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'manual',
    ARRAY_CONSTRUCT('DB.SCHEMA.TABLE_A', 'DB.SCHEMA.TABLE_B'),
    'MANUAL'
);
```

### Resume Workflow

If the workflow fails at any phase, **Resume Workflow** appears in Tab 5.
It detects the failed phase and skips all already-completed phases:

| Failed Phase | What gets skipped | What gets copied |
|---|---|---|
| SCHEMA_ANALYST | nothing | — |
| PLANNER | SCHEMA_ANALYST | Relationships |
| EXECUTOR | SCHEMA_ANALYST + PLANNER | Relationships + Decisions |
| VALIDATOR | + EXECUTOR | + Executor output |
| REFLECTOR | all prior phases | everything |

### Check Results

```sql
-- Run history
SELECT execution_id, status, current_phase, started_at, completed_at
FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
ORDER BY started_at DESC LIMIT 10;

-- Planner decisions
SELECT source_table, transformation_strategy, confidence_score, llm_reasoning
FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
WHERE execution_id = 'YOUR_EXECUTION_ID';

-- FK relationships
SELECT parent_table, child_table, relationship_type, confidence_score
FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
ORDER BY confidence_score DESC;

-- Coverage gaps
SELECT * FROM AGENT_FRAMEWORK.SILVER_GAPS;

-- Accumulated learnings
SELECT * FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
WHERE is_active = TRUE ORDER BY confidence_score DESC;
```

---

## Workflow 4: Gold Builder

### Via Streamlit (recommended)

1. **Tab 7: Analytics Builder** → set max tables slider (default 5)
2. Click **Propose Analytics DDLs** — dry_run=TRUE, no execution yet
3. Review each DDL in the expander panels
4. Click **Execute All DDLs** or individual execute buttons

### Via SQL

```sql
-- Propose only:
CALL AGENT_FRAMEWORK.BUILD_GOLD_FOR_NEW_TABLES(TRUE, 5);

-- Execute a reviewed DDL:
CALL AGENT_FRAMEWORK.GOLD_AGENTIC_EXECUTOR('CREATE OR REPLACE TABLE GOLD.MY_TABLE AS SELECT ...');
```

**Dynamic Table output:** When `p_pipeline_type = 'DYNAMIC_TABLE'`, Gold Builder
generates `CREATE OR REPLACE DYNAMIC TABLE` statements with `TARGET_LAG` and
`WAREHOUSE` from Pipeline Context.

---

## Workflow 5: Model Rotation

When a Cortex model is deprecated or unavailable:

### Auto-discover (recommended)

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL(NULL);
```

Priority order:
1. `llama3.3-70b`
2. `claude-3-7-sonnet`
3. `claude-3-5-sonnet-v2`
4. `mistral-large2`
5. `llama3.1-70b`
6. `llama3.1-8b`

**Cost guidance** (approximate tokens per Snowflake credit):

| Model | Tokens / Credit | Best for |
|---|---|---|
| `llama3.1-8b` | 1,000,000 | Reflector (summarization only) |
| `llama3.3-70b` | 200,000 | Executor, Gold Builder, Planner (default) |
| `llama3.1-70b` | 200,000 | Fallback for llama3.3-70b |
| `mistral-large2` | 75,000 | General fallback |
| `claude-3-5-sonnet-v2` | 25,000 | Schema Analyst, complex reasoning |
| `claude-3-7-sonnet` | 25,000 | Schema Analyst, demos |

### Switch to a specific model

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('claude-3-7-sonnet');
```

Or via Streamlit: **Tab 1 → Model Management → Validate & Set**.

Zero redeployment needed — all SPs read `MODEL_CONFIG` at runtime.

---

## Workflow 6: Contracts & Directives

### Schema Contracts (structural rules)

```sql
-- View active contracts
SELECT * FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS WHERE is_active = TRUE;

-- Add a custom contract
INSERT INTO AGENT_FRAMEWORK.SCHEMA_CONTRACTS
    (contract_scope, rule_category, rule_name, rule_value, description, applies_to_layer)
VALUES ('global', 'naming', 'gold_suffix', '_MART', 'Gold tables must end in _MART', 'GOLD');

-- Reset to defaults
CALL AGENT_FRAMEWORK.SEED_DEFAULT_CONTRACTS();
```

### Transformation Directives (per-table intent)

```sql
-- Add a table-specific directive
INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
    (source_table_pattern, target_layer, use_case, instructions, priority)
VALUES (
    'ORDERS', 'SILVER', 'order_dedup',
    'Deduplicate on ORDER_ID + UPDATED_AT. Preserve all status transitions.',
    9
);

-- Reset to defaults
CALL AGENT_FRAMEWORK.SEED_DEFAULT_DIRECTIVES();
```

Pattern matching: `%` = all tables, `ORDERS%` = tables starting with ORDERS.

---

## Workflow 7: DCM Export

### Phase 1 — Generate from Snowflake

**Via Streamlit: Tab 11 → DCM Export**

```sql
CALL AGENT_FRAMEWORK.GENERATE_DCM_PROJECT(
    'adf_pipeline',         -- project name
    'DATA_ENGINEER_ROLE',   -- role for Silver access
    'ANALYST_ROLE'          -- role for Gold access
);
```

Files written to `@AGENT_FRAMEWORK.DCM_OUTPUT`:

| File | Contents |
|------|----------|
| `manifest.yml` | Project config, DEV/PROD targets |
| `sources/definitions/infrastructure.sql` | `DEFINE SCHEMA` for SILVER and GOLD |
| `sources/definitions/tables.sql` | `DEFINE TABLE` for every Silver table |
| `sources/definitions/analytics.sql` | `DEFINE TABLE` for every Gold table |
| `sources/definitions/access.sql` | GRANT statements for Silver/Gold roles |
| `sources/definitions/expectations.sql` | NULL_COUNT DMF expectations on PK columns |

```bash
snow stage get @AGENT_FRAMEWORK.DCM_OUTPUT ./dcm_project -c YOUR_CONNECTION
```

### Phase 2 — Deploy via DCM skill

```bash
snow dcm create YOUR_DB.AGENT_FRAMEWORK.ADF_PIPELINE -c YOUR_CONNECTION
snow dcm deploy YOUR_DB.AGENT_FRAMEWORK.ADF_PIPELINE --target DEV -c YOUR_CONNECTION
```

**Talk track:**
> "The agent did the creative work — Bronze to Silver, Silver to Gold. Now we
> flip from agentic-exploratory mode to IaC mode. This DCM project goes into
> git. The customer manages their Gold layer like standard infrastructure —
> versioned, auditable, CI/CD deployable."

---

## Workflow 8: Brownfield Mode

Use when the customer already has Silver tables that should NOT be overwritten.

### Enable

```sql
-- Set pipeline context first, then:
CALL AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(TRUE);
```

Or via Streamlit: **Tab 2 → Context → Brownfield Mode toggle**.

### Behavior

- Bootstrap detects existing Silver tables → registers them as `silver_status = 'EXISTING'`
- Executor skips any table with `silver_status = 'EXISTING'` → logs as `SKIPPED`
- New Bronze tables (no Silver coverage) proceed normally

### Reset

```sql
CALL AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(FALSE);
```

---

## Workflow 9: Document Ingestion

Enrich the agent's context with PDFs, markdown files, or plain text. Uploaded
documents are chunked into `DOCUMENT_CONTEXT_ITEMS` and included in
`ATS_KNOWLEDGE_CORPUS` — the Cortex Search index reads these automatically.

### Via Streamlit: Tab 3 → Documents

Upload PDF or .txt/.md files via the file uploader. Select doc type
(architecture, runbook, data dictionary, business rules, other).

### Via SQL

```sql
-- Ingest a file already on a Snowflake stage (PDFs use PARSE_DOCUMENT):
CALL AGENT_FRAMEWORK.INGEST_DOCUMENT_FROM_STAGE(
    '@AGENT_FRAMEWORK.DOCUMENT_STAGE/my_spec.pdf',
    'data_dictionary',
    'Customer product catalog schema spec'
);

-- Ingest raw text directly:
CALL AGENT_FRAMEWORK.INGEST_DOCUMENT_TEXT(
    'HIPAA requires all PII columns to be masked in Gold. SSN must be hashed.',
    'business_rules',
    'HIPAA compliance rules'
);

-- List documents:
CALL AGENT_FRAMEWORK.LIST_DOCUMENTS();

-- Remove a document:
CALL AGENT_FRAMEWORK.REMOVE_DOCUMENT('my_spec.pdf');
```

**Note:** After ingesting documents, the `ATS_KNOWLEDGE_SEARCH` Cortex Search
service refreshes on its schedule (default: 1 hour). For immediate effect,
recreate the service via Tab 11 or rerun `10_cortex_search.sql`.

---

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| `AGENT_FRAMEWORK schema not found` | Framework not deployed | Run Workflow 1: Deploy |
| `MODEL_CONFIG.validated = FALSE` | No working Cortex model | Run Workflow 5: Model Rotation |
| Workflow stuck after Schema Analyst | Approval gate waiting | Review relationships in Tab 6, click Approve |
| Workflow shows "Interrupted" | Tab switch killed Python loop | Click "Cancel Interrupted Run", restart |
| Planner produced partial results | Crashed mid-batch | Use Reset Framework and run fresh |
| Silver row count variance > 1% on SCD2 | Expected — counts only `IS_CURRENT=TRUE` | `[SCD2]` tag in WORKFLOW_LOG; no action |
| Silver row count variance > 1% non-SCD2 | Dedup key mismatch | Add directive with explicit dedup key; Resume |
| `SILVER schema does not exist` | Reset dropped schemas | Run Bootstrap again |
| `EXECUTE IMMEDIATE` permission error | Insufficient role | Grant `CREATE TABLE`, `CREATE VIEW` on Silver/Gold |
| Cross-db Silver tables not validating | Validator using wrong DB | Ensure `p_output_schema` is fully qualified (DB.SCHEMA) |
| `TRY_TO_VARCHAR` error in Executor | Old SQL file deployed | Redeploy `04c_executor.sql` and `03_directives.sql` |

---

## SA Demo Script

**Pre-demo checklist:**
- [ ] Deploy complete (`SHOW SCHEMAS` shows AGENT_FRAMEWORK)
- [ ] `MODEL_CONFIG.validated = TRUE`
- [ ] At least 3 Bronze tables in `TABLE_LINEAGE_MAP`
- [ ] Pipeline Context set with business description
- [ ] Streamlit app open and connected

**Talk track order:**

1. **Tab 1 — Setup** — "Zero hardcoded model names. Everything reads from MODEL_CONFIG.
   When Snowflake retires a model, one SQL call and every SP updates. The Reset button
   starts clean without touching the database manually."

2. **Tab 2 — Context** — "Before we run anything, I describe the business to the agent.
   Two sentences about what they do, what Gold needs to answer, any compliance
   constraints. The output schema and dry_run flag are set here too — dry_run means
   the agent generates DDL but doesn't execute it until we say go."

3. **Tab 3 — Documents** — "Before the agent touches any data, I give it domain knowledge.
   Business rules, naming conventions, ERDs. It retrieves these via Cortex Search before
   every LLM call — so when I say MARKETBASKET must exclude deleted rows, the agent
   applies that automatically. Upload docs here, then run the workflow."

4. **Tab 4 — Contracts** — "These are the structural rules the agent must follow.
   SCD2 column names, monetary precision, PCI masking. Editable without redeploying.
   Reset to Defaults is a safe MERGE — custom rules are preserved."

5. **Tab 5 — Directives** — "Human-in-the-loop. I tell the agent what each table is
   for before it touches the data. ACCOUNTS = SCD Type 2 dimension.
   TRANSACTIONS = immutable append-only fact. Read at plan time, not runtime."

6. **Tab 6 — Workflow** — "Schema Analyst runs one LLM call across all tables to
   discover FK relationships. Then it pauses — I review before the Planner uses them.
   Human approval gate. Once approved, Planner batches tables by token budget, skips
   unchanged schemas, calls LLM per batch. Then Executor, Validator, Reflector.
   If anything fails, Resume picks up exactly where it left off."

7. **Tab 7 — Analytics Builder** — "Agent proposes Gold DDLs. I review each one.
   Never executes without a human seeing it. Propose 5, review, execute, propose 5 more —
   already-covered tables are excluded automatically."

8. **Tab 9 — Observe** — "Full execution history, cost attribution per run, and
   accumulated learnings. Every mistake the agent made is captured as a learning
   and injected into the next run's prompt. The agent gets better with every execution."

9. **Tab 11 — DCM Export** — "Once happy, I export as a DCM project. The SP reads
   live Silver and Gold schemas, generates DEFINE TABLE statements, access grants,
   and data quality expectations. Download and hand off to the DCM skill for
   analyze → plan → deploy. Customer commits to git — standard IaC from here."
