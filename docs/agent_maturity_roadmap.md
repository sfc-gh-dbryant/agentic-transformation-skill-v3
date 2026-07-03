# ATS Agent Maturity Roadmap

## Vision

The Agentic Transformation Skill evolves from an LLM-assisted automation tool into a
fully agent-based system where each pipeline phase is a conversation, not a function call.
The human role shifts from pipeline operator to pipeline approver and collaborator.

---

## Maturity Model

```
Level 1 - Scripted Automation
  Deterministic SQL pipelines. No intelligence.
  Human writes every query.

Level 2 - LLM-Assisted Automation          [ATS v3 - CURRENT]
  LLM fills intelligence gaps in a fixed workflow.
  Human triggers, system executes, human reviews output.
  Pipeline orchestrated by Streamlit, not agents.

Level 3 - Agentic Automation               [ATS v4 - CURRENT]
  Multiple specialized agents with tools.
  Workflow is predefined - agents execute within it.
  Conversational interaction bolted on (Agent Chat tab),
  not embedded in the pipeline itself.

Level 4 - Agent-Based Operation            [NEXT]
  Agents ARE the pipeline interface.
  Each phase is a conversation, not a function call.
  Humans participate in the pipeline, not just trigger it.
  Pipeline pauses at ambiguity, resumes on human response.

Level 5 - Autonomous Agent Systems         [HORIZON]
  Agents run continuously, escalate only on exceptions.
  Pipeline emerges from agent collaboration.
  Human role: oversight and exception handling only.
```

---

## What Changes at Level 4

### Conversational Checkpoints

Each phase agent presents reasoning and waits for human response when:
- Confidence falls below threshold
- A decision has business impact (e.g. PK conflict, schema drift)
- A prior conversation exists that may have changed

**Schema Analyst example:**
```
Agent:  "I found 24 relationships. Confident on 18.
         SIMPLEMART.SUPPLIER_ID has no target table in Bronze.
         Flag as known gap or block the Planner?"
Human:  "Flag it - SUPPLIERS table lands next week."
Agent:  Injects that context into Planner prompt, proceeds.
```

**Planner example:**
```
Agent:  "For DASHMART I am proposing CTAS with dedup on UPC.
         Business rules say use PRODUCT_KEY as PK but I see
         847 duplicates. Dedupe on (PRODUCT_KEY, STORE_NUMBER)
         or reject duplicates to a quarantine table?"
Human:  "Reject duplicates, quarantine them."
Agent:  Updates strategy, creates directive, proceeds.
```

**Validator example:**
```
Agent:  "DASHMART variance is 6.9% - outside 1% tolerance.
         The business rules doc explains ~7% dedup is expected.
         Auto-approve this pattern for tables with a
         business_rules doc that covers it?"
Human:  "Yes - add that as a standing directive."
Agent:  Creates directive, marks validation as approved.
```

---

### PIPELINE_CONVERSATIONS Table

Persistent memory of every agent-human exchange:

```sql
CREATE TABLE AGENT_FRAMEWORK.PIPELINE_CONVERSATIONS (
    conversation_id   VARCHAR DEFAULT UUID_STRING(),
    execution_id      VARCHAR,
    phase             VARCHAR,
    table_fqn         VARCHAR,
    agent_message     VARCHAR,
    human_response    VARCHAR,
    response_action   VARCHAR,   -- APPROVE, REJECT, MODIFY, DEFER
    injected_as       VARCHAR,   -- DIRECTIVE, LEARNING, CONTEXT
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

Agents read prior conversations for a table before running - they
remember what was decided in previous pipeline runs.

---

### Agent-to-Agent Consultation

Replace one-way phase handoffs with bidirectional consultation:

```
Schema Analyst  -->  Planner      (today: one-way handoff)
               <--               (next: Planner can ask SA to re-examine a table)

Planner         -->  Reflector    (today: Reflector reads learnings passively)
               <--               (next: Planner queries Reflector before generating strategy)
```

---

### Unified Conversation Interface

The interface becomes a conversation thread per pipeline run.
The active agent for the current phase is the participant.
Nav tabs become secondary to the conversation stream.

---

## Orchestrate Tab Evolution

| Today | Level 4 |
|-------|---------|
| Single call, returns JSON | Streaming conversation with agent |
| No visibility until complete | Real-time agent reasoning visible |
| No resume on failure | Agent detects prior state, resumes |
| Fixed sequence | Agent decides what to skip or retry |
| Human triggers only | Agent can request human input mid-run |

### Path to Orchestrate as Default

```
Phase 1 (now):
  - Add real-time WORKFLOW_LOG polling to Orchestrate tab
  - Add resume detection in RUN_AGENTIC_WORKFLOW
  - Parity with Workflow tab on visibility + resumability

Phase 2:
  - Add PIPELINE_CONVERSATIONS table
  - Schema Analyst + Planner emit conversational checkpoints
  - Streamlit shows pending approvals inline
  - Human responses injected as directives

Phase 3:
  - Agent-to-agent consultation between phases
  - Background execution via Snowflake Task + EXECUTE ASYNC
  - Workflow tab becomes manual override only

Phase 4:
  - Event-driven: new Bronze table fires Task, Agent pipeline runs
  - Human receives async notification of pending approvals
  - Snowflake Notifications (email/Slack) for checkpoint escalation
  - Orchestrate is the engine; human is the approver
```

---

## Two Near-Term Roadmap Capabilities

### 1. Background Discovery + Auto-Pipeline

Snowflake Task runs on schedule, detects new Bronze tables,
triggers ATS pipeline automatically.

```sql
CREATE TASK AGENT_FRAMEWORK.ATS_AUTO_DISCOVER_TASK
  WAREHOUSE = <warehouse>
  SCHEDULE  = 'USING CRON 0 * * * * UTC'
AS
  CALL AGENT_FRAMEWORK.ATS_AUTO_DISCOVER();
```

ATS_AUTO_DISCOVER SP:
1. Re-runs BOOTSTRAP to register new tables
2. Queries SILVER_GAPS for unprocessed tables
3. If gaps found, calls RUN_AGENTIC_WORKFLOW
4. Gold augmentation via BUILD_GOLD_FOR_NEW_TABLES post-execution

Schema changes to existing Bronze tables are already detected via
schema fingerprint hashing in the Planner (cache miss = re-plan).

**Complexity:** Low. 1 SP + 1 Task setup script + Streamlit toggle.

---

### 2. PII Access Policies

**Phase 1 - Discovery (Schema Analyst enhancement):**

During Schema Analyst execution, run SYSTEM$CLASSIFY on each
Bronze table. Store results in PII_COLUMN_REGISTRY:

```sql
CREATE TABLE AGENT_FRAMEWORK.PII_COLUMN_REGISTRY (
    table_fqn           VARCHAR,
    column_name         VARCHAR,
    semantic_category   VARCHAR,
    privacy_category    VARCHAR,
    confidence          FLOAT,
    masking_policy_name VARCHAR,
    policy_applied      BOOLEAN DEFAULT FALSE,
    created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Phase 2 - Policy Generation:**

New GENERATE_PII_POLICIES SP reads PII_COLUMN_REGISTRY and
generates masking policy DDL. DCM Export includes policies.sql.

| Layer | Approach |
|-------|----------|
| Silver | Tag-based masking on PII columns - survives schema rebuilds |
| Gold/Analytics | Role-based DDM - analysts see aggregated, no PII |
| Clinical rows | Row Access Policies per org unit / consent |

Phase 2 requires security design input from the customer.
Policy generation is automatable; application needs human approval.

**Complexity:** Phase 1 (discovery) = Low. Phase 2 (application) = Medium-High.

---

## MGB Applicability

| MGB Need | ATS Level 4 Capability |
|----------|------------------------|
| Clinician co-authors metric spec | Planner asks clarifying questions in natural language |
| Multiple hospital definitions | Schema Analyst presents differences; user confirms routing |
| Metric change triggers rebuild | Doc update triggers agent notification and targeted re-run |
| Persistent feedback loop | Every human response persists as a learning for future runs |
| PII protection | SYSTEM$CLASSIFY in Schema Analyst + tag-based masking in DCM Export |
| Audit trail | PIPELINE_CONVERSATIONS + WORKFLOW_LOG = full decision history |

---

## Summary

ATS is at Level 3. Level 4 is achievable with the existing Cortex Agents
infrastructure - it is primarily a workflow design and UX problem, not a
technology problem. The conversational layer already exists (Agent Chat tab);
it needs to be embedded in the pipeline rather than kept separate.

The Workflow tab becomes the debugger and manual override.
The Orchestrate tab becomes the autonomous engine.
The human becomes the approver, not the operator.

---

*Last updated: July 2026 | Danny Bryant | Snowflake Professional Services*
