# ATS v3 — Automated Test Suite Results

**Date:** 2026-06-25  
**Run by:** DBRYANT_COCO  
**Account:** SFPSCOGS-PS_WLS_DEMO_GREEN (AWS US-West-2)  
**Framework DB:** ATS_V3  
**Test DB:** ATS_V3_TEST (Bronze only — clean install state)  
**Model:** llama3.3-70b  
**Verdict:** 🟢 PASS — production-ready

---

## Summary

| Metric | Value |
|--------|-------|
| Total tests | 52 |
| ✅ PASS | 51 |
| ❌ FAIL | 0 |
| ⚠️ WARN | 1 |
| ⏭ SKIP | 0 |

---

## Results by Group

### 1. Infrastructure — 8/8 ✅

| Test | Result | Detail |
|------|--------|--------|
| SP count ≥ 27 | ✅ PASS | found 27 |
| AGENT_FRAMEWORK tables ≥ 12 | ✅ PASS | found 12 |
| AGENT_FRAMEWORK views ≥ 5 | ✅ PASS | found 5 |
| DOCUMENT_STAGE exists | ✅ PASS | |
| MODEL_CONFIG has validated model | ✅ PASS | llama3.3-70b |
| SCHEMA_CONTRACTS seeded ≥ 18 | ✅ PASS | 20 rows |
| TRANSFORMATION_DIRECTIVES seeded ≥ 21 | ✅ PASS | 23 rows |
| ATS_KNOWLEDGE_CORPUS view accessible | ✅ PASS | 0 rows (fresh install) |

---

### 2. Bootstrap — 5/5 ✅

| Test | Result | Detail |
|------|--------|--------|
| TABLE_LINEAGE_MAP has 5 Bronze tables | ✅ PASS | 5 rows |
| All 5 Bronze tables discovered | ✅ PASS | DASHMART, LCL, MARKETBASKET, RENSPETS, SIMPLEMART |
| All tables start as PENDING | ✅ PASS | 5/5 pending |
| SILVER_GAPS shows 5 gaps | ✅ PASS | 5 rows |
| COVERAGE_SUMMARY shows 0% complete | ✅ PASS | 0/5 complete |

---

### 3. Pipeline Context & Safety — 6/6 ✅

| Test | Result | Detail |
|------|--------|--------|
| dry_run = TRUE by default | ✅ PASS | True |
| overwrite_existing = FALSE by default | ✅ PASS | False |
| output_schema = AGENT_FRAMEWORK_OUTPUT | ✅ PASS | AGENT_FRAMEWORK_OUTPUT |
| brownfield_mode = FALSE by default | ✅ PASS | False |
| SET_BROWNFIELD_MODE(TRUE) persists | ✅ PASS | |
| SET_BROWNFIELD_MODE(FALSE) resets | ✅ PASS | |

---

### 4. Document Ingestion (B-01) — 6/6 ✅

| Test | Result | Detail |
|------|--------|--------|
| INGEST_DOCUMENT_TEXT succeeds | ✅ PASS | chunks=1 |
| DOCUMENT_CONTEXT_ITEMS populated | ✅ PASS | 1 chunk(s) |
| LIST_DOCUMENTS returns the document | ✅ PASS | |
| ATS_KNOWLEDGE_CORPUS includes document_context rows | ✅ PASS | 1 rows |
| REMOVE_DOCUMENT succeeds | ✅ PASS | chunks_deleted=1 |
| Corpus clean after removal | ✅ PASS | |

---

### 5. Core Pipeline — Dry Run — 6/6 ✅

| Test | Result | Detail |
|------|--------|--------|
| Dry-run pipeline returns execution_id | ✅ PASS | 66.0s · eid=fa6a1f5d… |
| WORKFLOW_EXECUTIONS row present | ✅ PASS | status=COMPLETE phase=COMPLETE |
| PLANNER_DECISIONS generated | ✅ PASS | 1 decision(s) |
| WORKFLOW_LOG has DRY_RUN entries | ✅ PASS | 1 entries |
| Dry run does NOT create Silver table | ✅ PASS | absent (correct) |
| silver_status remains PENDING after dry run | ✅ PASS | |

---

### 6. Core Pipeline — Live Run — 8/8 ✅

| Test | Result | Detail |
|------|--------|--------|
| dry_run set to FALSE | ✅ PASS | |
| Live pipeline call succeeds | ✅ PASS | 73.9s · eid=561ab4e3… |
| Silver table created with rows | ✅ PASS | 5,709 rows |
| Silver row count within 10% of Bronze | ✅ PASS | silver=5,709 bronze=5,709 diff=0.0% |
| TABLE_LINEAGE_MAP silver_status = COMPLETE | ✅ PASS | COMPLETE |
| Executor logged OK | ✅ PASS | 1 OK entries |
| Validator logged PASS | ✅ PASS | 1 PASS entries |
| Reflector captured learnings | ✅ PASS | 9 learnings |

---

### 7. Cortex Search — 5/5 ✅

| Test | Result | Detail |
|------|--------|--------|
| ATS_KNOWLEDGE_CORPUS has rows after pipeline run | ✅ PASS | 10 rows |
| Corpus includes 'learning' source type | ✅ PASS | {planner_decision, learning} |
| Corpus includes 'planner_decision' source type | ✅ PASS | {planner_decision, learning} |
| SEARCH_ATS_KNOWLEDGE returns relevant context | ✅ PASS | `[OPTIMIZATION] RENSPETS_PRODUCTS table: The presence of duplicates in the produc…` |
| COVERAGE_SUMMARY shows 1/5 complete (20%) | ✅ PASS | 1/5 |

---

### 8. Brownfield Mode (B-03) — 6/6 ✅

| Test | Result | Detail |
|------|--------|--------|
| Brownfield pipeline call succeeds | ✅ PASS | 74.4s |
| Executor logged SKIPPED (not ABORTED) | ✅ PASS | 1 SKIPPED entries |
| No ABORTED entries in brownfield run | ✅ PASS | 0 ABORTED (should be 0) |
| Silver row count unchanged (not overwritten) | ✅ PASS | before=5,709 after=5,709 |
| TABLE_LINEAGE_MAP shows EXISTING status | ✅ PASS | EXISTING |
| Reset to dry_run=TRUE, brownfield=FALSE | ✅ PASS | |

---

### 9. DCM Export — 1/1 ✅ · 1 WARN

| Test | Result | Detail |
|------|--------|--------|
| GENERATE_DCM_PROJECT succeeds | ✅ PASS | files_written=6 |
| DCM project contains Silver tables | ⚠️ WARN | 0 Silver table(s) |

**WARN note:** The brownfield run (Group 8) set RENSPETS lineage status to `EXISTING`. `GENERATE_DCM_PROJECT` only includes tables with `silver_status = 'COMPLETE'`. In a standard demo flow where DCM Export is run immediately after the live pipeline (before any brownfield operation), the Silver table would be present. This is expected behavior, not a defect.

---

## Test Environment

| Parameter | Value |
|-----------|-------|
| Test script | `tests/ats_v3_test_suite.py` |
| Connection | CoCo-Green |
| Framework database | ATS_V3 |
| Test database | ATS_V3_TEST |
| Bronze tables | 5 (DASHMART, LCL, MARKETBASKET, RENSPETS, SIMPLEMART) |
| Model | llama3.3-70b |
| Pipeline type | CTAS |
| Pre-test state | Full reset — all Silver/Gold dropped, framework cleared |
| Dry run pipeline time | 66.0s (1 table) |
| Live run pipeline time | 73.9s (1 table) |
| Brownfield run time | 74.4s (1 table, skipped) |
| Total suite runtime | ~8 min |

---

## How to Re-run

```bash
# Ensure clean state first (optional)
snow sql -c CoCo-Green -f setup/full_reset.sql

# Run suite
SNOWFLAKE_CONNECTION_NAME="CoCo-Green" \
  /opt/homebrew/anaconda3/bin/python tests/ats_v3_test_suite.py
```

Exit code `0` = all tests passed. Exit code `1` = one or more FAIL.

---

## Features Validated

| Feature | Covered by Group |
|---------|-----------------|
| Cross-DB Bootstrap, model auto-selection | 2 |
| Dry Run mode (no writes) | 3, 5 |
| Overwrite protection | 3 |
| Output schema isolation (never SILVER/GOLD) | 3, 5 |
| Brownfield mode toggle (B-03) | 3, 8 |
| Document Ingestion via corpus (B-01) | 4 |
| ATS_KNOWLEDGE_CORPUS UNION ALL with documents | 4 |
| Schema Analyst → Planner → Executor chain | 5, 6 |
| DDL generation and execution | 6 |
| Row count validation (Validator) | 6 |
| Learning capture (Reflector) | 6 |
| Cortex Search RAG retrieval | 7 |
| Brownfield SKIP (not ABORT) on existing tables | 8 |
| Lineage map EXISTING status | 8 |
| DCM 6-file project generation | 9 |
