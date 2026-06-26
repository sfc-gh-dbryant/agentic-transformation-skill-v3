"""
Agentic Transformation Skill — v4
===================================
Cortex Agents interface for the ATS v4 pipeline.

Tabs:
  1  Agent Hub      — Live status of all 6 Cortex Agents
  2  Orchestrate    — Run full pipeline via ATS_ORCHESTRATOR_AGENT
  3  Agent Chat     — Direct conversation with any individual agent
  4  Tool Inspector — Browse and invoke the 34 ATS_TOOL_* stored procedures
  5  Workflow Log   — Live execution trace and history
  6  Context        — Pipeline context (shared with v4 pipeline)
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
# Constants
# ─────────────────────────────────────────────────────────────────────────────

AGENTS = [
    {
        "name": "ATS_SCHEMA_ANALYST_AGENT",
        "label": "Schema Analyst",
        "icon": "🔍",
        "desc": "Discovers FK relationships, column metadata, and schema patterns across all Bronze tables.",
        "phase": "DISCOVERY",
        "tools": ["list_tables", "discover_schema", "sample_data", "search_relationships"],
    },
    {
        "name": "ATS_PLANNER_AGENT",
        "label": "Planner",
        "icon": "📋",
        "desc": "Generates transformation plans: dedup strategy, type casts, SCD-2 detection, PK inference.",
        "phase": "PLANNING",
        "tools": ["get_contracts", "get_directives", "get_pipeline_context", "search_prior_decisions", "get_columns"],
    },
    {
        "name": "ATS_EXECUTOR_AGENT",
        "label": "Executor",
        "icon": "⚡",
        "desc": "Generates and executes Silver DDL. Reads dry_run flag — safe by default.",
        "phase": "EXECUTION",
        "tools": ["get_columns", "get_planner_decision", "execute_ddl", "check_table_exists", "count_rows"],
    },
    {
        "name": "ATS_VALIDATOR_AGENT",
        "label": "Validator",
        "icon": "✅",
        "desc": "Validates Silver output: row count parity, PK uniqueness, NULL checks.",
        "phase": "VALIDATION",
        "tools": ["compare_counts", "check_pk_uniqueness", "validate_column", "get_executor_output"],
    },
    {
        "name": "ATS_REFLECTOR_AGENT",
        "label": "Reflector",
        "icon": "🪞",
        "desc": "Captures learnings, identifies patterns, updates the knowledge corpus for future runs.",
        "phase": "REFLECTION",
        "tools": ["save_learning", "search_learnings", "get_workflow_log", "get_workflow_status"],
    },
    {
        "name": "ATS_ORCHESTRATOR_AGENT",
        "label": "Orchestrator",
        "icon": "🎯",
        "desc": "Drives the full pipeline end-to-end. Calls all phase agents in sequence.",
        "phase": "ORCHESTRATION",
        "tools": ["run_schema_analyst", "run_planner", "run_executor", "run_validator", "run_reflector"],
    },
]

AGENT_NAMES = [a["name"] for a in AGENTS]
AGENT_LABELS = {a["name"]: f"{a['icon']} {a['label']}" for a in AGENTS}

SF_BLUE  = "#29B5E8"
SF_DARK  = "#1B2A4A"
SF_GREEN = "#00C49A"

# ─────────────────────────────────────────────────────────────────────────────
# Styling
# ─────────────────────────────────────────────────────────────────────────────

st.markdown(f"""
<style>
    .v4-header {{
        background: linear-gradient(135deg, {SF_DARK} 0%, #0D1B2E 100%);
        color: white; padding: 1.2rem 2rem 0.9rem;
        border-radius: 8px; margin-bottom: 1.2rem;
    }}
    .v4-header h1 {{ color: white; margin: 0; font-size: 1.5rem; }}
    .v4-header p  {{ color: {SF_BLUE}; margin: 0.2rem 0 0; font-size: 0.82rem; }}
    .agent-card {{
        background: #f8fbff; border: 1px solid #d1e4f5;
        border-radius: 8px; padding: 1rem 1.1rem; margin-bottom: 0.6rem;
        border-left: 4px solid {SF_BLUE};
    }}
    .agent-card h4 {{ margin: 0 0 0.2rem; font-size: 0.95rem; color: {SF_DARK}; }}
    .agent-card p  {{ margin: 0; font-size: 0.8rem; color: #555; }}
    .status-pill {{
        display: inline-block; padding: 2px 10px; border-radius: 12px;
        font-size: 0.75rem; font-weight: 600;
    }}
    .pill-green  {{ background: #d4edda; color: #155724; }}
    .pill-yellow {{ background: #fff3cd; color: #856404; }}
    .pill-red    {{ background: #f8d7da; color: #721c24; }}
    .pill-blue   {{ background: #d1ecf1; color: #0c5460; }}
    .pill-grey   {{ background: #e2e3e5; color: #383d41; }}
    .tool-tag {{
        display: inline-block; background: #e8f4fd; color: #0c5460;
        border-radius: 4px; padding: 1px 7px; font-size: 0.72rem;
        margin: 2px 2px 0 0; font-family: monospace;
    }}
    .chat-user   {{ background: #e8f4fd; border-radius: 8px; padding: 0.6rem 1rem; margin: 0.4rem 0; }}
    .chat-agent  {{ background: #f0f4f8; border-radius: 8px; padding: 0.6rem 1rem; margin: 0.4rem 0;
                   border-left: 3px solid {SF_BLUE}; }}
    .log-row     {{ font-family: monospace; font-size: 0.78rem; padding: 2px 0; }}
    .phase-badge {{
        display: inline-block; padding: 1px 8px; border-radius: 10px;
        font-size: 0.7rem; font-weight: 700; background: #1B2A4A; color: {SF_BLUE};
    }}
    .info-strip {{
        background: #f0f4f8; border-left: 4px solid {SF_BLUE};
        padding: 0.6rem 1rem; border-radius: 0 4px 4px 0;
        font-size: 0.85rem; margin-bottom: 1rem;
    }}
</style>
""", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

@st.cache_data(ttl=30)
def _db_context():
    row = session.sql(
        "SELECT CURRENT_DATABASE() AS db, CURRENT_ROLE() AS role, "
        "CURRENT_USER() AS usr, CURRENT_WAREHOUSE() AS wh"
    ).collect()[0]
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
                if isinstance(parsed, str):
                    parsed = json.loads(parsed)
                return parsed
            except Exception:
                return {"raw": str(val)}
        return {}
    except Exception as e:
        return {"status": "ERROR", "error": str(e)}


def pill(text: str, color: str = "blue") -> str:
    return f'<span class="status-pill pill-{color}">{text}</span>'


def agent_exists(name: str) -> bool:
    try:
        df = run_query(f"SHOW AGENTS LIKE '{name}' IN SCHEMA AGENT_FRAMEWORK")
        return not df.empty
    except Exception:
        return False


@st.cache_data(ttl=60)
def list_agents() -> pd.DataFrame:
    try:
        return session.sql("SHOW AGENTS IN SCHEMA AGENT_FRAMEWORK").to_pandas()
    except Exception:
        return pd.DataFrame()


@st.cache_data(ttl=15)
def list_tool_sps() -> pd.DataFrame:
    return run_query(
        "SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE "
        "FROM INFORMATION_SCHEMA.PROCEDURES "
        "WHERE PROCEDURE_SCHEMA = 'AGENT_FRAMEWORK' AND PROCEDURE_NAME LIKE 'ATS_TOOL_%' "
        "ORDER BY PROCEDURE_NAME"
    )


def call_agent(agent_name: str, message: str) -> str:
    try:
        rows = session.sql(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE_AGENT("
            f"    'AGENT_FRAMEWORK.{agent_name}', ?, '[]'"
            ")",
            params=[message]
        ).collect()
        if rows:
            return str(rows[0][0])
        return "No response."
    except Exception as e:
        return f"Error: {e}"


# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────

ctx = _db_context()
st.markdown(f"""
<div class="v4-header">
  <h1>🤖 Agentic Transformation Skill — v4</h1>
  <p>Cortex Agents Pipeline &nbsp;|&nbsp; {ctx["db"]} &nbsp;|&nbsp; {ctx["user"]} &nbsp;|&nbsp; {ctx["wh"]}</p>
</div>
""", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# Tabs
# ─────────────────────────────────────────────────────────────────────────────

tab1, tab2, tab3, tab4, tab5, tab6 = st.tabs([
    "🏠 Agent Hub",
    "🎯 Orchestrate",
    "💬 Agent Chat",
    "🔧 Tool Inspector",
    "📜 Workflow Log",
    "⚙️ Context",
])

# ─────────────────────────────────────────────────────────────────────────────
# TAB 1 — Agent Hub
# ─────────────────────────────────────────────────────────────────────────────

with tab1:
    st.subheader("Cortex Agent Status")
    st.markdown('<div class="info-strip">6 agents deployed to <b>AGENT_FRAMEWORK</b>. Each wraps a set of ATS_TOOL_* stored procedures.</div>', unsafe_allow_html=True)

    agents_df = list_agents()
    live_names = set(agents_df["name"].str.upper().tolist()) if not agents_df.empty else set()

    col_a, col_b = st.columns(2)
    for i, ag in enumerate(AGENTS):
        col = col_a if i % 2 == 0 else col_b
        is_live = ag["name"].upper() in live_names
        status_html = pill("LIVE", "green") if is_live else pill("NOT FOUND", "red")
        tools_html = " ".join(f'<span class="tool-tag">{t}</span>' for t in ag["tools"])
        with col:
            st.markdown(f"""
<div class="agent-card">
  <h4>{ag["icon"]} {ag["label"]} &nbsp; {status_html} &nbsp; <span class="phase-badge">{ag["phase"]}</span></h4>
  <p style="margin-bottom:0.4rem">{ag["desc"]}</p>
  <div>{tools_html}</div>
</div>
""", unsafe_allow_html=True)

    st.divider()
    c1, c2, c3 = st.columns(3)
    with c1:
        live_count = sum(1 for ag in AGENTS if ag["name"].upper() in live_names)
        st.metric("Agents Live", f"{live_count} / {len(AGENTS)}")
    with c2:
        tool_df = list_tool_sps()
        st.metric("Tool SPs", len(tool_df))
    with c3:
        exec_df = run_query("SELECT COUNT(*) AS n FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS")
        st.metric("Total Executions", int(exec_df.iloc[0]["N"]) if not exec_df.empty else 0)

    if st.button("🔄 Refresh Agent Status", key="hub_refresh"):
        st.cache_data.clear()
        st.rerun()

# ─────────────────────────────────────────────────────────────────────────────
# TAB 2 — Orchestrate
# ─────────────────────────────────────────────────────────────────────────────

with tab2:
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
        "SELECT bronze_table || ' (' || bronze_schema || ')' AS label, bronze_table "
        "FROM AGENT_FRAMEWORK.TABLE_LINEAGE_MAP ORDER BY bronze_table"
    )
    table_options = lineage_df["LABEL"].tolist() if not lineage_df.empty else []
    selected_labels = st.multiselect("Bronze tables", options=table_options, placeholder="All tables")
    selected_tables = []
    if selected_labels:
        label_to_tbl = dict(zip(lineage_df["LABEL"], lineage_df["BRONZE_TABLE"]))
        selected_tables = [label_to_tbl[l] for l in selected_labels]

    trigger_note = st.text_input("Run note (optional)", placeholder="e.g. Weekly refresh")

    if st.button("🚀 Run Orchestrator Agent", type="primary", key="run_orch"):
        tables_json = json.dumps(selected_tables) if selected_tables else "[]"
        note = trigger_note or "Streamlit v4 run"
        with st.spinner("Orchestrator running…"):
            result = run_call(
                f"CALL AGENT_FRAMEWORK.RUN_AGENTIC_WORKFLOW("
                f"    trigger_source => '{note}', "
                f"    tables_list => NULL, "
                f"    p_trigger_type => 'MANUAL'"
                f")"
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
        "FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        "ORDER BY started_at DESC LIMIT 10"
    )
    if recent_df.empty:
        st.caption("No executions yet.")
    else:
        st.dataframe(recent_df, use_container_width=True, hide_index=True)

# ─────────────────────────────────────────────────────────────────────────────
# TAB 3 — Agent Chat
# ─────────────────────────────────────────────────────────────────────────────

with tab3:
    st.subheader("Chat with an Agent")
    st.markdown('<div class="info-strip">Send a message directly to any individual agent. The agent will call its tools and respond with reasoning + results.</div>', unsafe_allow_html=True)

    agent_choice = st.selectbox(
        "Select agent",
        options=AGENT_NAMES,
        format_func=lambda n: AGENT_LABELS.get(n, n),
        key="chat_agent_select"
    )

    chosen = next((a for a in AGENTS if a["name"] == agent_choice), None)
    if chosen:
        st.markdown(f'<div class="info-strip">{chosen["icon"]} <b>{chosen["label"]}</b> — {chosen["desc"]}</div>', unsafe_allow_html=True)

    if "chat_history" not in st.session_state:
        st.session_state.chat_history = []
    if "chat_agent" not in st.session_state:
        st.session_state.chat_agent = agent_choice

    if st.session_state.chat_agent != agent_choice:
        st.session_state.chat_history = []
        st.session_state.chat_agent = agent_choice

    for msg in st.session_state.chat_history:
        if msg["role"] == "user":
            st.markdown(f'<div class="chat-user">👤 {msg["content"]}</div>', unsafe_allow_html=True)
        else:
            st.markdown(f'<div class="chat-agent">🤖 <b>{AGENT_LABELS.get(agent_choice, agent_choice)}</b><br>{msg["content"]}</div>', unsafe_allow_html=True)

    prompt = st.chat_input("Ask the agent…")
    if prompt:
        st.session_state.chat_history.append({"role": "user", "content": prompt})
        with st.spinner(f"{AGENT_LABELS.get(agent_choice)} thinking…"):
            reply = call_agent(agent_choice, prompt)
        st.session_state.chat_history.append({"role": "agent", "content": reply})
        st.rerun()

    if st.button("🗑️ Clear chat", key="clear_chat"):
        st.session_state.chat_history = []
        st.rerun()

    st.divider()
    st.markdown("**Suggested prompts for this agent**")
    prompts_by_agent = {
        "ATS_SCHEMA_ANALYST_AGENT": [
            "List all Bronze tables registered in this pipeline.",
            "Show me the schema for the DASHMART table.",
            "What relationships exist between these tables?",
        ],
        "ATS_PLANNER_AGENT": [
            "What transformation strategy would you recommend for SIMPLEMART?",
            "List the active schema contracts.",
            "Show me the active transformation directives.",
        ],
        "ATS_EXECUTOR_AGENT": [
            "Generate Silver DDL for RENSPETS.",
            "What would the Silver DDL look like for MARKETBASKET?",
            "Check if a Silver table already exists for LCL.",
        ],
        "ATS_VALIDATOR_AGENT": [
            "Validate the row counts for the last execution.",
            "Check PK uniqueness for the last Silver table created.",
        ],
        "ATS_REFLECTOR_AGENT": [
            "What learnings exist from previous runs?",
            "Search for learnings related to deduplication.",
            "Show me the workflow log for the last execution.",
        ],
        "ATS_ORCHESTRATOR_AGENT": [
            "Run the full pipeline in dry-run mode.",
            "What is the current pipeline status?",
            "Summarize the last workflow execution.",
        ],
    }
    for p in prompts_by_agent.get(agent_choice, []):
        if st.button(p, key=f"prompt_{p[:30]}"):
            st.session_state.chat_history.append({"role": "user", "content": p})
            with st.spinner("Agent thinking…"):
                reply = call_agent(agent_choice, p)
            st.session_state.chat_history.append({"role": "agent", "content": reply})
            st.rerun()

# ─────────────────────────────────────────────────────────────────────────────
# TAB 4 — Tool Inspector
# ─────────────────────────────────────────────────────────────────────────────

with tab4:
    st.subheader("ATS Tool SPs")
    st.markdown('<div class="info-strip">34 stored procedures powering the v4 agents. Each returns VARCHAR (JSON).</div>', unsafe_allow_html=True)

    tool_df = list_tool_sps()
    if tool_df.empty:
        st.warning("No ATS_TOOL_* SPs found. Have you run the v4 deploy?")
    else:
        col_left, col_right = st.columns([1, 2])

        with col_left:
            st.markdown(f"**{len(tool_df)} Tool SPs**")
            selected_tool = st.radio(
                "Select tool",
                options=tool_df["PROCEDURE_NAME"].tolist(),
                key="tool_select",
                label_visibility="collapsed"
            )

        with col_right:
            if selected_tool:
                sig_row = tool_df[tool_df["PROCEDURE_NAME"] == selected_tool]
                sig = sig_row.iloc[0]["ARGUMENT_SIGNATURE"] if not sig_row.empty else "()"
                st.markdown(f"**`{selected_tool}`**")
                st.code(f"CALL AGENT_FRAMEWORK.{selected_tool}{sig}", language="sql")

                st.markdown("**Run this tool**")
                call_sql = st.text_area(
                    "SQL (edit as needed)",
                    value=f"CALL AGENT_FRAMEWORK.{selected_tool}",
                    height=80,
                    key=f"tool_sql_{selected_tool}"
                )
                if st.button("▶ Execute", key=f"exec_tool_{selected_tool}"):
                    with st.spinner("Running…"):
                        result = run_call(call_sql)
                    st.json(result)

# ─────────────────────────────────────────────────────────────────────────────
# TAB 5 — Workflow Log
# ─────────────────────────────────────────────────────────────────────────────

with tab5:
    st.subheader("Workflow Execution History")

    if st.button("🔄 Refresh", key="log_refresh"):
        pass

    exec_df = run_query(
        "SELECT execution_id, workflow_name, status, trigger_source, trigger_type, "
        "TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') AS started, "
        "TO_CHAR(completed_at, 'YYYY-MM-DD HH24:MI:SS') AS completed, "
        "retry_count, last_error "
        "FROM AGENT_FRAMEWORK.WORKFLOW_EXECUTIONS "
        "ORDER BY started_at DESC LIMIT 50"
    )

    if exec_df.empty:
        st.info("No executions yet. Run the pipeline from the Orchestrate tab.")
    else:
        st.dataframe(exec_df, use_container_width=True, hide_index=True)

        selected_exec = st.selectbox(
            "View log for execution",
            options=exec_df["EXECUTION_ID"].tolist(),
            format_func=lambda x: f"{x[:12]}… ({exec_df[exec_df['EXECUTION_ID']==x]['STARTED'].iloc[0]})" if not exec_df[exec_df['EXECUTION_ID']==x].empty else x,
            key="exec_select"
        )

        if selected_exec:
            log_df = run_query(
                f"SELECT phase, status, message, "
                f"TO_CHAR(created_at, 'HH24:MI:SS') AS ts "
                f"FROM AGENT_FRAMEWORK.WORKFLOW_LOG "
                f"WHERE execution_id = '{selected_exec}' "
                f"ORDER BY created_at"
            )
            if log_df.empty:
                st.caption("No log entries for this execution.")
            else:
                status_colors = {"RUNNING": "🟡", "COMPLETE": "🟢", "ERROR": "🔴",
                                 "SKIPPED": "⚪", "ABORTED": "🔴", "PENDING": "🔵"}
                for _, row in log_df.iterrows():
                    icon = status_colors.get(str(row.get("STATUS", "")).upper(), "⚪")
                    st.markdown(
                        f'<div class="log-row">{icon} <b>[{row["TS"]}]</b> '
                        f'[{row["PHASE"]}] {row["MESSAGE"]}</div>',
                        unsafe_allow_html=True
                    )

    st.divider()
    st.markdown("**Planner Decisions (last 20)**")
    plan_df = run_query(
        "SELECT source_table, transformation_strategy, pk_columns, confidence_score, "
        "TO_CHAR(created_at, 'MM-DD HH24:MI') AS created "
        "FROM AGENT_FRAMEWORK.PLANNER_DECISIONS "
        "ORDER BY created_at DESC LIMIT 20"
    )
    if plan_df.empty:
        st.caption("No planner decisions yet.")
    else:
        st.dataframe(plan_df, use_container_width=True, hide_index=True)

# ─────────────────────────────────────────────────────────────────────────────
# TAB 6 — Context
# ─────────────────────────────────────────────────────────────────────────────

with tab6:
    st.subheader("Pipeline Context")
    st.markdown('<div class="info-strip">These settings are shared across all agents and injected into every LLM prompt.</div>', unsafe_allow_html=True)

    ctx_df = run_query("SELECT * FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")

    if ctx_df.empty:
        st.warning("PIPELINE_CONTEXT not found. Run Bootstrap first.")
    else:
        r = ctx_df.iloc[0]

        with st.form("context_form_v4"):
            biz_desc  = st.text_area("Business Description", value=str(r.get("BUSINESS_DESC") or ""), height=80)
            domain    = st.text_input("Data Domain", value=str(r.get("DATA_DOMAIN") or ""))
            gold_goals = st.text_area("Analytics Goals", value=str(r.get("GOLD_GOALS") or ""), height=60)
            constraints = st.text_area("Constraints", value=str(r.get("CONSTRAINTS") or ""), height=60)

            c1, c2, c3 = st.columns(3)
            pipeline_type = c1.selectbox("Pipeline Type", ["CTAS", "DYNAMIC_TABLE"],
                                          index=0 if str(r.get("PIPELINE_TYPE","CTAS")) == "CTAS" else 1)
            output_schema = c2.text_input("Output Schema", value=str(r.get("OUTPUT_SCHEMA","AGENT_FRAMEWORK_OUTPUT")))
            gold_mode = c3.selectbox("Gold Mode", ["FLAT", "STAR_SCHEMA", "DATA_VAULT", "ONE_BIG_TABLE"],
                                     index=["FLAT","STAR_SCHEMA","DATA_VAULT","ONE_BIG_TABLE"].index(
                                         str(r.get("GOLD_OUTPUT_MODE","FLAT"))))

            c4, c5 = st.columns(2)
            dry_run = c4.toggle("Dry Run (safe mode)", value=bool(r.get("DRY_RUN", True)))
            overwrite = c5.toggle("Allow Overwrite", value=bool(r.get("OVERWRITE_EXISTING", False)))

            submitted = st.form_submit_button("💾 Save Context", type="primary")
            if submitted:
                if overwrite and dry_run:
                    st.error("Cannot set overwrite=TRUE and dry_run=TRUE simultaneously.")
                else:
                    result = run_call(
                        f"CALL AGENT_FRAMEWORK.SET_PIPELINE_CONTEXT("
                        f"    p_business_desc      => $${biz_desc}$$,"
                        f"    p_data_domain        => $${domain}$$,"
                        f"    p_gold_goals         => $${gold_goals}$$,"
                        f"    p_constraints        => $${constraints}$$,"
                        f"    p_pipeline_type      => '{pipeline_type}',"
                        f"    p_output_schema      => '{output_schema}',"
                        f"    p_dry_run            => {str(dry_run).upper()},"
                        f"    p_overwrite_existing => {str(overwrite).upper()},"
                        f"    p_gold_output_mode   => '{gold_mode}'"
                        f")"
                    )
                    if "ERROR" in str(result):
                        st.error(str(result))
                    else:
                        st.success("Context saved.")

    st.divider()
    st.markdown("**Brownfield Mode**")
    bfield_df = run_query("SELECT brownfield_mode FROM AGENT_FRAMEWORK.PIPELINE_CONTEXT WHERE context_id = 1")
    if not bfield_df.empty:
        bfield_val = bool(bfield_df.iloc[0]["BROWNFIELD_MODE"])
        new_bfield = st.toggle("Brownfield Mode", value=bfield_val,
                               help="When ON, Bootstrap skips existing Silver tables (marks as EXISTING not ABORTED)")
        if new_bfield != bfield_val:
            run_call(f"CALL AGENT_FRAMEWORK.SET_BROWNFIELD_MODE({str(new_bfield).upper()})")
            st.success(f"Brownfield mode {'enabled' if new_bfield else 'disabled'}.")
