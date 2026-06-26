# ATS v3 — Full Feature Demo Walkthrough
**App URL:** https://app.snowflake.com/SFPSCOGS/ps_wls_demo_green/#/streamlit-apps/ATS_V3.AGENT_FRAMEWORK.AGENTIC_TRANSFORMATION_SKILL_V3
**Test Database:** `ATS_V3_TEST`
**Date:** June 2026

---

## Before You Start

This is the real-world pattern: framework DB (`ATS_V3`) is always separate from
Bronze data (`ATS_V3_TEST.BRONZE`). Bootstrap now handles cross-database discovery.

```sql
USE DATABASE ATS_V3;

-- Step 1: clear prior state
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');

-- Step 2: bootstrap pointing at the cross-database Bronze source
--   MY_DATA_DB.BRONZE  — fully-qualified (real customer pattern)
--   BRONZE             — plain schema name (same DB as framework — sandbox only)
--   DB1.BRONZE,DB2.RAW — comma-separated multi-source (LCL V2 pattern: 3 sources)
CALL AGENT_FRAMEWORK.BOOTSTRAP('ATS_V3_TEST.BRONZE');
```

Expected output:
```json
{ "sources_requested": ["ATS_V3_TEST.BRONZE"], "tables_discovered": 5,
  "tables_registered": 5, "model_validation": { "model": "llama3.3-70b" } }
```

In the **Streamlit Setup tab**, the Bootstrap input accepts the same format —
the placeholder shows `MY_DATA_DB.BRONZE  or  DB1.BRONZE,DB2.RAW`.

---

## TAB 1 — ⚙️ Setup

### 1a. Bootstrap status check
**What to verify:**
- Framework pill shows 🟢 Bootstrapped
- Model pill shows `llama3.3-70b` in green
- Foundation Table Coverage shows RENSPETS_PRODUCTS, DASHMART_PRODUCTS, LCL_PRODUCTS

**If not bootstrapped:** Enter `ATS_V3_TEST.BRONZE` in the Bronze Source(s) field → click **▶ Run Bootstrap**

Expected result:
```
Bootstrap complete. 5 tables registered. Model: llama3.3-70b
```

> **This input box is the real-world test.** A customer enters `THEIR_DATA_DB.BRONZE`
> — the framework database never needs to match the data database.

---

### 1b. Model Management (v3 P1 fix)
**What to test:** Switch model, validate, switch back
1. Use the dropdown — select `mistral-large2` → click **Validate & Set**
   - ✅ Confirm it validates and sets
2. Switch back to `llama3.3-70b` → **Validate & Set**
   - ✅ Confirm priority model restored
   - **Why this matters:** llama3.3-70b is the only model validated to generate
     clean DDL without backtick fences or COLUMN_NAME placeholders

---

### 1c. Cortex Intelligence (v3 NEW)
**What to verify:**
- Knowledge Search section shows status (empty on fresh run — expected, corpus populates after first workflow completes)
- Semantic View shows 🟢 `ATS_PIPELINE_SEMANTICS deployed`
- After running a workflow (step 5d), return here and test the search query:
  ```
  deduplicate product catalog transformation
  ```
  Expected: returns text from prior Planner decisions and learnings — NOT `No prior knowledge found.`

  **Verify directly with SQL:**
  ```sql
  -- Check corpus size after workflows complete
  SELECT source_type, COUNT(*) AS cnt
  FROM ATS_V3.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS
  GROUP BY source_type ORDER BY source_type;
  -- Expected: learning, planner_decision, schema_relationship rows

  CALL ATS_V3.AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE('product catalog transformation', 3);
  -- Expected: returns relevant prior decisions, NOT 'No prior knowledge found.'
  ```

---

### 1d. Reset Framework (v3 P0 fix — safe defaults)
**What to test:** Confirm two-step confirmation gate
1. Click **↺ Reset Framework**
   - ✅ Red warning appears: "This will drop SILVER and GOLD..."
2. Click **✗ Cancel**
   - ✅ Confirm it cancels cleanly (no reset occurred)
3. Click **↺ Reset Framework** → **✓ Confirm Reset**
   - ✅ Resets, then run Bootstrap again before continuing

---

## TAB 2 — 💡 Context

### 2a. Set Pipeline Context — Ren's Pets (Simple partner)
Fill in the form:

| Field | Value |
|-------|-------|
| Business Description | Pet specialty retailer selling branded pet food, supplies, and grooming products across Canada. Single virtual store, bilingual product catalogue. |
| Data Domain | Retail / Pet Supplies |
| Analytics Goals | Product performance by category and province, bilingual completeness rate, tax compliance by province, duplicate UPC detection |
| Constraints | Preserve all 19 source columns. Never drop UPC, TITLE, or IMAGES. Output must preserve OFFER_PRICE_DETAILS VARIANT structure. |
| Output Format | CTAS |
| Gold Output Model | FLAT |
| Output Schema | AGENT_FRAMEWORK_OUTPUT |
| Dry Run | ✅ ON (default) |
| Allow Overwrite | OFF |

Click **💾 Save Context**

**What to verify:**
- Status changes from yellow "Not configured" to green "Configured"
- Metrics row at bottom shows: `Output Schema = AGENT_FRAMEWORK_OUTPUT`, `Dry Run = ON`
- **Why this matters (P0 fix):** In v2, default was SILVER — would have overwritten production data

---

### 2b. Verify Output Safety banners
- With Dry Run ON → blue info box: *"Dry Run is ON — Executor will generate and log DDL..."*
- Toggle Dry Run OFF → green success: *"Dry Run is OFF — Executor will write to AGENT_FRAMEWORK_OUTPUT"*
- Enable Allow Overwrite with Dry Run OFF → amber warning appears
- Toggle Dry Run back ON → Allow Overwrite auto-disables (grayed out)
  - ✅ This is the v3 guard: can't set overwrite=TRUE while dry_run=TRUE

---

## TAB 3 — 📐 Contracts

### 3a. Review default contracts
- **Expected:** 19 contracts seeded (18 defaults + 1 Ren's Pets contract added in step 3b)
  ```sql
  SELECT COUNT(*) FROM ATS_V3.AGENT_FRAMEWORK.SCHEMA_CONTRACTS;
  -- Expected: 19
  SELECT rule_category, rule_name, is_active
  FROM ATS_V3.AGENT_FRAMEWORK.SCHEMA_CONTRACTS
  ORDER BY rule_category, rule_name;
  ```
- Toggle a contract OFF → **💾 Save Contract Changes** → toggle back ON → **💾 Save Contract Changes**
  - ✅ Confirms persistence — re-run the query above to verify `is_active` changed

### 3b. Add a partner-specific contract
Click **+ Add Contract**:

| Field | Value |
|-------|-------|
| Scope | partner |
| Category | column_preservation |
| Rule Name | renspets_preserve_images |
| Applies To | ENRICHED |
| Rule Value | NEVER drop or transform the IMAGES column. It contains a VARIANT array of bilingual image URLs (en + fr). Preserve as-is from Bronze. |
| Description | Ren's Pets bilingual image array must be preserved intact in Silver |

- ✅ Confirm it appears in the contracts list

---

## TAB 4 — 🎯 Directives

### 4a. Review default directives
- **Expected:** 22 directives (21 seeded defaults + 1 Ren's Pets directive added in step 4b)
  ```sql
  SELECT COUNT(*) FROM ATS_V3.AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES;
  -- Expected: 22
  SELECT source_table_pattern, use_case, priority, is_active
  FROM ATS_V3.AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
  ORDER BY priority DESC, source_table_pattern;
  ```

### 4b. Add a Ren's Pets-specific directive
Click **+ Add Directive**:

| Field | Value |
|-------|-------|
| Table Pattern | %RENSPETS% |
| Target Layer | SILVER |
| Use Case | composite_key_dedup |
| Priority | 1 |
| Instructions | This table has 19 products that share a UPC with another product (composite key duplicates). Do NOT deduplicate on UPC alone. Use PRODUCT_KEY as the unique identifier. The UPC duplication is intentional — distinct products sharing a barcode. |

- ✅ Confirm directive appears and priority=1

---

## TAB 5 — 🤖 Workflow (Core agentic pipeline)

### 5a. Run Agentic Workflow — with Schema Analyst approval gate
1. Ensure **"Auto-approve Schema Analyst relationships"** is **unchecked**
   - This causes the workflow to pause after Schema Analyst and show discovered FK relationships for review
2. Select table: `ATS_V3_TEST.BRONZE.RENSPETS_PRODUCTS` from the multiselect
3. Enter workflow name: `RENSPETS_DRY_RUN_01`
4. Click **▶ Run Agentic Workflow**
   - Phase 1 (Schema Analyst) runs and discovers FK relationships
   - Workflow **pauses** at the approval gate showing relationships grouped by confidence

5. Review the relationships — you don't need to know the data to interpret these:

   | Confidence | What it means | Action |
   |------------|--------------|--------|
   | ✅ **≥95%** | Highly likely a real FK — e.g. PROVINCE column matches a provinces lookup | Accept (do nothing) |
   | 🟡 **85–94%** | Probable but worth a glance — check if the column name makes sense as a join key | Accept unless it looks wrong |
   | 🔴 **<85%** | Weak signal — often a coincidental value match, not a real relationship | Remove these |

   **For RENSPETS_PRODUCTS specifically** — expected correct relationships:
   - `PROVINCE` → province reference ✅ keep
   - `CATEGORY` → category reference ✅ keep
   - `STORE_NUMBER` → store reference ✅ keep
   - Anything referencing `ORIGINAL_PRICE`, `SALE_PRICE`, `UPC`, or `TITLE` → 🗑 remove (not FK columns)

6. Click **✅ Approve & Continue to Planner**
   - Remaining phases run: Planner → Executor → Validator → Reflector

> **Demo tip:** For a live demo with an unfamiliar dataset, check "Auto-approve Schema
> Analyst relationships" to skip the gate entirely and keep the flow moving. The approval
> gate is most valuable when running against a customer's real production schema where
> incorrect FK joins would produce wrong Gold analytics.

---

### 5b. Run Agentic Workflow — Dry Run first (v3 P0 fix)

> **What dry run is for:** Reviewing the LLM-generated DDL before it executes.
> Did the LLM pick the right columns? Correct transformations? Sensible type casts?
> It has nothing to do with protecting SILVER — v3 never writes to SILVER at all.
> The output schema is `AGENT_FRAMEWORK_OUTPUT` by default.
>
> Three separate safety layers in v3:
> - **Output schema** → production SILVER/GOLD never touched (wrong schema entirely)
> - **Dry Run** → review generated DDL quality before execution
> - **Overwrite protection** → blocks execution if the output table already has rows
1. Click **▶ Run Workflow**
   - Workflow Name: `RENSPETS_DRY_RUN_01`
   - Tables: `ATS_V3_TEST.BRONZE.RENSPETS_PRODUCTS`
   - Model: `llama3.3-70b`
2. Watch the phase diagram: Schema Analyst → Planner → Executor → Validator → Reflector
3. When complete, check the **Executor result panel**:
   - ✅ Should show: *"DDL generated for 1 table — nothing written. Review in Observe tab."*
   - Status badge: `DRY_RUN_COMPLETE` in blue
   - **This is the P0 fix:** v2 would have written directly to SILVER

---

### 5c. Review DDL before executing
Go to **Tab 8 (Observe)** → Recent Workflow Log → find the `DRY_RUN` status row and read the generated DDL.

**What you CAN verify from the DDL:**
- ✅ All 19 source columns present (UPC, PRODUCT_KEY, TITLE, SIZE, UNIT_OF_MEASURE, ORIGINAL_PRICE, SALE_PRICE, PROVINCE, STORE_NUMBER, IS_TAXABLE, OFFER_PRICE_DETAILS fields, IMAGES, CATEGORY, TIMESTAMP, INTIME, _STAGE, PARTNER)
- ✅ `PRODUCT_KEY` appears as a column — the composite key directive was followed (LLM did not deduplicate on UPC alone)
- ✅ `IMAGES` appears in the SELECT — column was not dropped
- ✅ Output target is `AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS` — never SILVER or GOLD
- ✅ Source is `ATS_V3_TEST.BRONZE.RENSPETS_PRODUCTS` — cross-database query confirmed

**What you cannot verify from the DDL alone:**
- The IMAGES data type — a SELECT statement has no type declarations. To confirm it will land as VARIANT, run this after executing the live run:
```sql
SELECT COLUMN_NAME, DATA_TYPE
FROM ATS_V3.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
  AND TABLE_NAME   = 'RENSPETS_PRODUCTS'
  AND COLUMN_NAME  = 'IMAGES';
-- Expected: DATA_TYPE = VARIANT
```

Return to **Tab 5** → set **Dry Run OFF** in Context tab first (Tab 2), then:

---

### 5d. Run Agentic Workflow — Live execution
1. **Tab 2:** Toggle **Dry Run → OFF** → click **💾 Save Context**
2. **Tab 5:**
   - Check **"Auto-approve Schema Analyst relationships"** — single-table runs always return 0 relationships, so the gate adds no value here
   - Enter Workflow Name: `RENSPETS_LIVE_01`
   - Select table: `ATS_V3_TEST.BRONZE.RENSPETS_PRODUCTS`
   - Click **▶ Run Agentic Workflow**
3. When complete:
   - ✅ Executor: `Built 1/1 tables in AGENT_FRAMEWORK_OUTPUT as CTAS`
   - ✅ Validator: row counts match
   - ✅ Reflector: learnings captured

   **Verify with SQL:**
   ```sql
   -- Confirm output table exists with correct row count
   SELECT COUNT(*) AS silver_rows
   FROM ATS_V3.AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS;
   -- Expected: 5,709 (matches Bronze source exactly — no dedup, no valid_from column)

   -- Confirm IMAGES landed as VARIANT
   SELECT COLUMN_NAME, DATA_TYPE
   FROM ATS_V3.INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
     AND TABLE_NAME = 'RENSPETS_PRODUCTS'
     AND COLUMN_NAME = 'IMAGES';
   -- Expected: DATA_TYPE = VARIANT

   -- Confirm PRODUCT_KEY is present (composite key directive followed)
   SELECT COLUMN_NAME FROM ATS_V3.INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
     AND TABLE_NAME = 'RENSPETS_PRODUCTS'
     AND COLUMN_NAME = 'PRODUCT_KEY';
   -- Expected: 1 row returned
   ```

---

### 5e. Overwrite protection test (v3 P0 fix)
Run the same workflow again — the table already exists in `AGENT_FRAMEWORK_OUTPUT`:
1. Check **"Include already-processed tables"** — always visible in Tab 5
2. Select `ATS_V3_TEST.BRONZE.RENSPETS_PRODUCTS [done]` from the dropdown
3. Workflow Name: `RENSPETS_OVERWRITE_TEST`
4. Click **▶ Run Agentic Workflow**
   - ✅ Executor status: `ABORTED` with message *"AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS already exists with 5709 rows. Set overwrite_existing=>TRUE"*
   - **This is the P0 fix:** v2 would have silently overwritten

   **Verify with SQL:**
   ```sql
   SELECT phase, status, message
   FROM ATS_V3.AGENT_FRAMEWORK.WORKFLOW_LOG
   WHERE status = 'ABORTED'
   ORDER BY created_at DESC LIMIT 3;
   -- Expected: EXECUTOR | ABORTED | AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS already exists with 5709 rows...
   ```
5. Now test overwrite allowed: **Tab 2** → Allow Overwrite **ON** → **💾 Save Context** → return to **Tab 5** → re-run
   - ✅ Table rebuilt successfully

---

### 5f. Run workflow for DashMart Canada (Medium partner)
1. **Tab 2:** Update all four context fields for the new partner:
   - Business Description: *Canadian grocery delivery service. Products have inline tax rates per province. French product names for QC market only.*
   - Data Domain: *Retail / Grocery Delivery*
   - Analytics Goals: *Provincial tax compliance reporting, bilingual product completeness (QC), store-level product availability, duplicate UPC identification across stores.*
   - Constraints: *Preserve NAME_FR (NULL for non-QC rows is intentional). IS_TAXABLE is a computed boolean — do not re-derive it.*
   - Gold Output Model: **FLAT**
   - Turn **Allow Overwrite → OFF** (was left ON from step 5e)
   - Click **💾 Save Context** — Dry Run stays OFF, Output Schema stays `AGENT_FRAMEWORK_OUTPUT`
2. **Tab 5:**
   - Workflow Name: `DASHMART_LIVE_01`
   - Select: `ATS_V3_TEST.BRONZE.DASHMART_PRODUCTS`
   - Click **▶ Run Agentic Workflow**
3. Verify the output table was created and contains the right columns:

   **Option A — Tab 8 (Observe)** → Recent Workflow Log → find the `COMPLETE` entry for `DASHMART_LIVE_01` → read the executor message for column confirmation

   **Option B — SQL** (most reliable):
   ```sql
   -- Confirm the key columns exist
   SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
   FROM ATS_V3.INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT'
     AND TABLE_NAME   = 'DASHMART_PRODUCTS'
     AND COLUMN_NAME  IN ('GST_HST_TAX_RATE','PST_QST_TAX_RATE','NAME_FR','IS_TAXABLE')
   ORDER BY COLUMN_NAME;
   ```
   Expected — 4 rows:
   | COLUMN_NAME | DATA_TYPE | IS_NULLABLE |
   |-------------|-----------|-------------|
   | GST_HST_TAX_RATE | FLOAT or NUMBER | YES |
   | IS_TAXABLE | BOOLEAN | YES |
   | NAME_FR | TEXT | YES |
   | PST_QST_TAX_RATE | FLOAT or NUMBER | YES |

   ```sql
   -- Confirm NAME_FR is NULL for non-QC rows (not dropped, not defaulted)
   SELECT PROVINCE,
          COUNT(*)                                          AS total_rows,
          SUM(CASE WHEN NAME_FR IS NULL THEN 1 ELSE 0 END) AS null_name_fr,
          SUM(CASE WHEN NAME_FR IS NOT NULL THEN 1 ELSE 0 END) AS populated_name_fr
   FROM ATS_V3.AGENT_FRAMEWORK_OUTPUT.DASHMART_PRODUCTS
   GROUP BY PROVINCE ORDER BY PROVINCE;
   ```
   Expected:
   | PROVINCE | TOTAL_ROWS | NULL_NAME_FR | POPULATED_NAME_FR |
   |----------|-----------|--------------|-------------------|
   | AB | 3,640 | 3,640 | 0 |
   | BC | 3,640 | 3,640 | 0 |
   | MB | 3,640 | 3,640 | 0 |
   | ON | 3,640 | 3,640 | 0 |
   | QC | 3,640 | 0 | 3,640 |

   ```sql
   -- Confirm IS_TAXABLE was preserved, not re-derived
   SELECT IS_TAXABLE, COUNT(*) AS cnt, ROUND(COUNT(*)*100.0/(SELECT COUNT(*) FROM ATS_V3.AGENT_FRAMEWORK_OUTPUT.DASHMART_PRODUCTS),1) AS pct
   FROM ATS_V3.AGENT_FRAMEWORK_OUTPUT.DASHMART_PRODUCTS
   GROUP BY IS_TAXABLE;
   ```
   Expected:
   | IS_TAXABLE | CNT | PCT |
   |------------|-----|-----|
   | TRUE | 11,648 | 64.0% |
   | FALSE | 6,552 | 36.0% |

---

## TAB 6 — 🏆 Analytics Builder (Gold Layer)

### 6a. Propose and Execute Gold DDLs
At this point both Ren's Pets and DashMart have `silver_status = COMPLETE` and `gold_status = PENDING`, so both appear in `GOLD_GAPS`. The tab will show **2 Enriched tables without Analytics coverage**.

1. Set **Max tables to propose** slider to `2`
2. Click **🤖 Propose Analytics DDLs**
   - Calls `BUILD_GOLD_FOR_NEW_TABLES(TRUE, 2)` — the `TRUE` is the Gold Builder's own dry-run flag, independent of Pipeline Context
   - Agent generates DDL proposals for both Ren's Pets and DashMart Silver outputs
3. Two proposals appear — review each:
   - **Ren's Pets proposal:** expect a product or category aggregation (province × category performance, bilingual completeness, tax summary)
   - **DashMart proposal:** expect a tax compliance or store analytics table (GST/HST by province, IS_TAXABLE distribution, NAME_FR completeness by store)
4. Click **⚡ Execute All DDLs** to build both in one action
   - ✅ Two Gold tables created in `ATS_V3.GOLD` schema

> **Note on table names:** The LLM generates table names — they will be descriptive but not
> predictable. Review the DDL content to verify correctness, not the name.

**Verify with SQL:**
```sql
-- Confirm both Gold tables were created
SELECT TABLE_NAME, ROW_COUNT, CREATED
FROM ATS_V3.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'GOLD'
ORDER BY CREATED DESC LIMIT 5;
-- Expected: 2 new tables with > 0 rows

-- Confirm lineage map updated for both
SELECT bronze_table, silver_status, gold_status
FROM ATS_V3.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
WHERE bronze_table IN ('RENSPETS_PRODUCTS', 'DASHMART_PRODUCTS')
ORDER BY bronze_table;
```
Expected:
| BRONZE_TABLE | SILVER_STATUS | GOLD_STATUS |
|---|---|---|
| DASHMART_PRODUCTS | COMPLETE | COMPLETE |
| RENSPETS_PRODUCTS | COMPLETE | COMPLETE |

---

## TAB 7 — 🗂️ Registry

### 7a. Pipeline Flow
- Verify lineage: `RENSPETS_PRODUCTS (Bronze)` → `RENSPETS_PRODUCTS (Silver)` → Gold table (COMPLETE)
- Check that `DASHMART_PRODUCTS` also appears with Silver status COMPLETE

   **Verify with SQL:**
   ```sql
   SELECT bronze_table, bronze_database, silver_status, gold_status,
          silver_table, gold_table
   FROM ATS_V3.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
   ORDER BY bronze_table;
   ```
   Expected after completing steps 5d, 5f, and 6a:
   | BRONZE_TABLE | SILVER_STATUS | GOLD_STATUS |
   |---|---|---|
   | DASHMART_PRODUCTS | COMPLETE | PENDING |
   | LCL_PRODUCTS | PENDING | PENDING |
   | MARKETBASKET_PRODUCTS | PENDING | PENDING |
   | RENSPETS_PRODUCTS | COMPLETE | COMPLETE |
   | SIMPLEMART_PRODUCTS | PENDING | PENDING |

### 7b. Discovered Relationships
- FK relationships are stored per execution — use the execution selector on the right column
- Note: single-table runs return 0 relationships (correct behaviour — nothing to compare against)
- Multi-table runs will show cross-table FKs

   **Verify with SQL:**
   ```sql
   SELECT source_table, source_column, target_table, target_column,
          relationship_type, ROUND(confidence*100) AS confidence_pct
   FROM ATS_V3.AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
   ORDER BY confidence_pct DESC;
   -- Expected: 0 rows for single-table runs (Ren's Pets, DashMart)
   -- Non-zero rows if multi-table workflow was run
   ```

---

## TAB 8 — 📊 Observe

### 8a. Execution metrics
After completing steps 5b–5f, expected values:

   ```sql
   USE DATABASE ATS_V3;
   SELECT
       (SELECT COUNT(*) FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS)              AS total_runs,
       (SELECT COUNT(*) FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
        WHERE silver_status='COMPLETE')                                        AS enriched_tables,
       (SELECT COUNT(*) FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
        WHERE gold_status='COMPLETE')                                          AS analytics_tables,
       (SELECT COUNT(*) FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
        WHERE is_active=TRUE)                                                  AS active_learnings;
   ```
   Expected:
   | TOTAL_RUNS | ENRICHED_TABLES | ANALYTICS_TABLES | ACTIVE_LEARNINGS |
   |---|---|---|---|
   | ≥ 4 (dry run + live + overwrite test + dashmart) | 2 (Ren's Pets + DashMart) | 1 (Ren's Pets Gold) | > 0 |

### 8b. Workflow log color-coding (v3 NEW)
In Recent Workflow Log, verify:
- 🔵 Blue rows = `DRY_RUN` entries (DDL generated, not executed)
- 🟡 Yellow/bold rows = `ABORTED` entries (overwrite protection triggered)
- 🔴 Red rows = any `FAILED` entries
- 🟢 Green rows = `PASS` entries
- Summary counts below the table: *"X DRY_RUN entries", "Y ABORTED entries"*

### 8c. Promote a Learning (v3 NEW)
1. In Active Learnings table, find a high-confidence learning
2. Use **Promote a Learning** section → select it
3. Choose **📋 Schema Contract** → fill in fields → **✅ Promote**
   - ✅ Go to Tab 3 — new contract appears
4. Return, select another learning → promote as **🎯 Directive**
   - ✅ Go to Tab 4 — new directive appears

---

## TAB 9 — 🏷️ Partner Routing (v3 NEW)

### What is Partner Routing validation?

**The business problem:** Some partners have one Silver staging table that needs to fan out into multiple Gold tables based on a dimension value — a store banner, region, store format, product line, content type, etc.

This pattern appears across industries:

| Industry | Routing dimension | Example |
|----------|------------------|---------|
| Grocery | Store banner | LCL V2 — 14 banners → 13 Gold tables |
| Retail | Store format | MarketBasket — Express/Standard/Premium → 3 Gold tables ✅ *in our test data* |
| Media | Content type | Product categories → separate analytics tables |
| Financial | Product line | Segments → separate reporting tables |
| CPG | Distribution channel | Retail/DTC/Wholesale → channel Gold tables |

**What VALIDATE_PARTNER_ROUTING does:** For each configured routing rule, it:
1. Counts rows in Silver filtered by the routing value (e.g. `WHERE BANNER = 'superstore'`)
2. Applies exclusion filters (e.g. remove Ancillary, Liquor)
3. Counts rows in the target Gold table
4. Compares and reports PASS / FAIL / SKIP per rule

**What `PARTNER_ROUTING_CONFIG` (formerly PARTNER_BANNER_CONFIG) stores:**

| Column | Purpose |
|--------|---------|
| `partner_name` | Any label — `LCL`, `MARKETBASKET`, `ACME_RETAIL` |
| `banner_value` | The routing dimension value — `superstore`, `express`, `north_region` |
| `banner_column` | Column name in Silver to filter on — `BANNER`, `STORE_FORMAT`, `REGION` |
| `silver_table` | Fully-qualified Silver table FQN |
| `gold_table` | Target Gold table FQN (NULL = skip this rule) |
| `excluded_categories` | Comma-separated category values excluded from Gold by design |
| `merge_into_banner` | Routes this value's rows into another rule's Gold table |
| `upc_threshold_pct` | Acceptable % of non-standard UPCs |

> Tab 9 has two **horizontal sub-tabs** at the top: **⚙️ Banner Config** and **✅ Validate**.
> All steps use these sub-tabs, not the main navigation.

### 9a. Simple example — MarketBasket store formats
Our test data already has a 3-format routing pattern built. Use this to demonstrate the concept before LCL's complexity.

In the **⚙️ Banner Config** sub-tab → **Add Banner Entry**:

| Field | Value |
|-------|-------|
| Partner Name | MARKETBASKET |
| Routing Value | express |
| Silver Table | ATS_V3_TEST.SILVER.MARKETBASKET_PRODUCTS_SILVER |
| Gold Table | ATS_V3_TEST.GOLD.MARKETBASKET_EXPRESS |
| Banner Column | BANNER |
| Excluded Categories | Ancillary |

Repeat for `standard` → `MARKETBASKET_STANDARD` and `premium` → `MARKETBASKET_PREMIUM` (same Banner Column and Excluded Categories).

Then switch to **✅ Validate**, select **MARKETBASKET**, Database: `ATS_V3_TEST`, click **▶ Validate**

Expected:
| Rule | Status | Silver Rows | Excluded Rows | Gold Rows |
|------|--------|-------------|---------------|-----------|
| express | ✅ PASS | 13,267 | 1,895 | 11,372 |
| standard | ✅ PASS | 13,267 | 1,896 | 11,371 |
| premium | ✅ PASS | 13,266 | 1,895 | 11,371 |

---

### 9b. Seed LCL V2 complex example config
The routing config is not auto-populated at Bootstrap — it must be configured for each partner. The LCL example demonstrates all advanced features: 14 rules, merge targets, exclusion filters, and a null-Gold-table SKIP rule.

In the **⚙️ Banner Config** sub-tab, scroll to **"Seed Grocery Example Config"**:
1. Silver Schema: `ATS_V3_TEST.SILVER`
2. Gold Schema: `ATS_V3_TEST.GOLD`
3. Click **🌱 Seed Example**
   - ✅ *"Seeded 14 banner config rows for LCL."*

After seeding, the config table should show 14 LCL rows.

**Verify with SQL:**
```sql
SELECT partner_name, banner_value, silver_table, gold_table,
       excluded_categories, merge_into_banner
FROM ATS_V3.AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
WHERE partner_name = 'LCL'
ORDER BY config_id;
-- Expected: 14 rows
```

### 9c. Review the LCL routing rules
In the **⚙️ Banner Config** sub-tab, confirm the table shows:
- `independentcitymarket` → merge_into_banner = `independent` ✅
- `your ind grocer` → gold_table = NULL ✅
- All 12 other banners → excluded_categories = `Ancillary,Liquor` ✅

### 9d. Add a manual routing entry
Test the Add Banner Entry form:

| Field | Value |
|-------|-------|
| Partner Name | RENSPETS |
| Banner Value | all |
| Silver Table | ATS_V3_TEST.SILVER.RENSPETS_PRODUCTS_SILVER |
| Gold Table | ATS_V3_TEST.GOLD.RENSPETS_GOLD |
| Banner Column | (leave blank — single-banner) |
| Excluded Categories | (none) |

- ✅ Confirm row added to the table

### 9e. Validate LCL V2 routing
This is the test that was completely impossible in v2. Switch to the **✅ Validate** sub-tab:
1. Select partner: **LCL**
2. **Database (optional):** `ATS_V3_TEST` — required here because our Silver and Gold tables are in a different database than the framework
3. Click **▶ Validate Banners**

Expected results (all 14 banners):

| Banner | Status | Silver Rows | Merged Rows | Gold Rows | Variance |
|--------|--------|-------------|-------------|-----------|----------|
| dominion | ✅ PASS | 3,463 | 0 | 3,463 | 0% |
| fortinos | ✅ PASS | 3,117 | 0 | 3,117 | 0% |
| independent | ✅ PASS | 3,464 | 3,116 (ICM) | 6,580 | 0% |
| loblaws | ✅ PASS | 3,117 | 0 | 3,117 | 0% |
| maxi | ✅ PASS | 3,118 | 0 | 3,118 | 0% |
| nofrills | ✅ PASS | 3,463 | 0 | 3,463 | 0% |
| provigo | ✅ PASS | 3,116 | 0 | 3,116 | 0% |
| rass | ✅ PASS | 3,118 | 0 | 3,118 | 0% |
| superstore | ✅ PASS | 3,116 | 0 | 3,116 | 0% |
| valumart | ✅ PASS | 3,463 | 0 | 3,463 | 0% |
| wholesaleclub | ✅ PASS | 3,463 | 0 | 3,463 | 0% |
| zehrs | ✅ PASS | 3,463 | 0 | 3,463 | 0% |
| independentcitymarket | ⏭️ SKIPPED | — | — | — | merges → independent |
| your ind grocer | ⏭️ SKIPPED | — | — | — | gold_table = NULL |

- Overall: **`VALIDATED — 12/14 passed, 2 skipped`**

> **Note on 0% variance:** In our test data, the Gold tables were built directly from Silver
> after exclusion filters were applied, so Silver and Gold match exactly. In a real LCL V2
> deployment, the Silver staging table contains ALL categories including Ancillary and Liquor,
> so Gold < Silver would be expected and the SP accounts for this via `excluded_categories`.

**Why this matters:** In v2, this entire scenario was impossible — single-banner architecture blocked LCL (Canada's largest grocer) entirely.

---

## TAB 10 — 📦 DCM Export

### 10a. Generate DCM project

**Pre-flight check:** Tab opens showing two metrics — confirm before proceeding:
- **Silver Tables: 2** (Ren's Pets + DashMart enriched in `AGENT_FRAMEWORK_OUTPUT`)
- **Gold Tables: 2** (Ren's Pets + DashMart Gold from Tab 6)

Leave all defaults as-is:

| Field | Default | Why |
|-------|---------|-----|
| Project Name | `adf_pipeline` | Used as the DCM project identifier |
| Data Engineer Role | `DATA_ENGINEER_ROLE` | Role granted MODIFY on Silver/Gold |
| Analyst Role | `ANALYST_ROLE` | Role granted SELECT on Gold |

Click **⚡ Generate DCM Project**

Expected success message:
```
Generated 6 files — 2 Silver, 2 Gold tables.
```

### 10b. Review generated files

Three file tabs appear — review each:

| File | What to verify |
|------|---------------|
| `manifest.yml` | `DEFINE TABLE` entries for each Silver and Gold table; `version:` block present |
| `setup.sql` | `CREATE OR REPLACE TABLE` statements with correct schemas (`AGENT_FRAMEWORK_OUTPUT`, `GOLD`) |
| `teardown.sql` | `DROP TABLE IF EXISTS` statements matching the setup tables |

Each file tab has a **⬇ Download** button for individual file download.

### 10c. Verify and download

**Verify with SQL** (confirms the SP read the correct tables):
```sql
-- Confirm lineage map has the 2 Silver + 1 Gold the DCM project was built from
SELECT bronze_table, silver_status, gold_status, silver_table, gold_table
FROM ATS_V3.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP
WHERE silver_status = 'COMPLETE'
ORDER BY bronze_table;
-- Expected: DASHMART_PRODUCTS (silver COMPLETE, gold COMPLETE), RENSPETS_PRODUCTS (silver COMPLETE, gold COMPLETE)
```

**Deploy instructions** appear below the files:
```bash
# 1. Download project files from stage
snow stage get @AGENT_FRAMEWORK.DCM_OUTPUT ./dcm_project -c <connection>

# 2. Register & deploy
snow dcm deploy ./dcm_project
```

> **Why this matters:** The customer's DE team takes the downloaded project, commits it to git, and deploys with `snow dcm deploy` — no manual DDL, fully versioned, role-based access pre-configured.

---

## Cross-Tab Verification Checks

After completing the above, verify these cross-cutting outcomes:

```sql
USE DATABASE ATS_V3;

-- 1. Learnings accumulated (Cortex Search will use these)
SELECT learning_type, COUNT(*) AS cnt
FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
WHERE is_active = TRUE GROUP BY 1 ORDER BY cnt DESC;
-- Expected: rows for SUCCESS_PATTERN, FAILURE_PATTERN, OPTIMIZATION types

-- 2. Planner decisions recorded with correct strategies
SELECT source_table, transformation_strategy, pk_columns, confidence_score
FROM AGENT_FRAMEWORK.PLANNER_DECISIONS ORDER BY created_at DESC;
-- Expected: RENSPETS_PRODUCTS → deduplicate (or ctas), DASHMART_PRODUCTS → deduplicate

-- 3. Overwrite protection fired correctly
SELECT phase, status, LEFT(message,120) AS msg
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status = 'ABORTED' ORDER BY created_at DESC LIMIT 5;
-- Expected: AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS already exists with 5709 rows...

-- 4. DRY_RUN entries (Ren's Pets dry run)
SELECT phase, status, LEFT(message,120) AS ddl_preview
FROM AGENT_FRAMEWORK.WORKFLOW_LOG
WHERE status = 'DRY_RUN' ORDER BY created_at DESC LIMIT 5;
-- Expected: [DRY RUN] AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS — DDL generated...

-- 5. Cortex Search corpus populated
SELECT source_type, COUNT(*) AS cnt
FROM ATS_V3.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS
GROUP BY source_type ORDER BY source_type;
-- Expected: learning (n rows), planner_decision (n rows)
-- schema_relationship rows only appear after multi-table workflow runs

-- 6. Test Cortex Search end-to-end
CALL ATS_V3.AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE('deduplicate renspets product key', 3);
-- Expected: returns text describing transformation decisions for RENSPETS or similar tables
-- Should NOT return 'No prior knowledge found.' after at least 1 completed run
```

---

## v3 Fix Coverage

| Issue | Test Step | v3 Fix Verified |
|-------|-----------|-----------------|
| Production data overwritten by default | Tab 5d–5e | Output schema = AGENT_FRAMEWORK_OUTPUT, ABORTED on overwrite |
| No dry-run mode | Tab 5b–5c | DRY_RUN_COMPLETE status, DDL in log, nothing executed |
| No existence check before CTAS | Tab 5e | ABORTED with row count in message |
| Multi-banner partners not supported | Tab 9e | LCL 14-rule routing validation passes |
| Gold filter accounting (Gold < Silver valid) | Tab 9e | excluded_categories handled, no false FAIL |
| Column hallucination (INGEST_DATE etc.) | Tab 5d | INFORMATION_SCHEMA column injection prevents hallucination |
| Validator PK check using wrong column | Tab 8b | pk_columns from PLANNER_DECISIONS, not guessed |
| Partner routing quote-escape errors | Tab 9e | Python SP — f-strings, isolated try/except per rule |
