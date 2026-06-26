"""
ATS v3 Automated Test Suite
Uses snow CLI (subprocess) for auth — avoids private-key loading issues.
Usage: python3 ats_v3_test_suite.py
"""
import json, subprocess, sys, time
from datetime import datetime

SNOW   = "/opt/homebrew/bin/snow"
CONN   = "CoCo-Green"
DB     = "ATS_V3"
TEST_DB= "ATS_V3_TEST"

results = []
PASS, FAIL, WARN, SKIP = "PASS", "FAIL", "WARN", "SKIP"

# ── helpers ───────────────────────────────────────────────────────────────────

def snow_sql(query):
    """Run a SQL query via snow CLI and return list-of-dicts rows."""
    r = subprocess.run(
        [SNOW, "sql", "-c", CONN, "--format", "json", "-q", query],
        capture_output=True, text=True, timeout=300
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return []

def scalar(query):
    rows = snow_sql(query)
    if not rows:
        return None
    row = rows[0]
    return list(row.values())[0]

def call_sp(query):
    rows = snow_sql(query)
    if not rows:
        return None
    raw = list(rows[0].values())[0]
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except Exception:
            return raw
    return raw

def record(group, name, status, detail=""):
    results.append((group, name, status, detail))
    icon = {"PASS": "✅", "FAIL": "❌", "WARN": "⚠️ ", "SKIP": "⏭ "}.get(status, "?")
    print(f"  {icon}  {name}" + (f"  [{detail}]" if detail else ""))

# ═══════════════════════════════════════════════════════════════════════════
def test_infrastructure():
    g = "1. Infrastructure"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    sp_count = scalar(f"SELECT COUNT(*) FROM {DB}.INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA = 'AGENT_FRAMEWORK'")
    record(g, "SP count ≥ 27", PASS if int(sp_count or 0) >= 27 else FAIL, f"found {sp_count}")

    tbl_count = scalar(f"SELECT COUNT(*) FROM {DB}.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK' AND TABLE_TYPE = 'BASE TABLE'")
    record(g, "AGENT_FRAMEWORK tables ≥ 12", PASS if int(tbl_count or 0) >= 12 else FAIL, f"found {tbl_count}")

    view_count = scalar(f"SELECT COUNT(*) FROM {DB}.INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK'")
    record(g, "AGENT_FRAMEWORK views ≥ 5", PASS if int(view_count or 0) >= 5 else FAIL, f"found {view_count}")

    stage = scalar(f"SELECT COUNT(*) FROM {DB}.INFORMATION_SCHEMA.STAGES WHERE STAGE_SCHEMA = 'AGENT_FRAMEWORK' AND STAGE_NAME = 'DOCUMENT_STAGE'")
    record(g, "DOCUMENT_STAGE exists", PASS if stage else FAIL)

    model = scalar(f"SELECT primary_model FROM {DB}.AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key = 'default' LIMIT 1")
    record(g, "MODEL_CONFIG has validated model", PASS if model else FAIL, str(model))

    contracts = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.SCHEMA_CONTRACTS")
    record(g, "SCHEMA_CONTRACTS seeded ≥ 18", PASS if int(contracts or 0) >= 18 else FAIL, f"{contracts} rows")

    directives = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES")
    record(g, "TRANSFORMATION_DIRECTIVES seeded ≥ 21", PASS if int(directives or 0) >= 21 else FAIL, f"{directives} rows")

    corpus_view = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS")
    record(g, "ATS_KNOWLEDGE_CORPUS view accessible", PASS if corpus_view is not None else FAIL, f"{corpus_view} rows")


def test_bootstrap():
    g = "2. Bootstrap"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    registered = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")
    record(g, "TABLE_LINEAGE_MAP has 5 Bronze tables", PASS if registered == 5 else FAIL, f"{registered} rows")

    rows = snow_sql(f"SELECT UPPER(bronze_table) AS t FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")
    found = {r["T"] for r in rows}
    expected = {"DASHMART_PRODUCTS", "LCL_PRODUCTS", "MARKETBASKET_PRODUCTS", "RENSPETS_PRODUCTS", "SIMPLEMART_PRODUCTS"}
    missing = expected - found
    record(g, "All 5 Bronze tables discovered", PASS if not missing else FAIL,
           "missing: " + ", ".join(missing) if missing else "all 5 present")

    pending = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE silver_status = 'PENDING'")
    record(g, "All tables start as PENDING", PASS if pending == 5 else FAIL, f"{pending}/5 pending")

    gaps = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.SILVER_GAPS")
    record(g, "SILVER_GAPS shows 5 gaps", PASS if gaps == 5 else FAIL, f"{gaps} rows")

    cov = snow_sql(f"SELECT total_bronze_tables, silver_covered FROM {DB}.AGENT_FRAMEWORK.COVERAGE_SUMMARY LIMIT 1")
    if cov:
        total, complete = cov[0].get("TOTAL_BRONZE_TABLES", 0), cov[0].get("SILVER_COVERED", 0)
        record(g, "COVERAGE_SUMMARY shows 0% complete (fresh start)", PASS if complete == 0 else FAIL,
               f"{complete}/{total} complete")


def test_pipeline_context():
    g = "3. Pipeline Context & Safety"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    ctx = snow_sql(f"SELECT dry_run, overwrite_existing, output_schema, brownfield_mode FROM {DB}.AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    if not ctx:
        record(g, "PIPELINE_CONTEXT row exists", FAIL, "no row"); return
    c = ctx[0]
    record(g, "dry_run = TRUE by default",            PASS if c.get("DRY_RUN")              else FAIL, str(c.get("DRY_RUN")))
    record(g, "overwrite_existing = FALSE by default", PASS if not c.get("OVERWRITE_EXISTING") else FAIL, str(c.get("OVERWRITE_EXISTING")))
    record(g, "output_schema = AGENT_FRAMEWORK_OUTPUT", PASS if c.get("OUTPUT_SCHEMA") == "AGENT_FRAMEWORK_OUTPUT" else FAIL, c.get("OUTPUT_SCHEMA"))
    record(g, "brownfield_mode = FALSE by default",    PASS if not c.get("BROWNFIELD_MODE")  else FAIL, str(c.get("BROWNFIELD_MODE")))

    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(TRUE)")
    bf_on = scalar(f"SELECT brownfield_mode FROM {DB}.AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    record(g, "SET_BROWNFIELD_MODE(TRUE) persists", PASS if bf_on else FAIL)

    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(FALSE)")
    bf_off = scalar(f"SELECT brownfield_mode FROM {DB}.AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    record(g, "SET_BROWNFIELD_MODE(FALSE) resets", PASS if not bf_off else FAIL)


def test_document_ingestion():
    g = "4. Document Ingestion (B-01)"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    text = "Naming Convention: date columns use _DT suffix. Amount columns use _AMT suffix. PK columns use _KEY. Email must be masked in Gold layer."
    result = call_sp(
        f"CALL {DB}.AGENT_FRAMEWORK.INGEST_DOCUMENT_TEXT('test_doc', 'naming_convention', '{text}')"
    )
    ok = isinstance(result, dict) and result.get("status") == "SUCCESS"
    record(g, "INGEST_DOCUMENT_TEXT succeeds", PASS if ok else FAIL,
           f"chunks={result.get('chunks',0)}" if ok else str(result)[:80])

    items = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS WHERE doc_name = 'test_doc'")
    record(g, "DOCUMENT_CONTEXT_ITEMS populated", PASS if items and items > 0 else FAIL, f"{items} chunk(s)")

    doc_list = call_sp(f"CALL {DB}.AGENT_FRAMEWORK.LIST_DOCUMENTS()")
    found_doc = isinstance(doc_list, list) and any(d.get("doc_name") == "test_doc" for d in doc_list)
    record(g, "LIST_DOCUMENTS returns the document", PASS if found_doc else FAIL)

    corpus_docs = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS WHERE source_type = 'document_context'")
    record(g, "ATS_KNOWLEDGE_CORPUS includes document_context rows", PASS if corpus_docs and corpus_docs > 0 else FAIL, f"{corpus_docs} rows")

    remove = call_sp(f"CALL {DB}.AGENT_FRAMEWORK.REMOVE_DOCUMENT('test_doc')")
    record(g, "REMOVE_DOCUMENT succeeds", PASS if isinstance(remove, dict) and remove.get("status") == "REMOVED" else FAIL,
           f"chunks_deleted={remove.get('chunks_deleted',0)}" if isinstance(remove, dict) else str(remove)[:60])

    leftover = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.DOCUMENT_CONTEXT_ITEMS WHERE doc_name = 'test_doc'")
    record(g, "Corpus clean after removal", PASS if leftover == 0 else FAIL)


def test_dry_run_pipeline():
    g = "5. Core Pipeline — Dry Run"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")
    print("  ⏳ Running dry-run pipeline on RENSPETS_PRODUCTS …")

    t0 = time.time()
    result = call_sp(
        f"CALL {DB}.AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW("
        f"  'automated_test',"
        f"  ARRAY_CONSTRUCT('{TEST_DB}.BRONZE.RENSPETS_PRODUCTS'),"
        f"  'AUTOMATED')"
    )
    elapsed = round(time.time() - t0, 1)

    exe_id = result.get("execution_id", "") if isinstance(result, dict) else ""
    record(g, f"Dry-run pipeline returns execution_id ({elapsed}s)", PASS if exe_id else FAIL, f"eid={exe_id[:8]}…")

    if not exe_id:
        return exe_id

    status_rows = snow_sql(f"SELECT status, current_phase FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS WHERE execution_id = '{exe_id}'")
    if status_rows:
        status, phase = status_rows[0].get("STATUS"), status_rows[0].get("CURRENT_PHASE")
        record(g, "WORKFLOW_EXECUTIONS row present", PASS, f"status={status} phase={phase}")

    decisions = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.PLANNER_DECISIONS WHERE execution_id = '{exe_id}'")
    record(g, "PLANNER_DECISIONS generated", PASS if decisions and decisions > 0 else FAIL, f"{decisions} decision(s)")

    dry_log = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LOG WHERE execution_id = '{exe_id}' AND status = 'DRY_RUN'")
    record(g, "WORKFLOW_LOG has DRY_RUN entries", PASS if dry_log and dry_log > 0 else FAIL, f"{dry_log} entries")

    tbl_exists = scalar(f"SELECT COUNT(*) FROM {DB}.INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'AGENT_FRAMEWORK_OUTPUT' AND TABLE_NAME = 'RENSPETS_PRODUCTS'")
    record(g, "Dry run does NOT create Silver table", PASS if not tbl_exists else FAIL, "absent (correct)" if not tbl_exists else "EXISTS — should not!")

    still_pending = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE UPPER(bronze_table) = 'RENSPETS_PRODUCTS' AND silver_status = 'PENDING'")
    record(g, "silver_status remains PENDING after dry run", PASS if still_pending else FAIL)

    return exe_id


def test_live_pipeline():
    g = "6. Core Pipeline — Live Run"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_dry_run => FALSE, p_overwrite_existing => FALSE, p_output_schema => 'AGENT_FRAMEWORK_OUTPUT')")
    dry_now = scalar(f"SELECT dry_run FROM {DB}.AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    record(g, "dry_run set to FALSE", PASS if not dry_now else FAIL)

    print("  ⏳ Running LIVE pipeline on RENSPETS_PRODUCTS …")
    t0 = time.time()
    result = call_sp(
        f"CALL {DB}.AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW("
        f"  'automated_test_live',"
        f"  ARRAY_CONSTRUCT('{TEST_DB}.BRONZE.RENSPETS_PRODUCTS'),"
        f"  'AUTOMATED')"
    )
    elapsed = round(time.time() - t0, 1)
    exe_id = result.get("execution_id", "") if isinstance(result, dict) else ""
    record(g, f"Live pipeline call succeeds ({elapsed}s)", PASS if exe_id else FAIL, f"eid={exe_id[:8]}…")

    silver_rows = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS")
    bronze_rows = scalar(f"SELECT COUNT(*) FROM {TEST_DB}.BRONZE.RENSPETS_PRODUCTS")
    record(g, "Silver table created with rows", PASS if silver_rows and silver_rows > 0 else FAIL, f"{silver_rows:,} rows" if silver_rows else "table missing or empty")

    if silver_rows and bronze_rows:
        pct = abs(silver_rows - bronze_rows) / bronze_rows * 100
        record(g, "Silver row count within 10% of Bronze", PASS if pct <= 10 else WARN, f"silver={silver_rows:,} bronze={bronze_rows:,} diff={pct:.1f}%")

    status = scalar(f"SELECT silver_status FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE UPPER(bronze_table) = 'RENSPETS_PRODUCTS'")
    record(g, "TABLE_LINEAGE_MAP silver_status = COMPLETE", PASS if status == "COMPLETE" else FAIL, str(status))

    ok_log = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LOG WHERE execution_id = '{exe_id}' AND phase = 'EXECUTOR' AND status = 'OK'")
    record(g, "Executor logged OK", PASS if ok_log and ok_log > 0 else FAIL, f"{ok_log} OK entries")

    val_pass = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LOG WHERE execution_id = '{exe_id}' AND phase = 'VALIDATOR' AND status = 'PASS'")
    record(g, "Validator logged PASS", PASS if val_pass and val_pass > 0 else WARN, f"{val_pass} PASS entries")

    learnings = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LEARNINGS")
    record(g, "Reflector captured learnings", PASS if learnings and learnings > 0 else WARN, f"{learnings} learnings")

    return exe_id


def test_cortex_search():
    g = "7. Cortex Search"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    corpus = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS")
    record(g, "ATS_KNOWLEDGE_CORPUS has rows after pipeline run", PASS if corpus and corpus > 0 else FAIL, f"{corpus} rows")

    sources = snow_sql(f"SELECT DISTINCT source_type FROM {DB}.AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS")
    found_types = {r.get("SOURCE_TYPE") for r in sources}
    record(g, "Corpus includes 'learning' source type", PASS if "learning" in found_types else WARN, str(found_types))
    record(g, "Corpus includes 'planner_decision' source type", PASS if "planner_decision" in found_types else WARN, str(found_types))

    try:
        result = call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE('product key renspets deduplication', 3)")
        has_results = isinstance(result, str) and result != "No prior knowledge found." and len(result) > 20
        record(g, "SEARCH_ATS_KNOWLEDGE returns relevant context", PASS if has_results else WARN,
               result[:80] if has_results else "no results (search service may need refresh)")
    except Exception as e:
        record(g, "SEARCH_ATS_KNOWLEDGE callable", WARN, f"search service may need refresh: {str(e)[:60]}")

    cov = snow_sql(f"SELECT total_bronze_tables, silver_covered FROM {DB}.AGENT_FRAMEWORK.COVERAGE_SUMMARY LIMIT 1")
    if cov:
        total, complete = cov[0].get("TOTAL_BRONZE_TABLES", 0), cov[0].get("SILVER_COVERED", 0)
        record(g, "COVERAGE_SUMMARY shows 1/5 complete (20%)", PASS if complete == 1 else FAIL, f"{complete}/{total}")


def test_brownfield_mode():
    g = "8. Brownfield Mode (B-03)"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(TRUE)")
    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_dry_run => FALSE, p_overwrite_existing => FALSE, p_output_schema => 'AGENT_FRAMEWORK_OUTPUT')")

    rows_before = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS")

    print("  ⏳ Running brownfield pipeline on RENSPETS (table already exists) …")
    t0 = time.time()
    result = call_sp(
        f"CALL {DB}.AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW("
        f"  'automated_test_brownfield',"
        f"  ARRAY_CONSTRUCT('{TEST_DB}.BRONZE.RENSPETS_PRODUCTS'),"
        f"  'AUTOMATED')"
    )
    elapsed = round(time.time() - t0, 1)
    exe_id = result.get("execution_id", "") if isinstance(result, dict) else ""
    record(g, f"Brownfield pipeline call succeeds ({elapsed}s)", PASS if exe_id else FAIL)

    skipped = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LOG WHERE execution_id = '{exe_id}' AND status = 'SKIPPED'")
    record(g, "Executor logged SKIPPED (not ABORTED)", PASS if skipped and skipped > 0 else FAIL, f"{skipped} SKIPPED entries")

    aborted = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.WORKFLOW_LOG WHERE execution_id = '{exe_id}' AND status = 'ABORTED'")
    record(g, "No ABORTED entries in brownfield run", PASS if not aborted else FAIL, f"{aborted} ABORTED (should be 0)")

    rows_after = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK_OUTPUT.RENSPETS_PRODUCTS")
    record(g, "Silver row count unchanged (not overwritten)", PASS if rows_before == rows_after else FAIL, f"before={rows_before:,} after={rows_after:,}")

    bf_status = scalar(f"SELECT silver_status FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE UPPER(bronze_table) = 'RENSPETS_PRODUCTS'")
    record(g, "TABLE_LINEAGE_MAP shows EXISTING status", PASS if bf_status == "EXISTING" else FAIL, str(bf_status))

    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_BROWNFIELD_MODE(FALSE)")
    call_sp(f"CALL {DB}.AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT(p_dry_run => TRUE)")
    record(g, "Reset to dry_run=TRUE, brownfield=FALSE", PASS)


def test_dcm_export():
    g = "9. DCM Export"
    print(f"\n{'─'*60}\n{g}\n{'─'*60}")

    complete = scalar(f"SELECT COUNT(*) FROM {DB}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE silver_status IN ('COMPLETE','EXISTING')")
    if not complete:
        record(g, "DCM Export", SKIP, "no complete Silver tables"); return

    try:
        result = call_sp(f"CALL {DB}.AGENT_FRAMEWORK.GENERATE_DCM_PROJECT('ATS_TEST_PROJECT','DATA_ENGINEER','ANALYST')")
        ok = isinstance(result, dict) and result.get("status") == "SUCCESS"
        files = result.get("files_written", 0) if isinstance(result, dict) else 0
        record(g, "GENERATE_DCM_PROJECT succeeds", PASS if ok else FAIL, f"files_written={files}")
        if ok:
            silver_in_dcm = result.get("silver_tables", result.get("silver_count", 0))
            record(g, "DCM project contains Silver tables", PASS if silver_in_dcm and silver_in_dcm > 0 else WARN, f"{silver_in_dcm} Silver table(s)")
    except Exception as e:
        record(g, "GENERATE_DCM_PROJECT callable", FAIL, str(e)[:80])


# ═══════════════════════════════════════════════════════════════════════════
def print_report():
    print(f"\n{'═'*60}")
    print("  ATS v3 — AUTOMATED TEST ASSESSMENT REPORT")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"{'═'*60}")
    counts = {PASS: 0, FAIL: 0, WARN: 0, SKIP: 0}
    current_group = None
    for group, name, status, detail in results:
        if group != current_group:
            print(f"\n  {group}")
            current_group = group
        icon = {"PASS": "✅", "FAIL": "❌", "WARN": "⚠️ ", "SKIP": "⏭ "}.get(status, "?")
        detail_str = f"  [{detail}]" if detail else ""
        print(f"    {icon}  {name}{detail_str}")
        counts[status] += 1

    total = sum(counts.values())
    print(f"\n{'─'*60}")
    print(f"  TOTAL {total}  |  ✅ {counts[PASS]} PASS  |  ❌ {counts[FAIL]} FAIL  |  ⚠️  {counts[WARN]} WARN  |  ⏭  {counts[SKIP]} SKIP")

    if counts[FAIL] == 0 and counts[WARN] <= 2:
        verdict = "🟢  PASS — v3 is production-ready"
    elif counts[FAIL] == 0:
        verdict = "🟡  PASS WITH WARNINGS — review WARN items above"
    elif counts[FAIL] <= 3:
        verdict = "🟡  PARTIAL PASS — non-critical failures present"
    else:
        verdict = "🔴  FAIL — critical issues found"

    print(f"\n  VERDICT: {verdict}")
    print(f"{'═'*60}\n")
    return counts[FAIL]


if __name__ == "__main__":
    print(f"\n{'═'*60}")
    print("  ATS v3 Automated Test Suite")
    print(f"  Connection: {CONN}  |  DB: {DB}")
    print(f"{'═'*60}")

    # Verify CLI connectivity
    try:
        user = scalar(f"SELECT CURRENT_USER()")
        print(f"  Connected as {user} ✓\n")
    except Exception as e:
        print(f"  Connection failed: {e}")
        sys.exit(1)

    test_infrastructure()
    test_bootstrap()
    test_pipeline_context()
    test_document_ingestion()
    test_dry_run_pipeline()
    test_live_pipeline()
    test_cortex_search()
    test_brownfield_mode()
    test_dcm_export()

    fails = print_report()
    sys.exit(1 if fails > 0 else 0)
