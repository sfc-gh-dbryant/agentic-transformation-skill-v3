# ATS v3 Release Notes

**Version:** 3.0.0  
**Date:** June 2026  
**Status:** Ready for SA testing  

---

## Summary

v3 addresses all P0 blockers identified during the v2 SA test. The skill is now safe to run against customer environments: it will never write to a production schema by default, and will abort with a clear message if a target table already has rows.

---

## P0 Changes (Customer Safety)

### 1. Safe Output Schema — Never Writes to SILVER/GOLD by Default

**Problem (v2):** `RUN_AGENTIC_WORKFLOW` defaulted output to `SILVER`. Running it against an account with existing data overwrote production tables. One test destroyed 6 columns from a live table.

**Fix (v3):**
- All Executor output goes to `AGENT_FRAMEWORK_OUTPUT` by default.
- `SILVER` and `GOLD` schemas are never touched unless explicitly configured.
- `SET_PIPELINE_CONTEXT` accepts `p_output_schema` to change the target.

```sql
-- v2 (dangerous default)
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW();
-- → wrote to SILVER.* with no warning

-- v3 (safe default)
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW();
-- → writes to AGENT_FRAMEWORK_OUTPUT.* or aborts if target has rows
```

---

### 2. Dry Run Mode — Review Before You Execute

**Problem (v2):** No way to see what the LLM would generate before it executed.

**Fix (v3):**
- `dry_run = TRUE` is the default. The Executor generates DDL, logs it to `WORKFLOW_LOG`, and returns `DRY_RUN_COMPLETE`. Nothing is written.
- Set `dry_run => FALSE` explicitly to execute.

```sql
-- Review generated DDL first
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_dry_run => TRUE);
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW();
-- Check WORKFLOW_LOG for DRY_RUN entries — inspect the SQL before running for real

-- When satisfied:
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_dry_run => FALSE);
CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW();
```

---

### 3. Overwrite Protection

**Problem (v2):** No check for existing tables — silently overwrote data.

**Fix (v3):**
- If the target table exists AND has rows, the Executor aborts with `TARGET_EXISTS_NO_OVERWRITE`.
- `WORKFLOW_LOG` records the exact table name and row count.
- To allow overwrite, set `overwrite_existing => TRUE` explicitly with `dry_run => FALSE`.

```sql
-- Default: protected
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_overwrite_existing => FALSE); -- default

-- To overwrite intentionally:
CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(
    p_dry_run            => FALSE,
    p_overwrite_existing => TRUE
);
```

**Guard:** Setting `overwrite_existing = TRUE` with `dry_run = TRUE` returns an error — the combination is ambiguous and rejected.

---

### 4. Column Hallucination Prevention

**Problem (v2):** The Executor hallucinated column names (`INGEST_DATE`, `OTHER_COLUMNS`) that didn't exist, requiring 3 retries per table (6 wasted LLM calls per run).

**Fix (v3):**
- Executor fetches the exact column list from `INFORMATION_SCHEMA.COLUMNS` before calling the LLM.
- The prompt now includes: `EXACT COLUMN LIST — use ONLY these column names, do NOT invent others`.
- Retry message explicitly says: *"Re-verify all column names exist in the EXACT COLUMN LIST above."*

---

### 5. Multi-Banner Partner Support

**Problem (v2):** The skill assumed 1 Bronze → 1 Silver → 1 Gold. LCL V2 (Canada's largest grocer) has 14 banners routing to 13 Gold tables. Completely unsupported.

**Fix (v3):** New `09_banner_config.sql` adds:

| Object | Description |
|--------|-------------|
| `PARTNER_BANNER_CONFIG` | Maps partner+banner → silver subset → gold table |
| `GET_BANNER_CONFIG(partner)` | Returns all active banners as VARIANT |
| `VALIDATE_MULTI_BANNER(partner)` | Validates all Gold tables vs Silver subsets with exclusion accounting |
| `SEED_LCL_BANNER_CONFIG()` | Pre-seeded LCL V2 config (14 banners, adapt table names to env) |

Key capabilities:
- Per-banner Silver filters (e.g. `WHERE BANNER = 'superstore'`)
- Gold exclusion accounting: `Gold = Silver - excluded` (validates correctly when Gold < Silver)
- Merge targets: routes `ICM` rows into `GOLD_INDEPENDENT`
- Banners with no Gold table are skipped with INFO, not FAIL
- Partner-specific UPC thresholds (e.g. LCL allows 30% non-standard due to coupon items)

---

### 6. Validator PK Check Fixed

**Problem (v2):** `VALIDATE_PARTNER` guessed the PK column, sometimes picking `ORIGINAL_PRICE`.

**Fix (v3):** `WORKFLOW_VALIDATOR` now reads `pk_columns` from `PLANNER_DECISIONS` where the Planner recorded its analysis, and includes it in the validation result object.

---

## P1 Changes (Quality)

### RESET_FRAMEWORK SP Added

`RESET_FRAMEWORK` was called by the Streamlit UI but never defined in v2. Now implemented in `00_bootstrap.sql`. Requires `confirm => 'YES'` to prevent accidental invocation.

### SET_PIPELINE_CONTEXT — Named Parameters

Now has 9 clearly named parameters with defaults. Eliminates the positional argument confusion from v2 (which had 15 unnamed positional args in some builds).

### SETUP_ALL.sql — Snowsight Guidance

Clarified that `!source` directives require Snow CLI. Added step-by-step Snowsight instructions for running each file individually.

### SKILL.md Fixes

- `TRANSFORMATION_DIRECTIVES` column names corrected (`source_table_pattern`, `target_layer`, `use_case`, `instructions` — previously documented as `table_name`, `table_type`, `intent`, `notes`)
- Added SQL scripting gotchas reference section
- Added multi-banner usage section
- Updated `SET_PIPELINE_CONTEXT` example to named parameter syntax

---

## What Was NOT Changed (Intentional)

- **WORKFLOW_PLANNER** — Planner phase was rated the strongest in v2 testing. No changes.
- **WORKFLOW_REFLECTOR** — Learning mechanism is working. No changes.
- **Gold Builder** — Not in scope for v3. Gold-layer output safety is handled by the output_schema mechanism.
- **Python SP rewrite** — The feedback report recommended rewriting `VALIDATE_PARTNER` as a Python SP for maintainability. Scoped for v4. The `VALIDATE_MULTI_BANNER` SP is new SQL but structured more cleanly.

---

## Upgrade from v2

For accounts already running v2, run the migration ALTERs in `07_pipeline_context.sql` to add the new columns with safe defaults:

```sql
ALTER TABLE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    ADD COLUMN IF NOT EXISTS output_schema VARCHAR(200) NOT NULL DEFAULT 'AGENT_FRAMEWORK_OUTPUT';
ALTER TABLE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    ADD COLUMN IF NOT EXISTS dry_run BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE AGENT_FRAMEWORK.PIPELINE_CONTEXT
    ADD COLUMN IF NOT EXISTS overwrite_existing BOOLEAN NOT NULL DEFAULT FALSE;
```

Then redeploy `04c_executor.sql` and `09_banner_config.sql`.

> **Note:** After upgrading, existing automations that relied on the Executor writing directly to `SILVER` will stop writing data (dry_run defaults to TRUE). This is intentional — review and set `dry_run => FALSE` and `output_schema` explicitly before re-running.

---

## Known Limitations (Scoped for v4)

| # | Issue | Impact |
|---|-------|--------|
| 1 | Python SP rewrite for `VALIDATE_PARTNER` | Maintainability; dynamic SQL remains hard to read |
| 2 | Brownfield mode (validate existing tables, don't rebuild) | Medium — needed for customers with live pipelines |
| 3 | Deployment rollback script | Low — partial deploys still require manual cleanup |
| 4 | Cost attribution per workflow run | Low — nice to have for internal tracking |
| 5 | `SETUP_ALL.sql` Snowsight native execution | Low — workaround documented |

---

---

## v4 Architectural Direction

v4 replaces the stored procedure pipeline with a **Cortex Agents architecture** — each phase (Schema Analyst, Planner, Executor, Validator, Reflector) becomes a Cortex Agent with its own tool set. Agents can make multiple LLM calls per phase, invoke tools between them, and reason about results before concluding.

The Cortex Search service and Semantic View built in v3 are the primary tool backends for v4 agents — no changes required to those components.

Full design: **`docs/v4_architecture.md`**

### B-01: Customer Document Ingestion
**Priority:** High  
**Requested:** June 2026 SA testing session

**What it does:** Upload customer documents (PDFs, ERDs, 10-Ks, data dictionaries, naming convention docs, marketing plans, design docs) as additional context for the Planner and Executor. The LLM extracts rules from the documents and surfaces them as Schema Contracts, Directives, or RAG-style supplemental context injected into every prompt.

**Why it matters:** Today the Planner makes decisions based on column names and pipeline context text only. A customer's naming convention document, domain glossary, or ERD would dramatically improve Planner accuracy and reduce hallucination — especially for complex schemas with non-obvious column semantics.

**Three ingestion paths:**

| Path | Input | Tool | Output |
|------|-------|------|--------|
| **Structured extraction** | PDF/DOCX (naming convention, data dictionary, governance policy) | `CORTEX.AI_EXTRACT` or `CORTEX.PARSE_DOCUMENT` | New Schema Contracts + Directives auto-created from extracted rules |
| **Column glossary** | CSV/Excel (column name → business definition mapping) | `st.file_uploader` → stage → parse | Injected into Executor prompt as column-level context |
| **Unstructured context** | Marketing plan, 10-K, domain whitepaper | Chunk → `CORTEX.EMBED` → Cortex Search index | Retrieved by Planner via `SEARCH_ATS_KNOWLEDGE` on every run |

**Implementation notes:**
- Path 3 (Cortex Search) is already partially wired. Documents fed into `ATS_KNOWLEDGE_CORPUS` would be picked up by the Planner automatically with zero code changes to the workflow engine.
- Path 1 uses `CORTEX.AI_EXTRACT` with a schema that maps to `SCHEMA_CONTRACTS` and `TRANSFORMATION_DIRECTIVES` columns. The LLM extracts rules; the SA reviews and approves before they're saved.
- Streamlit UI: new **📄 Document Upload** tab with `st.file_uploader`, document type selector, preview of extracted rules, and an approve/reject flow before committing to the knowledge base.
- Stage path: `@AGENT_FRAMEWORK.AGENT_STAGE/docs/`

**Sketch of the extraction prompt:**
```
Given this document, extract:
1. Naming conventions (column naming rules → Schema Contracts)
2. Business definitions (column → meaning → Directives)  
3. Data quality rules (constraints, valid values → Contracts)
4. Domain relationships (table purpose, FK intent → Planner context)

Return JSON with: rule_type, rule_value, applies_to_table (or % for all), confidence.
```

---

### B-02: Industry-Specific Intelligence Packs
**Priority:** Medium

Pre-built bundles of Contracts, Directives, and domain glossaries per vertical (Retail/CPG, Healthcare, Financial Services, Manufacturing). User selects industry at Bootstrap time. Reduces time-to-first-run for common verticals from hours to minutes.

---

### B-03: Brownfield Mode
**Priority:** High

When existing Silver/Gold tables are detected, default to validate-and-export mode instead of build mode. Generates transformation logic as dbt/DT/INSERT scripts for review, compares against existing tables for correctness, never creates new tables unless explicitly requested. Required for customers with live pipelines.

---

### B-04: Multi-Source Bronze
**Priority:** Medium *(partially addressed in v3 — Bootstrap now accepts comma-separated cross-DB sources)*

Full support for comma-separated schemas or multiple databases as Bronze sources. Planner handles tables from different source systems in a single workflow run.

---

### B-06: Gold Layer Awareness — Augment Existing Analytics
**Priority:** High  
**Requested:** June 2026 SA testing session

**What it does:** The Schema Analyst and Planner inspect the existing Gold layer before generating new DDL. Instead of treating Gold as an empty target, the framework reads what already exists, understands its structure, and generates analytics that build on top of it — new derived tables, gap-filling aggregations, JOIN candidates, and column augmentations.

**Why it matters:** Most real customer engagements are brownfield. A customer running ATS against an existing data platform (for example) already has Gold tables built by their engineering team. Today ATS ignores those entirely. With Gold awareness, it could identify what's missing, what could be enriched, and what derived views would add value — without touching or duplicating what already exists.

**Difference from B-03 (Brownfield Mode):**

| | B-03 Brownfield Mode | B-06 Gold Awareness |
|--|---------------------|---------------------|
| Goal | Don't overwrite existing tables | USE existing tables as context to build better ones |
| Schema Analyst | Reads Bronze only | Reads Bronze + Silver + existing Gold |
| Planner output | Net-new Silver tables | Gap-filling Gold tables, augmentations, derived views |
| Example | "Don't touch GOLD.LCL_SUPERSTORE" | "GOLD.LCL_SUPERSTORE exists — generate GOLD.LCL_REGIONAL_ROLLUP joining it with SILVER" |

**Implementation design:**

1. **Schema Analyst extension** — after scanning Bronze tables, also scan schemas registered as Gold targets in `TABLE_LINEAGE_MAP`. Feed existing Gold column definitions into the Planner prompt alongside Bronze schemas.

2. **Planner prompt addition:**
```
EXISTING GOLD TABLES (do not recreate — build on top of these):
TABLE: GOLD.LCL_GOLD_SUPERSTORE
COLUMNS: UPC, BANNER, TITLE, PRICE, CATEGORY, STORE_ID, ...
ROW_COUNT: ~3,000

Generate ONLY net-new tables or views that:
- Are not already represented above
- Add analytical value the existing Gold layer does not have
- May JOIN with or aggregate from the existing Gold tables above
```

3. **Cortex Search path (low-lift)** — index existing Gold schemas into `ATS_KNOWLEDGE_CORPUS` as a new `source_type = 'gold_schema'`. The Planner already retrieves from Cortex Search before each batch — Gold schemas would be surfaced automatically with no Planner code changes.

4. **Gap analysis output** — Planner returns a new field `gap_analysis` alongside `transformation_strategy`:
   - `AUGMENT` — add columns to an existing Gold table
   - `DERIVE` — new table that aggregates or joins existing Gold
   - `NEW` — no overlap with existing Gold (standard behavior today)

**Streamlit UI:** Add a "Gold Awareness" toggle in Tab 2 (Context). When ON, Bootstrap also scans the Gold schema and registers existing tables as context-only entries in `TABLE_LINEAGE_MAP` with a new `discovery_method = 'GOLD_SCAN'`.

---

### B-07: Output Model Support — Star Schema, Data Vault, One Big Table
**Priority:** High  
**Requested:** June 2026 SA testing session

Add a `target_model` parameter to `PIPELINE_CONTEXT` (separate from `pipeline_type` which controls CTAS vs Dynamic Table):

| `target_model` | Output | Best for |
|---------------|--------|---------|
| `FLAT` | Denormalized Silver tables (current default) | Fast POCs, ML features |
| `STAR_SCHEMA` | `FACT_` + `DIM_` tables, surrogate keys, grain, SCD Type 2 | BI/reporting |
| `DATA_VAULT` | HUBs + LINKs + SATs with hash keys, load date, record source | Enterprise DW, auditability |
| `ONE_BIG_TABLE` | Single wide table per domain | Cortex Analyst, ad-hoc |

**Note on Star Schema:** Partially implemented in v2 (`gold_output_mode = STAR_SCHEMA`). Scoped out of v3 — carry forward to v4.

**Note on Data Vault + Multi-Banner:** Data Vault is ideal for LCL V2-style partners. Each banner becomes a LINK between HUB_PRODUCT and HUB_BANNER. The vault unifies the data model; business vault views split it by banner at query time — eliminating the need for 13 separate Gold tables.

**Note on LLM suitability:** Data Vault patterns are highly structured and rule-based, making them well-suited for LLM generation. The Planner can identify HUB/LINK/SAT candidates from business keys (UPC, CUSTOMER_ID), FK relationships, and descriptive attributes.

**v4 agent implications:** See `v4_design_notes.md` Note 009.

---

### B-05: Deployment Rollback Script
**Priority:** Low

`teardown.sh` that drops all ATS framework objects in reverse dependency order. Needed for clean re-deploys and for customers who want to remove the framework after a POC.

