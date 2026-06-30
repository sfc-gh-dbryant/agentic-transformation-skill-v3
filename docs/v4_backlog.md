# ATS Product Backlog

**Maintained by:** Danny Bryant  
**Last Updated:** June 2026  
**Framework:** `ATS_V4.AGENT_FRAMEWORK`

This document tracks what has been built across versions and what remains. Items are grouped by theme, not by sprint. Status column reflects state as of v4 GA.

---

## Version Baseline

| Version | Status | Key Theme |
|---------|--------|-----------|
| v1 | Archived | Proof of concept — single LLM call, no retries, no safety |
| v2 | Archived | First SA-tested version. Shipped with P0 safety defects |
| v3 | ✅ Shipped | P0 safety fixes, multi-banner support, Cortex Search + Semantic View |
| v4 | ✅ Shipped | Cortex Agents layer, 35 tool SPs, cost attribution, Observe redesign |

---

## Core Pipeline

### Phase Execution

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `WORKFLOW_PLANNER` SP — per-table LLM strategy decisions | v1 | ✅ Done | Unchanged since v2 — consistently the strongest phase |
| `WORKFLOW_EXECUTOR` SP — LLM-generated Silver DDL with retry loop | v1 | ✅ Done | 3-retry self-correcting loop with CONFLICT_REDIRECTED guard |
| `WORKFLOW_VALIDATOR` SP — Bronze/Silver row count parity | v1 | ✅ Done | SCD2-aware, cross-database INFORMATION_SCHEMA support added in v4 |
| `WORKFLOW_REFLECTOR` SP — post-mortem learnings | v1 | ✅ Done | Deduplication via Cortex Search added in v3 |
| `WORKFLOW_SCHEMA_ANALYST` SP — FK relationship discovery | v3 | ✅ Done | Python SP rewrite in v3; domain-agnostic prompt |
| `RUN_AGENTIC_WORKFLOW` SP — full 5-phase orchestration | v2 | ✅ Done | CLI/Task entry point. Streamlit calls phases individually |
| Parallel phase execution | — | 🔲 Backlog | Phases still run sequentially. Cortex Agents parallel calling not implemented |
| Resume-from-phase on failure | — | 🔲 Backlog | A failed Executor run requires full re-run or manual phase call |

### LLM Quality & Hallucination Prevention

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| Column hallucination guard — inject exact INFORMATION_SCHEMA column list | v3 | ✅ Done | Reduced retries from avg 2.4 to 0 on clean runs |
| `CONFLICT_REDIRECTED` variable name guard | v4 | ✅ Done | Pre-execution `SELECT INTO` check blocks before Snowflake sees the SQL |
| `TRY_TO_VARCHAR` non-existent function blocked via HARD RULE | v4 | ✅ Done | Added to Executor prompt after SA testing caught this |
| Model configuration table — no hardcoded model names | v3 | ✅ Done | `MODEL_CONFIG` table; `VALIDATE_MODEL` SP tests and selects |
| Retry error feedback loop — inject SQL error into next prompt | v3 | ✅ Done | Error message + column list re-injected on each retry |
| Confidence scoring in Planner decisions | v4 | ✅ Done | Stored in `PLANNER_DECISIONS.confidence_score` |

---

## Safety & Brownfield Handling

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| Safe output schema — never writes to SILVER/GOLD by default | v3 | ✅ Done | Default is `AGENT_FRAMEWORK_OUTPUT`. Was P0 blocker in v2 |
| Dry run mode — generates DDL, never executes | v3 | ✅ Done | Default `dry_run = TRUE`. Must opt-in to execute |
| Overwrite protection — two-key interlock | v3 | ✅ Done | Both `dry_run=FALSE` AND `overwrite_existing=TRUE` required |
| Brownfield mode — skip existing Silver tables | v3 | ✅ Done | Logs as `EXISTING`, not failure. Only processes Silver gaps |
| Conflict redirect — VIEW/DT/empty table → fallback schema | v3 | ✅ Done | Automatic. Default fallback `{output_schema}_STAGING` |
| Configurable fallback schema | v3 | ✅ Done | `SET_CONFLICT_FALLBACK_SCHEMA()` SP |
| Gold conflict redirect | v4 | ✅ Done | Same mechanism applied to Gold Builder output |
| `RESET_FRAMEWORK` SP — full wipe with confirmation gate | v3 | ✅ Done | Was called by Streamlit in v2 but never implemented |
| `CLEAR_WORKFLOW_HISTORY` SP — soft reset between runs | v3 | ✅ Done | Preserves contracts, directives, learnings |
| Teardown/rollback script | — | 🔲 Backlog | B-05. `teardown.sh` to drop all ATS objects in reverse dependency order |

---

## Configuration & Context

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `PIPELINE_CONTEXT` table — single-row operational config | v2 | ✅ Done | 9 named parameters via `SET_PIPELINE_CONTEXT` |
| `SCHEMA_CONTRACTS` — editable structural rules for LLM | v2 | ✅ Done | Per-layer (Silver/Gold), editable via Streamlit Tab 2 |
| `TRANSFORMATION_DIRECTIVES` — per-table business intent | v2 | ✅ Done | LIKE pattern matching, editable via Streamlit Tab 3 |
| `MODEL_CONFIG` — runtime model selection | v3 | ✅ Done | `VALIDATE_MODEL` tests candidates and stores winner |
| Named parameters on `SET_PIPELINE_CONTEXT` | v3 | ✅ Done | Was positional in v2; confusing and error-prone |
| Multi-source Bronze — comma-separated cross-DB schemas | v3 | ✅ Done | `BOOTSTRAP` accepts `'DB1.BRONZE,DB2.RAW'` |
| Pipeline type — CTAS vs Dynamic Table | v3 | ✅ Done | `pipeline_type` + `target_lag` in PIPELINE_CONTEXT |
| Gold output mode — FLAT / STAR_SCHEMA / DATA_VAULT / ONE_BIG_TABLE | v3 partial | 🔶 Partial | Parameter exists in PIPELINE_CONTEXT. Star Schema partially implemented in v2 (scoped out of v3). Data Vault and One Big Table are prompt-driven only — no structural enforcement |
| Industry intelligence packs | — | 🔲 Backlog | B-02. Pre-built Contracts + Directives bundles per vertical (Retail/CPG, Healthcare, FSI, Manufacturing) |

---

## Knowledge & Memory

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `WORKFLOW_LEARNINGS` — persistent cross-run memory | v2 | ✅ Done | Reflector MERGEs learnings; survives `CLEAR_WORKFLOW_HISTORY` |
| `SCHEMA_RELATIONSHIPS` — discovered FK/entity relationships | v3 | ✅ Done | Written by Schema Analyst, injected into Planner prompts |
| `ATS_KNOWLEDGE_CORPUS` view — UNION ALL over all knowledge sources | v3 | ✅ Done | Learnings + decisions + relationships + documents |
| `ATS_KNOWLEDGE_SEARCH` Cortex Search service — semantic retrieval | v3 | ✅ Done | ~1-hour refresh cycle. Used by Planner before each batch |
| `SEARCH_ATS_KNOWLEDGE` function — callable by agents and SPs | v3 | ✅ Done | Returns top-N relevant items by semantic similarity |
| Planner injects prior decisions from Cortex Search | v3 | ✅ Done | Reduces hallucination and reuses proven strategies |
| Document ingestion — PDF/text RAG context | v4 | ✅ Done | B-01. `INGEST_DOCUMENT_FROM_STAGE`, `INGEST_DOCUMENT_TEXT`, `DOCUMENT_CONTEXT_ITEMS`. Chunks indexed into Cortex Search |
| Document extraction → auto-create Contracts/Directives | — | 🔲 Backlog | B-01 Phase 2. Use `AI_EXTRACT` to parse rules from uploaded docs into structured `SCHEMA_CONTRACTS` / `TRANSFORMATION_DIRECTIVES` rows with SA review/approve flow |
| Column glossary ingestion — CSV/Excel → Executor prompt context | — | 🔲 Backlog | B-01 Phase 3. `column_name → business definition` mapping injected at DDL generation time |
| Learning confidence decay — demote stale learnings | — | 🔲 Backlog | Learnings from old runs should carry less weight. No decay mechanism currently |

---

## Cortex Agents Layer (v4)

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| 35 `ATS_TOOL_*` stored procedures — tool layer | v4 | ✅ Done | One SP per agent tool. JSON in/out contract |
| `ATS_SCHEMA_ANALYST_AGENT` — FK/relationship discovery | v4 | ✅ Done | Samples data to verify FK hypotheses before recording |
| `ATS_PLANNER_AGENT` — transformation strategy decisions | v4 | ✅ Done | Reads context, contracts, directives, prior decisions |
| `ATS_EXECUTOR_AGENT` — Silver DDL generation + execution | v4 | ✅ Done | GET_COLUMNS tool + conflict guard = 0 retries on clean run |
| `ATS_VALIDATOR_AGENT` — quality validation | v4 | ✅ Done | PK uniqueness, row count parity, SCD2-aware |
| `ATS_REFLECTOR_AGENT` — learning extraction | v4 | ✅ Done | Deduplicates via Cortex Search before saving |
| `ATS_ORCHESTRATOR_AGENT` — end-to-end coordination | v4 | ✅ Done | v3 SP bridge tools allow chaining while sub-agents validated |
| Schema Analyst approval gate — pause for human review | v4 | ✅ Done | Orchestrator surfaces relationship table; SA reviews before Planner proceeds |
| Parallel agent execution (multiple tables concurrently) | — | 🔲 Backlog | Current: sequential per table. Target: Executor processes N tables in parallel via Cortex Agents batch calling |
| Gold awareness — Planner reads existing Gold before generating | — | 🔲 Backlog | B-06. Schema Analyst scans existing Gold. Planner generates AUGMENT/DERIVE/NEW decisions. Cortex Search path already wires this for low-lift first pass |
| Direct Agent execution path in Streamlit | v4 | 🔶 Partial | Agent Hub and Orchestrate tabs exist. Full interactive agent conversation UX not finalized |

---

## Gold Layer

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `GOLD_AGENTIC_EXECUTOR` SP — LLM-generated Gold DDL with 3-retry loop | v3 | ✅ Done | Python SP. Supports multi-statement DDL (CREATE + CLUSTER BY) |
| `BUILD_GOLD_FOR_NEW_TABLES` SP — batch Gold build from GOLD_GAPS | v3 | ✅ Done | dry_run mode for proposal review in Streamlit |
| `GOLD_GAPS` view — Silver tables with no Gold counterpart | v3 | ✅ Done | Used by Build Gold for new tables |
| Gold output mode parameter in Planner prompt | v4 | 🔶 Partial | `ATS_TOOL_GET_GOLD_SCHEMAS` tool defined. Not yet wired into default Planner prompt |
| Star Schema output — FACT_ + DIM_ tables with surrogate keys | v2 partial | 🔲 Backlog | B-07. `gold_output_mode = STAR_SCHEMA`. Scoped out of v3. LLM generates structure; no structural enforcement layer |
| Data Vault output — HUBs + LINKs + SATs | — | 🔲 Backlog | B-07. Ideal for multi-banner (LCL) patterns. High LLM suitability for rule-based vault generation |
| One Big Table output — single wide table per domain | — | 🔲 Backlog | B-07. Good for Cortex Analyst / ad-hoc use cases |
| Gold awareness — augment existing Gold rather than recreate | — | 🔲 Backlog | B-06. See Cortex Agents section above |
| `EXPORT_DCM_PROJECT` / `GENERATE_DCM_PROJECT` — DCM handoff | v3 | ✅ Done | Generates DEFINE statements + manifest.yml from Gold tables |

---

## Multi-Banner Support

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `PARTNER_BANNER_CONFIG` table — banner routing config | v3 | ✅ Done | Maps Silver → N Gold tables via banner_column filter |
| `GET_BANNER_CONFIG()` function | v3 | ✅ Done | Returns active banner config as VARIANT array |
| `VALIDATE_MULTI_BANNER` SP | v3 | ✅ Done | Python SP. Validates all Gold tables with exclusion and merge accounting |
| `SEED_LCL_BANNER_CONFIG` SP — LCL V2 reference seeding | v3 | ✅ Done | 14 banners, 13 Gold tables, coupon UPC threshold |
| Banner-driven Data Vault modeling | — | 🔲 Backlog | B-07 extension. Each banner = LINK between HUB_PRODUCT and HUB_BANNER. Eliminates 13-table Gold pattern |

---

## Observability & Monitoring

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `WORKFLOW_LOG` table — per-event operational log | v1 | ✅ Done | Phase, table, status (OK/WARN/ERROR/INFO), message, timestamp |
| `WORKFLOW_EXECUTIONS` table — one row per run | v1 | ✅ Done | Status, current phase, phase timestamps, tables built/failed |
| Streamlit Observe tab — KPI metrics, per-table results | v3 | ✅ Done | Run selector, 4 KPIs, color-coded per-table retry counts |
| Per-table retry count visible in Observe | v4 | ✅ Done | Redesigned in v4 — was not visible in v3 |
| `WORKFLOW_COST_ATTRIBUTION` table — cost per run | v4 | ✅ Done | Warehouse credits (near real-time) + Cortex credits (45-min delay) |
| `CAPTURE_WORKFLOW_COST` SP — standalone cost attribution | v4 | ✅ Done | Not wired into pipeline. Re-runnable. Backfillable |
| Cost section in Observe tab | v4 | ✅ Done | KPIs, phase duration bar chart, LLM call summary, retry waste % |
| `ATS_PIPELINE_SEMANTICS` semantic view | v3 | ✅ Done | Natural language queries over pipeline state via Cortex Analyst |
| Cost alerting — notify when credits/run exceeds threshold | — | 🔲 Backlog | `WORKFLOW_COST_ATTRIBUTION` has the data. Need alert trigger (Task + email notification integration) |
| Phase performance trending — p50/p95 per phase over time | — | 🔲 Backlog | WORKFLOW_EXECUTIONS has timestamps. Dashboard view not built |
| Per-model cost comparison — llama vs mistral vs arctic | — | 🔲 Backlog | `MODEL_CONFIG` tracks active model. No A/B cost comparison across runs |

---

## Deployment & Infrastructure

| Item | Introduced | Status | Notes |
|------|-----------|--------|-------|
| `deploy.sh` — automated ordered deployment | v2 | ✅ Done | Handles file order, connection injection, database substitution |
| `SETUP_ALL.sql` — Snowsight fallback with step-by-step instructions | v3 | ✅ Done | For accounts without Snow CLI |
| Streamlit app — full management UI | v2 | ✅ Done | 5 tabs: Model, Contracts, Directives, Pipeline, Observe |
| Agent Hub + Orchestrate tabs in Streamlit | v4 | ✅ Done | Direct Cortex Agent conversation interface |
| Python connector deploy pattern for SQL Scripting SPs | v4 | ✅ Done | Required because `snow sql -f` fails on `||` inside `$$` blocks |
| `VALIDATE_MODEL` — auto-selects working model at bootstrap | v3 | ✅ Done | Tests priority list, picks first that responds |
| `STAGE AGENT_STAGE` — Streamlit deployment stage | v2 | ✅ Done | Used by `snow streamlit deploy` |
| `STAGE DOCUMENT_STAGE` — RAG document upload stage | v4 | ✅ Done | Source stage for `INGEST_DOCUMENT_FROM_STAGE` |
| `STAGE DCM_OUTPUT` — DCM project export stage | v3 | ✅ Done | Target for `EXPORT_DCM_PROJECT` |
| Teardown / rollback script | — | 🔲 Backlog | B-05. Drop all ATS framework objects in reverse dependency order |
| Multi-account deployment packaging | — | 🔲 Backlog | Currently requires manual connection parameter injection. Self-contained deploy bundle for customer handoff |

---

## Backlog Items — Prioritized

| ID | Item | Priority | Version Target | Source |
|----|------|----------|---------------|--------|
| B-01a | Document ingestion — PDF/text → Cortex Search RAG | ✅ Done | v4 | SA testing request |
| B-01b | Document extraction → auto-create Contracts/Directives (AI_EXTRACT + review flow) | High | v5 | v3 release notes |
| B-01c | Column glossary ingestion — CSV/Excel → prompt context | Medium | v5 | v3 release notes |
| B-02 | Industry intelligence packs — pre-built Contracts + Directives per vertical | Medium | v5 | v3 release notes |
| B-03 | Brownfield mode | ✅ Done | v3 | SA testing P0 |
| B-04 | Multi-source Bronze (comma-separated cross-DB) | ✅ Done | v3 | SA testing request |
| B-05 | Teardown / rollback script | Low | v5 | v3 release notes |
| B-06 | Gold layer awareness — Planner reads existing Gold before generating | High | v5 | SA testing request |
| B-07a | Star Schema output mode | Medium | v5 | v3 release notes |
| B-07b | Data Vault output mode | Medium | v5 | v3 release notes |
| B-07c | One Big Table output mode | Low | v5 | v3 release notes |
| B-08 | Parallel Executor — process N tables concurrently | Medium | v5 | Architecture gap |
| B-09 | Cost alerting — notify when spend/run exceeds threshold | Low | v5 | Identified during v4 cost work |
| B-10 | Phase performance trending dashboard | Low | v5 | Identified during v4 Observe redesign |
| B-11 | Learning confidence decay — demote stale learnings | Medium | v5 | Architecture gap |
| B-12 | Resume-from-phase on failure | High | v5 | Operational gap — full re-run required today |
| B-13 | Multi-account deployment packaging for customer handoff | Medium | v5 | Delivery gap |
| B-14 | Gold output mode fully wired into Planner prompt | Medium | v5 | v4 partial — tool defined, prompt not updated |
| B-15 | Schema evolution — backup-restore with cardinality mapping for renamed columns | Medium | v5 | CK comparison report |
| B-16 | VIEW output format — live query over Bronze, no CTAS | Low | v5 | CK comparison report |
| B-17 | Git-trackable config export — YAML snapshot of contracts + directives | Medium | v5 | CK comparison report |
| B-18 | Hybrid deployment pattern — Python-for-DDL + Skill-for-intelligence documented option | Medium | v5 | CK comparison report |

---

## External Review Findings

Two independent reviews were conducted against v2. Every actionable finding is tracked here with its current resolution status.

---

### Jeremy Guzman Salazar — SKILL_FEEDBACK_REPORT (2026-05-27)

**Context:** End-to-end test session using three partners at increasing complexity — Ren's Pets (5.7K rows, simple), DashMart Canada (181K rows, medium), LCL V2 (97M rows, 14 banners, complex).

**Jeremy's overall conclusion:** *"The skill is NOT safe for customer environments in its current state. With P0 fixes it becomes a viable SA delivery tool. With P1 fixes it becomes a customer-facing product that scales from 5K-row simple partners to 97M-row enterprise pipelines."*

#### P0 Findings — Blocks Customer Use

| # | Finding | Root Cause | Resolution | Version |
|---|---------|-----------|-----------|---------|
| JG-P0-1 | **Production data destruction** — `RUN_AGENTIC_WORKFLOW` executed a CTAS that replaced `SILVER.RENSPETS_RENSPETS_PRODUCTS`, dropping 6 columns from live data | `PIPELINE_CONTEXT` defaulted to `silver_schema='SILVER'` with no existence check, dry-run, or confirmation gate | ✅ Fixed: default output to `AGENT_FRAMEWORK_OUTPUT`, dry-run=TRUE default, two-key overwrite interlock | v3 |
| JG-P0-2 | **Multi-banner architecture gap** — skill assumes 1 Bronze → 1 Silver → 1 Gold. LCL V2 has 14 banners → 13 Gold tables with exclusion filters. `VALIDATE_PARTNER` cannot iterate 13 banner tables; row count parity invalid when Gold < Silver by design | Single-medallion architecture; no concept of banner routing in any framework table | ✅ Fixed: `PARTNER_BANNER_CONFIG` table, `VALIDATE_MULTI_BANNER` SP, Gold filter accounting, UPC threshold override, `SEED_LCL_BANNER_CONFIG` | v3 |
| JG-P0-3 | **`SET_PIPELINE_CONTEXT` — 15 positional parameters** with no documentation on ordering. Error-prone and undiscoverable | Grew organically; never refactored | ✅ Fixed: named parameters, reduced to essential fields with clear defaults | v3 |
| JG-P0-4 | **Gold filter accounting** — validator assumed Silver = Gold, failing when Gold has exclusion filters (Ancillary/Liquor) | `VALIDATE_PARTNER` hard-coded Silver=Gold parity | ✅ Fixed: `VALIDATE_MULTI_BANNER` accounts for `Gold = Silver - excluded` per banner | v3 |

#### P1 Findings — Impacts Quality

| # | Finding | Root Cause | Resolution | Version |
|---|---------|-----------|-----------|---------|
| JG-P1-1 | **Column hallucination** — Executor hallucinated `INGEST_DATE`, `OTHER_COLUMNS`. 3 retries × 2 runs = 6 wasted LLM calls per table. Reflector learnings didn't prevent recurrence on run 2 | LLM generates column names from training patterns, not actual schema | ✅ Fixed: `ATS_TOOL_GET_COLUMNS` injects exact INFORMATION_SCHEMA column list before each DDL generation; `CONFLICT_REDIRECTED` guard blocks additional hallucination class | v3 + v4 |
| JG-P1-2 | **Validator PK check guessing** — flagged `ORIGINAL_PRICE` as PK column; should read from `PLANNER_DECISIONS` | Validator inferred PK from column names rather than using Planner output | ✅ Fixed: `WORKFLOW_VALIDATOR` reads `pk_columns` from `PLANNER_DECISIONS` | v3 |
| JG-P1-3 | **`COLUMNS_DROPPED` warning is noisy** — Executor intentionally drops columns per directive; Validator flagged these as WARN | Validator had no context on intentional drops | ✅ Fixed: COLUMNS_DROPPED demoted from WARN to INFO | v3 |
| JG-P1-4 | **Brownfield mode missing** — skill assumes greenfield. When existing tables present, should default to validate/export, not build | Architecture designed for net-new only | ✅ Fixed: `brownfield_mode` flag in PIPELINE_CONTEXT; Executor skips existing Silver tables (logs as EXISTING, not failure) | v3 |
| JG-P1-5 | **Rewrite complex SPs as Python** — `VALIDATE_PARTNER` had 6-layer quote escaping, 200-line monolithic SP, no error handling, hardcoded database name, single-banner assumption | SQL Scripting limitations for dynamic SQL | ✅ Fixed: `VALIDATE_MULTI_BANNER` rewritten as Python SP. Gold Builder SPs also Python. SQL Scripting reserved for simpler CRUD | v3 + v4 |

#### P2 Findings — Nice to Have

| # | Finding | Resolution | Version |
|---|---------|-----------|---------|
| JG-P2-1 | Deployment rollback script — no cleanup if deploy fails midway | 🔲 Open — B-05 in backlog | — |
| JG-P2-2 | Hardcoded database name (`PETL_DEV`) in dynamic SQL | ✅ Fixed: uses `CURRENT_DATABASE()` and FQN throughout | v3 |
| JG-P2-3 | Duplicate-key INFO metric to SP output for monitoring drift | 🔶 Partial — WORKFLOW_LOG captures this per-table; no dedicated metric column surfaced in Streamlit | — |
| JG-P2-4 | Document SQL Scripting gotchas in SKILL.md | ✅ Done: documented in SKILL.md; Python SP pattern now default for complex logic | v3 |
| JG-P2-5 | Cost attribution per workflow run (tokens used, credits consumed) | ✅ Fixed: `CAPTURE_WORKFLOW_COST` SP + `WORKFLOW_COST_ATTRIBUTION` table + Observe tab cost section | v4 |
| JG-P2-6 | Staging table awareness — some Silver tables (e.g. Zehrs 97.6M) feed multiple Gold tables | ✅ Fixed: `PARTNER_BANNER_CONFIG` models this routing; Zehrs-style patterns supported via banner filter | v3 |

#### Deployment Issues Found

| Finding | Resolution | Version |
|---------|-----------|---------|
| `SETUP_ALL.sql` `!source` directives only work in SnowSQL CLI, not Snowsight | ✅ Fixed: step-by-step Snowsight instructions added | v3 |
| No idempotency on some objects — re-running fails if constraints exist | ✅ Fixed: `CREATE OR REPLACE` and `IF NOT EXISTS` throughout | v3 |
| `deploy.sh` doesn't validate parameters before starting | 🔶 Partial — validates connection; parameter validation improved but not exhaustive | — |
| No rollback mechanism — partial deploys leave orphaned schema | 🔲 Open — B-05 | — |

#### SQL Scripting Gotchas Documented by Jeremy

These patterns were documented and are now embedded in the codebase conventions:

- `EXECUTE IMMEDIATE ... INTO` not supported — must use RESULTSET + FOR loop
- `'row'` is a reserved keyword — use `'rec'` as iterator variable
- `VALUES` clause doesn't support expressions like `ARRAY_SIZE()` — pre-compute into variables
- Variable references in `INSERT...SELECT` need `:var` colon prefix — without it treated as column names
- Multiple `LET` cursor declarations in sequence fail — reuse a single RESULTSET variable

---

### Circle K NA Pipeline — SKILL_COMPARISON_REPORT (2026-06-25)

**Context:** Head-to-head comparison of custom Python pipeline vs `agentic-transformation-skill-v2` on the same PDI_ENT_LAVAL dataset (20 tables, NA_RAW → NA_CLEANSED). Dataset has non-standard enterprise column naming (`ITEMGRPMEMB_`, `ITEMMFGRTYPE_`, `RTLPKG_` prefixes).

**Report conclusion:** *"The approaches are complementary — custom Python wins on DDL precision and speed; the skill wins on intelligence, observability, and pipeline export capabilities. The optimal production design is a hybrid."*

#### Key Metrics from Head-to-Head Test

| Metric | Custom Python | Skill v2 | Current Status (v4) |
|--------|--------------|---------|---------------------|
| DDL accuracy (first run) | 100% (20/20) | 15% (3/20) | ✅ Resolved — GET_COLUMNS tool + column list injection → retries=0 on clean run |
| Execution time (full pipeline) | ~20 seconds | ~20 minutes | 🔲 Open — still ~20 min. Parallel execution (B-08) would address this |
| Schema evolution pass rate | 87% | 75% | 🔶 Partial — drift detection improved; backup-restore not in skill |
| FK relationships auto-discovered | 0 | 8 | ✅ Skill advantage confirmed and maintained in v4 |
| Learnings accumulated | 0 | 12 | ✅ Skill advantage — Cortex Search + WORKFLOW_LEARNINGS |
| Validation checks | 0 | 10 configurable | ✅ Maintained in v4 |
| Pipeline export formats | 3 (VIEW/CTAS/DT) | 4 + DCM | ✅ Maintained + expanded |
| Gold layer generation | ❌ | ✅ | ✅ Maintained |
| Cost per run | ~0.01 credits | ~0.5–2 credits | 🔶 Still ~0.5–2 — cost is fundamental to LLM-based DDL |
| Config version control | YAML/git | SQL tables | 🔲 Open — see CK-5 below |

#### Findings and Status

| ID | Finding | Resolution | Version |
|----|---------|-----------|---------|
| CK-1 | **DDL accuracy 15% first run** — `llama3.3-70b` generated training-pattern column names (`BOOLEAN_COL`, `BRAND_ID`, `STATE_ID`) instead of actual schema names for non-standard enterprise prefixes | ✅ Fixed: GET_COLUMNS tool injects exact INFORMATION_SCHEMA list; retries=0 on clean v4 run | v3 + v4 |
| CK-2 | **`TRY_CAST(NUMBER AS VARCHAR)` syntax error** — snow CLI rejected; fix was `TRY_TO_VARCHAR()` in recommendation. NOTE: `TRY_TO_VARCHAR()` does not exist in Snowflake either | ✅ Fixed: `TRY_TO_VARCHAR` blocked via HARD RULE in Executor prompt. Use `TO_VARCHAR(x)` | v4 |
| CK-3 | **CALENDAR row count 84% variance** — skill deduped on `DAY_DATE` (only 8 distinct in 50 test rows). Correct key is `CALENDAR_KEY` | ✅ Pattern: correct dedup key via directive. Directive-driven dedup is working mechanism | v3 |
| CK-4 | **VIEW output format not supported** — Python supports `--output-format VIEW` (live query, no data copy); skill only supports CTAS and Dynamic Table | 🔲 Open — VIEW format not in scope for v4. Would require Executor to generate `CREATE OR REPLACE VIEW` DDL instead of CTAS |  — |
| CK-5 | **Config version control** — Python YAML configs are git-trackable. Skill config lives in Snowflake SQL tables (not in source control without manual export) | 🔲 Open — DCM export partially addresses Gold objects. Full YAML-exportable config not implemented | — |
| CK-6 | **Schema evolution — backup-restore with cardinality mapping** — Python has `schema_evolution_backup_restore.py` for data-safe column renames (backup → alter → cardinality-map → restore). Skill has no equivalent | 🔲 Open — new backlog item B-15 | — |
| CK-7 | **Schema drift detection** — Python has `auto_schema_evolution.py` 6-stage pipeline (detect → auto-map → suggest → generate → deploy → report). Skill had `DETECT_SCHEMA_DRIFT` SP (compare Bronze INFORMATION_SCHEMA vs stored Silver DDL) | 🔶 Partial — schema change detection exists via INFORMATION_SCHEMA comparison. Full 6-stage evolution pipeline not implemented | — |
| CK-8 | **Performance gap** — 20 min for 20 tables vs 20 seconds. Cost ~0.5–2 credits vs ~0.01 | 🔲 Open — fundamental to LLM-based approach. Parallel execution (B-08) would reduce wall time. Hybrid architecture (Python for DDL, Skill for intelligence) is the recommended mitigation | — |
| CK-9 | **Hybrid architecture recommended** — "Use each where it excels: Python for DDL generation and schema evolution; Skill for FK discovery, validation, exports, DCM handoff, Gold analytics" | 🔶 Noted — `agt_` prefix files in Circle K project implement this hybrid. Not formalized as a supported ATS deployment pattern | — |
| CK-10 | **Cross-database operation** — Python reads any DB natively; Skill required manual TABLE_LINEAGE_MAP seeding for cross-DB Bronze | ✅ Fixed: BOOTSTRAP accepts comma-separated cross-DB sources; Validator uses EXECUTE IMMEDIATE for cross-DB INFORMATION_SCHEMA | v3 + v4 |

#### New Backlog Items from Comparison Report

| ID | Item | Priority | Source |
|----|------|----------|--------|
| B-15 | Schema evolution — backup-restore with cardinality mapping for renamed columns | Medium | CK-6 |
| B-16 | VIEW output format (live query over Bronze, no CTAS) | Low | CK-4 |
| B-17 | Git-trackable config export — YAML snapshot of SCHEMA_CONTRACTS + TRANSFORMATION_DIRECTIVES | Medium | CK-5 |
| B-18 | Hybrid deployment pattern — formalize Python-for-DDL + Skill-for-intelligence as a documented deployment option | Medium | CK-9 |

---

## What v5 Should Solve

Based on the backlog above, v5 should focus on three themes:

**1. Smarter Planning (B-01b, B-01c, B-06, B-11)**  
The Planner today sees Bronze + context text. v5 should give it: structured rules extracted from customer documents, column glossaries, existing Gold schemas, and decaying learnings that don't pollute newer runs with stale patterns.

**2. More Robust Execution (B-08, B-12, B-15)**  
Parallel table execution would cut run time materially for large schemas. Resume-from-phase would remove the operational pain of re-running 50-table sets because one table failed at phase 4. Schema evolution backup-restore (from Circle K review) would allow safe column rename handling.

**3. Richer Output Models (B-07a/b/c, B-14)**  
Star Schema and Data Vault are the two patterns enterprise customers actually deploy to production. Supporting them as first-class output modes — with structural enforcement, not just LLM hints — would significantly expand the addressable engagement scope.

**4. Hybrid Deployment Pattern (B-17, B-18)**  
The Circle K comparison proved that Python-for-DDL + Skill-for-intelligence is a viable production pattern. Formalizing this as a documented deployment option, with git-trackable config export, makes ATS usable for customers who already have deterministic DDL generation pipelines but want the SK intelligence layer (FK discovery, validation, learnings, exports).
