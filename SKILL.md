---
name: agentic-transformation-skill-v3
description: "Deploy and operate an Agentic Data Foundry on Snowflake. Use when: building a Silver layer from raw/Bronze tables, building Gold analytical tables, deploying agentic SQL pipelines, setting up schema contracts, transformation directives, running Planner/Executor/Validator/Reflector workflows, configuring partner routing rules (one Silver table fanning out to multiple Gold tables based on store banner, region, format, product line, or any dimension), validating multi-target routing, querying pipeline knowledge with Cortex Search, using a Semantic View for text-to-SQL analytics, or handing off a data transformation framework to a customer. Triggers: agentic data foundry, silver layer, gold layer, bronze to silver, transformation pipeline, schema contracts, transformation directives, agentic workflow, model config, deploy transformation skill, data foundry, partner routing, multi-banner, banner config, routing validation, gold exclusion, store format, region routing, dry run, brownfield, cortex search, semantic view, knowledge search, text-to-SQL, ATS_KNOWLEDGE_SEARCH, ATS_PIPELINE_SEMANTICS."
---

# Agentic Transformation Skill v3

A Snowflake-native SA delivery accelerator. Deploys an AGENT_FRAMEWORK schema
into any Snowflake database and gives the SA (or customer) a 10-tab Streamlit
app to drive Schema Analyst -> Planner -> Executor -> Validator -> Reflector
Silver/Gold pipeline with zero hardcoded model names, Cortex Search-enhanced planning, a Semantic View for text-to-SQL, and a DCM production handoff.

## Tab Reference

| # | Tab | Purpose |
|---|-----|---------|
| 1 | Setup | Bootstrap, model management, Reset Framework |
| 2 | Context | Pipeline Context (business desc, domain, goals, constraints, pipeline output type, **dry_run, output_schema**) |
| 3 | Contracts | Schema Contracts — structural rules |
| 4 | Directives | Transformation Directives — per-table intent |
| 5 | Workflow | Run agentic workflow, Schema Analyst approval gate |
| 6 | Analytics Builder | Propose and execute Gold DDLs |
| 7 | Registry | Pipeline lineage and FK relationships |
| 8 | Observe | Execution history, learnings, metrics, promote learnings to contracts/directives |
| 9 | Partner Routing | Routing config CRUD (any dimension: banner, region, format), seed example configs, per-rule validation with variance reporting |
| 10 | DCM Export | Generate and download DCM project files |

## Package Location

```
agentic-transformation-skill/
├── SKILL.md
├── setup/
│   ├── SETUP_ALL.sql             <- Snow CLI deploy (run files individually in Snowsight)
│   ├── 00_bootstrap.sql          <- Schema, MODEL_CONFIG, BOOTSTRAP, RESET_FRAMEWORK
│   ├── 01_transformation_registry.sql
│   ├── 02_schema_contracts.sql
│   ├── 03_directives.sql
│   ├── 04a_discover_schema.sql
│   ├── 04b_planner.sql
│   ├── 04c_executor.sql          <- v3: dry_run, safe output_schema, column injection
│   ├── 04d_validator.sql         <- v3: pk_columns from PLANNER_DECISIONS
│   ├── 04e_reflector.sql
│   ├── 04f_orchestrator.sql
│   ├── 05_gold_builder.sql
│   ├── 06_schema_analyst.sql
│   ├── 07_pipeline_context.sql   <- v3: output_schema, dry_run, overwrite_existing
│   ├── 08_dcm_export.sql
│   ├── 09_banner_config.sql      <- v3 NEW: multi-banner support, VALIDATE_MULTI_BANNER
│   ├── 10_cortex_search.sql      <- v3 NEW: ATS_KNOWLEDGE_CORPUS, Cortex Search service
│   ├── 11_semantic_view.sql      <- v3 NEW: ATS_PIPELINE_SEMANTICS semantic view
│   └── deploy.sh
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
| **Intake / Context** | "new customer", "first time", "what does this pipeline do", "set context", "describe the business" | [Workflow 0: Intake](#workflow-0-intake--pipeline-context) |
| **Deploy** | "deploy this", "set this up", "install", "clean account" | [Workflow 1: Deploy](#workflow-1-deploy) |
| **Bootstrap** | "run bootstrap", "discover tables", "initialize" | [Workflow 2: Bootstrap](#workflow-2-bootstrap--first-run) |
| **Run workflow** | "run the pipeline", "build silver", "transform tables" | [Workflow 3: Agentic Workflow](#workflow-3-run-the-agentic-workflow) |
| **Dry run** | "dry run", "preview ddl", "what would it generate", "review before executing" | [Workflow 3: Dry-Run → Review → Execute](#v3-dry-run--review--execute-workflow) |
| **Gold** | "build gold", "propose gold", "analytical tables" | [Workflow 4: Gold Builder](#workflow-4-gold-builder) |
| **Model** | "switch model", "validate model", "model deprecated", "change cortex model" | [Workflow 5: Model Rotation](#workflow-5-model-rotation) |
| **Contracts/Directives** | "add directive", "edit contracts", "schema rules" | [Workflow 6: Contracts & Directives](#workflow-6-contracts--directives) |
| **DCM export** | "export to dcm", "production handoff", "dcm project", "commit to git", "deploy gold to prod" | [Workflow 7: DCM Export](#workflow-7-dcm-export) |
| **Partner Routing** | "partner routing", "multi-banner", "validate routing", "store format", "region routing", "gold exclusion", "banner config", "routing validation" | [Workflow 8: Partner Routing Validation](#workflow-8-partner-routing-validation-v3) |
| **Cortex Search / Semantic View** | "knowledge search", "search prior runs", "semantic view", "text-to-SQL", "cortex analyst", "ATS_KNOWLEDGE_SEARCH", "ATS_PIPELINE_SEMANTICS" | [Workflow 9: Cortex Intelligence](#workflow-9-cortex-intelligence-v3) |

---

## Prerequisites

Before any workflow, verify:

1. **Bronze tables exist** — this skill does NOT ingest data
2. **Cortex is enabled** on the account
3. User has `CREATE SCHEMA`, `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE STAGE`,
   `CREATE STREAMLIT` privileges on the target database
4. Snow CLI installed (Option A only) — verify with `snow --version`

```sql
-- Quick privilege check
SELECT CURRENT_ROLE(), CURRENT_DATABASE(), CURRENT_WAREHOUSE();
SHOW GRANTS TO ROLE IDENTIFIER(CURRENT_ROLE());
```

---

## Workflow 0: Intake / Pipeline Context

Run this at the start of **every new customer engagement** before bootstrap.
The context is injected into every Planner LLM call — without it the agent
makes generic decisions; with it, it makes domain-informed ones.

Ask the customer these four questions conversationally, then write the answers
to `PIPELINE_CONTEXT` in a single call:

```
1. "Describe your business in 2-3 sentences."
   -> business_desc

2. "What industry and data type are we working with?"
   -> data_domain  (e.g. "Healthcare / Insurance Claims")

3. "What business questions must your analytics layer answer?"
   -> gold_goals   (e.g. "Fraud detection, cost-per-encounter, provider KPIs")

4. "Any compliance, privacy, or architectural constraints the agent must respect?"
   -> constraints  (e.g. "HIPAA -- no PII in Gold. Full audit trail in Silver.")
```

Once you have the answers, write them to Snowflake:

```sql
USE DATABASE YOUR_DATABASE;
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_business_desc      => 'We are a healthcare payer processing insurance claims for 2M members.',
    p_data_domain        => 'Healthcare / Insurance Claims',
    p_gold_goals         => 'Fraud detection, cost-per-encounter analytics, provider performance KPIs.',
    p_constraints        => 'HIPAA compliant -- no PII in Gold layer. Full audit trail required in Silver.',
    p_pipeline_type      => 'CTAS',
    p_target_lag         => '1 hour',
    p_output_schema      => 'AGENT_FRAMEWORK_OUTPUT',  -- v3: NEVER writes to SILVER/GOLD by default
    p_dry_run            => TRUE,                      -- v3: set FALSE only when ready to execute
    p_overwrite_existing => FALSE                      -- v3: set TRUE only to intentionally overwrite
);
```

> **v3 Safety Note:** `dry_run=TRUE` is the default. The Executor will generate DDL and log it
> without writing any data. Review the DDL in Tab 8 → Observe → Workflow Log before setting
> `dry_run=FALSE` to execute for real.

Or via Streamlit: **Tab 2 -> Context** — fill the form and click **Save Context**.

Verify:

```sql
SELECT AGENT_FRAMEWORK.PIPELINE_CONTEXT_AS_PROMPT();
```

Expected: a formatted multi-line string that will appear at the top of every
Planner prompt. If `NULL` is returned, no context is set.

---

## Workflow 1: Deploy

### Option A — Snow CLI (~2 min)

```bash
./setup/deploy.sh \
  --connection YOUR_CONNECTION \
  --database   YOUR_DATABASE  \
  --bronze-schema RAW
```

```bash
# From the app/ directory (uses snowflake.yml for all config)
cd app && snow streamlit deploy -c YOUR_CONNECTION --replace
```

### Option B — Snowsight Only (no CLI)

> **Important:** `SETUP_ALL.sql` uses `!source` directives which only work with the Snow CLI.
> For Snowsight, run each file individually in this order:

1. Open Snowsight → Worksheets → New Worksheet
2. Set `TARGET_DB` variable at top: `SET TARGET_DB = 'YOUR_DATABASE';`
3. Run each file in order:
   - `00_bootstrap.sql` → `01_transformation_registry.sql` → `02_schema_contracts.sql`
   - `03_directives.sql` → `04a_discover_schema.sql` → `04b_planner.sql`
   - `04c_executor.sql` → `04d_validator.sql` → `04e_reflector.sql` → `04f_orchestrator.sql`
   - `05_gold_builder.sql` → `06_schema_analyst.sql` → `07_pipeline_context.sql`
   - `08_dcm_export.sql` → `09_banner_config.sql`
4. Run bootstrap: `CALL AGENT_FRAMEWORK.BOOTSTRAP('RAW');`
5. Go to Snowsight → **Streamlit** → **+ Streamlit App**
6. Set Database = YOUR_DATABASE, Schema = AGENT_FRAMEWORK
7. Paste contents of `app/streamlit_app.py` and click **Run**

### Reset / Re-run from Scratch

Use the **Reset Framework** button on **Tab 1 -> Setup** (requires two-step
confirmation). This drops SILVER/GOLD, truncates all metadata tables, reseeds
default contracts and directives, and clears Pipeline Context. Bootstrap is
re-run automatically by the Reset procedure.

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

Bootstrap does:
1. Runs `VALIDATE_MODEL` — auto-discovers the best available Cortex model
2. Creates `AGENT_FRAMEWORK_OUTPUT`, `SILVER` and `GOLD` schemas if they do not exist
3. Scans `INFORMATION_SCHEMA` for Bronze tables -> seeds `TABLE_LINEAGE_MAP`
4. Seeds default Schema Contracts (if empty)
5. Seeds default Transformation Directives (if empty)
6. Returns a JSON summary with table count, model used, contract/directive counts

> **Cross-database Bronze sources:** BOOTSTRAP natively supports FQ paths and comma-separated multi-source:
> ```sql
> -- Single cross-DB source
> CALL AGENT_FRAMEWORK.BOOTSTRAP('CUSTOMER_DB.BRONZE');
>
> -- Multiple sources (LCL V2 pattern)
> CALL AGENT_FRAMEWORK.BOOTSTRAP('DB1.BRONZE,DB2.RAW,DB3.STAGE');
> ```

Via Streamlit: **Tab 1 -> Run Bootstrap** button does the same thing.

---

## Workflow 3: Run the Agentic Workflow

The workflow runs five phases in sequence:

```
Schema Analyst -> [Approval Gate] -> Planner -> Executor -> Validator -> Reflector
```

### Phase: Schema Analyst

Single LLM call across ALL Bronze tables. Discovers FK relationships and stores
them in `AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS`. Results are fed into the Planner
as additional context (e.g. "ACCOUNTS has 5 inbound FKs -> SCD Type 2").

### Phase: Approval Gate (Schema Analyst Results)

After Schema Analyst completes, the workflow **pauses**. The Streamlit app shows
the discovered FK relationships grouped by confidence tier (HIGH/MEDIUM/LOW).

- Review the relationships and remove any that are incorrect
- Check **Auto-approve** to skip this gate on future runs
- Click **Approve & Continue to Planner** to proceed

This gate prevents the Planner from acting on incorrect FK assumptions.

### Phase: Planner (v3 — dynamic batching + schema-hash cache)

The Planner:
- Groups tables into token-budget batches (target ~6000 tokens per LLM call)
- Skips tables whose schema MD5 fingerprint matches a prior COMPLETED run
- For each batch: calls the LLM with schema + Pipeline Context + contracts + directives
- Writes one row to `PLANNER_DECISIONS` per table with strategy, transformations, confidence

### Phase: Executor (v3 — safe output, dry-run, column injection)

Reads `PLANNER_DECISIONS`, generates DDL via LLM, and:
- **Checks `output_schema`** — writes to `AGENT_FRAMEWORK_OUTPUT` by default, never SILVER/GOLD
- **Checks `dry_run`** — if `TRUE` (default), logs DDL to `WORKFLOW_LOG` without executing
- **Checks existing rows** — if target table has rows and `overwrite_existing=FALSE`, logs `ABORTED`
- **Injects exact column list** from source database's `INFORMATION_SCHEMA` into the LLM prompt to prevent column name hallucination

### Phase: Validator

Counts rows in Bronze vs Silver (using `pk_columns` from `PLANNER_DECISIONS` for PK checks).
Flags variance > 1%. Writes results to `WORKFLOW_LOG`. SCD2 tables are validated
against `IS_CURRENT = TRUE` rows only.

### Phase: Reflector

Reviews failures and variances. Writes learnings to `WORKFLOW_LEARNINGS` for
use on the next run.

### Via Streamlit (recommended for demos)

1. Open **Tab 5: Workflow**
2. Multi-select Bronze tables (leave empty = all gaps)
3. Click **Run Agentic Workflow**
4. Review Schema Analyst results at the approval gate
5. Click **Approve & Continue to Planner**
6. Watch the live phase diagram

### Resume Workflow

If the workflow fails at **any phase**, the **Resume Workflow** button appears
automatically below the failure message. It detects the failed phase and skips
all already-completed phases, copying their outputs into a new execution:

| Failed Phase | What gets skipped | What gets copied |
|---|---|---|
| SCHEMA_ANALYST | nothing | — |
| PLANNER | SCHEMA_ANALYST | Relationships |
| EXECUTOR | SCHEMA_ANALYST + PLANNER | Relationships + Decisions |
| VALIDATOR | + EXECUTOR | + Executor output |
| REFLECTOR | all prior phases | everything |

Reused phases are shown as ⏩ in the phase diagram.

### v3: Dry-Run → Review → Execute Workflow

The recommended first run on any new environment:

```sql
-- Step 1: dry run (default) — review generated DDL, nothing written
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_dry_run       => TRUE,
    p_output_schema => 'AGENT_FRAMEWORK_OUTPUT'
);
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW('review', ARRAY_CONSTRUCT('DB.SCHEMA.MY_TABLE'));

-- Step 2: review generated DDL in WORKFLOW_LOG
SELECT status, LEFT(message, 2000) AS ddl_preview
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status = 'DRY_RUN'
ORDER BY created_at DESC;

-- Step 3: when satisfied, flip dry_run off and re-run
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_dry_run            => FALSE,
    p_output_schema      => 'AGENT_FRAMEWORK_OUTPUT',
    p_overwrite_existing => FALSE
);
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');  -- clear prior run state
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW('live', ARRAY_CONSTRUCT('DB.SCHEMA.MY_TABLE'));
```

**Verify output:**
```sql
SELECT table_schema, table_name, row_count
FROM YOUR_DB.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'AGENT_FRAMEWORK_OUTPUT';
```

### Via SQL (scripted / scheduled)

```sql
-- All Bronze tables with no Silver coverage:
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW('manual', NULL);

-- Specific tables only:
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW(
    'manual',
    ARRAY_CONSTRUCT('DB.SCHEMA.TABLE_A', 'DB.SCHEMA.TABLE_B')
);
```

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

-- FK relationships discovered
SELECT parent_table, child_table, relationship_type, confidence_score
FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
ORDER BY confidence_score DESC;

-- Coverage gaps remaining
SELECT * FROM AGENT_FRAMEWORK.SILVER_GAPS;

-- Accumulated learnings
SELECT * FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
WHERE is_active = TRUE
ORDER BY confidence_score DESC;
```

---

## Workflow 4: Gold Builder

### Via Streamlit (recommended — human review gate)

1. **Tab 6: Analytics Builder** -> set max tables slider (default 5)
2. Click **Propose Analytics DDLs** — dry_run=TRUE, no execution yet
3. Review each DDL in the expander panels
4. Click **Execute All DDLs** or individual execute buttons
5. Re-click Propose to generate more (already-covered tables are excluded)

Tables without Gold coverage are surfaced via the `GOLD_GAPS` view. Once a
Gold table is executed, it is removed from future proposals automatically.

### Via SQL

```sql
-- Propose only (review before executing):
CALL AGENT_FRAMEWORK.BUILD_GOLD_FOR_NEW_TABLES(TRUE, 5);

-- Execute a specific reviewed DDL:
CALL AGENT_FRAMEWORK.GOLD_AGENTIC_EXECUTOR('CREATE OR REPLACE TABLE GOLD.MY_TABLE AS SELECT ...');
```

**Dynamic Table output:** If `PIPELINE_CONTEXT.pipeline_type = 'DYNAMIC_TABLE'`,
the Gold Builder generates `CREATE OR REPLACE DYNAMIC TABLE` statements with
`TARGET_LAG` and `WAREHOUSE` set from Pipeline Context. CLUSTER BY goes inside
the CREATE (before AS) — not in a separate ALTER.

---

## Workflow 5: Model Rotation

When a Cortex model is deprecated or unavailable:

### Auto-discover (recommended)

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL(NULL);
```

Priority order (v3 — `llama3.3-70b` first based on testing):
1. `llama3.3-70b`
2. `llama3.1-70b`
3. `mistral-large2`
4. `claude-3-7-sonnet`

**Cost guidance** (tokens per Snowflake credit):

| Model | Tokens / Credit | Best for |
|---|---|---|
| `llama3.3-70b` | 200,000 | **Recommended default** — Executor, Planner, Gold Builder |
| `llama3.1-8b` | 1,000,000 | Reflector (summarization only) |
| `mistral-large2` | 75,000 | General fallback |
| `claude-3-5-sonnet-v2` | 25,000 | Schema Analyst, complex reasoning |
| `claude-3-7-sonnet` | 25,000 | Schema Analyst, demos |

### Switch to a specific model

```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('claude-3-7-sonnet');
```

Or via Streamlit: **Tab 1 -> Model Management -> Validate & Set**.

No stored procedures need to be redeployed. All SPs read `MODEL_CONFIG` at
runtime — zero hardcoded model names anywhere in the codebase.

---

## Workflow 6: Contracts & Directives

### Schema Contracts (structural rules)

Edit in Streamlit **Tab 3** or via SQL:

```sql
-- View active contracts
SELECT * FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS WHERE is_active = TRUE;

-- Add a custom contract
INSERT INTO AGENT_FRAMEWORK.SCHEMA_CONTRACTS
    (contract_scope, rule_category, rule_name, rule_value, description, applies_to_layer)
VALUES ('global', 'naming', 'gold_suffix', '_MART', 'Gold tables must end in _MART', 'GOLD');

-- Reset to defaults (MERGE -- safe, preserves custom contracts)
CALL AGENT_FRAMEWORK.SEED_DEFAULT_CONTRACTS();
```

### Transformation Directives (per-table intent)

Edit in Streamlit **Tab 4** or via SQL:

```sql
-- Add a table-specific directive
INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
    (source_table_pattern, target_layer, use_case, instructions, priority)
VALUES (
    'ORDERS', 'SILVER', 'order_dedup',
    'Deduplicate on ORDER_ID + UPDATED_AT. Preserve all status transitions.',
    9
);

-- Pattern matching: % = all tables, ORDERS% = tables starting with ORDERS
-- Reset to defaults (DELETE known defaults + INSERT -- preserves custom directives)
CALL AGENT_FRAMEWORK.SEED_DEFAULT_DIRECTIVES();
```

---

## Workflow 7: DCM Export

Generates a deployable Database Change Management project from the live Silver
and Gold schemas. Two phases: Snowflake-side generation (this skill), then
deploy via the `$dcm` skill.

### Phase 1 — Generate from Snowflake (this skill)

**Via Streamlit: Tab 10 -> DCM Export**

1. Set project name (default: `adf_pipeline`)
2. Set Data Engineer Role and Analyst Role names
3. Click **Generate DCM Project**
4. Review each generated file in the tabbed code viewer
5. Download files using the per-file download buttons

**Via SQL:**

```sql
CALL AGENT_FRAMEWORK.GENERATE_DCM_PROJECT(
    'adf_pipeline',         -- project name
    'DATA_ENGINEER_ROLE',   -- role for Silver access
    'ANALYST_ROLE'          -- role for Gold access
);
```

The SP generates six files written to `@AGENT_FRAMEWORK.DCM_OUTPUT`:

| File | Contents |
|------|----------|
| `manifest.yml` | Project config, DEV/PROD targets |
| `sources/definitions/infrastructure.sql` | `DEFINE SCHEMA` for SILVER and GOLD |
| `sources/definitions/tables.sql` | `DEFINE TABLE` for every Silver table |
| `sources/definitions/analytics.sql` | `DEFINE TABLE` for every Gold table |
| `sources/definitions/access.sql` | GRANT statements for Silver/Gold roles |
| `sources/definitions/expectations.sql` | NULL_COUNT DMF expectations on PK columns — sourced from Planner decisions (falls back to `_ID` heuristic for tables with no Planner history) |

**Download from stage:**

```bash
snow stage get @AGENT_FRAMEWORK.DCM_OUTPUT ./dcm_project -c YOUR_CONNECTION
```

### Phase 2 — Deploy via DCM skill (hand off)

At this point, invoke the `$dcm` skill with intent DEPLOY.

```bash
# Register the project
snow dcm create YOUR_DB.AGENT_FRAMEWORK.ADF_PIPELINE -c YOUR_CONNECTION

# Deploy (analyze -> plan -> confirm -> deploy)
snow dcm deploy YOUR_DB.AGENT_FRAMEWORK.ADF_PIPELINE --target DEV -c YOUR_CONNECTION
```

The `$dcm` skill will run analyze -> plan -> present CREATE/ALTER/DROP summary
-> wait for explicit confirmation -> deploy.

**Talk track:**
> "The agent did the creative work -- Bronze to Silver, Silver to Gold. Now we
> flip from agentic-exploratory mode to IaC mode. This DCM project goes into
> git. The customer manages their Gold layer like any other schema
> infrastructure -- versioned, auditable, CI/CD deployable."

---

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| `AGENT_FRAMEWORK schema not found` | Framework not deployed | Run Workflow 1: Deploy |
| `MODEL_CONFIG.validated = FALSE` | No working Cortex model found | Run Workflow 5: Model Rotation |
| **Tables not written after workflow** | `dry_run=TRUE` (default) | Review DDL in `WORKFLOW_LOG WHERE status='DRY_RUN'`, then set `p_dry_run=>FALSE` and re-run |
| **ABORTED in WORKFLOW_LOG** | Target table exists with rows | Either use a different `output_schema`, or set `p_overwrite_existing=>TRUE` with `p_dry_run=>FALSE` |
| **"column list unavailable" in dry-run DDL** | Bronze tables are in a different database than the framework | Seed `TABLE_LINEAGE_MAP` manually (see Bootstrap cross-database note) |
| **Wrong output schema** | `output_schema` defaults to `AGENT_FRAMEWORK_OUTPUT` | Call `SET_PIPELINE_CONTEXT(p_output_schema=>'YOUR_SCHEMA')` |
| Workflow stuck after Schema Analyst | Approval gate waiting | Review relationships in Tab 5 and click Approve |
| Workflow shows "Interrupted" in Tab 5 | Tab switch killed Python loop | Click "Cancel Interrupted Run", restart |
| Planner produced partial results | Crashed mid-batch | Use Reset Framework and run fresh |
| Silver row count variance > 1% on SCD2 table | Expected — Validator counts only `IS_CURRENT=TRUE` rows | `[SCD2]` tag appears in WORKFLOW_LOG; no action needed |
| Silver row count variance > 1% on non-SCD2 table | Dedup key mismatch or bad JOIN | Add directive with explicit dedup key; use Resume Workflow → Executor |
| `SILVER schema does not exist` | Reset dropped schemas | Bootstrap recreates them; run Bootstrap again |
| `EXECUTE IMMEDIATE` permission error | Insufficient role | Grant `CREATE TABLE`, `CREATE VIEW` on Silver/Gold schemas |

---

## SA Demo Script

**Pre-demo checklist:**
- [ ] Deploy complete (`SHOW SCHEMAS` shows AGENT_FRAMEWORK)
- [ ] MODEL_CONFIG shows `validated = TRUE`, model = `llama3.3-70b`
- [ ] At least 3 Bronze tables in TABLE_LINEAGE_MAP
- [ ] `dry_run = FALSE` in PIPELINE_CONTEXT (check Tab 2 — Dry Run toggle must be OFF)
- [ ] `output_schema` set to your target schema (check Tab 2)
- [ ] Streamlit app open and connected

**Talk track order:**

1. **Tab 1 -- Setup** -- "Zero hardcoded model names. Everything reads from MODEL_CONFIG.
   When Snowflake retires a model, one SQL call and every SP updates. The Reset button
   here lets us start clean without touching the database manually."

2. **Tab 2 -- Context** -- "Before we run anything, I describe the business to the agent.
   Two sentences about what they do, what the Gold layer needs to answer, any compliance
   constraints. Notice the Output Safety section -- dry_run is ON by default. That means
   the first run generates SQL and logs it without touching any data. I review it, then
   flip dry_run off when I am satisfied. The agent can never accidentally overwrite a
   production table."

3. **Tab 3 -- Contracts** -- "These are the structural rules the agent must follow.
   SCD2 column names, monetary precision, PCI masking requirements. Editable without
   redeploying anything. Reset to Defaults is a safe MERGE -- custom rules are preserved."

4. **Tab 4 -- Directives** -- "This is the human-in-the-loop. I tell the agent exactly
   what each table is for before it touches the data. ACCOUNTS = SCD Type 2 dimension.
   TRANSACTIONS = immutable append-only fact. The agent reads these at plan time."

5. **Tab 5 -- Workflow** -- "First, the Schema Analyst runs a single LLM call across all
   23 tables to discover FK relationships. Then it pauses -- I review the relationships
   before the Planner uses them. This is the human approval gate. Once I approve, the
   Planner batches tables by token budget, skips unchanged schemas from prior runs,
   and calls the LLM. Then Executor, Validator, Reflector."

6. **Tab 6 -- Analytics Builder** -- "The agent proposes Gold DDLs. I review each one.
   It never executes DDL without a human seeing it. I can propose 5, review, execute,
   then propose 5 more -- already-covered tables are excluded automatically."

7. **Tab 10 -- DCM Export** -- "Once I am happy, I export it as a DCM project. The SP
   reads the live Silver and Gold schemas, generates DEFINE TABLE statements, access
   grants, and data quality expectations. I download the files and hand off to the
   DCM skill for analyze -> plan -> deploy. The customer commits that project to git
   and manages their data layer as standard infrastructure-as-code."

---

## Schema Reference (v3 — Actual Column Names)

### TRANSFORMATION_DIRECTIVES
> Previously documented incorrectly. These are the actual column names.

| Column | Type | Description |
|--------|------|-------------|
| `source_table_pattern` | VARCHAR | Table name or pattern (e.g. `ORDERS`, `ORDERS_%`) |
| `target_layer` | VARCHAR | `SILVER` or `GOLD` |
| `use_case` | VARCHAR | Short label (e.g. `SCD2_DIMENSION`, `FACT_TABLE`) |
| `instructions` | VARCHAR(4000) | Free-text injected into Planner prompt |
| `priority` | INTEGER | Lower = applied first |
| `is_active` | BOOLEAN | FALSE = directive ignored at runtime |

### PIPELINE_CONTEXT (v3 new columns)

| Column | Default | Description |
|--------|---------|-------------|
| `output_schema` | `AGENT_FRAMEWORK_OUTPUT` | All CTAS output goes here. Never SILVER/GOLD by default. |
| `dry_run` | `TRUE` | Generate DDL without executing. Set FALSE to write data. |
| `overwrite_existing` | `FALSE` | Abort if target table has rows. Requires `dry_run=FALSE`. |

---

## Snowflake SQL Scripting Gotchas

| Issue | Wrong | Correct |
|-------|-------|---------|
| Read scalar from dynamic SQL | `EXECUTE IMMEDIATE ... INTO :var` | Use RESULTSET + cursor: `LET rs RESULTSET := ...; LET c CURSOR FOR rs; OPEN c; FETCH c INTO var; CLOSE c;` |
| Reserved iterator keyword | `FOR row IN cursor` | `FOR rec IN cursor` — `row` is reserved |
| Expression in VALUES() | `VALUES(ARRAY_SIZE(:arr))` | Pre-compute into a variable first |
| Variable in INSERT...SELECT | missing `:` prefix | Always use `:var` — without it treated as column name |
| Multiple cursor declarations | `LET cur1...; LET cur2...` | Reuse a single RESULTSET variable between uses |

**Recommendation:** Use Python SPs for complex procedural logic. Reserve SQL SPs for simple CRUD.

---

## Workflow 8: Multi-Banner Validation (v3)

```sql
-- Seed LCL V2 example config (14 banners, 13 Gold tables)
CALL AGENT_FRAMEWORK.SEED_LCL_BANNER_CONFIG('SILVER', 'GOLD');

-- Validate all banners (accounts for exclusion filters, merges, missing Gold tables)
CALL AGENT_FRAMEWORK.VALIDATE_MULTI_BANNER('LCL');
```

Key fields in `PARTNER_BANNER_CONFIG`:
- `excluded_categories` — rows excluded from Gold by design (Gold < Silver is valid)
- `merge_into_banner` — banner rows that route into another banner's Gold table
- `upc_threshold_pct` — acceptable % of non-standard UPCs (e.g. 30 for LCL coupon items)
- `gold_table = NULL` — banner has no Gold output; skipped with INFO not FAIL

---

## Workflow 9: Cortex Intelligence (v3)

### What it is

Two v3-only infrastructure components that make the ATS progressively smarter
and queryable with natural language:

| Component | Object | Purpose |
|-----------|--------|---------|
| **Knowledge Search** | `AGENT_FRAMEWORK.ATS_KNOWLEDGE_SEARCH` | Cortex Search service indexing 3 knowledge tables. Planner queries it before every LLM batch to inject relevant prior decisions. |
| **Semantic View** | `AGENT_FRAMEWORK.ATS_PIPELINE_SEMANTICS` | YAML-based semantic model over 5 ATS tables. Enables Cortex Analyst text-to-SQL against pipeline metadata. |
| **Corpus View** | `AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS` | UNION ALL backing view (learnings + planner decisions + schema relationships). Required by Cortex Search. |
| **Search SP** | `AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE` | Python SP called by Planner. Returns top-N prior decisions relevant to the current table list. |

### Check status

Both components are visible in **Tab 1 (Setup) → Cortex Intelligence** section.

```sql
-- Check corpus size
SELECT COUNT(*), source_type FROM AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS GROUP BY 2;

-- Test the search SP
CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE('deduplicate product catalog', 3);
```

### Deploy / redeploy

If the search service or semantic view is missing (e.g. after a fresh deploy):

```bash
# From the v3 setup directory:
./deploy.sh --connection MY_CONN --database MY_DB --bronze-schema BRONZE --warehouse MY_WH

# Or individually:
snow sql -c MY_CONN -f setup/10_cortex_search.sql
snow sql -c MY_CONN -f setup/11_semantic_view.sql
```

### Use Cortex Analyst with the Semantic View

```sql
-- Reference for Cortex Analyst
SELECT SYSTEM$REFERENCE('SEMANTIC_VIEW', 'ATS_PIPELINE_SEMANTICS', 'SESSION', 'USAGE');
```

Natural language questions the semantic view supports:
- "How many tables were planned in the last run?"
- "Which tables have active schema contracts?"
- "Show tables with ABORTED executor status"
- "What transformation strategies did the planner choose?"
- "Which learnings have the highest confidence score?"

### How the Planner uses Knowledge Search

Each time WORKFLOW_PLANNER runs, before the first LLM batch it calls:

```sql
CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE(
    'transformation strategy for tables: TABLE_A, TABLE_B', 8
) INTO :search_result;
```

The results (prior decisions, learnings, FK relationships) are prepended to
`existing_learnings` and injected into the batch prompt. This reduces
hallucination and retry loops on tables the framework has seen before.

### Notes
- The search service indexes automatically every hour (TARGET_LAG = '1 hour')
- After a fresh install the corpus will be empty until the first workflow run populates WORKFLOW_LEARNINGS and PLANNER_DECISIONS
- `SEARCH_ATS_KNOWLEDGE` is a **Python stored procedure** (not a SQL UDF) because `SEARCH_PREVIEW` requires a constant second argument; call it with `CALL ... INTO :var` in SQL scripting

