# ATS v3 Testing Guide

This guide walks an SA through deploying and testing ATS v3 from scratch using the MarketBasket test dataset.
**Estimated time: ~25 minutes.**

> **Tested on:** CoCo-Green (SFPSCOGS-PS_WLS_DEMO_GREEN, AWS US West 2) using `llama3.3-70b`.

---

## Prerequisites

- Snowflake account with Cortex enabled
- `ACCOUNTADMIN` or equivalent (CREATE DATABASE, CREATE SCHEMA, CREATE PROCEDURE, EXECUTE CORTEX)
- Snow CLI installed — verify with `snow --version`
- ATS v3 files at: `~/Dev/coco/agentic-transformation-skill-v3/`

---

## Step 1: Create Test Database and Deploy Framework

```bash
# Create the test database
snow sql -c <your-connection> -q "CREATE DATABASE IF NOT EXISTS MARKETBASKET_TEST"

# Deploy the framework using deploy.sh (handles all 00-09 files in correct order)
cd ~/Dev/coco/agentic-transformation-skill-v3

bash setup/deploy.sh \
  --connection <your-connection> \
  --database   MARKETBASKET_TEST \
  --bronze-schema BRONZE
```

Expected output: each file prints `✓  <filename> complete` followed by a BOOTSTRAP JSON result showing `status: SUCCESS`.

### Deploy Streamlit App

```bash
cd ~/Dev/coco/agentic-transformation-skill-v3/app

snow streamlit deploy -c <your-connection> --replace
```

### Verify Deploy

```sql
USE DATABASE MARKETBASKET_TEST;

SELECT 'PROCEDURES' AS type, COUNT(*) AS n FROM INFORMATION_SCHEMA.PROCEDURES WHERE procedure_schema = 'AGENT_FRAMEWORK'
UNION ALL SELECT 'FUNCTIONS',  COUNT(*) FROM INFORMATION_SCHEMA.FUNCTIONS  WHERE function_schema  = 'AGENT_FRAMEWORK'
UNION ALL SELECT 'TABLES',     COUNT(*) FROM INFORMATION_SCHEMA.TABLES     WHERE table_schema     = 'AGENT_FRAMEWORK' AND table_type = 'BASE TABLE';
-- Expected: PROCEDURES >= 18, FUNCTIONS >= 9, TABLES >= 10
```

---

## Step 2: Select the Right Model

**Critical:** Bootstrap auto-selects the first available model. On most accounts, `llama3.3-70b` produces the cleanest DDL. Force it explicitly:

```sql
USE DATABASE MARKETBASKET_TEST;
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('llama3.3-70b');
-- Expected: {"status": "SUCCESS", "model": "llama3.3-70b", ...}
```

> If `llama3.3-70b` returns FAILED (not available on this account), run `CALL AGENT_FRAMEWORK.VALIDATE_MODEL(NULL)` to auto-select and note which model was chosen.

---

## Step 3: Load Test Data

```bash
snow sql -c <your-connection> -f demo/test_v3_data.sql
```

**Expected final SELECT:**

| Table | Rows |
|-------|------|
| BRONZE.SIMPLEMART_PRODUCTS | 5,000 |
| BRONZE.MARKETBASKET_PRODUCTS | 40,000 |
| SILVER.MARKETBASKET_PRODUCTS_SILVER | ~39,800 |
| GOLD.MARKETBASKET_STANDARD | ~11,200 |
| GOLD.MARKETBASKET_EXPRESS | ~11,200 |
| GOLD.MARKETBASKET_PREMIUM | ~11,200 |

> Pre-built Silver and Gold tables simulate an existing production environment for overwrite-protection testing.

---

## Step 4: Run Test Scenarios

Open `demo/test_v3_scenarios.sql` in Snowsight and run each section individually.

> **Tip:** Use Snowsight "Run Selected" to execute one block at a time and inspect results between sections.

---

## Test Scenarios and Pass Criteria

### T-01: Deploy & Bootstrap Verification

| Check | Pass Condition |
|-------|----------------|
| Framework SPs deployed | PROCEDURES ≥ 18 |
| Framework functions deployed | FUNCTIONS ≥ 9 |
| `RESET_FRAMEWORK` SP exists | Returns `status=RESET` — was missing in v2 |
| Bootstrap discovers Bronze tables | `bronze_tables = 2` in BOOTSTRAP result |
| Model is `llama3.3-70b` | `SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG` |

---

### T-02: Dry Run Mode (P0-2)

| Check | Pass Condition |
|-------|----------------|
| Workflow returns `DRY_RUN_COMPLETE` | Check `executor.status` in workflow result |
| `AGENT_FRAMEWORK_OUTPUT` empty | `tables_in_output = 0` |
| `WORKFLOW_LOG` has `DRY_RUN` entries | Rows with `status = 'DRY_RUN'` and `[DRY RUN]` prefix |
| Generated DDL uses real column names | DDL contains `PRODUCT_ID`, `SKU`, `PRODUCT_NAME`, etc. — **not** `COLUMN_NAME` |

**What to look for in the log:**
```
[DRY RUN] AGENT_FRAMEWORK_OUTPUT.SIMPLEMART_PRODUCTS — DDL generated, NOT executed.
CREATE OR REPLACE TABLE AGENT_FRAMEWORK_OUTPUT.SIMPLEMART_PRODUCTS AS
SELECT
  PRODUCT_ID,
  SKU,
  PRODUCT_NAME,
  ...
FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY PRODUCT_ID ORDER BY UPDATED_DATE DESC) AS RN
      FROM MARKETBASKET_TEST.BRONZE.SIMPLEMART_PRODUCTS
      WHERE IS_DELETED = FALSE) T
WHERE RN = 1
```

> **If the DDL contains `COLUMN_NAME` or `COLUMN1` as column references:** The column list lookup failed. Check that the Bronze table exists and that `TABLE_LINEAGE_MAP` has the correct `bronze_database` value. See Troubleshooting below.

---

### T-03: Safe Output Schema (P0-1)

| Check | Pass Condition |
|-------|----------------|
| Table created in `AGENT_FRAMEWORK_OUTPUT` | Table exists with `ROW_COUNT > 0` |
| No SIMPLEMART table in `SILVER` | `silver_tables = 0` |
| Lineage map updated | `silver_schema = 'AGENT_FRAMEWORK_OUTPUT'`, `silver_status = 'COMPLETE'` |
| Execution status | `executor.status = 'EXECUTED'`, `built = 1` |

---

### T-04: Overwrite Protection (P0-1)

| Check | Pass Condition |
|-------|----------------|
| `ABORTED` log entry exists | `status = 'ABORTED'` in `WORKFLOW_LOG` |
| Message contains row count | `...already exists with 39,8XX rows. Set overwrite_existing=>TRUE...` |
| Original Silver table intact | `COUNT(*) ≈ 39,800` |
| Guard rejects ambiguous config | `SET_PIPELINE_CONTEXT(p_overwrite_existing=>TRUE, p_dry_run=>TRUE)` returns ERROR |

> **How it works:** The executor derives the target table name from the Bronze source name (`MARKETBASKET_PRODUCTS`). It checks `AGENT_FRAMEWORK_OUTPUT.MARKETBASKET_PRODUCTS` for existing rows before generating DDL. If rows exist and `overwrite_existing=FALSE`, it logs ABORTED and skips to the next table — the LLM is never called.

---

### T-05: Column Injection / Hallucination Prevention (P0-3)

| Check | Pass Condition |
|-------|----------------|
| DRY_RUN log contains real column names | `PRODUCT_ID`, `SKU`, `PRODUCT_NAME`, `CATEGORY`, `PRICE`, etc. |
| No invented columns | No `INGEST_DATE`, `COLUMN_NAME`, `COLUMN1`, `OTHER_COLUMNS` |

**Verify against actual schema:**
```sql
SELECT column_name, data_type
FROM MARKETBASKET_TEST.INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'BRONZE' AND table_name = 'SIMPLEMART_PRODUCTS'
ORDER BY ordinal_position;
```
Every column referenced in the DRY_RUN DDL must appear in this list.

---

### T-06: Multi-Banner Validation — Python SP (P0-4)

| Check | Pass Condition |
|-------|----------------|
| 3 banner configs seeded | `COUNT(*) = 3` in `PARTNER_BANNER_CONFIG` for MARKETBASKET |
| `VALIDATE_MULTI_BANNER` returns `VALIDATED` | `status = 'VALIDATED'`, `fail_count = 0` |
| Per-banner variance ≤ 1% | `variance_pct < 1.0` for all 3 banners |
| Exclusion accounting correct | `excluded_rows ≈ 1/7 of silver_rows` (Ancillary category = 1 of 7 categories) |
| `expected_gold = silver_rows - excluded_rows` | Not `silver_rows = gold_rows` |

**Sample expected result:**
```json
{
  "partner": "MARKETBASKET",
  "status": "VALIDATED",
  "total_banners": 3,
  "pass_count": 3,
  "fail_count": 0,
  "results": [
    { "banner": "express",  "silver_rows": 13267, "excluded_rows": 1895,
      "expected_gold": 11372, "gold_rows": 11372, "variance_pct": 0.0, "status": "PASS" },
    { "banner": "premium",  "silver_rows": 13267, "excluded_rows": 1895,
      "expected_gold": 11372, "gold_rows": 11371, "variance_pct": 0.01, "status": "PASS" },
    { "banner": "standard", "silver_rows": 13266, "excluded_rows": 1895,
      "expected_gold": 11371, "gold_rows": 11371, "variance_pct": 0.0, "status": "PASS" }
  ]
}
```

---

### T-07: Validator PK Check (P0-5)

| Check | Pass Condition |
|-------|----------------|
| `pk_columns` in PLANNER_DECISIONS | Not NULL, references actual PK column (e.g. `PRODUCT_ID`) |
| Validator result includes `pk_columns` | Present in `validator_output:results[0]:pk_columns` |

```sql
SELECT source_table, pk_columns, transformation_strategy
FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
ORDER BY priority;

SELECT value:pk_columns::VARCHAR AS pk_cols, value:passed::BOOLEAN AS passed
FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS,
     LATERAL FLATTEN(input => validator_output:results)
ORDER BY pk_cols;
```

---

### T-08: Final Pass/Fail Summary

Run the T-08 block in `test_v3_scenarios.sql`. Expected:

```
P0-2 Dry Run: AGENT_FRAMEWORK_OUTPUT empty after dry run     → PASS
P0-1 Safe Schema: SIMPLEMART in AGENT_FRAMEWORK_OUTPUT       → PASS
P0-1 Overwrite: ABORTED log entry exists                     → PASS
P0-1 Overwrite: Silver row count preserved at ~39800         → PASS
P0-3 Columns: DRY_RUN log entries exist                      → PASS
P0-4 Multi-Banner: 3 banners seeded                          → PASS
P0-5 PK Check: pk_columns populated                         → PASS or NEEDS_FULL_RUN
```

---

## Troubleshooting

### Generated DDL contains `COLUMN_NAME`, `COLUMN1`, or placeholder text
The column list lookup returned empty. Two causes:
1. **Bronze table doesn't exist** — verify `test_v3_data.sql` ran successfully
2. **Framework and Bronze are in different databases** — the executor queries `INFORMATION_SCHEMA` of the framework database. If your Bronze tables are in another database, seed `TABLE_LINEAGE_MAP` manually and ensure the `bronze_database` column is set correctly:
```sql
SELECT bronze_table, bronze_database FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP;
-- bronze_database must match the actual database containing the Bronze tables
```

### Executor keeps retrying / syntax errors in DDL
The active model is likely `mistral-large2` which generates markdown-fenced SQL. Fix:
```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('llama3.3-70b');
```
Then reset and re-run the workflow.

### T-04 shows `OK` instead of `ABORTED`
The overwrite check fires on the **derived target table name** (Bronze source name, e.g. `MARKETBASKET_PRODUCTS`), not on pre-existing tables with different names (`MARKETBASKET_PRODUCTS_SILVER`). For T-04, the pre-built table from T-03 (`AGENT_FRAMEWORK_OUTPUT.SIMPLEMART_PRODUCTS`) is used as the overwrite target — not the Silver table. Re-read T-04 setup steps in `test_v3_scenarios.sql`.

### `VALIDATE_MULTI_BANNER` returns `No banner config found`
Run the `INSERT INTO AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG` block in T-06 first.

### `WORKFLOW_SCHEMA_ANALYST` not found
`06_schema_analyst.sql` may have deployed to the wrong database (contains a hardcoded `USE DATABASE` line in older versions). Redeploy:
```bash
printf "SET TARGET_DB = 'MARKETBASKET_TEST'; SET BRONZE_SCHEMA = 'BRONZE';\n" > /tmp/06.sql
cat setup/06_schema_analyst.sql >> /tmp/06.sql
snow sql -c <your-connection> -f /tmp/06.sql
```

### `RESET_FRAMEWORK` returns error
Pass the confirmation string:
```sql
CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES');  -- 'YES' required
```

---

## Clean Up

```sql
DROP DATABASE IF EXISTS MARKETBASKET_TEST;
```

---

## Reporting Results

Screenshot the T-08 summary query output. For any failures, include:
1. Which test scenario failed
2. The full `WORKFLOW_LOG` message (`SELECT message FROM AGENT_FRAMEWORK.WORKFLOW_LOG WHERE status IN ('FAILED','ABORTED','ERROR') ORDER BY created_at DESC LIMIT 5`)
3. The `PLANNER_DECISIONS` row for the relevant table
4. Active model: `SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG`
