"""
Agentic Transformation Skill — v4
===================================
Cortex Agents interface for the ATS v4 pipeline.
Includes all v3 features plus 4 new Cortex Agents tabs.

Tabs:
  1  Setup            — Bootstrap, model validation, Foundation table discovery
  2  Agent Hub        — Live status of all 6 Cortex Agents [v4 NEW]
  3  Orchestrate      — Run full pipeline via ATS_ORCHESTRATOR_AGENT [v4 NEW]
  4  Agent Chat       — Direct conversation with any individual agent [v4 NEW]
  5  Tool Inspector   — Browse and invoke the 34 ATS_TOOL_* SPs [v4 NEW]
  6  Context          — Pipeline context: business description, domain, Gold goals
  7  Contracts        — Edit structural rules injected into LLM prompts
  8  Directives       — Edit per-table business intent
  9  Workflow         — Run agentic Enriched pipeline with live phase display
  10 Analytics Builder — Review + execute or export Analytics DDL proposals
  11 Registry         — Transformation Registry: lineage map + learnings
  12 Observe          — Observability: KPIs, executor perf, learning intelligence loop
  13 Partner Routing  — Banner/routing config and validation
  14 DCM Export       — Generate DCM project from pipeline output
  15 Documents        — Upload domain documents into knowledge corpus
"""

import json
import time
import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session
from snowflake.snowpark.exceptions import SnowparkSessionException

# ─────────────────────────────────────────────────────────────────────────────
# Session
# ─────────────────────────────────────────────────────────────────────────────

try:
    session = get_active_session()
except SnowparkSessionException:
    st.error("No active Snowflake session. Deploy this app as a Streamlit in Snowflake app.")
    st.stop()

st.set_page_config(page_title="ATS v4 — Cortex Agents", page_icon="🤖", layout="wide")

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

@st.cache_data(ttl=30)
def _db_context():
    row = session.sql("SELECT CURRENT_DATABASE() AS db, CURRENT_ROLE() AS role, CURRENT_USER() AS usr, CURRENT_WAREHOUSE() AS wh").collect()[0]
    return {"db": row["DB"], "role": row["ROLE"], "user": row["USR"], "wh": row["WH"]}


def run_query(sql: str) -> pd.DataFrame:
    try:
        return session.sql(sql).to_pandas()
    except Exception as e:
        st.error(f"Query error: {e}")
        return pd.DataFrame()


def run_call(sql: str) -> dict:
    try:
        rows = session.sql(sql).collect()
        if rows:
            val = rows[0][0]
            try:
                parsed = json.loads(val) if isinstance(val, str) else val
                # Python SPs returning json.dumps() get double-encoded by Snowflake
                # RETURNS VARIANT — parse a second time if still a string
                if isinstance(parsed, str):
                    parsed = json.loads(parsed)
                return parsed
            except Exception:
                return {"raw": str(val)}
        return {}
    except Exception as e:
        return {"status": "ERROR", "error": str(e)}


def run_call_param(proc: str, param: str, param2: str = None) -> dict:
    try:
        if param2 is not None:
            rows = session.sql(f"CALL {proc}(?, ?)", params=[param, param2]).collect()
        else:
            rows = session.sql(f"CALL {proc}(?)", params=[param]).collect()
        if rows:
            val = rows[0][0]
            try:
                parsed = json.loads(val) if isinstance(val, str) else val
                if isinstance(parsed, str):
                    parsed = json.loads(parsed)
                return parsed
            except Exception:
                return {"raw": str(val)}
        return {}
    except Exception as e:
        return {"status": "ERROR", "error": str(e)}


def framework_exists() -> bool:
    df = run_query("SHOW TABLES LIKE 'MODEL_CONFIG' IN SCHEMA AGENT_FRAMEWORK")
    return not df.empty


def bootstrap_done() -> bool:
    try:
        df = run_query("SELECT validated FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key='default' LIMIT 1")
        return not df.empty and bool(df.iloc[0]["VALIDATED"])
    except Exception:
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Styling
# ─────────────────────────────────────────────────────────────────────────────

SF_BLUE  = "#29B5E8"
SF_DARK  = "#1B2A4A"
SF_GREEN = "#00C49A"

st.markdown(f"""
<style>
    .main-header {{
        background: linear-gradient(135deg, {SF_DARK} 0%, #0D1B2E 100%);
        color: white; padding: 1.2rem 2rem 0.9rem;
        border-radius: 8px; margin-bottom: 1.2rem;
    }}
    .main-header h1 {{ color: white; margin: 0; font-size: 1.5rem; }}
    .main-header p  {{ color: {SF_BLUE}; margin: 0.2rem 0 0; font-size: 0.82rem; }}
    .main-header .v4-badge {{
        display: inline-block; background: {SF_BLUE}; color: {SF_DARK};
        font-size: 0.65rem; font-weight: 800; padding: 2px 8px;
        border-radius: 10px; margin-left: 8px; vertical-align: middle;
        letter-spacing: 0.05em;
    }}
    .status-pill {{
        display: inline-block; padding: 2px 10px; border-radius: 12px;
        font-size: 0.75rem; font-weight: 600;
    }}
    .pill-green  {{ background: #d4edda; color: #155724; }}
    .pill-yellow {{ background: #fff3cd; color: #856404; }}
    .pill-red    {{ background: #f8d7da; color: #721c24; }}
    .pill-blue   {{ background: #d1ecf1; color: #0c5460; }}
    .info-strip {{
        background: #f0f4f8; border-left: 4px solid {SF_BLUE};
        padding: 0.6rem 1rem; border-radius: 0 4px 4px 0;
        font-size: 0.85rem; margin-bottom: 1rem;
    }}
    .ddl-block {{
        background: #1e1e1e; color: #d4d4d4; font-family: monospace;
        font-size: 0.8rem; padding: 1rem; border-radius: 4px;
        white-space: pre-wrap; word-break: break-all;
        max-height: 260px; overflow-y: auto;
    }}
    /* Sidebar nav */
    .nav-section {{
        font-size: 0.68rem; font-weight: 800; letter-spacing: 0.1em;
        color: #8a9ab5; text-transform: uppercase;
        padding: 0.6rem 0 0.2rem 0; margin-top: 0.2rem;
    }}
    section[data-testid="stSidebar"] button[kind="secondary"] {{
        background: transparent !important;
        border: none !important;
        color: #2c3e50 !important;
        text-align: left !important;
        padding: 0.3rem 0.5rem !important;
        font-size: 0.85rem !important;
        font-weight: 400 !important;
        width: 100% !important;
    }}
    section[data-testid="stSidebar"] button[kind="primary"] {{
        background: {SF_BLUE}22 !important;
        border: 1px solid {SF_BLUE}55 !important;
        border-radius: 6px !important;
        color: {SF_DARK} !important;
        font-weight: 600 !important;
        text-align: left !important;
        padding: 0.3rem 0.5rem !important;
        font-size: 0.85rem !important;
        width: 100% !important;
    }}
</style>
""", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────

ctx = _db_context()

st.markdown(f"""
<div class="main-header">
  <h1>🤖 Agentic Transformation Skill <span class="v4-badge">v4</span></h1>
  <p>{ctx['db']} &nbsp;·&nbsp; {ctx['role']} &nbsp;·&nbsp; {ctx['user']} &nbsp;·&nbsp; {ctx['wh']}</p>
</div>
""", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# Guard
# ─────────────────────────────────────────────────────────────────────────────

if not framework_exists():
    st.warning("AGENT_FRAMEWORK schema not found in the current database.")
    st.markdown("""
**Deploy the framework first.**

**Option A — Snow CLI:**
```bash
./setup/deploy.sh --connection YOUR_CONN --database YOUR_DB --bronze-schema RAW
```

**Option B — Snowsight Worksheet:**
1. Paste `setup/SETUP_ALL.sql`
2. Set `TARGET_DB` and `BRONZE_SCHEMA` at the top and run all statements
""")
    st.stop()

# ─────────────────────────────────────────────────────────────────────────────
# Phase diagram (ADF-style gradient pills)
# ─────────────────────────────────────────────────────────────────────────────

PHASE_CONFIGS = [
    ("SCHEMA_ANALYST", "Relationship Discovery", "#2196F3", "#1565C0"),
    ("PLANNER",        "LLM Planning",           "#9C27B0", "#7B1FA2"),
    ("EXECUTOR",       "Self-Correcting SQL",    "#FF9800", "#F57C00"),
    ("VALIDATOR",      "Quality Check",          "#4CAF50", "#388E3C"),
    ("REFLECTOR",      "Capture Learnings",      "#607D8B", "#455A64"),
]


def render_phase_diagram(phase_states: dict | None = None) -> str:
    if phase_states is None:
        phase_states = {}
    pills = []
    for name, subtitle, c1, c2 in PHASE_CONFIGS:
        state = phase_states.get(name, "pending")
        if state == "completed":
            bg = "linear-gradient(135deg,#4CAF50,#2E7D32)"; shadow = "rgba(76,175,80,0.4)"; icon = "✅ "
        elif state == "running":
            bg = "linear-gradient(135deg,#FFC107,#FF8F00)"; shadow = "rgba(255,193,7,0.4)"; icon = "🔄 "
        elif state == "failed":
            bg = "linear-gradient(135deg,#f44336,#c62828)"; shadow = "rgba(244,67,54,0.4)"; icon = "❌ "
        elif state == "skipped":
            bg = "linear-gradient(135deg,#9E9E9E,#757575)"; shadow = "rgba(158,158,158,0.2)"; icon = "⏭️ "
        elif state == "reused":
            bg = "linear-gradient(135deg,#1976D2,#0D47A1)"; shadow = "rgba(25,118,210,0.4)"; icon = "⏩ "
        else:
            bg = f"linear-gradient(135deg,{c1},{c2})"; shadow = "rgba(100,100,100,0.15)"; icon = ""
        pills.append(f'''<div style="background:{bg};color:white;padding:10px 16px;border-radius:10px;
            text-align:center;min-width:110px;box-shadow:0 2px 8px {shadow};transition:all 0.3s;">
            <div style="font-weight:700;font-size:0.85rem;">{icon}{name}</div>
            <div style="font-size:0.7rem;opacity:0.85;">{subtitle}</div></div>''')
    arrow = '<div style="font-size:1.4rem;color:#666;">→</div>'
    return '<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin:0.5rem 0 1rem 0;">' + arrow.join(pills) + '</div>'


# ─────────────────────────────────────────────────────────────────────────────
# Sidebar
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Sidebar nav — grouped navigation
# ─────────────────────────────────────────────────────────────────────────────

_NAV_GROUPS = [
    ("Pipeline", [
        (0,  "⚙️",  "Setup"),
        (5,  "💡",  "Context"),
        (6,  "📐",  "Contracts"),
        (7,  "🎯",  "Directives"),
        (8,  "🤖",  "Workflow"),
    ]),
    ("Cortex Agents", [
        (1,  "🏠",  "Agent Hub"),
        (2,  "🎯",  "Orchestrate"),
        (3,  "💬",  "Agent Chat"),
        (4,  "🔧",  "Tool Inspector"),
    ]),
    ("Analytics", [
        (9,  "🏆",  "Analytics Builder"),
        (10, "🗂️",  "Registry"),
        (11, "📊",  "Observe"),
    ]),
    ("Ops & Export", [
        (12, "🏷️",  "Partner Routing"),
        (13, "📦",  "DCM Export"),
        (14, "📄",  "Documents"),
    ]),
]


def render_sidebar():
    if "active_tab" not in st.session_state:
        st.session_state["active_tab"] = 0

    with st.sidebar:
        st.markdown(f"""
<div style="background:linear-gradient(135deg,{SF_DARK} 0%,#0D1B2E 100%);
            border-radius:8px;padding:0.9rem 1rem 0.7rem;margin-bottom:0.8rem;">
  <div style="color:white;font-size:1rem;font-weight:700;margin:0;">🤖 ATS</div>
  <div style="color:{SF_BLUE};font-size:0.72rem;margin-top:2px;">v4 · Cortex Agents</div>
</div>
""", unsafe_allow_html=True)

        for group_label, items in _NAV_GROUPS:
            st.markdown(f'<div class="nav-section">{group_label}</div>', unsafe_allow_html=True)
            for idx, icon, label in items:
                active = st.session_state["active_tab"] == idx
                if st.button(
                    f"{icon}  {label}",
                    key=f"sidenav_{idx}",
                    use_container_width=True,
                    type="primary" if active else "secondary",
                ):
                    st.session_state["active_tab"] = idx
                    st.rerun()

        st.markdown("---")
        if st.button("🔄 Refresh", use_container_width=True, key="sidebar_refresh"):
            st.cache_data.clear()
            st.rerun()

        st.markdown("---")
        try:
            cov = run_query("SELECT * FROM AGENT_FRAMEWORK.COVERAGE_SUMMARY")
            total_df = run_query("SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")
            total = int(total_df.iloc[0]["CNT"]) if not total_df.empty else 0
            silver_pct = round(float(cov["SILVER_PCT"].mean()), 0) if not cov.empty else 0
            gold_pct   = round(float(cov["GOLD_PCT"].mean()), 0)   if not cov.empty else 0
            c1, c2 = st.columns(2)
            c1.metric("Enriched", f"{silver_pct}%")
            c2.metric("Analytics", f"{gold_pct}%")
            st.caption(f"{total} Foundation tables")
        except Exception:
            st.caption("No coverage data")

        last_wf = run_query("""
            SELECT status, current_phase, started_at
            FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            ORDER BY started_at DESC LIMIT 1
        """)
        if not last_wf.empty:
            row = last_wf.iloc[0]
            status = row["STATUS"]
            pill_cls = "pill-green" if status == "COMPLETED" else ("pill-red" if status == "FAILED" else "pill-yellow")
            st.markdown(f"**Last Run** &nbsp;<span class='status-pill {pill_cls}'>{status}</span>", unsafe_allow_html=True)
            st.caption(f"{str(row['STARTED_AT'])[:16]}")

        if "wf_execution_id" in st.session_state:
            st.caption(f"🆔 `{st.session_state['wf_execution_id'][:8]}…`")


# ─────────────────────────────────────────────────────────────────────────────
# Tab render functions
# ─────────────────────────────────────────────────────────────────────────────

def render_setup_tab():
    st.subheader("Framework Setup")

    bootstrapped = bootstrap_done()
    col_a, col_b, col_c = st.columns(3)

    model_df = run_query("SELECT primary_model, fallback_model, validated, last_validated FROM AGENT_FRAMEWORK.MODEL_CONFIG WHERE config_key='default' LIMIT 1")
    model_name      = model_df.iloc[0]["PRIMARY_MODEL"] if not model_df.empty else "unknown"
    model_validated = bool(model_df.iloc[0]["VALIDATED"]) if not model_df.empty else False

    table_count_df = run_query("SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")
    table_count = int(table_count_df.iloc[0]["CNT"]) if not table_count_df.empty else 0

    coverage_df = run_query("SELECT * FROM AGENT_FRAMEWORK.COVERAGE_SUMMARY")

    with col_a:
        pill_class = "pill-green" if bootstrapped else "pill-yellow"
        pill_text  = "Bootstrapped" if bootstrapped else "Needs Bootstrap"
        st.markdown(f"**Framework** &nbsp;<span class='status-pill {pill_class}'>{pill_text}</span>", unsafe_allow_html=True)
        st.caption(f"{table_count} Bronze tables registered")

    with col_b:
        pill_class = "pill-green" if model_validated else "pill-red"
        st.markdown(f"**Model** &nbsp;<span class='status-pill {pill_class}'>{model_name}</span>", unsafe_allow_html=True)
        last_val = model_df.iloc[0]["LAST_VALIDATED"] if not model_df.empty else None
        st.caption(f"Last validated: {str(last_val)[:16] if last_val else 'never'}")

    with col_c:
        if not coverage_df.empty:
            avg_silver = round(float(coverage_df["SILVER_PCT"].mean()), 1)
            avg_gold   = round(float(coverage_df["GOLD_PCT"].mean()), 1)
            st.markdown(f"**Coverage** &nbsp;<span class='status-pill pill-blue'>{avg_silver}% Enriched / {avg_gold}% Analytics</span>", unsafe_allow_html=True)
            st.caption("Across all Foundation tables")
        else:
            st.markdown("**Coverage** &nbsp;<span class='status-pill pill-yellow'>No data</span>", unsafe_allow_html=True)
            st.caption("Run Bootstrap to discover tables")

    st.divider()

    if not bootstrapped:
        st.markdown("#### Run Bootstrap")
        st.markdown('<div class="info-strip">Bootstrap discovers your Foundation tables, validates the Cortex model, and seeds default contracts and directives. Run once per environment.</div>', unsafe_allow_html=True)
        bronze_schema = st.text_input("Bronze Source(s)", value="", placeholder="MY_DATA_DB.BRONZE  or  DB1.BRONZE,DB2.RAW", help="Cross-database (MY_DB.BRONZE), plain schema (BRONZE), or comma-separated multi-source (DB1.BRONZE,DB2.RAW).")
        if st.button("▶ Run Bootstrap", type="primary", use_container_width=True):
            with st.spinner(f"Bootstrapping '{bronze_schema.strip()}'..."):
                result = run_call(f"CALL AGENT_FRAMEWORK.BOOTSTRAP('{bronze_schema.strip()}')")
            if result.get("status") == "SUCCESS":
                n = result.get('tables_registered', result.get('bronze_tables', 0))
                skipped = result.get('sources_skipped', [])
                msg = f"Bootstrap complete. {n} tables registered. Model: {result.get('model_validation', {}).get('model', 'unknown')}"
                if skipped:
                    msg += f" (sources not found: {skipped})"
                st.success(msg)
                st.cache_data.clear()
                st.rerun()
            else:
                st.error(f"Bootstrap failed: {result}")
    else:
        st.markdown("#### Model Management")
        c1, c2 = st.columns([2, 1])
        with c1:
            known_models = ["llama3.3-70b", "llama3.1-70b", "llama3.1-8b", "mistral-large2", "claude-3-7-sonnet", "claude-3-5-sonnet-v2"]
            new_model = st.selectbox("Switch Active Model", options=known_models,
                                     index=known_models.index(model_name) if model_name in known_models else 0)
        with c2:
            st.markdown("<br>", unsafe_allow_html=True)
            if st.button("Validate & Set", use_container_width=True):
                with st.spinner(f"Validating {new_model}..."):
                    result = run_call(f"CALL AGENT_FRAMEWORK.VALIDATE_MODEL('{new_model}')")
                if result.get("status") == "SUCCESS":
                    st.success(f"Active model updated to: {result.get('model')}")
                    st.cache_data.clear()
                    st.rerun()
                else:
                    st.error(f"Validation failed: {result.get('error', 'Unknown error')}")

        st.markdown("#### Re-discover Foundation Tables")
        bronze_refresh_schema = st.text_input("Bronze Source(s)", value="", key="refresh_schema", placeholder="MY_DATA_DB.BRONZE or DB1.BRONZE,DB2.RAW")
        if st.button("↻ Re-discover Tables"):
            with st.spinner("Scanning INFORMATION_SCHEMA..."):
                result = run_call(f"CALL AGENT_FRAMEWORK.BOOTSTRAP('{bronze_refresh_schema.strip()}')")
            st.success(f"Discovery complete: {result.get('tables_registered', result.get('bronze_tables',0))} tables registered")
            st.cache_data.clear()
            st.rerun()

    if not coverage_df.empty:
        st.divider()
        st.markdown("#### Foundation Table Coverage")
        st.dataframe(coverage_df, use_container_width=True, hide_index=True)

    st.divider()
    st.markdown("#### 🔍 Cortex Intelligence (v3)")
    ci_col1, ci_col2 = st.columns(2)

    with ci_col1:
        st.markdown("**Knowledge Search**")
        corpus_df = run_query("""
            SELECT COUNT(*) AS TOTAL,
                   SUM(CASE WHEN source_type='learning' THEN 1 ELSE 0 END) AS LEARNINGS,
                   SUM(CASE WHEN source_type='planner_decision' THEN 1 ELSE 0 END) AS DECISIONS,
                   SUM(CASE WHEN source_type='schema_relationship' THEN 1 ELSE 0 END) AS RELATIONSHIPS
            FROM AGENT_FRAMEWORK.ATS_KNOWLEDGE_CORPUS
        """)
        if not corpus_df.empty and corpus_df.iloc[0]["TOTAL"]:
            total = int(corpus_df.iloc[0]["TOTAL"])
            learnings = int(corpus_df.iloc[0]["LEARNINGS"])
            decisions = int(corpus_df.iloc[0]["DECISIONS"])
            rels = int(corpus_df.iloc[0]["RELATIONSHIPS"])
            st.markdown(f"<span class='status-pill pill-green'>Active — {total} items indexed</span>", unsafe_allow_html=True)
            st.caption(f"{learnings} learnings · {decisions} planner decisions · {rels} relationships")
            test_q = st.text_input("Test search query", placeholder="e.g. deduplicate transformation strategy", key="ci_test_q")
            if st.button("🔎 Test Search", key="ci_test_btn"):
                with st.spinner("Searching knowledge base..."):
                    sr = run_query(f"CALL AGENT_FRAMEWORK.SEARCH_ATS_KNOWLEDGE('{test_q.replace(chr(39), chr(39)*2)}', 3)")
                    if sr is not None and not sr.empty:
                        st.code(str(sr.iloc[0, 0]), language=None)
        else:
            st.markdown("<span class='status-pill pill-yellow'>Empty — run a workflow to populate</span>", unsafe_allow_html=True)
            st.caption("ATS_KNOWLEDGE_CORPUS has no rows yet")

    with ci_col2:
        st.markdown("**Semantic View**")
        try:
            sv_check = run_query(
                "SELECT LENGTH(SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW('ATS_PIPELINE_SEMANTICS')) AS yaml_len"
            )
            sv_exists = not sv_check.empty and int(sv_check.iloc[0]["YAML_LEN"]) > 0
        except Exception:
            sv_exists = False
        if sv_exists:
            st.markdown("<span class='status-pill pill-green'>ATS_PIPELINE_SEMANTICS deployed</span>", unsafe_allow_html=True)
            st.caption("Use in Cortex Analyst or any text-to-SQL interface")
            st.code("SELECT SYSTEM$REFERENCE('SEMANTIC_VIEW',\n  'ATS_PIPELINE_SEMANTICS',\n  'SESSION', 'USAGE');", language="sql")
        else:
            st.markdown("<span class='status-pill pill-yellow'>Not deployed</span>", unsafe_allow_html=True)
            st.caption("Run 11_semantic_view.sql to deploy ATS_PIPELINE_SEMANTICS")


    st.divider()
    st.markdown("#### 🗑 Reset Framework")
    st.markdown('<div class="info-strip">Drops Silver and Gold schemas, clears all workflow history, and reseeds default contracts and directives. Run Bootstrap again after reset.</div>', unsafe_allow_html=True)

    if "confirm_reset_framework" not in st.session_state:
        st.session_state["confirm_reset_framework"] = False

    if not st.session_state["confirm_reset_framework"]:
        if st.button("↺ Reset Framework", use_container_width=True, key="reset_framework_btn"):
            st.session_state["confirm_reset_framework"] = True
            st.rerun()
    else:
        st.error("⚠️ This will drop SILVER and GOLD and clear all workflow history. This cannot be undone.")
        rc1, rc2 = st.columns(2)
        if rc1.button("✓ Confirm Reset", type="primary", use_container_width=True, key="confirm_reset_yes"):
            with st.spinner("Resetting framework..."):
                result = run_call("CALL AGENT_FRAMEWORK.RESET_FRAMEWORK('YES')")
            st.session_state["confirm_reset_framework"] = False
            for key in ["wf_phase_states", "wf_phase_results", "wf_running", "wf_awaiting_approval",
                        "wf_approval_execution_id", "wf_failed", "wf_failure_phase", "wf_failure_error"]:
                st.session_state.pop(key, None)
            st.success("Reset complete. Run Bootstrap to begin.")
            st.cache_data.clear()
            st.rerun()
        if rc2.button("✗ Cancel", use_container_width=True, key="confirm_reset_no"):
            st.session_state["confirm_reset_framework"] = False
            st.rerun()


def render_context_tab():
    st.subheader("Pipeline Context")
    st.markdown('<div class="info-strip">Describe your business and analytics goals once. This context is injected into every Planner prompt so the agent makes domain-informed decisions instead of generic ones.</div>', unsafe_allow_html=True)

    df = run_query("SELECT business_desc, data_domain, gold_goals, constraints, pipeline_type, target_lag, output_schema, dry_run, overwrite_existing, gold_output_mode, brownfield_mode, set_by, set_at FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")

    current = df.iloc[0] if not df.empty else {}

    configured = not df.empty and any(
        current.get(c) for c in ["BUSINESS_DESC", "DATA_DOMAIN", "GOLD_GOALS", "CONSTRAINTS"]
    )
    cur_pipeline_type    = current.get("PIPELINE_TYPE", "CTAS") or "CTAS"
    cur_target_lag       = current.get("TARGET_LAG", "1 hour") or "1 hour"
    cur_output_schema    = current.get("OUTPUT_SCHEMA", "AGENT_FRAMEWORK_OUTPUT") or "AGENT_FRAMEWORK_OUTPUT"
    cur_dry_run          = bool(current.get("DRY_RUN", True))
    cur_overwrite        = bool(current.get("OVERWRITE_EXISTING", False))
    cur_gold_output_mode = current.get("GOLD_OUTPUT_MODE", "FLAT") or "FLAT"
    cur_brownfield_mode  = bool(current.get("BROWNFIELD_MODE", False))

    if configured:
        st.markdown("&nbsp;<span class='status-pill pill-green'>Configured</span> &nbsp;"
                    f"<small>Last updated by {current.get('SET_BY','?')} at {str(current.get('SET_AT',''))[:16]}</small>",
                    unsafe_allow_html=True)
    else:
        st.markdown("&nbsp;<span class='status-pill pill-yellow'>Not configured</span> &nbsp;"
                    "<small>Planner will apply generic best practices until context is set.</small>",
                    unsafe_allow_html=True)

    st.divider()

    with st.form("pipeline_context_form"):
        business_desc = st.text_area(
            "Business Description",
            value=current.get("BUSINESS_DESC") or "",
            height=100,
            placeholder="e.g. We are a healthcare payer processing insurance claims for 2M members across 5 states.",
            help="Who is the customer and what do they do? 2-3 sentences."
        )
        data_domain = st.text_input(
            "Data Domain",
            value=current.get("DATA_DOMAIN") or "",
            placeholder="e.g. Healthcare / Insurance Claims",
            help="Short label for the industry and data type."
        )
        gold_goals = st.text_area(
            "Analytics Goals (Gold Layer)",
            value=current.get("GOLD_GOALS") or "",
            height=100,
            placeholder="e.g. Fraud detection, cost-per-encounter analysis, provider performance KPIs, member risk scoring.",
            help="What business questions must the Gold layer answer? The Planner uses this to shape aggregations and joins."
        )
        constraints = st.text_area(
            "Constraints",
            value=current.get("CONSTRAINTS") or "",
            height=80,
            placeholder="e.g. HIPAA compliant — no PII in Gold layer. Retain full audit trail in Silver. No DELETE operations.",
            help="Compliance, privacy, or architectural constraints the agent must respect."
        )

        st.divider()
        st.markdown("**Pipeline Output Type**")
        col_pt, col_lag = st.columns([1, 1])
        with col_pt:
            pipeline_type = st.selectbox(
                "Output Format",
                options=["CTAS", "DYNAMIC_TABLE"],
                index=0 if cur_pipeline_type == "CTAS" else 1,
                help="CTAS: static snapshot tables (default). DYNAMIC_TABLE: auto-refreshing Snowflake Dynamic Tables."
            )
        with col_lag:
            lag_options = ["1 minute", "5 minutes", "1 hour", "1 day", "DOWNSTREAM"]
            lag_default = cur_target_lag if cur_target_lag in lag_options else "1 hour"
            target_lag = st.selectbox(
                "Target Lag",
                options=lag_options,
                index=lag_options.index(lag_default),
                disabled=(pipeline_type == "CTAS"),
                help="How frequently the Dynamic Table refreshes. Only applies when Output Format = DYNAMIC_TABLE."
            )
        if pipeline_type == "DYNAMIC_TABLE":
            st.info("⚡ Dynamic Tables will auto-refresh on the selected lag. Ensure the warehouse has sufficient credits for continuous refresh.", icon=None)

        st.divider()
        st.markdown("**Output Safety (v3)**")
        col_schema, col_dry, col_overwrite = st.columns([2, 1, 1])
        with col_schema:
            output_schema = st.text_input(
                "Output Schema",
                value=cur_output_schema,
                help="All Executor output goes here. Default: AGENT_FRAMEWORK_OUTPUT. Never set to SILVER or GOLD directly."
            )
        with col_dry:
            dry_run = st.toggle(
                "Dry Run",
                value=cur_dry_run,
                help="ON (default): generate DDL and log it, do not execute. Turn OFF only when ready to write data."
            )
        with col_overwrite:
            overwrite_existing = st.toggle(
                "Allow Overwrite",
                value=cur_overwrite,
                disabled=dry_run,
                help="OFF (default): abort if target table already has rows. Only enable with Dry Run OFF."
            )
        if dry_run:
            st.info("🔍 Dry Run is ON — the Executor will generate and log DDL without writing any data. Review in the Observe tab before disabling.", icon=None)
        elif not dry_run and overwrite_existing:
            st.warning("⚠️ Dry Run is OFF and Allow Overwrite is ON — the Executor will overwrite existing tables.", icon=None)
        else:
            st.success("✅ Dry Run is OFF — the Executor will write to: " + (output_schema.strip() or "AGENT_FRAMEWORK_OUTPUT"), icon=None)

        st.divider()
        st.markdown("**Gold Output Model**")
        gold_mode_options = ["FLAT", "STAR_SCHEMA", "DATA_VAULT", "ONE_BIG_TABLE"]
        gold_mode_help = {
            "FLAT":         "Denormalized tables (default). Simple Silver CTAS output.",
            "STAR_SCHEMA":  "FACT_ + DIM_ tables with surrogate keys, grain, and SCD Type 2 metadata.",
            "DATA_VAULT":   "HUB + LINK + SAT tables with hash keys, load dates, and record source.",
            "ONE_BIG_TABLE": "Single wide denormalized table per domain. Best for Cortex Analyst.",
        }
        gold_output_mode = st.selectbox(
            "Gold Output Model",
            options=gold_mode_options,
            index=gold_mode_options.index(cur_gold_output_mode) if cur_gold_output_mode in gold_mode_options else 0,
            help=gold_mode_help.get(cur_gold_output_mode, "")
        )
        st.caption(gold_mode_help.get(gold_output_mode, ""))

        st.divider()
        st.markdown("**Brownfield Mode**")
        brownfield_mode = st.toggle(
            "Brownfield Mode",
            value=cur_brownfield_mode,
            help="ON: skip Silver tables that already exist in the output schema instead of aborting. "
                 "Use when the customer has manually built Silver tables that ATS should leave intact."
        )
        if brownfield_mode:
            st.info(
                "🏗️ Brownfield Mode is ON — the Executor will skip tables that already exist in the "
                f"output schema ({output_schema.strip() or 'AGENT_FRAMEWORK_OUTPUT'}) "
                "rather than failing. Existing tables are registered as EXISTING in the lineage map.",
                icon=None
            )

        submitted = st.form_submit_button("💾 Save Context", type="primary", use_container_width=True)

    if submitted:
        def _esc(v):
            return v.replace("'", "''") if v else ""
        safe_schema = (output_schema.strip() or "AGENT_FRAMEWORK_OUTPUT").replace("'", "''")
        sql = (
            f"CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT("
            f"p_business_desc=>'{_esc(business_desc)}', "
            f"p_data_domain=>'{_esc(data_domain)}', "
            f"p_gold_goals=>'{_esc(gold_goals)}', "
            f"p_constraints=>'{_esc(constraints)}', "
            f"p_pipeline_type=>'{pipeline_type}', "
            f"p_target_lag=>'{target_lag}', "
            f"p_output_schema=>'{safe_schema}', "
            f"p_dry_run=>{str(dry_run).upper()}, "
            f"p_overwrite_existing=>{str(overwrite_existing).upper()}, "
            f"p_gold_output_mode=>'{gold_output_mode}')"
        )
        result = run_query(sql)
        if result is not None and not result.empty:
            msg = str(result.iloc[0, 0])
            if msg.startswith('ERROR'):
                st.error(msg)
            else:
                run_call(f"CALL AGENT_FRAMEWORK.SET_BROWNFIELD_MODE({str(brownfield_mode).upper()})")
                st.success("Pipeline context saved.")
        else:
            st.success("Pipeline context saved.")
        st.cache_data.clear()
        st.rerun()

    if configured:
        st.divider()
        st.markdown("#### Prompt Preview")
        st.markdown("This is the exact block injected at the top of each Planner LLM call:")
        preview_parts = []
        if current.get("BUSINESS_DESC"):
            preview_parts.append(f"Business: {current['BUSINESS_DESC']}")
        if current.get("DATA_DOMAIN"):
            preview_parts.append(f"Domain: {current['DATA_DOMAIN']}")
        if current.get("GOLD_GOALS"):
            preview_parts.append(f"Analytics Goals: {current['GOLD_GOALS']}")
        if current.get("CONSTRAINTS"):
            preview_parts.append(f"Constraints: {current['CONSTRAINTS']}")
        st.code("\n".join(preview_parts), language=None)

        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Output Format", cur_pipeline_type)
        c2.metric("Target Lag", cur_target_lag if cur_pipeline_type == "DYNAMIC_TABLE" else "N/A")
        c3.metric("Output Schema", cur_output_schema)
        c4.metric("Dry Run", "ON" if cur_dry_run else "OFF")


def render_contracts_tab():
    st.subheader("Schema Contracts")
    st.markdown('<div class="info-strip">Structural rules injected into every LLM prompt. The agent must follow these when generating Enriched and Analytics DDL.</div>', unsafe_allow_html=True)

    df_contracts = run_query("""
        SELECT contract_id, contract_scope, rule_category, rule_name,
               rule_value, description, applies_to_layer, is_active
        FROM AGENT_FRAMEWORK.SCHEMA_CONTRACTS
        ORDER BY rule_category, rule_name
    """)

    if not df_contracts.empty:
        edited_contracts = st.data_editor(
            df_contracts.drop(columns=["CONTRACT_ID"]),
            use_container_width=True,
            hide_index=True,
            key="contracts_editor",
            column_config={
                "CONTRACT_SCOPE":   st.column_config.TextColumn("Scope", width="small"),
                "RULE_CATEGORY":    st.column_config.TextColumn("Category"),
                "RULE_NAME":        st.column_config.TextColumn("Rule Name"),
                "RULE_VALUE":       st.column_config.TextColumn("Value"),
                "DESCRIPTION":      st.column_config.TextColumn("Description", width="large"),
                "APPLIES_TO_LAYER": st.column_config.TextColumn("Layer", width="small"),
                "IS_ACTIVE":        st.column_config.CheckboxColumn("Active"),
            },
        )

        edited_state = st.session_state.get("contracts_editor", {})
        if edited_state.get("edited_rows"):
            if st.button("💾 Save Contract Changes", type="primary", key="save_contracts"):
                for row_idx, changes in edited_state["edited_rows"].items():
                    contract_id = df_contracts.iloc[row_idx]["CONTRACT_ID"]
                    for col, val in changes.items():
                        if col == "IS_ACTIVE":
                            try:
                                session.sql(
                                    "UPDATE AGENT_FRAMEWORK.SCHEMA_CONTRACTS SET is_active = ? WHERE contract_id = ?",
                                    params=[val, contract_id]
                                ).collect()
                            except Exception as e:
                                st.error(f"Save failed: {e}")
                st.success("Contract changes saved.")
                st.cache_data.clear()
                st.rerun()
        if "confirm_reset_contracts" not in st.session_state:
            st.session_state["confirm_reset_contracts"] = False

        if not st.session_state["confirm_reset_contracts"]:
            if st.button("↺ Reset to Defaults", use_container_width=True):
                st.session_state["confirm_reset_contracts"] = True
                st.rerun()
        else:
            st.warning("This will merge default contracts back in (safe — uses MERGE, preserves custom rules). Proceed?")
            cc1, cc2 = st.columns(2)
            if cc1.button("✓ Confirm Reset", type="primary", use_container_width=True):
                with st.spinner("Reseeding defaults..."):
                    run_call("CALL AGENT_FRAMEWORK.SEED_DEFAULT_CONTRACTS()")
                st.session_state["confirm_reset_contracts"] = False
                st.success("Default contracts merged in.")
                st.cache_data.clear()
                st.rerun()
            if cc2.button("✗ Cancel", use_container_width=True):
                st.session_state["confirm_reset_contracts"] = False
                st.rerun()
    else:
        st.info("No contracts defined. Seed defaults from Setup tab after Bootstrap.")

    st.divider()
    st.markdown("#### Add New Contract")
    with st.form("new_contract_form"):
        c1, c2, c3 = st.columns([1, 1, 1])
        new_scope    = c1.text_input("Scope", value="global", help="'global' applies to all tables")
        new_category = c2.text_input("Rule Category", help="e.g. naming, cdc_columns, deduplication")
        new_layer    = c3.selectbox("Applies To Layer", ["ENRICHED", "ANALYTICS", "ALL"])
        new_name     = st.text_input("Rule Name", help="Short identifier, e.g. schema_reference_style")
        new_value    = st.text_area("Rule Value (the enforceable rule)", height=80)
        new_desc     = st.text_area("Description (optional context)", height=60)

        if st.form_submit_button("Add Contract", type="primary"):
            if new_category and new_name and new_value:
                try:
                    session.sql("""
                        INSERT INTO AGENT_FRAMEWORK.SCHEMA_CONTRACTS
                            (contract_scope, rule_category, rule_name, rule_value,
                             description, applies_to_layer, is_active, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, TRUE, CURRENT_USER())
                    """, params=[new_scope, new_category, new_name,
                                 new_value, new_desc, new_layer]).collect()
                    st.success(f"Contract added: [{new_category}] {new_name}")
                    st.cache_data.clear()
                    st.rerun()
                except Exception as e:
                    st.error(f"Failed to add contract: {e}")
            else:
                st.warning("Rule Category, Rule Name, and Rule Value are required.")


def render_directives_tab():
    st.subheader("Transformation Directives")
    st.markdown('<div class="info-strip">Per-table business intent. Tell the agent what each table is FOR — demand forecasting, churn prediction, general hygiene, etc. Matched via SQL LIKE patterns on table names.</div>', unsafe_allow_html=True)

    df_directives = run_query("""
        SELECT directive_id, source_table_pattern, target_layer,
               use_case, instructions, priority, is_active
        FROM AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
        ORDER BY priority DESC, source_table_pattern
    """)

    if df_directives.empty:
        st.info("No directives defined. Seed defaults or add one below.")
    else:
        st.data_editor(
            df_directives.drop(columns=["DIRECTIVE_ID"]),
            use_container_width=True,
            num_rows="fixed",
            column_config={
                "SOURCE_TABLE_PATTERN": st.column_config.TextColumn("Table Pattern", help="SQL LIKE pattern, e.g. 'ORDERS' or '%' for all"),
                "TARGET_LAYER":         st.column_config.SelectboxColumn("Layer", options=["SILVER", "GOLD", "BOTH"]),
                "USE_CASE":             st.column_config.TextColumn("Use Case"),
                "INSTRUCTIONS":         st.column_config.TextColumn("Instructions (injected into LLM prompt)", width="large"),
                "PRIORITY":             st.column_config.NumberColumn("Priority", min_value=1, max_value=10),
                "IS_ACTIVE":            st.column_config.CheckboxColumn("Active"),
            },
            key="directives_editor",
            hide_index=True,
        )

        directive_edits = st.session_state.get("directives_editor", {})
        if directive_edits.get("edited_rows"):
            if st.button("💾 Save Directive Changes", type="primary", key="save_directives"):
                for row_idx, changes in directive_edits["edited_rows"].items():
                    directive_id = df_directives.iloc[row_idx]["DIRECTIVE_ID"]
                    for col, val in changes.items():
                        col_map = {"IS_ACTIVE": "is_active", "PRIORITY": "priority"}
                        db_col = col_map.get(col)
                        if db_col:
                            try:
                                session.sql(
                                    f"UPDATE AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES SET {db_col} = ? WHERE directive_id = ?",
                                    params=[val, directive_id]
                                ).collect()
                            except Exception as e:
                                st.error(f"Save failed: {e}")
                st.success("Directive changes saved.")
                st.cache_data.clear()
                st.rerun()

    st.divider()
    st.markdown("#### Add New Directive")

    with st.form("new_directive_form"):
        d1, d2, d3 = st.columns([2, 1, 1])
        with d1:
            new_pattern = st.text_input("Table Pattern", value="%", help="SQL LIKE pattern")
        with d2:
            new_layer = st.selectbox("Layer", ["SILVER", "GOLD", "BOTH"])
        with d3:
            new_priority = st.number_input("Priority", min_value=1, max_value=10, value=5)
        new_use_case     = st.text_input("Use Case (short label)")
        new_instructions = st.text_area("Instructions (injected into LLM prompt)", height=120)

        if st.form_submit_button("Add Directive", type="primary") and new_use_case and new_instructions:
            safe_instr = new_instructions.replace("'", "''")
            run_query(f"""
                INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
                    (source_table_pattern, target_layer, use_case, instructions, priority)
                VALUES ('{new_pattern}', '{new_layer}', '{new_use_case}', '{safe_instr}', {new_priority})
            """)
            st.success("Directive added.")
            st.cache_data.clear()
            st.rerun()

    if st.button("↺ Reset Directives to Defaults"):
        with st.spinner("Seeding defaults..."):
            run_call("CALL AGENT_FRAMEWORK.SEED_DEFAULT_DIRECTIVES()")
        st.success("Default directives restored")
        st.cache_data.clear()
        st.rerun()


def _run_phases(execution_id, skip_phases, diagram_container, phase_descriptions,
                stop_after=None):
    phase_placeholders = {p: st.empty() for p, *_ in PHASE_CONFIGS}
    status_placeholder = st.empty()
    status_placeholder.info("\u23f3 Starting workflow...")
    phases = [p for p, *_ in PHASE_CONFIGS]
    workflow_failed = False

    for i, phase in enumerate(phases):
        if phase in skip_phases:
            st.session_state["wf_phase_states"][phase] = "reused"
            phase_placeholders[phase].markdown(f"\u23e9 **Phase {i+1}: {phase}** \u2014 Reused from prior run")
            diagram_container.markdown(render_phase_diagram(st.session_state["wf_phase_states"]), unsafe_allow_html=True)
            continue

        if workflow_failed and phase != "REFLECTOR":
            st.session_state["wf_phase_states"][phase] = "skipped"
            phase_placeholders[phase].markdown(f"\u23ed\ufe0f **Phase {i+1}: {phase}** \u2014 Skipped")
            diagram_container.markdown(render_phase_diagram(st.session_state["wf_phase_states"]), unsafe_allow_html=True)
            continue

        st.session_state["wf_phase_states"][phase] = "running"
        diagram_container.markdown(render_phase_diagram(st.session_state["wf_phase_states"]), unsafe_allow_html=True)
        phase_placeholders[phase].markdown(f"\U0001f504 **Phase {i+1}: {phase}** \u2014 {phase_descriptions[phase]}...")
        status_placeholder.info(f"\u23f3 Running **{phase}**...")

        try:
            result = run_call(f"CALL AGENT_FRAMEWORK.WORKFLOW_{phase}('{execution_id}')")
            st.session_state["wf_phase_results"][phase] = result

            if isinstance(result, dict) and result.get("status") == "ERROR" and phase != "REFLECTOR":
                raise Exception(result.get("error", str(result)))

            st.session_state["wf_phase_states"][phase] = "completed"
            phase_placeholders[phase].markdown(f"\u2705 **Phase {i+1}: {phase}** \u2014 {phase_descriptions[phase]}")

        except Exception as e:
            err_msg = str(e)[:500]
            if phase == "REFLECTOR":
                st.session_state["wf_phase_states"][phase] = "completed"
                phase_placeholders[phase].markdown(f"\u26a0\ufe0f **Phase {i+1}: {phase}** \u2014 Partial ({err_msg[:80]})")
                st.session_state["wf_phase_results"][phase] = {"error": err_msg}
            else:
                st.session_state["wf_phase_states"][phase] = "failed"
                phase_placeholders[phase].markdown(f"\u274c **Phase {i+1}: {phase}** \u2014 FAILED")
                workflow_failed = True
                st.session_state["wf_failed"]        = True
                st.session_state["wf_failure_phase"] = phase
                st.session_state["wf_failure_error"] = err_msg

        diagram_container.markdown(render_phase_diagram(st.session_state["wf_phase_states"]), unsafe_allow_html=True)

        if stop_after and phase == stop_after and not workflow_failed:
            st.session_state["wf_awaiting_approval"]     = True
            st.session_state["wf_approval_execution_id"] = execution_id
            st.session_state["wf_running"]               = False
            run_query(f"""
                UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
                SET current_phase = 'AWAITING_APPROVAL'
                WHERE execution_id = '{execution_id}'
            """)
            st.cache_data.clear()
            st.rerun()
            return

    final_status = "FAILED" if workflow_failed else "COMPLETED"
    run_query(f"""
        UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
        SET status = '{final_status}', completed_at = CURRENT_TIMESTAMP()
        WHERE execution_id = '{execution_id}'
    """)
    st.session_state["wf_running"]           = False
    st.session_state["wf_awaiting_approval"] = False
    st.cache_data.clear()
    st.rerun()


# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# Workflow Tab \u2014 module-level constants and helpers
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

_PHASE_DESCRIPTIONS = {
    "SCHEMA_ANALYST": "Discovering FK relationships across all tables",
    "PLANNER":        "LLM analyzing schemas & planning transformations",
    "EXECUTOR":       "Running transformations with self-correction",
    "VALIDATOR":      "Validating data quality & row counts",
    "REFLECTOR":      "Capturing learnings for future runs",
}

_PHASE_ORDER = ["SCHEMA_ANALYST", "PLANNER", "EXECUTOR", "VALIDATOR", "REFLECTOR"]

_IN_PROGRESS_STATUSES = {"PENDING", "PLANNING", "EXECUTING", "VALIDATING", "REFLECTING"}


def _fetch_workflow_state() -> dict:
    df = run_query("""
        SELECT execution_id, status, current_phase, started_at, completed_at,
               DATEDIFF('second', started_at, COALESCE(completed_at, CURRENT_TIMESTAMP())) AS elapsed_sec
        FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
        ORDER BY started_at DESC LIMIT 1
    """)
    latest     = df.iloc[0] if not df.empty else None
    db_status  = str(latest["STATUS"])        if latest is not None else None
    db_phase   = str(latest["CURRENT_PHASE"]) if latest is not None else None
    db_elapsed = int(latest["ELAPSED_SEC"])   if latest is not None else 0
    db_eid     = str(latest["EXECUTION_ID"])  if latest is not None else None
    is_running = db_status in _IN_PROGRESS_STATUSES
    return {
        "db_status":  db_status,
        "db_phase":   db_phase,
        "db_elapsed": db_elapsed,
        "db_eid":     db_eid,
        "is_running": is_running,
        "is_stuck":   is_running and not st.session_state.get("wf_running", False),
    }


def _rel_section(label: str, df: pd.DataFrame, approval_eid: str, flag: bool = False):
    if df.empty:
        return
    st.markdown(f"**{label}** ({len(df)})")
    display = df[["SOURCE_TABLE","SOURCE_COLUMN","TARGET_TABLE","TARGET_COLUMN",
                  "RELATIONSHIP_TYPE","CONFIDENCE_PCT"]].copy()
    display.columns = ["From Table","FK Column","\u2192 References","PK Column","Type","Conf %"]
    display["From Table"]           = display["From Table"].str.split(".").str[-1]
    display["\u2192 References"]    = display["\u2192 References"].str.split(".").str[-1]
    st.dataframe(display, use_container_width=True, hide_index=True,
        column_config={
            "From Table":          st.column_config.TextColumn(width=120),
            "FK Column":           st.column_config.TextColumn(width=160),
            "\u2192 References":   st.column_config.TextColumn(width=120),
            "PK Column":           st.column_config.TextColumn(width=120),
            "Type":                st.column_config.TextColumn(width=80),
            "Conf %":              st.column_config.NumberColumn(format="%d%%", width=70),
        })
    if not flag:
        return
    del_opts = [
        f"{r['SOURCE_TABLE'].split('.')[-1]}.{r['SOURCE_COLUMN']} \u2192 "
        f"{r['TARGET_TABLE'].split('.')[-1]}.{r['TARGET_COLUMN']}"
        for _, r in df.iterrows()
    ]
    to_delete = st.multiselect(f"Select to remove from {label.split()[0]} group:",
                               options=del_opts, default=[], key=f"del_{label[:10]}")
    if to_delete and st.button(f"\U0001f5d1 Remove selected ({len(to_delete)})", key=f"del_btn_{label[:10]}"):
        for rel_str in to_delete:
            parts = rel_str.split(" \u2192 ")
            src = parts[0].split(".")
            tgt = parts[1].split(".")
            run_query(f"""
                DELETE FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
                WHERE execution_id = '{approval_eid}'
                  AND source_table  LIKE '%{src[0]}'
                  AND source_column = '{src[1]}'
                  AND target_table  LIKE '%{tgt[0]}'
            """)
        st.cache_data.clear()
        st.rerun()


def _render_approval_gate(approval_eid: str, diagram_container, phase_descriptions: dict):
    rels_df = run_query(f"""
        SELECT source_table, source_column, target_table, target_column,
               relationship_type, ROUND(confidence * 100) AS confidence_pct
        FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
        WHERE execution_id = '{approval_eid}'
        ORDER BY confidence_pct DESC, source_table
    """)

    if rels_df.empty:
        st.info("\u2139\ufe0f Schema Analyst found no cross-table relationships. Proceeding automatically to Planner.")
        st.session_state["wf_awaiting_approval"] = False
        st.session_state["wf_running"]           = True
        st.session_state.setdefault("wf_phase_states",  {p: "pending" for p, *_ in PHASE_CONFIGS})
        st.session_state.setdefault("wf_phase_results", {})
        st.session_state.setdefault("wf_failed",        False)
        st.session_state.setdefault("wf_failure_phase", None)
        st.session_state.setdefault("wf_failure_error", None)
        _run_phases(approval_eid, skip_phases={"SCHEMA_ANALYST"},
                    diagram_container=diagram_container,
                    phase_descriptions=phase_descriptions)
        return

    st.warning(
        f"\u23f8\ufe0f **Awaiting approval** \u2014 Schema Analyst discovered **{len(rels_df)} relationships**. "
        f"Review and remove any incorrect ones before the Planner runs."
    )
    high   = rels_df[rels_df["CONFIDENCE_PCT"] >= 95]
    medium = rels_df[(rels_df["CONFIDENCE_PCT"] >= 85) & (rels_df["CONFIDENCE_PCT"] < 95)]
    low    = rels_df[rels_df["CONFIDENCE_PCT"] < 85]

    with st.container(border=True):
        _rel_section("\u2705 High confidence (\u226595%)", high, approval_eid)
        if not medium.empty or not low.empty:
            st.divider()
        _rel_section("\U0001f7e1 Medium confidence (85\u201394%) \u2014 review carefully", medium, approval_eid, flag=True)
        _rel_section("\U0001f534 Low confidence (<85%) \u2014 likely incorrect", low, approval_eid, flag=True)

    a1, a2 = st.columns([2, 1])
    with a1:
        if st.button("\u2705 Approve & Continue to Planner", type="primary",
                     use_container_width=True, key="approve_relationships_btn"):
            st.session_state["wf_awaiting_approval"] = False
            st.session_state["wf_running"]           = True
            _run_phases(approval_eid, skip_phases={"SCHEMA_ANALYST"},
                        diagram_container=diagram_container,
                        phase_descriptions=phase_descriptions)
    with a2:
        if st.button("\u2717 Cancel Run", use_container_width=True, key="cancel_approval_btn"):
            run_query(f"""
                UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
                SET status = 'FAILED', completed_at = CURRENT_TIMESTAMP()
                WHERE execution_id = '{approval_eid}'
            """)
            st.session_state["wf_awaiting_approval"] = False
            st.cache_data.clear()
            st.rerun()
    st.divider()


def _render_workflow_status(state: dict, phase_results: dict):
    db_status  = state["db_status"]
    db_phase   = state["db_phase"]
    db_elapsed = state["db_elapsed"]
    db_eid     = state["db_eid"]
    is_running = state["is_running"]
    is_stuck   = state["is_stuck"]

    if is_running and not is_stuck:
        st.info(f"\u23f3 **Workflow running** \u2014 Phase: **{db_phase or '...'}** &nbsp;|&nbsp; Elapsed: {db_elapsed}s")
        return

    if is_stuck:
        st.warning(
            f"\u26a0\ufe0f **Workflow interrupted** \u2014 Execution `{db_eid}` is marked **{db_phase}** in the database "
            f"but is no longer running in this session. Cancel this run to start a new one."
        )
        if st.button("\U0001f5d1 Cancel Interrupted Run", type="primary"):
            run_query(f"""
                UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
                SET status = 'FAILED', completed_at = CURRENT_TIMESTAMP()
                WHERE execution_id = '{db_eid}'
            """)
            for k in ("wf_phase_states", "wf_phase_results", "wf_running"):
                st.session_state.pop(k, None)
            st.cache_data.clear()
            st.rerun()
        return

    if phase_results and db_status == "COMPLETED":
        executor_r  = phase_results.get("EXECUTOR",  {})
        planner_r   = phase_results.get("PLANNER",   {})
        validator_r = phase_results.get("VALIDATOR", {})
        reflector_r = phase_results.get("REFLECTOR", {})
        dry_run_count = executor_r.get('dry_run_count', 0) or 0
        success_count = executor_r.get('success_count', 0) or 0
        if dry_run_count and dry_run_count > int(success_count or 0):
            st.info(f"\U0001f50d **Dry run complete** \u2014 {db_elapsed}s &nbsp;|&nbsp; ID: `{db_eid}`  \n"
                    f"DDL generated for **{dry_run_count}** table(s) \u2014 nothing written. "
                    f"Review DDL in the **Observe** tab (status = DRY_RUN), "
                    f"then set **Dry Run OFF** in Context and re-run.")
        else:
            st.success(f"\u2705 **Last run complete** \u2014 {db_elapsed}s &nbsp;|&nbsp; ID: `{db_eid}`")
        aborted = run_query(f"""
            SELECT LEFT(message, 200) AS msg FROM AGENT_FRAMEWORK.WORKFLOW_LOG
            WHERE status = 'ABORTED' AND execution_id = '{db_eid}'
            ORDER BY created_at LIMIT 5
        """)
        for _, r in aborted.iterrows():
            st.warning(f"\u26d4 **ABORTED:** {r['MSG']}")
        st.markdown(f"""
| Metric | Value |
|--------|-------|
| Tables Planned | {planner_r.get('tables_planned', '—')} |
| DDL Generated (Dry Run) | {dry_run_count if dry_run_count else '—'} |
| Executions Succeeded | {executor_r.get('success_count', '—')} |
| Executions Failed | {executor_r.get('fail_count', '—')} |
| Output Schema | {executor_r.get('output_schema', '—')} |
| Validations Passed | {validator_r.get('pass_count', '—')} |
| Learnings Captured | {reflector_r.get('learnings_processed', '—')} |
""")
        return

    if db_status == "COMPLETED" and db_eid:
        st.success(f"\u2705 **Last run complete** \u2014 {db_elapsed}s &nbsp;|&nbsp; ID: `{db_eid}`")
        return

    if db_status == "FAILED" and db_eid:
        fail_phase = st.session_state.get("wf_failure_phase") or db_phase or ""
        st.error(f"\u274c **Last run failed** at phase: **{fail_phase}**")
        if st.session_state.get("wf_failure_error"):
            st.code(st.session_state["wf_failure_error"])
        _RESUME_LABELS = {
            "SCHEMA_ANALYST":     "Restart from Schema Analyst",
            "PLANNER":            "Resume from Planner",
            "EXECUTOR":           "Resume from Executor (reuse Planner decisions)",
            "VALIDATOR":          "Resume from Validator (reuse Executor output)",
            "VALIDATOR_COMPLETE": "Resume from Validator (reuse Executor output)",
            "REFLECTOR":          "Resume from Reflector",
        }
        resume_label = _RESUME_LABELS.get(fail_phase.upper(), "Resume Workflow")
        st.info(f"\U0001f4a1 **{resume_label}** \u2014 click below to continue without re-running completed phases.")


def _build_table_selector() -> str:
    lineage_count_df = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")
    lineage_count = int(lineage_count_df.iloc[0]["CNT"]) if not lineage_count_df.empty else 0

    if lineage_count == 0:
        raw_df = run_query("""
            SELECT CURRENT_DATABASE() AS DB, table_schema AS SCH, table_name AS TBL
            FROM INFORMATION_SCHEMA.TABLES WHERE table_schema = 'RAW' ORDER BY table_name
        """)
        if raw_df.empty:
            st.warning("No Foundation tables found in RAW schema. Add tables and re-run Bootstrap from the Setup tab.")
            return ""
        db = raw_df.iloc[0]["DB"]
        all_tables = [f"{db}.{r['SCH']}.{r['TBL']}" for _, r in raw_df.iterrows()]
        st.info(f"Bootstrap not yet run. {len(all_tables)} Foundation tables found in RAW schema.")
        selected = st.multiselect("Select tables to transform (leave empty = all)", options=all_tables, default=[])
        chosen = selected if selected else all_tables
        return "ARRAY_CONSTRUCT(" + ", ".join(f"'{t}'" for t in chosen) + ")"

    show_all = st.checkbox(
        "Include already-processed tables", value=False, key="wf_show_all_tables",
        help="Check to re-run a completed table \u2014 e.g. to test overwrite protection."
    )
    all_tables_df = run_query("""
        SELECT bronze_database, bronze_schema, bronze_table, silver_status
        FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP ORDER BY bronze_table
    """)
    if show_all:
        all_tables = [
            f"{r['BRONZE_DATABASE']}.{r['BRONZE_SCHEMA']}.{r['BRONZE_TABLE']}"
            + (" [done]" if r['SILVER_STATUS'] == 'COMPLETE' else "")
            for _, r in all_tables_df.iterrows()
        ]
    else:
        pending_df = all_tables_df[all_tables_df['SILVER_STATUS'] != 'COMPLETE']
        if pending_df.empty:
            st.success('All Foundation tables have Enriched coverage. Check "Include already-processed tables" to re-run one.')
        all_tables = [
            f"{r['BRONZE_DATABASE']}.{r['BRONZE_SCHEMA']}.{r['BRONZE_TABLE']}"
            for _, r in (all_tables_df if show_all else pending_df).iterrows()
        ]

    selected = st.multiselect(
        "Select tables to transform (leave empty = all pending)", options=all_tables, default=[],
    )
    if selected:
        cleaned = [t.replace(" [done]", "") for t in selected]
        return "ARRAY_CONSTRUCT(" + ", ".join(f"'{t}'" for t in cleaned) + ")"
    pending = [t for t in all_tables if "[done]" not in t]
    return "ARRAY_CONSTRUCT(" + ", ".join(f"'{t}'" for t in pending) + ")"


def _start_new_run(tables_param_sql: str, workflow_name: str, auto_approve: bool, diagram_container):
    st.session_state["wf_phase_states"]  = {p: "pending" for p, *_ in PHASE_CONFIGS}
    st.session_state["wf_phase_results"] = {}
    st.session_state["wf_failed"]        = False
    st.session_state["wf_failure_phase"] = None
    st.session_state["wf_failure_error"] = None
    st.session_state["wf_running"]       = True

    eid_df = run_query("SELECT UUID_STRING() AS eid")
    execution_id = eid_df.iloc[0]["EID"] if not eid_df.empty else "unknown"
    st.session_state["wf_execution_id"] = execution_id

    safe_name = (workflow_name.strip().replace("'", "''") or f"RUN_{execution_id[:8].upper()}")
    run_query(f"""
        INSERT INTO AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            (execution_id, workflow_name, trigger_source, trigger_type, status, tables_requested)
        SELECT '{execution_id}', '{safe_name}', 'manual', 'MANUAL', 'PENDING', {tables_param_sql}
    """)
    _run_phases(execution_id, skip_phases=set(), diagram_container=diagram_container,
                phase_descriptions=_PHASE_DESCRIPTIONS,
                stop_after=None if auto_approve else "SCHEMA_ANALYST")


def _render_resume_button(state: dict, run_button_disabled: bool, diagram_container):
    db_status = state["db_status"]
    db_phase  = state["db_phase"]
    db_eid    = state["db_eid"]

    if db_status != "FAILED" or not db_eid:
        return

    _phase_key   = (db_phase or "").replace("_COMPLETE", "").replace("_ERROR", "")
    _resume_idx  = _PHASE_ORDER.index(_phase_key) if _phase_key in _PHASE_ORDER else 0
    _skip_phases = set(_PHASE_ORDER[:_resume_idx])

    prior_decisions_df = run_query(f"""
        SELECT COUNT(*) AS cnt FROM AGENT_FRAMEWORK.PLANNER_DECISIONS WHERE execution_id = '{db_eid}'
    """) if "PLANNER" in _skip_phases else None
    _has_decisions = ("PLANNER" not in _skip_phases or (
        prior_decisions_df is not None and not prior_decisions_df.empty
        and int(prior_decisions_df.iloc[0]["CNT"]) > 0
    ))

    prior_executor_df = run_query(f"""
        SELECT executor_output FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS WHERE execution_id = '{db_eid}'
    """) if "EXECUTOR" in _skip_phases else None
    _has_executor_output = ("EXECUTOR" not in _skip_phases or (
        prior_executor_df is not None and not prior_executor_df.empty
        and prior_executor_df.iloc[0]["EXECUTOR_OUTPUT"] is not None
    ))

    if not (_has_decisions and _has_executor_output):
        return

    _resume_labels = {
        "SCHEMA_ANALYST": "\u21bb Restart from Schema Analyst",
        "PLANNER":        "\u21bb Resume from Planner",
        "EXECUTOR":       "\u21bb Resume from Executor",
        "VALIDATOR":      "\u21bb Resume from Validator",
        "REFLECTOR":      "\u21bb Resume from Reflector",
    }
    if not st.button(_resume_labels.get(_phase_key, "\u21bb Resume Workflow"),
                     use_container_width=True, key="resume_workflow_btn",
                     disabled=run_button_disabled, type="primary"):
        return

    _initial_states = {p: ("reused" if p in _skip_phases else "pending") for p in _PHASE_ORDER}
    st.session_state["wf_phase_states"]  = _initial_states
    st.session_state["wf_phase_results"] = {}
    st.session_state["wf_failed"]        = False
    st.session_state["wf_failure_phase"] = None
    st.session_state["wf_failure_error"] = None
    st.session_state["wf_running"]       = True

    eid_df = run_query("SELECT UUID_STRING() AS eid")
    new_eid = eid_df.iloc[0]["EID"] if not eid_df.empty else "unknown"
    st.session_state["wf_execution_id"] = new_eid

    run_query(f"""
        INSERT INTO AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            (execution_id, workflow_name, trigger_source, trigger_type, status, tables_requested)
        SELECT '{new_eid}', 'SILVER_BUILDER', 'resume', 'MANUAL', 'PENDING', tables_requested
        FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS WHERE execution_id = '{db_eid}'
    """)
    if "SCHEMA_ANALYST" in _skip_phases:
        run_query(f"""
            INSERT INTO AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS
                (execution_id, source_table, source_column, target_table,
                 target_column, relationship_type, confidence)
            SELECT '{new_eid}', source_table, source_column, target_table,
                   target_column, relationship_type, confidence
            FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS WHERE execution_id = '{db_eid}'
        """)
        run_query(f"""
            UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            SET schema_analyst_completed_at = CURRENT_TIMESTAMP(),
                current_phase = 'SCHEMA_ANALYST_COMPLETE'
            WHERE execution_id = '{new_eid}'
        """)
    if "PLANNER" in _skip_phases:
        run_query(f"""
            INSERT INTO AGENT_FRAMEWORK.PLANNER_DECISIONS
                (execution_id, source_table, target_schema, transformation_strategy,
                 detected_patterns, recommended_actions, priority, llm_reasoning,
                 confidence_score, model_used)
            SELECT '{new_eid}', source_table, target_schema, transformation_strategy,
                   detected_patterns, recommended_actions, priority, llm_reasoning,
                   confidence_score, model_used
            FROM AGENT_FRAMEWORK.PLANNER_DECISIONS WHERE execution_id = '{db_eid}'
        """)
        run_query(f"""
            UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            SET planning_completed_at = CURRENT_TIMESTAMP(),
                current_phase = 'PLANNER_COMPLETE'
            WHERE execution_id = '{new_eid}'
        """)
    if "EXECUTOR" in _skip_phases:
        run_query(f"""
            UPDATE AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
            SET executor_output = (SELECT executor_output FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS
                                   WHERE execution_id = '{db_eid}'),
                execution_completed_at = CURRENT_TIMESTAMP(),
                current_phase = 'EXECUTOR_COMPLETE'
            WHERE execution_id = '{new_eid}'
        """)
    _run_phases(new_eid, skip_phases=_skip_phases,
                diagram_container=diagram_container,
                phase_descriptions=_PHASE_DESCRIPTIONS)


def _render_run_history(db_eid: str):
    hist_df = run_query("""
        SELECT execution_id, status, current_phase,
               ARRAY_SIZE(tables_requested) AS tables_count,
               started_at, completed_at,
               schema_analyst_completed_at, planning_completed_at,
               execution_completed_at, validation_completed_at, reflection_completed_at,
               DATEDIFF('second', started_at, COALESCE(completed_at, CURRENT_TIMESTAMP())) AS total_sec,
               DATEDIFF('second', started_at,                  schema_analyst_completed_at) AS analyst_sec,
               DATEDIFF('second', schema_analyst_completed_at, planning_completed_at)       AS plan_sec,
               DATEDIFF('second', planning_completed_at,       execution_completed_at)      AS exec_sec,
               DATEDIFF('second', execution_completed_at,      validation_completed_at)     AS val_sec,
               DATEDIFF('second', validation_completed_at,
                        COALESCE(reflection_completed_at, completed_at, CURRENT_TIMESTAMP())) AS reflect_sec
        FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS ORDER BY started_at DESC LIMIT 10
    """)

    if hist_df.empty:
        st.caption("No runs yet.")
        return

    def _sec(val):
        try:
            v = float(val)
            return 0 if (v != v) else int(v)
        except (TypeError, ValueError):
            return 0

    st.markdown("#### \u23f1 Step Timing \u2014 Latest Run")
    latest    = hist_df.iloc[0]
    analyst_s = _sec(latest.get("ANALYST_SEC"))
    plan_s    = _sec(latest.get("PLAN_SEC"))
    exec_s    = _sec(latest.get("EXEC_SEC"))
    val_s     = _sec(latest.get("VAL_SEC"))
    reflect_s = _sec(latest.get("REFLECT_SEC"))
    total_s   = _sec(latest.get("TOTAL_SEC"))

    c1, c2, c3, c4, c5, c6 = st.columns(6)
    c1.metric("\U0001f50d Analyst",  f"{analyst_s}s",  delta=f"{analyst_s/total_s*100:.0f}% of total"  if total_s else None, delta_color="off")
    c2.metric("\U0001f9e0 Plan",     f"{plan_s}s",     delta=f"{plan_s/total_s*100:.0f}% of total"     if total_s else None, delta_color="off")
    c3.metric("\u2699\ufe0f Execute",f"{exec_s}s",     delta=f"{exec_s/total_s*100:.0f}% of total"     if total_s else None, delta_color="off")
    c4.metric("\u2705 Validate",     f"{val_s}s",      delta=f"{val_s/total_s*100:.0f}% of total"      if total_s else None, delta_color="off")
    c5.metric("\U0001f501 Reflect",  f"{reflect_s}s",  delta=f"{reflect_s/total_s*100:.0f}% of total"  if total_s else None, delta_color="off")
    c6.metric("\U0001f3c1 Total",    f"{total_s}s")

    bar_data = pd.DataFrame({
        "Step":    ["\U0001f50d Analyst", "\U0001f9e0 Plan", "\u2699\ufe0f Execute", "\u2705 Validate", "\U0001f501 Reflect"],
        "Seconds": [analyst_s, plan_s, exec_s, val_s, reflect_s],
    })
    st.bar_chart(bar_data.set_index("Step"), color="#4C78A8", height=220)

    if len(hist_df) > 1:
        st.markdown("#### All Runs \u2014 Step Timing")
        timing_cols = ["EXECUTION_ID","STATUS","TABLES_COUNT",
                       "PLAN_SEC","EXEC_SEC","VAL_SEC","REFLECT_SEC","TOTAL_SEC"]
        st.dataframe(
            hist_df[[c for c in timing_cols if c in hist_df.columns]],
            use_container_width=True, hide_index=True,
            column_config={
                "EXECUTION_ID": st.column_config.TextColumn("Run ID",      width=220),
                "STATUS":       st.column_config.TextColumn("Status",      width=90),
                "TABLES_COUNT": st.column_config.NumberColumn("Tables",    width=70),
                "PLAN_SEC":     st.column_config.NumberColumn("Plan (s)",     format="%d"),
                "EXEC_SEC":     st.column_config.NumberColumn("Execute (s)",  format="%d"),
                "VAL_SEC":      st.column_config.NumberColumn("Validate (s)", format="%d"),
                "REFLECT_SEC":  st.column_config.NumberColumn("Reflect (s)",  format="%d"),
                "TOTAL_SEC":    st.column_config.NumberColumn("Total (s)",    format="%d"),
            },
        )

    st.markdown("#### Execution Detail")
    selected_exec = st.selectbox("View execution", options=hist_df["EXECUTION_ID"].tolist())
    if selected_exec:
        detail_df = run_query(f"""
            SELECT source_table, transformation_strategy, confidence_score, llm_reasoning, model_used
            FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
            WHERE execution_id = '{selected_exec}' ORDER BY priority
        """)
        if not detail_df.empty:
            st.dataframe(detail_df, use_container_width=True, hide_index=True)
        else:
            st.caption("No planner decisions for this execution.")

    if "wf_phase_results" in st.session_state and st.session_state["wf_phase_results"]:
        with st.expander("\U0001f4cb Last Run \u2014 Full JSON"):
            st.json(st.session_state["wf_phase_results"])


# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# Workflow Tab \u2014 orchestrator (thin)
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

def render_workflow_tab():
    st.header("\U0001f916 Agentic Workflow Engine")
    st.markdown('<div class="info-strip">Runs the five-phase agentic pipeline: <strong>Schema Analyst \u2192 Planner \u2192 Executor \u2192 Validator \u2192 Reflector</strong>. Each phase is called individually so you see live progress as it runs.</div>', unsafe_allow_html=True)

    state = _fetch_workflow_state()

    if not state["is_running"]:
        st.session_state["wf_running"] = False

    if state["db_phase"] == "AWAITING_APPROVAL" and state["db_status"] == "ANALYZING":
        if not st.session_state.get("wf_awaiting_approval"):
            st.session_state["wf_awaiting_approval"]     = True
            st.session_state["wf_approval_execution_id"] = state["db_eid"]

    diagram_container = st.empty()
    diagram_container.markdown(
        render_phase_diagram(st.session_state.get("wf_phase_states", {})),
        unsafe_allow_html=True
    )

    if st.session_state.get("wf_awaiting_approval"):
        approval_eid = st.session_state.get("wf_approval_execution_id", state["db_eid"])
        _render_approval_gate(approval_eid, diagram_container, _PHASE_DESCRIPTIONS)
    else:
        _render_workflow_status(state, st.session_state.get("wf_phase_results", {}))

    st.divider()

    col1, col2 = st.columns([1, 1])
    with col1:
        st.subheader("\U0001f680 Run Workflow")
        run_button_disabled = state["is_running"] or st.session_state.get("wf_awaiting_approval", False)
        auto_approve = st.checkbox(
            "Auto-approve Schema Analyst relationships",
            value=st.session_state.get("wf_auto_approve", False),
            help="Skip the relationship review gate and proceed directly to the Planner.",
            key="auto_approve_checkbox"
        )
        st.session_state["wf_auto_approve"] = auto_approve
        tables_param_sql = _build_table_selector()
        workflow_name = st.text_input(
            "Workflow Name", value="",
            placeholder="e.g. RENSPETS_DRY_RUN_01",
            help="Optional label to identify this run in the Observe tab. Auto-generated if left blank.",
            key="wf_name_input"
        )
        if st.button("\U0001f916 Run Agentic Workflow", type="primary",
                     use_container_width=True, disabled=run_button_disabled,
                     key="run_workflow_btn"):
            _start_new_run(tables_param_sql, workflow_name, auto_approve, diagram_container)
        _render_resume_button(state, run_button_disabled, diagram_container)
        st.markdown("---")
        qa1, qa2 = st.columns(2)
        with qa1:
            if st.button("\U0001f504 Refresh Dashboard", use_container_width=True, key="wf_refresh"):
                st.cache_data.clear()
                st.rerun()
        with qa2:
            if st.button("\U0001f9f9 Clear Workflow History", use_container_width=True, key="wf_clear"):
                run_call("CALL AGENT_FRAMEWORK.CLEAR_WORKFLOW_HISTORY()")
                st.success("Workflow history cleared.")
                st.cache_data.clear()
                st.rerun()
    with col2:
        st.subheader("\U0001f4ca Recent Runs")
        _render_run_history(state["db_eid"])

    if state["is_running"] and not state["is_stuck"]:
        time.sleep(3)
        st.rerun()

def render_gold_tab():
    st.subheader("Analytics Builder")
    st.markdown('<div class="info-strip">The agent proposes Analytics DDL for each Enriched table with no Analytics coverage. <strong>You review every DDL before execution.</strong> Execute directly or export as a DCM project for production handoff.</div>', unsafe_allow_html=True)

    ctx = _db_context()
    built_df = run_query(f"""
        SELECT
            t.TABLE_NAME                            AS ANALYTICS_OBJECT,
            t.TABLE_TYPE                            AS TYPE,
            t.ROW_COUNT                             AS NUM_ROWS,
            t.BYTES                                 AS SIZE_BYTES,
            t.CREATED                               AS CREATED_AT,
            t.LAST_ALTERED                          AS LAST_MODIFIED,
            COALESCE(lm.silver_table, '—')          AS SOURCE_ENRICHED_TABLE,
            COALESCE(lm.last_refreshed_at::VARCHAR, '—') AS LAST_PIPELINE_RUN
        FROM {ctx['db']}.INFORMATION_SCHEMA.TABLES t
        LEFT JOIN AGENT_FRAMEWORK.TABLE_LINEAGE_MAP lm
            ON UPPER(lm.gold_table) = UPPER(t.TABLE_NAME)
        WHERE t.TABLE_SCHEMA = 'GOLD'
        ORDER BY t.TABLE_NAME
    """)

    if not built_df.empty:
        a1, a2, a3 = st.columns(3)
        a1.metric("Analytics Objects", len(built_df))
        a2.metric("Total Rows", f"{int(built_df['NUM_ROWS'].fillna(0).sum()):,}")
        total_mb = built_df["SIZE_BYTES"].fillna(0).sum() / 1_048_576

        a3.metric("Total Size", f"{total_mb:.1f} MB")

        st.dataframe(
            built_df.drop(columns=["SIZE_BYTES"]),
            use_container_width=True,
            hide_index=True,
            column_config={
                "ANALYTICS_OBJECT":    st.column_config.TextColumn("Object", width="medium"),
                "TYPE":                st.column_config.TextColumn("Type", width="small"),
                "NUM_ROWS":             st.column_config.NumberColumn("Rows", format="%d"),
                "CREATED_AT":          st.column_config.DatetimeColumn("Created", format="MMM D, YYYY HH:mm"),
                "LAST_MODIFIED":       st.column_config.DatetimeColumn("Last Modified", format="MMM D, YYYY HH:mm"),
                "SOURCE_ENRICHED_TABLE": st.column_config.TextColumn("Source (Enriched)", width="medium"),
                "LAST_PIPELINE_RUN":   st.column_config.TextColumn("Last Pipeline Run"),
            },
        )
        st.divider()
    else:
        st.info("No Analytics objects built yet. Propose and execute DDLs below.")
        st.divider()

    gold_gaps = run_query("""
        SELECT bronze_table, bronze_schema, silver_table, silver_schema, gold_status
        FROM AGENT_FRAMEWORK.GOLD_GAPS ORDER BY silver_table
    """)

    silver_count_df = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE silver_table IS NOT NULL")
    silver_count = int(silver_count_df.iloc[0]["CNT"]) if not silver_count_df.empty else 0

    if gold_gaps.empty and silver_count == 0:
        st.info("No Enriched tables yet. Run the Enrichment Workflow first.")
    elif gold_gaps.empty:
        st.success("All Enriched tables have Analytics coverage.")
    else:
        st.markdown(f"**{len(gold_gaps)} Enriched tables without Analytics coverage.**")

        c_propose, c_opts = st.columns([1, 1])
        with c_propose:
            max_tables = st.slider("Max tables to propose", min_value=1, max_value=20, value=5)
        with c_opts:
            st.markdown("<br>", unsafe_allow_html=True)
            propose_clicked = st.button("🤖 Propose Analytics DDLs", type="primary", use_container_width=True)

        if propose_clicked:
            with st.spinner(f"Agent generating {max_tables} Analytics DDL proposals..."):
                result = run_call(f"CALL AGENT_FRAMEWORK.BUILD_GOLD_FOR_NEW_TABLES(TRUE, {max_tables})")
            proposals = result.get("proposals", []) if isinstance(result, dict) else []
            if proposals:
                st.session_state["gold_proposals"] = proposals
                st.success(f"Generated {len(proposals)} proposals. Review below.")
            else:
                st.warning(f"No proposals returned. Result: {result}")

    if "gold_proposals" in st.session_state and st.session_state["gold_proposals"]:
        st.divider()
        st.markdown("#### Review Proposals")

        ea_col, _ = st.columns([1, 2])
        with ea_col:
            if st.button("⚡ Execute All DDLs", type="primary", use_container_width=True, key="exec_all"):
                proposals = list(st.session_state["gold_proposals"])
                results = {"success": [], "failed": []}
                progress = st.progress(0, text="Executing Analytics DDLs...")
                for idx, proposal in enumerate(proposals):
                    silver = proposal.get("silver_table", f"Table {idx+1}")
                    ddl    = proposal.get("proposed_ddl", "")
                    silver_tbl = silver.split(".")[-1] if silver else None
                    progress.progress((idx) / len(proposals), text=f"Executing {silver_tbl} ({idx+1}/{len(proposals)})...")
                    exec_result = run_call_param("AGENT_FRAMEWORK.GOLD_AGENTIC_EXECUTOR", ddl, silver_tbl)
                    if exec_result.get("status") == "EXECUTED":
                        results["success"].append(exec_result.get("gold_table", silver_tbl))
                    else:
                        results["failed"].append({"table": silver_tbl, "error": exec_result.get("error", str(exec_result))})
                progress.progress(1.0, text="Done.")
                st.session_state["gold_proposals"] = []
                st.cache_data.clear()
                if results["success"]:
                    st.success(f"Created {len(results['success'])} Analytics tables: {', '.join(results['success'])}")
                if results["failed"]:
                    for f in results["failed"]:
                        st.error(f"Failed: {f['table']} — {f['error']}")
                st.rerun()

        for i, proposal in enumerate(list(st.session_state["gold_proposals"])):
            silver = proposal.get("silver_table", f"Table {i+1}")
            ddl    = proposal.get("proposed_ddl", "")

            with st.expander(f"📋 {silver}", expanded=(i == 0)):
                st.markdown(f'<div class="ddl-block">{ddl}</div>', unsafe_allow_html=True)

                col_exec, col_skip = st.columns([1, 1])
                with col_exec:
                    if st.button("✅ Execute DDL", key=f"exec_{i}", use_container_width=True):
                        with st.spinner(f"Executing DDL for {silver}..."):
                            silver_tbl = silver.split(".")[-1] if silver else None
                            exec_result = run_call_param("AGENT_FRAMEWORK.GOLD_AGENTIC_EXECUTOR", ddl, silver_tbl)
                        if exec_result.get("status") == "EXECUTED":
                            st.success(f"Created: {exec_result.get('gold_table')}")
                            st.session_state["gold_proposals"].pop(i)
                            st.cache_data.clear()
                            st.rerun()
                        else:
                            st.error(f"Execution failed: {exec_result}")
                with col_skip:
                    if st.button("⏭ Skip", key=f"skip_{i}", use_container_width=True):
                        st.session_state["gold_proposals"].pop(i)
                        st.rerun()

        st.divider()
        st.markdown("#### Export as DCM Project (Production Handoff)")
        st.markdown('<div class="info-strip">Exports all finalized Analytics tables as a DCM project to a Snowflake stage. SA downloads, commits to git, and customer deploys with <code>snow dcm deploy</code>.</div>', unsafe_allow_html=True)

        dcm_stage = st.text_input("Output Stage", value=f"@{ctx['db']}.AGENT_FRAMEWORK.AGENT_STAGE")
        if st.button("📦 Export DCM Project", use_container_width=True):
            with st.spinner("Generating DCM project files..."):
                dcm_result = run_call(f"CALL AGENT_FRAMEWORK.EXPORT_DCM_PROJECT('{dcm_stage}')")
            if dcm_result.get("status") == "EXPORTED":
                st.success(f"DCM project written to: {dcm_result.get('stage')}")
                st.markdown(f"**Tables exported:** {dcm_result.get('table_count', 0)}")
                st.code(dcm_result.get("next_steps", ""), language="bash")
            else:
                st.error(f"Export failed: {dcm_result}")


def render_observability_tab():
    st.subheader("Observability")
    _render_obs_kpi_metrics()
    st.divider()
    _render_obs_charts()
    st.divider()
    _render_obs_learnings()
    st.markdown("**Recent Workflow Log**")
    _render_obs_workflow_log()


def _render_obs_kpi_metrics():
    def _kv(df):
        return int(df["CNT"].iloc[0]) if not df.empty else 0

    runs_df      = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS")
    silver_df    = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE silver_status = 'COMPLETE'")
    gold_df      = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE gold_status = 'COMPLETE'")
    learnings_df = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS WHERE is_active = TRUE")
    total_df     = run_query("SELECT COUNT(*) AS CNT FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP")

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Workflow Runs",    _kv(runs_df))
    c2.metric("Enriched Tables",  _kv(silver_df),   delta=f"/ {_kv(total_df)} total")
    c3.metric("Analytics Tables", _kv(gold_df),     delta=f"/ {_kv(total_df)} total")
    c4.metric("Active Learnings", _kv(learnings_df))


def _render_obs_charts():
    col1, col2 = st.columns([2, 1])
    with col1:
        st.markdown("**Executor Results per Run**")
        exec_df = run_query("""
            SELECT workflow_name AS RUN,
                   COALESCE(executor_output:success_count::INT, 0) AS SUCCEEDED,
                   COALESCE(executor_output:fail_count::INT, 0)    AS FAILED
            FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS ORDER BY started_at
        """)
        if not exec_df.empty:
            st.bar_chart(exec_df.set_index("RUN")[["SUCCEEDED", "FAILED"]])
        else:
            st.info("No runs yet.")

    with col2:
        st.markdown("**Learning Types**")
        types_df = run_query("""
            SELECT learning_type AS TYPE, COUNT(*) AS COUNT
            FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
            WHERE is_active = TRUE GROUP BY 1
        """)
        if not types_df.empty:
            st.bar_chart(types_df.set_index("TYPE"))
        else:
            st.info("No learnings yet.")

    c1, c2, c3 = st.columns(3)
    with c1:
        st.markdown("**Confidence Distribution**")
        conf_df = run_query("""
            SELECT CASE WHEN confidence_score >= 0.9 THEN 'High (>=0.9)'
                        WHEN confidence_score >= 0.7 THEN 'Med (0.7-0.9)'
                        ELSE 'Low (<0.7)' END AS BAND,
                   COUNT(*) AS LEARNINGS
            FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
            WHERE is_active = TRUE GROUP BY 1
        """)
        if not conf_df.empty:
            st.bar_chart(conf_df.set_index("BAND"))

    with c2:
        st.markdown("**Layer Coverage**")
        cov_df = run_query("""
            SELECT CASE WHEN gold_status  = 'COMPLETE' THEN 'Full (F+E+A)'
                        WHEN silver_status = 'COMPLETE' THEN 'Foundation+Enriched'
                        ELSE 'Foundation Only' END AS COVERAGE,
                   COUNT(*) AS TABLES
            FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP GROUP BY 1
        """)
        if not cov_df.empty:
            st.bar_chart(cov_df.set_index("COVERAGE"))

    with c3:
        st.markdown("**Learnings per Run**")
        lpr_df = run_query("""
            SELECT e.workflow_name AS RUN, COUNT(l.learning_id) AS LEARNINGS
            FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS e
            LEFT JOIN AGENT_FRAMEWORK.WORKFLOW_LEARNINGS l
              ON l.execution_id = e.execution_id
            GROUP BY e.workflow_name, e.started_at ORDER BY e.started_at
        """)
        if not lpr_df.empty:
            st.bar_chart(lpr_df.set_index("RUN"))


def _render_obs_learnings():
    st.markdown("**Active Learnings — ranked by confidence**")
    top_df = run_query("""
        SELECT learning_type AS TYPE, source_context AS CONTEXT,
               observation AS OBSERVATION, recommendation AS RECOMMENDATION,
               ROUND(confidence_score, 2) AS CONFIDENCE, times_observed AS OBSERVED
        FROM AGENT_FRAMEWORK.WORKFLOW_LEARNINGS
        WHERE is_active = TRUE ORDER BY confidence_score DESC, times_observed DESC
    """)
    if top_df.empty:
        st.info("No learnings yet. Run the Agentic Workflow to start accumulating.")
        return

    all_types = sorted(top_df["TYPE"].dropna().unique().tolist())
    selected_types = st.multiselect("Drill into Learning Type", options=all_types,
                                    default=all_types, key="obs_type_filter")
    filtered_df = top_df[top_df["TYPE"].isin(selected_types)] if selected_types else top_df
    st.dataframe(filtered_df, use_container_width=True, hide_index=True)

    st.divider()
    st.markdown("**🔼 Promote a Learning**")
    promote_labels = [
        f"[{r['TYPE']}] {r['CONTEXT']} — {str(r['RECOMMENDATION'])[:70]}..."
        for _, r in filtered_df.iterrows()
    ]
    selected_promote = st.selectbox(
        "Select learning",
        ["— select a learning to promote —"] + promote_labels,
        key="promote_selector"
    )

    if selected_promote == "— select a learning to promote —":
        return

    sel_row    = filtered_df.iloc[promote_labels.index(selected_promote)]
    promote_as = st.radio("Promote as", ["📋 Schema Contract", "🎯 Directive"],
                          horizontal=True, key="promote_as")

    if promote_as == "📋 Schema Contract":
        with st.form("promote_contract_form"):
            st.caption("Adds a structural rule applied globally to every LLM prompt.")
            c1, c2 = st.columns(2)
            scope    = c1.text_input("Contract Scope", value="global")
            category = c2.text_input("Rule Category",
                value=sel_row["TYPE"].replace("success_pattern","").replace("failure_pattern","").replace("optimization","naming").strip("_") or "general")
            rule_name   = c1.text_input("Rule Name", value=sel_row["CONTEXT"].lower().replace(" ", "_")[:50])
            applies     = c2.selectbox("Applies To Layer", ["ENRICHED", "ANALYTICS", "ALL"])
            rule_value  = st.text_area("Rule Value", value=sel_row["RECOMMENDATION"], height=100)
            description = st.text_area("Description", value=sel_row["OBSERVATION"], height=80)
            if st.form_submit_button("✅ Promote to Schema Contract", type="primary"):
                try:
                    session.sql("""
                        INSERT INTO AGENT_FRAMEWORK.SCHEMA_CONTRACTS
                            (contract_scope, rule_category, rule_name, rule_value,
                             description, applies_to_layer, is_active, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, TRUE, CURRENT_USER())
                    """, params=[scope, category, rule_name, rule_value, description, applies]).collect()
                    st.success(f"Promoted to Schema Contract: [{category}] {rule_name}")
                    st.cache_data.clear()
                    st.rerun()
                except Exception as e:
                    st.error(f"Promotion failed: {e}")
    else:
        with st.form("promote_directive_form"):
            st.caption("Adds a per-table instruction injected into every EXECUTOR prompt matching the pattern.")
            c1, c2 = st.columns(2)
            pattern  = c1.text_input("Table Pattern (% = all)", value="%")
            layer    = c2.selectbox("Target Layer", ["ENRICHED", "ANALYTICS"])
            use_case = c1.text_input("Use Case",
                value=sel_row["TYPE"].replace("_pattern", "").strip("_") or "general")
            priority     = c2.number_input("Priority (1=highest)", min_value=1, max_value=10, value=5)
            instructions = st.text_area("Instructions", value=sel_row["RECOMMENDATION"], height=120)
            if st.form_submit_button("✅ Promote to Directive", type="primary"):
                try:
                    session.sql("""
                        INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
                            (source_table_pattern, target_layer, use_case,
                             instructions, priority, is_active, created_by)
                        VALUES (?, ?, ?, ?, ?, TRUE, CURRENT_USER())
                    """, params=[pattern, layer, use_case, instructions, int(priority)]).collect()
                    st.success(f"Promoted to Directive: [{layer}] {use_case} (pattern: {pattern})")
                    st.cache_data.clear()
                    st.rerun()
                except Exception as e:
                    st.error(f"Promotion failed: {e}")


def _render_obs_workflow_log():
    log_df = run_query("""
        SELECT created_at AS TIMESTAMP, phase AS PHASE, status AS STATUS, message AS MESSAGE
        FROM AGENT_FRAMEWORK.WORKFLOW_LOG ORDER BY created_at DESC LIMIT 50
    """)
    if log_df.empty:
        st.info("No log entries yet.")
        return

    def _row_style(row):
        if row["STATUS"] == "DRY_RUN":
            return ["background-color:#e8f4fd; color:#0c5460"] * len(row)
        if row["STATUS"] == "ABORTED":
            return ["background-color:#fff3cd; color:#856404; font-weight:bold"] * len(row)
        if row["STATUS"] in ("FAILED", "FATAL", "ERROR"):
            return ["background-color:#f8d7da; color:#721c24"] * len(row)
        if row["STATUS"] == "PASS":
            return ["background-color:#d4edda; color:#155724"] * len(row)
        return [""] * len(row)

    st.dataframe(log_df.style.apply(_row_style, axis=1), use_container_width=True, hide_index=True)

    dry_count     = int((log_df["STATUS"] == "DRY_RUN").sum())
    aborted_count = int((log_df["STATUS"] == "ABORTED").sum())
    if dry_count:
        st.info(f"🔍 {dry_count} DRY_RUN entries — DDL was generated but not executed. Review above.")
    if aborted_count:
        st.warning(f"⛔ {aborted_count} ABORTED entries — target tables had existing rows. Set **Allow Overwrite** ON or use a different output schema.")




def render_registry_tab():
    st.subheader("Pipeline Lineage & Relationships")

    ctx = _db_context()
    reg_tab1, reg_tab2 = st.tabs(["📊 Pipeline Flow", "🔗 Discovered Relationships"])

    with reg_tab1:
        lineage_df = run_query(f"""
            SELECT
                lm.bronze_table                                     AS FOUNDATION_TABLE,
                lm.bronze_database                                  AS BRONZE_DB,
                COALESCE(r.row_count, 0)                            AS FOUNDATION_ROWS,
                COALESCE(lm.silver_table, '—')                      AS ENRICHED_TABLE,
                COALESCE(lm.silver_schema, 'AGENT_FRAMEWORK_OUTPUT') AS ENRICHED_SCHEMA,
                COALESCE(s.row_count, 0)                            AS ENRICHED_ROWS,
                COALESCE(lm.gold_table, '—')                        AS ANALYTICS_TABLE,
                COALESCE(lm.gold_schema, 'GOLD')                    AS ANALYTICS_SCHEMA,
                COALESCE(g.row_count, 0)                            AS ANALYTICS_ROWS,
                lm.silver_status                                    AS ENRICHED_STATUS,
                lm.gold_status                                      AS ANALYTICS_STATUS,
                COALESCE(pd.transformation_strategy, 'unknown')     AS STRATEGY
            FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP lm
            LEFT JOIN {ctx['db']}.INFORMATION_SCHEMA.TABLES r
                ON r.table_schema = UPPER(lm.bronze_schema)
                AND UPPER(r.table_name) = UPPER(lm.bronze_table)
            LEFT JOIN INFORMATION_SCHEMA.TABLES s
                ON UPPER(s.table_schema) = UPPER(COALESCE(lm.silver_schema, 'AGENT_FRAMEWORK_OUTPUT'))
                AND UPPER(s.table_name)  = UPPER(COALESCE(lm.silver_table, ''))
            LEFT JOIN INFORMATION_SCHEMA.TABLES g
                ON UPPER(g.table_schema) = UPPER(COALESCE(lm.gold_schema, 'GOLD'))
                AND UPPER(g.table_name)  = UPPER(COALESCE(lm.gold_table, ''))
            LEFT JOIN (
                SELECT DISTINCT
                    UPPER(SPLIT_PART(source_table, '.', 3)) AS tbl,
                    transformation_strategy
                FROM AGENT_FRAMEWORK.PLANNER_DECISIONS
            ) pd ON UPPER(lm.bronze_table) = pd.tbl
            ORDER BY lm.bronze_table
        """)

        if not lineage_df.empty:
            total_f = int(lineage_df["FOUNDATION_ROWS"].fillna(0).sum())
            total_e = int(lineage_df["ENRICHED_ROWS"].fillna(0).sum())
            total_a = int(lineage_df["ANALYTICS_ROWS"].fillna(0).sum())
            cdc_drop = f"-{(1 - total_e / total_f) * 100:.0f}% CDC filter" if total_f else "—"

            c1, c2, c3, c4 = st.columns(4)
            c1.metric("Foundation Rows", f"{total_f:,}")
            c2.metric("Enriched Rows",   f"{total_e:,}", delta=cdc_drop, delta_color="off")
            c3.metric("Analytics Rows",  f"{total_a:,}")
            c4.metric("Tables in Pipeline", len(lineage_df))

            st.markdown("---")
            st.markdown("##### Row Volume Through Each Layer")

            for _, row in lineage_df.iterrows():
                f_rows = int(row["FOUNDATION_ROWS"] or 0)
                e_rows = int(row["ENRICHED_ROWS"]   or 0)
                a_rows = int(row["ANALYTICS_ROWS"]  or 0)
                filt_pct = f"-{(1 - e_rows/f_rows)*100:.0f}%" if f_rows else "—"
                strat    = row.get("STRATEGY") or "unknown"
                e_ok     = row["ENRICHED_STATUS"]  == "COMPLETE"
                a_ok     = row["ANALYTICS_STATUS"] == "COMPLETE"

                col1, col2, col3, col4, col5 = st.columns([2, 1.2, 1.2, 1.2, 0.6])
                col1.markdown(f"**{row['FOUNDATION_TABLE']}**  \n`strategy: {strat}`")
                col2.markdown(f"🟤 **Foundation**  \n{f_rows:,} rows")
                e_schema = row.get('ENRICHED_SCHEMA') or 'AGENT_FRAMEWORK_OUTPUT'
                a_schema = row.get('ANALYTICS_SCHEMA') or 'GOLD'
                col3.markdown(f"→ 🟡 **Enriched** `{e_schema}`  \n{e_rows:,} rows `{filt_pct}`")
                col4.markdown(f"→ 🟢 **Analytics** `{a_schema}`  \n{a_rows:,} rows")
                col5.markdown(f"{'✅' if e_ok else '⏳'}  \n{'✅' if a_ok else '⏳'}")
                st.markdown("---")

            st.markdown("##### Full Detail")
            st.dataframe(
                lineage_df,
                use_container_width=True,
                hide_index=True,
                column_config={
                    "FOUNDATION_TABLE":  st.column_config.TextColumn("Foundation Table"),
                    "FOUNDATION_ROWS":   st.column_config.NumberColumn("F Rows",  format="%d"),
                    "ENRICHED_TABLE":    st.column_config.TextColumn("Enriched Table"),
                    "ENRICHED_ROWS":     st.column_config.NumberColumn("E Rows",  format="%d"),
                    "ANALYTICS_TABLE":   st.column_config.TextColumn("Analytics Table"),
                    "ANALYTICS_ROWS":    st.column_config.NumberColumn("A Rows",  format="%d"),
                    "ENRICHED_STATUS":   st.column_config.TextColumn("E Status",  width=90),
                    "ANALYTICS_STATUS":  st.column_config.TextColumn("A Status",  width=90),
                    "STRATEGY":          st.column_config.TextColumn("Strategy"),
                },
            )
        else:
            st.info("No lineage data yet. Run the Agentic Workflow to populate.")

    with reg_tab2:
        llm_rels_df = run_query("""
            SELECT
                SPLIT_PART(sr.source_table, '.', -1)  AS FROM_TABLE,
                sr.source_column                       AS FK_COLUMN,
                SPLIT_PART(sr.target_table, '.', -1)  AS TO_TABLE,
                sr.target_column                       AS PK_COLUMN,
                sr.relationship_type                   AS REL_TYPE,
                ROUND(sr.confidence * 100)             AS CONFIDENCE_PCT,
                sr.llm_reasoning                       AS REASONING
            FROM AGENT_FRAMEWORK.SCHEMA_RELATIONSHIPS sr
            INNER JOIN AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS we
                ON sr.execution_id = we.execution_id
            WHERE sr.discovery_method = 'SCHEMA_ANALYST'
            ORDER BY sr.confidence DESC, sr.source_table, sr.source_column
        """)

        has_llm = not llm_rels_df.empty

        if has_llm:
            st.caption("Relationships discovered by the Schema Analyst LLM phase — including non-obvious name mismatches.")
            conf_filter = st.slider("Min confidence %", 0, 100, 70, key="conf_slider")
            filtered = llm_rels_df[llm_rels_df["CONFIDENCE_PCT"] >= conf_filter]

            rel_type_badge = {"FK": "🔑", "SOFT_FK": "🔗", "LOOKUP": "📋"}
            for _, r in filtered.iterrows():
                badge = rel_type_badge.get(r["REL_TYPE"], "🔗")
                same_name = r["FK_COLUMN"].replace("_ID","").replace("_REF","").replace("_NUM","").upper() == r["TO_TABLE"].replace("S","").upper()
                name_flag = "" if same_name else " ⚡ *non-obvious*"
                st.markdown(
                    f"{badge} **{r['FROM_TABLE']}**.`{r['FK_COLUMN']}` &nbsp;→&nbsp; "
                    f"**{r['TO_TABLE']}**.`{r['PK_COLUMN']}` "
                    f"&nbsp;<small>{r['CONFIDENCE_PCT']}%{name_flag}</small>",
                    unsafe_allow_html=True,
                )

            st.markdown("---")
            st.dataframe(
                filtered,
                use_container_width=True, hide_index=True,
                column_config={
                    "FROM_TABLE":     st.column_config.TextColumn("From Table"),
                    "FK_COLUMN":      st.column_config.TextColumn("FK Column"),
                    "TO_TABLE":       st.column_config.TextColumn("→ References"),
                    "PK_COLUMN":      st.column_config.TextColumn("PK Column"),
                    "REL_TYPE":       st.column_config.TextColumn("Type", width=80),
                    "CONFIDENCE_PCT": st.column_config.NumberColumn("Confidence %", format="%d%%"),
                    "REASONING":      st.column_config.TextColumn("LLM Reasoning", width=300),
                },
            )
        else:
            st.info("Run the Agentic Workflow to populate LLM-discovered relationships. The Schema Analyst phase discovers FK relationships across all tables in a single pass.")


# ─────────────────────────────────────────────────────────────────────────────
# DCM Export Tab
# ─────────────────────────────────────────────────────────────────────────────

def render_banner_tab():
    st.subheader("Partner Routing Configuration & Validation")
    st.markdown('<div class="info-strip">Configure routing rules for partners where one Silver table fans out to multiple Gold tables based on a dimension value (banner, region, store format, product line, etc.). Each routing rule maps a Silver subset to a specific Gold table with optional exclusion filters and merge targets. <strong>Example:</strong> A grocery partner with 14 store banners → 13 Gold tables. A retailer with store formats (Express/Standard/Premium) → 3 Gold tables.</div>', unsafe_allow_html=True)

    cfg_tab, validate_tab = st.tabs(["⚙️ Banner Config", "✅ Validate"])

    with cfg_tab:
        st.markdown("#### Partner Banner Configuration")
        df = run_query("""
            SELECT config_id, partner_name, banner_value, silver_table, gold_table,
                   excluded_categories, merge_into_banner, upc_threshold_pct, is_active, notes
            FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
            ORDER BY partner_name, config_id
        """)
        if not df.empty:
            st.dataframe(df, use_container_width=True, hide_index=True)
        else:
            st.info("No routing configs yet. Add rows below or use the Seed Example button to load a sample grocery partner config (14 banners → 13 Gold tables).")

        st.divider()
        st.markdown("#### Add Banner Entry")
        with st.form("add_banner_form"):
            c1, c2 = st.columns(2)
            partner  = c1.text_input("Partner Name", placeholder="e.g. ACME_GROCERY, RETAILER_A")
            banner   = c2.text_input("Routing Value", placeholder="e.g. superstore, express, north_region")
            c3, c4 = st.columns(2)
            silver   = c3.text_input("Silver Table (DB.SCHEMA.TABLE)", placeholder="MY_DB.SILVER.PRODUCTS_SILVER")
            gold     = c4.text_input("Gold Table (schema.table)", placeholder="GOLD.GOLD_SUPERSTORE")
            c5, c6 = st.columns(2)
            banner_col  = c5.text_input("Banner Column", value="BANNER")
            excl_cats   = c6.text_input("Excluded Categories (comma-sep)", placeholder="Ancillary,Liquor")
            c7, c8 = st.columns(2)
            merge_into  = c7.text_input("Merge Into Banner (optional)", placeholder="independent")
            upc_thresh  = c8.number_input("UPC Threshold %", min_value=0.0, max_value=100.0, value=0.0, step=0.5)
            notes       = st.text_input("Notes (optional)")
            submitted   = st.form_submit_button("➕ Add Banner", type="primary", use_container_width=True)

        if submitted:
            if not partner or not banner or not silver:
                st.error("Partner Name, Banner Value, and Silver Table are required.")
            else:
                def _e(v): return v.replace("'", "''") if v else ""
                sql = f"""
                    INSERT INTO AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG
                        (partner_name, bronze_table, silver_table, banner_column, banner_value,
                         gold_table, merge_into_banner, excluded_categories, upc_threshold_pct, notes)
                    VALUES ('{_e(partner)}', '{_e(silver)}', '{_e(silver)}', '{_e(banner_col)}',
                            '{_e(banner)}', {("'" + _e(gold) + "'") if gold else "NULL"},
                            {("'" + _e(merge_into) + "'") if merge_into else "NULL"},
                            {("'" + _e(excl_cats) + "'") if excl_cats else "NULL"},
                            {upc_thresh}, {("'" + _e(notes) + "'") if notes else "NULL"})
                """
                run_query(sql)
                st.success(f"Added banner '{banner}' for partner '{partner}'.")
                st.cache_data.clear()
                st.rerun()

        st.divider()
        st.markdown("#### Seed Grocery Example Config (LCL V2 — 14 banners → 13 Gold tables)")
        c_schema, c_gold_schema, c_seed = st.columns([2, 2, 1])
        silver_schema = c_schema.text_input("Silver Schema", value="SILVER", key="lcl_silver")
        gold_schema   = c_gold_schema.text_input("Gold Schema", value="GOLD", key="lcl_gold")
        if c_seed.button("🌱 Seed Example", use_container_width=True):
            result = run_call(f"CALL AGENT_FRAMEWORK.SEED_LCL_BANNER_CONFIG('{silver_schema}', '{gold_schema}')")
            st.success(result if isinstance(result, str) else "LCL banner config seeded.")
            st.cache_data.clear()
            st.rerun()

    with validate_tab:
        st.markdown("#### Run Partner Routing Validation")
        partners = run_query("SELECT DISTINCT partner_name FROM AGENT_FRAMEWORK.PARTNER_BANNER_CONFIG WHERE is_active = TRUE ORDER BY partner_name")
        partner_list = partners["PARTNER_NAME"].tolist() if not partners.empty else []

        if not partner_list:
            st.warning("No banner configs found. Add entries in the Banner Config tab first.")
        else:
            c1, c2 = st.columns([2, 1])
            selected_partner = c1.selectbox("Partner", partner_list)
            db_override = c2.text_input("Database (optional)", placeholder="leave blank = current DB")

            if st.button("▶ Validate Banners", type="primary", use_container_width=True):
                db_arg = f"'{db_override}'" if db_override.strip() else "NULL"
                with st.spinner(f"Validating {selected_partner} banners..."):
                    result = run_call(f"CALL AGENT_FRAMEWORK.VALIDATE_MULTI_BANNER('{selected_partner}', {db_arg})")

                if result:
                    import json
                    try:
                        r = json.loads(result) if isinstance(result, str) else result
                        status = r.get("status", "UNKNOWN")
                        pc = r.get("pass_count", 0)
                        fc = r.get("fail_count", 0)
                        sc = r.get("skip_count", 0)
                        total = r.get("total_banners", 0)

                        if status == "VALIDATED":
                            st.success(f"✅ **VALIDATED** — {pc}/{total} banners passed, {sc} skipped")
                        else:
                            st.error(f"❌ **VALIDATION_FAILURES** — {fc} failed, {pc} passed, {sc} skipped")

                        results = r.get("results", [])
                        if results:
                            for br in results:
                                b_status = br.get("status", "?")
                                icon = "✅" if b_status == "PASS" else ("⏭️" if b_status == "SKIPPED" else ("⛔" if b_status == "ABORTED" else "❌"))
                                with st.expander(f"{icon} **{br.get('banner', '?')}** — {b_status}"):
                                    if b_status in ("PASS", "FAIL"):
                                        merged = br.get('merged_rows', 0) or 0
                                        merged_row = f"| Merged Rows (from other rules) | {merged:,} |\n" if merged else ""
                                        st.markdown(f"""| Metric | Value |
|--------|-------|
| Silver Rows | {br.get('silver_rows', '—'):,} |
| Excluded Rows | {br.get('excluded_rows', '—'):,} |
{merged_row}| Expected Gold | {br.get('expected_gold', '—'):,} |
| Actual Gold Rows | {br.get('gold_rows', '—'):,} |
| Variance | {br.get('variance_pct', '—')}% |
| Gold Table | `{br.get('gold_table', '—')}` |
""")
                                        if b_status == "FAIL":
                                            st.error(br.get("reason", ""))
                                    elif b_status == "SKIPPED":
                                        st.caption(br.get("reason", ""))
                                    elif b_status == "ERROR":
                                        st.error(br.get("error", "Unknown error"))
                    except Exception as ex:
                        st.error(f"Could not parse result: {ex}")
                        st.json(result)


def render_dcm_tab():
    st.subheader("📦 DCM Project Export")
    st.caption("Generate a deployable Database Change Management project from your ADF pipeline output.")

    ctx = _db_context()

    col_cfg1, col_cfg2, col_cfg3 = st.columns(3)
    with col_cfg1:
        project_name = st.text_input("Project Name", value="adf_pipeline", key="dcm_project_name")
    with col_cfg2:
        de_role = st.text_input("Data Engineer Role", value="DATA_ENGINEER_ROLE", key="dcm_de_role")
    with col_cfg3:
        analyst_role = st.text_input("Analyst Role", value="ANALYST_ROLE", key="dcm_analyst_role")

    silver_count = run_query(f"SELECT COUNT(*) AS CNT FROM {ctx['db']}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE silver_status = 'COMPLETE'")
    gold_count   = run_query(f"SELECT COUNT(*) AS CNT FROM {ctx['db']}.AGENT_FRAMEWORK.TABLE_LINEAGE_MAP WHERE gold_status = 'COMPLETE'")
    n_silver = int(silver_count.iloc[0]["CNT"]) if not silver_count.empty else 0
    n_gold   = int(gold_count.iloc[0]["CNT"])   if not gold_count.empty   else 0

    m1, m2 = st.columns(2)
    m1.metric("Silver Tables", n_silver)
    m2.metric("Gold Tables",   n_gold)

    if n_silver == 0:
        st.warning("No Silver tables found. Run the Enrichment Workflow first.")
        return

    if st.button("⚡ Generate DCM Project", type="primary", use_container_width=True):
        with st.spinner("Generating DCM project files..."):
            result = run_call(
                f"CALL AGENT_FRAMEWORK.GENERATE_DCM_PROJECT('{project_name}', '{de_role}', '{analyst_role}')"
            )

        if isinstance(result, dict) and result.get("status") == "SUCCESS":
            st.session_state["dcm_result"] = result
            st.success(f"Generated {len(result.get('files_written', []))} files — {result['silver_tables']} Silver, {result['gold_tables']} Gold tables.")
        else:
            st.error(f"Generation failed: {result}")

    if "dcm_result" in st.session_state:
        result   = st.session_state["dcm_result"]
        contents = result.get("contents", {})
        files    = result.get("files_written", [])

        st.divider()
        st.markdown("#### Generated Files")

        file_tabs = st.tabs([f.split("/")[-1] for f in files])
        for tab, fpath in zip(file_tabs, files):
            with tab:
                content = contents.get(fpath, "")
                lang = "yaml" if fpath.endswith(".yml") else "sql"
                st.code(content, language=lang)
                st.download_button(
                    label=f"⬇ Download {fpath.split('/')[-1]}",
                    data=content,
                    file_name=fpath.split("/")[-1],
                    mime="text/plain",
                    key=f"dl_{fpath.replace('/', '_')}"
                )

        st.divider()
        st.markdown("#### Deploy Instructions")
        deploy_cmd = result.get("deploy_hint", "")
        st.info("Download all files maintaining the directory structure, then run:")
        st.code(f"""# 1. Download project files from stage
snow stage get @AGENT_FRAMEWORK.DCM_OUTPUT ./dcm_project -c <connection>

# 2. Register & deploy
{deploy_cmd}""", language="bash")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def render_documents_tab():
    st.subheader("Knowledge Documents")
    st.markdown(
        '<div class="info-strip">Upload domain documents (naming conventions, ERDs, data dictionaries) '
        'so the Planner retrieves them via Cortex Search before every LLM batch. '
        'Zero changes to the Planner SP — documents are indexed into '
        '<code>ATS_KNOWLEDGE_CORPUS</code> and retrieved automatically.</div>',
        unsafe_allow_html=True
    )

    doc_type_options = {
        "Naming Convention":   "naming_convention",
        "Data Dictionary":     "data_dictionary",
        "ERD / Schema Map":    "erd",
        "Business Glossary":   "glossary",
        "Compliance Rules":    "compliance",
        "General":             "general",
    }

    st.divider()
    st.markdown("#### Upload Document")

    col_up, col_type = st.columns([2, 1])
    with col_up:
        uploaded = st.file_uploader(
            "Choose a file",
            type=["pdf", "txt", "md"],
            help="PDF files are parsed via PARSE_DOCUMENT. TXT/MD files are indexed directly.",
            key="doc_uploader"
        )
    with col_type:
        doc_type_label = st.selectbox(
            "Document Type",
            options=list(doc_type_options.keys()),
            help="Helps the Planner understand what kind of context this document provides."
        )

    doc_name_default = uploaded.name if uploaded else ""
    doc_name = st.text_input(
        "Document Name (used as identifier in the corpus)",
        value=doc_name_default,
        placeholder="e.g. naming_convention_v2.pdf",
        help="Must be unique. Re-uploading with the same name replaces existing chunks."
    )

    if st.button("📥 Index Document", type="primary", disabled=(uploaded is None or not doc_name.strip())):
        doc_type_val = doc_type_options[doc_type_label]
        file_ext = uploaded.name.rsplit(".", 1)[-1].lower() if "." in uploaded.name else "txt"

        with st.spinner(f"Indexing **{doc_name}** …"):
            try:
                if file_ext == "pdf":
                    stage_filename = doc_name.replace(" ", "_")
                    session.file.put_stream(
                        uploaded,
                        f"@AGENT_FRAMEWORK.DOCUMENT_STAGE/{stage_filename}",
                        auto_compress=False,
                        overwrite=True
                    )
                    result_df = run_query(
                        f"CALL AGENT_FRAMEWORK.INGEST_DOCUMENT_FROM_STAGE("
                        f"'@AGENT_FRAMEWORK.DOCUMENT_STAGE/{stage_filename}', "
                        f"'{doc_name.replace(chr(39), chr(39)*2)}', "
                        f"'{doc_type_val}')"
                    )
                else:
                    raw_text = uploaded.read().decode("utf-8", errors="replace")
                    safe_text = raw_text.replace("'", "''")
                    result_df = run_query(
                        f"CALL AGENT_FRAMEWORK.INGEST_DOCUMENT_TEXT("
                        f"'{doc_name.replace(chr(39), chr(39)*2)}', "
                        f"'{doc_type_val}', "
                        f"'{safe_text[:50000]}')"
                    )

                if result_df is not None and not result_df.empty:
                    result = result_df.iloc[0, 0]
                    if isinstance(result, str):
                        import json as _json
                        try:
                            result = _json.loads(result)
                        except Exception:
                            pass
                    if isinstance(result, dict) and result.get("status") == "SUCCESS":
                        chunks = result.get("chunks", "?")
                        chars  = result.get("chars", "?")
                        st.success(
                            f"✅ **{doc_name}** indexed — {chunks} chunks, {chars:,} characters. "
                            f"Cortex Search will pick it up within 1 hour.",
                            icon=None
                        )
                        st.cache_data.clear()
                        st.rerun()
                    else:
                        err = result.get("error", str(result)) if isinstance(result, dict) else str(result)
                        st.error(f"Ingestion failed: {err}")
                else:
                    st.error("No result returned from ingestion SP.")
            except Exception as e:
                st.error(f"Upload error: {e}")

    st.divider()
    st.markdown("#### Indexed Documents")

    import json as _doc_json
    docs_result = run_query("CALL AGENT_FRAMEWORK.LIST_DOCUMENTS()")
    docs = []
    if docs_result is not None and not docs_result.empty:
        raw = docs_result.iloc[0, 0]
        try:
            docs = _doc_json.loads(raw) if isinstance(raw, str) else (raw or [])
        except Exception:
            docs = []

    if not docs:
        st.info("No documents indexed yet. Upload a document above to get started.", icon=None)
    else:
        for row in docs:
            with st.expander(f"📄 {row['doc_name']}  ·  {row['chunk_count']} chunks  ·  {row['doc_type']}"):
                c1, c2, c3 = st.columns(3)
                c1.metric("Chunks", int(row["chunk_count"]))
                c2.metric("Characters", f"{int(row['total_chars']):,}")
                c3.metric("Indexed By", row.get("created_by") or "—")
                st.caption(f"Indexed at {str(row.get('created_at', ''))[:16]}")
                if st.button(f"🗑️ Remove {row['doc_name']}", key=f"rm_{row['doc_name']}"):
                    safe_dn = row["doc_name"].replace("'", "''")
                    run_call(f"CALL AGENT_FRAMEWORK.REMOVE_DOCUMENT('{safe_dn}')")
                    st.cache_data.clear()
                    st.rerun()

    st.divider()
    st.markdown("#### How It Works")
    st.markdown("""
1. Documents are chunked (~1,500 chars each) and stored in `DOCUMENT_CONTEXT_ITEMS`.
2. The `ATS_KNOWLEDGE_CORPUS` view includes these chunks alongside learnings and prior decisions.
3. The Cortex Search service (`ATS_KNOWLEDGE_SEARCH`) re-indexes the corpus every hour.
4. Before each Planner LLM batch, `SEARCH_ATS_KNOWLEDGE()` retrieves top-matching chunks for the tables being planned — including any document context.
5. No changes to the Planner SP are needed.

**Best documents to upload:** naming conventions, column glossaries, ERD descriptions, data dictionaries, compliance rule sets.
""")


# ─────────────────────────────────────────────────────────────────────────────
# v4 NEW: Agent Hub / Orchestrate / Agent Chat / Tool Inspector
# ─────────────────────────────────────────────────────────────────────────────

_V4_AGENTS = [
    {"name": "ATS_SCHEMA_ANALYST_AGENT", "label": "Schema Analyst", "icon": "🔍",
     "phase": "DISCOVERY",
     "desc": "Discovers FK relationships, column metadata, and schema patterns across all Bronze tables.",
     "tools": ["list_tables", "discover_schema", "sample_data", "search_relationships"]},
    {"name": "ATS_PLANNER_AGENT", "label": "Planner", "icon": "📋",
     "phase": "PLANNING",
     "desc": "Generates transformation plans: dedup strategy, type casts, SCD-2 detection, PK inference.",
     "tools": ["get_contracts", "get_directives", "get_pipeline_context", "search_prior_decisions", "get_columns"]},
    {"name": "ATS_EXECUTOR_AGENT", "label": "Executor", "icon": "⚡",
     "phase": "EXECUTION",
     "desc": "Generates and executes Silver DDL. Reads dry_run flag — safe by default.",
     "tools": ["get_columns", "get_planner_decision", "execute_ddl", "check_table_exists", "count_rows"]},
    {"name": "ATS_VALIDATOR_AGENT", "label": "Validator", "icon": "✅",
     "phase": "VALIDATION",
     "desc": "Validates Silver output: row count parity, PK uniqueness, NULL checks.",
     "tools": ["compare_counts", "check_pk_uniqueness", "validate_column", "get_executor_output"]},
    {"name": "ATS_REFLECTOR_AGENT", "label": "Reflector", "icon": "🪞",
     "phase": "REFLECTION",
     "desc": "Captures learnings, identifies patterns, updates the knowledge corpus for future runs.",
     "tools": ["save_learning", "search_learnings", "get_workflow_log", "get_workflow_status"]},
    {"name": "ATS_ORCHESTRATOR_AGENT", "label": "Orchestrator", "icon": "🎯",
     "phase": "ORCHESTRATION",
     "desc": "Drives the full pipeline end-to-end. Calls all phase agents in sequence.",
     "tools": ["run_schema_analyst", "run_planner", "run_executor", "run_validator", "run_reflector"]},
]

_V4_AGENT_LABELS = {a["name"]: f"{a['icon']} {a['label']}" for a in _V4_AGENTS}


def _call_cortex_agent(agent_name: str, message: str, history: list = None) -> str:
    """
    Call a Cortex Agent via the REST API.
    SNOWFLAKE.CORTEX.COMPLETE_AGENT does not exist as a SQL function;
    agents are only reachable through /api/v2/cortex/agent:run.
    """
    import requests as _req

    try:
        db    = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]
        host  = session.connection.host
        token = session.connection.rest.token
    except Exception as e:
        return f"Session error: {e}"

    agent_id = f"{db}.AGENT_FRAMEWORK.{agent_name}"
    messages = list(history or []) + [
        {"role": "user", "content": [{"type": "text", "text": message}]}
    ]

    try:
        resp = _req.post(
            f"https://{host}/api/v2/cortex/agent:run",
            headers={
                "Authorization": f'Snowflake Token="{token}"',
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json={"model": agent_id, "messages": messages},
            timeout=120,
        )
    except Exception as e:
        return f"Request failed: {e}"

    if resp.status_code != 200:
        return f"Agent error {resp.status_code}: {resp.text[:400]}"

    try:
        data    = resp.json()
        choices = data.get("choices", [])
        if not choices:
            return f"No choices in response: {data}"
        content = choices[0].get("message", {}).get("content", [])
        texts   = [c["text"] for c in content if c.get("type") == "text"]
        return "\n".join(texts) or str(data)
    except Exception as e:
        return f"Parse error: {e} — raw: {resp.text[:200]}"


def render_agent_hub_tab():
    st.subheader("Cortex Agent Status")
    st.markdown('<div class="info-strip">6 agents deployed to <b>AGENT_FRAMEWORK</b>. Each wraps a set of ATS_TOOL_* stored procedures.</div>', unsafe_allow_html=True)

    try:
        agents_df = session.sql("SHOW AGENTS IN SCHEMA AGENT_FRAMEWORK").to_pandas()
        live_names = set(agents_df["name"].str.upper().tolist())
    except Exception:
        live_names = set()

    col_a, col_b = st.columns(2)
    for i, ag in enumerate(_V4_AGENTS):
        col = col_a if i % 2 == 0 else col_b
        is_live = ag["name"].upper() in live_names
        status_html = '<span class="status-pill pill-green">LIVE</span>' if is_live else '<span class="status-pill pill-red">NOT FOUND</span>'
        tools_html = " ".join(f'<span style="display:inline-block;background:#e8f4fd;color:#0c5460;border-radius:4px;padding:1px 7px;font-size:0.72rem;margin:2px 2px 0 0;font-family:monospace">{t}</span>' for t in ag["tools"])
        with col:
            st.markdown(f"""
<div class="agent-card" style="background:#f8fbff;border:1px solid #d1e4f5;border-radius:8px;padding:1rem 1.1rem;margin-bottom:0.6rem;border-left:4px solid #29B5E8;">
  <h4 style="margin:0 0 0.2rem;font-size:0.95rem;color:#1B2A4A;">{ag["icon"]} {ag["label"]} &nbsp; {status_html} &nbsp; <span style="display:inline-block;padding:1px 8px;border-radius:10px;font-size:0.7rem;font-weight:700;background:#1B2A4A;color:#29B5E8;">{ag["phase"]}</span></h4>
  <p style="margin:0 0 0.4rem;font-size:0.8rem;color:#555;">{ag["desc"]}</p>
  <div>{tools_html}</div>
</div>
""", unsafe_allow_html=True)

    st.divider()
    c1, c2, c3 = st.columns(3)
    c1.metric("Agents Live", f"{sum(1 for ag in _V4_AGENTS if ag['name'].upper() in live_names)} / {len(_V4_AGENTS)}")
    tool_df = run_query("SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA = 'AGENT_FRAMEWORK' AND PROCEDURE_NAME LIKE 'ATS_TOOL_%'")
    c2.metric("Tool SPs", int(tool_df.iloc[0]["N"]) if not tool_df.empty else 0)
    exec_df = run_query("SELECT COUNT(*) AS N FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS")
    c3.metric("Total Executions", int(exec_df.iloc[0]["N"]) if not exec_df.empty else 0)
    if st.button("🔄 Refresh Agent Status", key="hub_refresh"):
        st.cache_data.clear()
        st.rerun()


def render_orchestrate_tab():
    st.subheader("Run Full Pipeline via Orchestrator Agent")
    st.markdown('<div class="info-strip">The Orchestrator drives all 5 phases in sequence: Discovery → Planning → Execution → Validation → Reflection.</div>', unsafe_allow_html=True)

    ctx_df = run_query("SELECT dry_run, output_schema, pipeline_type FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    if not ctx_df.empty:
        r = ctx_df.iloc[0]
        dry = bool(r["DRY_RUN"])
        c1, c2, c3 = st.columns(3)
        c1.metric("Mode", "DRY RUN" if dry else "LIVE")
        c2.metric("Output Schema", str(r["OUTPUT_SCHEMA"]))
        c3.metric("Pipeline Type", str(r["PIPELINE_TYPE"]))
        if dry:
            st.info("dry_run = TRUE — DDL will be generated but NOT executed. Set to FALSE in the Context tab to go live.")

    st.markdown("**Select tables to transform** (leave empty to process all registered tables):")
    lineage_df = run_query(
        "SELECT bronze_table || ' (' || bronze_schema || ')' AS LABEL, bronze_table AS TBL "
        "FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP ORDER BY bronze_table"
    )
    table_options = lineage_df["LABEL"].tolist() if not lineage_df.empty else []
    selected_labels = st.multiselect("Bronze tables", options=table_options, placeholder="All tables", key="orch_table_select")
    trigger_note = st.text_input("Run note (optional)", placeholder="e.g. Weekly refresh", key="orch_note")

    if st.button("🚀 Run Orchestrator Agent", type="primary", key="run_orch_v4"):
        note = trigger_note or "Streamlit v4 orchestrate"
        with st.spinner("Orchestrator running…"):
            result = run_call(
                f"CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW("
                f"trigger_source => '{note}', tables_list => NULL, p_trigger_type => 'MANUAL')"
            )
        if result.get("status") == "ERROR":
            st.error(result.get("error", str(result)))
        else:
            st.success("Pipeline triggered.")
            st.json(result)

    st.divider()
    st.markdown("**Recent executions**")
    recent_df = run_query(
        "SELECT execution_id, status, trigger_source, "
        "TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI') AS started, "
        "DATEDIFF('second', started_at, COALESCE(completed_at, CURRENT_TIMESTAMP())) AS elapsed_s "
        "FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS ORDER BY started_at DESC LIMIT 10"
    )
    if recent_df.empty:
        st.caption("No executions yet.")
    else:
        st.dataframe(recent_df, use_container_width=True, hide_index=True)


def render_agent_chat_tab():
    st.subheader("Chat with an Agent")
    st.markdown('<div class="info-strip">Send a message directly to any individual agent. The agent will call its tools and respond with reasoning + results.</div>', unsafe_allow_html=True)

    agent_choice = st.selectbox(
        "Select agent",
        options=[a["name"] for a in _V4_AGENTS],
        format_func=lambda n: _V4_AGENT_LABELS.get(n, n),
        key="chat_agent_select_v4"
    )
    chosen = next((a for a in _V4_AGENTS if a["name"] == agent_choice), None)
    if chosen:
        st.markdown(f'<div class="info-strip">{chosen["icon"]} <b>{chosen["label"]}</b> — {chosen["desc"]}</div>', unsafe_allow_html=True)

    if "v4_chat_history" not in st.session_state:
        st.session_state.v4_chat_history = []
    if "v4_chat_agent" not in st.session_state:
        st.session_state.v4_chat_agent = agent_choice
    if st.session_state.v4_chat_agent != agent_choice:
        st.session_state.v4_chat_history = []
        st.session_state.v4_chat_agent = agent_choice

    for msg in st.session_state.v4_chat_history:
        if msg["role"] == "user":
            st.markdown(f'<div style="background:#e8f4fd;border-radius:8px;padding:0.6rem 1rem;margin:0.4rem 0;">👤 {msg["content"]}</div>', unsafe_allow_html=True)
        else:
            st.markdown(f'<div style="background:#f0f4f8;border-radius:8px;padding:0.6rem 1rem;margin:0.4rem 0;border-left:3px solid #29B5E8;">🤖 <b>{_V4_AGENT_LABELS.get(agent_choice, agent_choice)}</b><br>{msg["content"]}</div>', unsafe_allow_html=True)

    prompt = st.chat_input("Ask the agent…", key="v4_chat_input")
    if prompt:
        st.session_state.v4_chat_history.append({"role": "user", "content": prompt})
        with st.spinner(f"{_V4_AGENT_LABELS.get(agent_choice)} thinking…"):
                reply = _call_cortex_agent(agent_choice, prompt)
        st.session_state.v4_chat_history.append({"role": "agent", "content": reply})
        st.rerun()

    if st.button("🗑️ Clear chat", key="clear_v4_chat"):
        st.session_state.v4_chat_history = []
        st.rerun()

    st.divider()
    prompts_by_agent = {
        "ATS_SCHEMA_ANALYST_AGENT": ["List all Bronze tables registered.", "Show me the schema for the first table.", "What relationships exist between tables?"],
        "ATS_PLANNER_AGENT": ["What transformation strategy for the first table?", "List the active schema contracts.", "Show active transformation directives."],
        "ATS_EXECUTOR_AGENT": ["Generate Silver DDL for the first pending table.", "What DDL would you generate for a simple fact table?", "Check if any Silver tables already exist."],
        "ATS_VALIDATOR_AGENT": ["What validations would you run?", "Check PK uniqueness for the last created table."],
        "ATS_REFLECTOR_AGENT": ["What learnings exist from prior runs?", "Search for deduplication learnings.", "Show me the last workflow log."],
        "ATS_ORCHESTRATOR_AGENT": ["What is the current pipeline status?", "Run the full pipeline in dry-run mode.", "Summarize the last execution."],
    }
    st.markdown("**Quick prompts:**")
    for p in prompts_by_agent.get(agent_choice, []):
        if st.button(p, key=f"v4prompt_{p[:30]}"):
            st.session_state.v4_chat_history.append({"role": "user", "content": p})
            with st.spinner("Thinking…"):
                    reply = _call_cortex_agent(agent_choice, p)
            st.session_state.v4_chat_history.append({"role": "agent", "content": reply})
            st.rerun()


def render_tool_inspector_tab():
    st.subheader("ATS Tool SPs")
    st.markdown('<div class="info-strip">34 stored procedures powering the v4 agents. Each returns VARCHAR (JSON). Select a tool to view its signature and run it.</div>', unsafe_allow_html=True)

    tool_df = run_query(
        "SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE "
        "FROM INFORMATION_SCHEMA.PROCEDURES "
        "WHERE PROCEDURE_SCHEMA = 'AGENT_FRAMEWORK' AND PROCEDURE_NAME LIKE 'ATS_TOOL_%' "
        "ORDER BY PROCEDURE_NAME"
    )
    if tool_df.empty:
        st.warning("No ATS_TOOL_* SPs found. Have you deployed v4_tools.sql?")
        return

    col_left, col_right = st.columns([1, 2])
    with col_left:
        st.markdown(f"**{len(tool_df)} Tool SPs**")
        selected_tool = st.radio("Select tool", options=tool_df["PROCEDURE_NAME"].tolist(), key="tool_select_v4", label_visibility="collapsed")
    with col_right:
        if selected_tool:
            sig_row = tool_df[tool_df["PROCEDURE_NAME"] == selected_tool]
            sig = sig_row.iloc[0]["ARGUMENT_SIGNATURE"] if not sig_row.empty else "()"
            st.markdown(f"**`{selected_tool}`**")
            st.code(f"CALL AGENT_FRAMEWORK.{selected_tool}{sig}", language="sql")
            call_sql = st.text_area("SQL (edit as needed)", value=f"CALL AGENT_FRAMEWORK.{selected_tool}", height=80, key=f"tool_sql_{selected_tool}")
            if st.button("▶ Execute", key=f"exec_tool_{selected_tool}"):
                with st.spinner("Running…"):
                    result = run_call(call_sql)
                st.json(result)


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    render_sidebar()

    TAB_NAMES  = [
        "⚙️ Setup",
        "🏠 Agent Hub",
        "🎯 Orchestrate",
        "💬 Agent Chat",
        "🔧 Tool Inspector",
        "💡 Context",
        "📐 Contracts",
        "🎯 Directives",
        "🤖 Workflow",
        "🏆 Analytics Builder",
        "🗂️ Registry",
        "📊 Observe",
        "🏷️ Partner Routing",
        "📦 DCM Export",
        "📄 Documents",
    ]
    TAB_RENDER = [
        render_setup_tab,
        render_agent_hub_tab,
        render_orchestrate_tab,
        render_agent_chat_tab,
        render_tool_inspector_tab,
        render_context_tab,
        render_contracts_tab,
        render_directives_tab,
        render_workflow_tab,
        render_gold_tab,
        render_registry_tab,
        render_observability_tab,
        render_banner_tab,
        render_dcm_tab,
        render_documents_tab,
    ]

    if "active_tab" not in st.session_state:
        st.session_state["active_tab"] = 0

    TAB_RENDER[st.session_state["active_tab"]]()


if __name__ == "__main__":
    main()
