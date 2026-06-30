-- =============================================================================
-- ATS v4 — Multi-Agent Orchestration
-- Replaces v3 SP bridges in the Orchestrator with direct sub-agent calls
-- via Python UDFs + External Access Integration + PAT secret.
--
-- Architecture:
--   Orchestrator Agent
--     → calls ATS_CALL_SCHEMA_ANALYST (UDF)
--         → HTTP POST /api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_SCHEMA_ANALYST_AGENT:run
--     → calls ATS_CALL_PLANNER (UDF)  → ATS_PLANNER_AGENT
--     → calls ATS_CALL_EXECUTOR (UDF) → ATS_EXECUTOR_AGENT
--     → calls ATS_CALL_VALIDATOR (UDF)→ ATS_VALIDATOR_AGENT
--     → calls ATS_CALL_REFLECTOR (UDF)→ ATS_REFLECTOR_AGENT
--
-- Deploy:
--   printf "USE ROLE ACCOUNTADMIN; USE DATABASE ATS_V4; USE WAREHOUSE DBRYANT_COCO_WH_S;\n" > /tmp/v4_ma.sql
--   cat setup/v4_multi_agent.sql >> /tmp/v4_ma.sql
--   snow sql -c "CoCo-Green" -f /tmp/v4_ma.sql
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE ATS_V4;
USE SCHEMA AGENT_FRAMEWORK;
USE WAREHOUSE DBRYANT_COCO_WH_S;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. NETWORK RULE — egress to this Snowflake account's REST API
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE NETWORK RULE ATS_AGENT_EGRESS_RULE
    MODE       = EGRESS
    TYPE       = HOST_PORT
    VALUE_LIST = ('dua47004.prod2.us-west-2.aws.snowflakecomputing.com');

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. SECRET — PAT token for agent-to-agent auth
--    Generate from: Snowflake UI → User Menu → My Profile → Authentication → Generate Token
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE SECRET ATS_AGENT_PAT_SECRET
    TYPE          = GENERIC_STRING
    SECRET_STRING = '<YOUR_SNOWFLAKE_PAT_TOKEN>';  -- Generate: Snowflake UI → User Menu → My Profile → Authentication → Generate Token

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. EXTERNAL ACCESS INTEGRATION
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ATS_AGENT_EAI
    ALLOWED_NETWORK_RULES        = (ATS_AGENT_EGRESS_RULE)
    ALLOWED_AUTHENTICATION_SECRETS = ALL
    ENABLED                      = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. GRANTS
-- ─────────────────────────────────────────────────────────────────────────────
GRANT READ  ON SECRET    AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET  TO ROLE ACCOUNTADMIN;
GRANT USAGE ON INTEGRATION ATS_AGENT_EAI                         TO ROLE ACCOUNTADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. PYTHON UDFs — one per sub-agent
--    Each UDF: receives a message string, calls the sub-agent REST endpoint,
--    parses SSE stream, returns the agent's full text response.
-- ─────────────────────────────────────────────────────────────────────────────

-- Helper macro — same body for all 5, only URL differs
-- Schema Analyst
CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ATS_CALL_SCHEMA_ANALYST(message VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
EXTERNAL_ACCESS_INTEGRATIONS = (ATS_AGENT_EAI)
SECRETS = ('agent_token' = AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET)
HANDLER = 'run'
AS $$
import _snowflake, requests, json

def run(message):
    token = _snowflake.get_generic_secret_string('agent_token')
    url   = 'https://dua47004.prod2.us-west-2.aws.snowflakecomputing.com/api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_SCHEMA_ANALYST_AGENT:run'
    payload = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': message}]}]}
    resp = requests.post(url,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
        json=payload, stream=True, timeout=300, verify=False)
    if resp.status_code != 200:
        return f'ERROR {resp.status_code}: {resp.text[:400]}'
    chunks, evt = [], None
    for line in resp.iter_lines():
        line = line.decode('utf-8') if isinstance(line, bytes) else line
        if line.startswith('event: '):   evt = line[7:].strip()
        elif line.startswith('data: '):
            try:
                d = json.loads(line[6:])
            except: continue
            if evt == 'response.text.delta': chunks.append(d.get('text',''))
            elif evt == 'error':             return f'AGENT_ERROR: {d}'
            elif evt == 'done':              break
    return ''.join(chunks) or 'No response.'
$$;

-- Planner
CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ATS_CALL_PLANNER(message VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
EXTERNAL_ACCESS_INTEGRATIONS = (ATS_AGENT_EAI)
SECRETS = ('agent_token' = AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET)
HANDLER = 'run'
AS $$
import _snowflake, requests, json

def run(message):
    token = _snowflake.get_generic_secret_string('agent_token')
    url   = 'https://dua47004.prod2.us-west-2.aws.snowflakecomputing.com/api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_PLANNER_AGENT:run'
    payload = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': message}]}]}
    resp = requests.post(url,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
        json=payload, stream=True, timeout=300, verify=False)
    if resp.status_code != 200:
        return f'ERROR {resp.status_code}: {resp.text[:400]}'
    chunks, evt = [], None
    for line in resp.iter_lines():
        line = line.decode('utf-8') if isinstance(line, bytes) else line
        if line.startswith('event: '):   evt = line[7:].strip()
        elif line.startswith('data: '):
            try: d = json.loads(line[6:])
            except: continue
            if evt == 'response.text.delta': chunks.append(d.get('text',''))
            elif evt == 'error':             return f'AGENT_ERROR: {d}'
            elif evt == 'done':              break
    return ''.join(chunks) or 'No response.'
$$;

-- Executor
CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ATS_CALL_EXECUTOR(message VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
EXTERNAL_ACCESS_INTEGRATIONS = (ATS_AGENT_EAI)
SECRETS = ('agent_token' = AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET)
HANDLER = 'run'
AS $$
import _snowflake, requests, json

def run(message):
    token = _snowflake.get_generic_secret_string('agent_token')
    url   = 'https://dua47004.prod2.us-west-2.aws.snowflakecomputing.com/api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_EXECUTOR_AGENT:run'
    payload = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': message}]}]}
    resp = requests.post(url,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
        json=payload, stream=True, timeout=600, verify=False)
    if resp.status_code != 200:
        return f'ERROR {resp.status_code}: {resp.text[:400]}'
    chunks, evt = [], None
    for line in resp.iter_lines():
        line = line.decode('utf-8') if isinstance(line, bytes) else line
        if line.startswith('event: '):   evt = line[7:].strip()
        elif line.startswith('data: '):
            try: d = json.loads(line[6:])
            except: continue
            if evt == 'response.text.delta': chunks.append(d.get('text',''))
            elif evt == 'error':             return f'AGENT_ERROR: {d}'
            elif evt == 'done':              break
    return ''.join(chunks) or 'No response.'
$$;

-- Validator
CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ATS_CALL_VALIDATOR(message VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
EXTERNAL_ACCESS_INTEGRATIONS = (ATS_AGENT_EAI)
SECRETS = ('agent_token' = AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET)
HANDLER = 'run'
AS $$
import _snowflake, requests, json

def run(message):
    token = _snowflake.get_generic_secret_string('agent_token')
    url   = 'https://dua47004.prod2.us-west-2.aws.snowflakecomputing.com/api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_VALIDATOR_AGENT:run'
    payload = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': message}]}]}
    resp = requests.post(url,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
        json=payload, stream=True, timeout=300, verify=False)
    if resp.status_code != 200:
        return f'ERROR {resp.status_code}: {resp.text[:400]}'
    chunks, evt = [], None
    for line in resp.iter_lines():
        line = line.decode('utf-8') if isinstance(line, bytes) else line
        if line.startswith('event: '):   evt = line[7:].strip()
        elif line.startswith('data: '):
            try: d = json.loads(line[6:])
            except: continue
            if evt == 'response.text.delta': chunks.append(d.get('text',''))
            elif evt == 'error':             return f'AGENT_ERROR: {d}'
            elif evt == 'done':              break
    return ''.join(chunks) or 'No response.'
$$;

-- Reflector
CREATE OR REPLACE FUNCTION AGENT_FRAMEWORK.ATS_CALL_REFLECTOR(message VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
EXTERNAL_ACCESS_INTEGRATIONS = (ATS_AGENT_EAI)
SECRETS = ('agent_token' = AGENT_FRAMEWORK.ATS_AGENT_PAT_SECRET)
HANDLER = 'run'
AS $$
import _snowflake, requests, json

def run(message):
    token = _snowflake.get_generic_secret_string('agent_token')
    url   = 'https://dua47004.prod2.us-west-2.aws.snowflakecomputing.com/api/v2/databases/ATS_V4/schemas/AGENT_FRAMEWORK/agents/ATS_REFLECTOR_AGENT:run'
    payload = {'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': message}]}]}
    resp = requests.post(url,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
        json=payload, stream=True, timeout=300, verify=False)
    if resp.status_code != 200:
        return f'ERROR {resp.status_code}: {resp.text[:400]}'
    chunks, evt = [], None
    for line in resp.iter_lines():
        line = line.decode('utf-8') if isinstance(line, bytes) else line
        if line.startswith('event: '):   evt = line[7:].strip()
        elif line.startswith('data: '):
            try: d = json.loads(line[6:])
            except: continue
            if evt == 'response.text.delta': chunks.append(d.get('text',''))
            elif evt == 'error':             return f'AGENT_ERROR: {d}'
            elif evt == 'done':              break
    return ''.join(chunks) or 'No response.'
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ORCHESTRATOR AGENT — updated to use UDF-based sub-agent calls
--    Keeps: list_silver_gaps, create_execution, get_workflow_status,
--           update_workflow_status, log_workflow_event (SP tools, unchanged)
--    Replaces: run_schema_analyst/planner/executor/validator/reflector (SP bridges)
--           → call_schema_analyst/planner/executor/validator/reflector (UDF tools)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_ORCHESTRATOR_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 900, "tokens": 500000 } },
  "instructions": {
    "orchestration": "You are the Orchestrator for the Agentic Transformation Skill v4. You coordinate five specialist agents in sequence to transform Bronze tables into Silver.\n\nWorkflow:\n1. Call list_silver_gaps to identify Bronze tables needing Silver transformation.\n2. Call create_execution with trigger_source='agent' and tables_json (JSON array of FQNs) to register the run.\n3. Call log_workflow_event(execution_id, 'ORCHESTRATOR', 'STARTED', 'Pipeline started').\n4. Phase 1 — Schema Analyst: call call_schema_analyst with a message like: 'Execution ID: {id}. Analyze FK relationships across these Bronze tables: {tables}. Use your discover_schema and sample_data tools.'\n   Call update_workflow_status(execution_id, 'SCHEMA_ANALYST', 'COMPLETE') when done.\n5. Phase 2 — Planner: call call_planner with: 'Execution ID: {id}. Plan Silver transformation strategies for these tables: {tables}. Use the schema relationships just discovered.'\n   Call update_workflow_status(execution_id, 'PLANNER', 'COMPLETE') when done.\n6. Phase 3 — Executor: call call_executor with: 'Execution ID: {id}. Execute Silver DDL for these tables: {tables}. Use the Planner decisions already recorded.'\n   Call update_workflow_status(execution_id, 'EXECUTOR', 'COMPLETE') when done.\n7. Phase 4 — Validator: call call_validator with: 'Execution ID: {id}. Validate all Silver tables produced in this run.'\n   Call update_workflow_status(execution_id, 'VALIDATOR', 'COMPLETE') when done.\n8. Phase 5 — Reflector: call call_reflector with: 'Execution ID: {id}. Reflect on this pipeline run and save any new learnings.'\n   Call update_workflow_status(execution_id, 'REFLECTOR', 'COMPLETE') when done.\n9. Call update_workflow_status(execution_id, 'ORCHESTRATOR', 'COMPLETE').\n10. Call log_workflow_event(execution_id, 'ORCHESTRATOR', 'COMPLETE', 'Pipeline completed successfully').\n\nIf any sub-agent returns a response starting with ERROR or AGENT_ERROR, call log_workflow_event with status ERROR, call update_workflow_status with status ERROR, and stop immediately.",
    "response": "Return a JSON summary with: execution_id, phases_completed (array), final_status (COMPLETE/ERROR), tables_processed (count), duration_note."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "list_silver_gaps",
        "description": "Returns all Bronze tables that currently have no Silver coverage. Use to determine which tables to include in a run.",
        "input_schema": { "type": "object", "properties": {} }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "create_execution",
        "description": "Creates a new workflow execution record and returns the execution_id.",
        "input_schema": {
          "type": "object",
          "properties": {
            "trigger_source": { "type": "string", "description": "Who triggered the run: 'manual', 'agent', 'scheduled'" },
            "tables_json":    { "type": "string", "description": "JSON array of fully-qualified table FQNs, or null for all gaps" }
          },
          "required": ["trigger_source"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_workflow_status",
        "description": "Returns the current status and phase of a workflow execution.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" }
          },
          "required": ["execution_id"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "update_workflow_status",
        "description": "Updates the status and current_phase of a workflow execution.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string" },
            "phase":        { "type": "string", "description": "SCHEMA_ANALYST | PLANNER | EXECUTOR | VALIDATOR | REFLECTOR | ORCHESTRATOR | COMPLETE | ERROR" },
            "status":       { "type": "string", "description": "RUNNING | COMPLETE | ERROR" }
          },
          "required": ["execution_id", "phase", "status"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "log_workflow_event",
        "description": "Writes an event to WORKFLOW_LOG.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string" },
            "phase":        { "type": "string" },
            "status":       { "type": "string", "description": "STARTED | COMPLETE | ERROR" },
            "message":      { "type": "string" }
          },
          "required": ["execution_id", "phase", "status", "message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "call_schema_analyst",
        "description": "Calls the Schema Analyst Agent directly. Pass a natural language message including execution_id and table list. The agent will discover FK relationships using its own tools.",
        "input_schema": {
          "type": "object",
          "properties": {
            "message": { "type": "string", "description": "Instruction for the Schema Analyst Agent including execution_id and table FQNs" }
          },
          "required": ["message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "call_planner",
        "description": "Calls the Planner Agent directly. Pass a message with execution_id and tables. The agent will determine transformation strategies using its own tools.",
        "input_schema": {
          "type": "object",
          "properties": {
            "message": { "type": "string", "description": "Instruction for the Planner Agent" }
          },
          "required": ["message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "call_executor",
        "description": "Calls the Executor Agent directly. Pass execution_id and tables. The agent will generate and execute Silver DDL using its own tools.",
        "input_schema": {
          "type": "object",
          "properties": {
            "message": { "type": "string", "description": "Instruction for the Executor Agent" }
          },
          "required": ["message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "call_validator",
        "description": "Calls the Validator Agent directly. Pass execution_id. The agent will validate Silver table quality using its own tools.",
        "input_schema": {
          "type": "object",
          "properties": {
            "message": { "type": "string", "description": "Instruction for the Validator Agent" }
          },
          "required": ["message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "call_reflector",
        "description": "Calls the Reflector Agent directly. Pass execution_id. The agent will analyze the run and save learnings using its own tools.",
        "input_schema": {
          "type": "object",
          "properties": {
            "message": { "type": "string", "description": "Instruction for the Reflector Agent" }
          },
          "required": ["message"]
        }
      }
    }
  ],
  "tool_resources": {
    "list_silver_gaps":    { "type": "procedure", "identifier": "AGENT_FRAMEWORK.ATS_TOOL_LIST_SILVER_GAPS",    "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 } },
    "create_execution":    { "type": "procedure", "identifier": "AGENT_FRAMEWORK.ATS_TOOL_CREATE_EXECUTION",    "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 } },
    "get_workflow_status": { "type": "procedure", "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_WORKFLOW_STATUS", "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 } },
    "update_workflow_status": { "type": "procedure", "identifier": "AGENT_FRAMEWORK.ATS_TOOL_UPDATE_WORKFLOW_STATUS", "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 } },
    "log_workflow_event":  { "type": "procedure", "identifier": "AGENT_FRAMEWORK.ATS_TOOL_LOG_WORKFLOW_EVENT",  "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 } },
    "call_schema_analyst": { "type": "function",  "identifier": "AGENT_FRAMEWORK.ATS_CALL_SCHEMA_ANALYST",     "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 } },
    "call_planner":        { "type": "function",  "identifier": "AGENT_FRAMEWORK.ATS_CALL_PLANNER",            "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 } },
    "call_executor":       { "type": "function",  "identifier": "AGENT_FRAMEWORK.ATS_CALL_EXECUTOR",           "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 600 } },
    "call_validator":      { "type": "function",  "identifier": "AGENT_FRAMEWORK.ATS_CALL_VALIDATOR",          "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 } },
    "call_reflector":      { "type": "function",  "identifier": "AGENT_FRAMEWORK.ATS_CALL_REFLECTOR",          "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 } }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. USAGE grants on new UDFs
-- ─────────────────────────────────────────────────────────────────────────────
GRANT USAGE ON FUNCTION AGENT_FRAMEWORK.ATS_CALL_SCHEMA_ANALYST(VARCHAR) TO ROLE ACCOUNTADMIN;
GRANT USAGE ON FUNCTION AGENT_FRAMEWORK.ATS_CALL_PLANNER(VARCHAR)        TO ROLE ACCOUNTADMIN;
GRANT USAGE ON FUNCTION AGENT_FRAMEWORK.ATS_CALL_EXECUTOR(VARCHAR)       TO ROLE ACCOUNTADMIN;
GRANT USAGE ON FUNCTION AGENT_FRAMEWORK.ATS_CALL_VALIDATOR(VARCHAR)      TO ROLE ACCOUNTADMIN;
GRANT USAGE ON FUNCTION AGENT_FRAMEWORK.ATS_CALL_REFLECTOR(VARCHAR)      TO ROLE ACCOUNTADMIN;
GRANT USAGE ON AGENT   AGENT_FRAMEWORK.ATS_ORCHESTRATOR_AGENT             TO ROLE ACCOUNTADMIN;
