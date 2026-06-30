# v3 → v4 Architecture Shift

> **The one-sentence version:**
> v3 is a pipeline of stored procedures where each phase makes one LLM call and moves on. v4 keeps that pipeline and adds a Cortex Agents layer alongside it — each phase now has an agent that can invoke tools, verify its own assumptions, and reason across multiple steps before committing to an action.

---

## What Actually Changed

The v3 pipeline works. It ships Silver tables. It has a retry loop when the LLM makes a mistake. That pipeline is still running in v4, unchanged.

What v4 adds is a second execution path sitting alongside it — a layer of Cortex Agents where each phase can think before it acts. The agents don't replace the SPs. They use the same tables, write to the same logs, and produce the same outputs. The difference is *how* they arrive at the result.

---

## The Core Shift: One Call vs. A Reasoning Loop

In v3, the Executor phase works like this:

```mermaid
flowchart LR
    A([Start]) --> B[Inject schema\ninto prompt]
    B --> C[LLM Call\nGenerate DDL]
    C --> D{SQL valid?}
    D -- Yes --> E([Execute & log])
    D -- No --> F[Inject error\nback into prompt]
    F --> C

    style A fill:#e8f4f8,stroke:#4a90d9
    style E fill:#d4edda,stroke:#28a745
    style F fill:#fff3cd,stroke:#ffc107
    style C fill:#f0e6ff,stroke:#7c3aed
```

The LLM gets one shot. If it fails, the error is fed back and it tries again. The retry loop eventually recovers, but it starts blind — the LLM guesses column names from training patterns rather than from the actual schema.

In v4, the Executor Agent works like this:

```mermaid
flowchart LR
    A([Start]) --> B[GET_COLUMNS\ntool call]
    B --> C{Reason:\ncolumns confirmed?}
    C --> D[VALIDATE_COLUMN\ntool call]
    D --> E{Reason:\nDDL safe to generate?}
    E --> F[Generate DDL\ngrounded on known columns]
    F --> G[EXECUTE_DDL\ntool call]
    G --> H{Reason:\ndid it work?}
    H -- Yes --> I([Log result])
    H -- No --> E

    style A fill:#e8f4f8,stroke:#4a90d9
    style I fill:#d4edda,stroke:#28a745
    style B fill:#e6f3ff,stroke:#0d6efd
    style D fill:#e6f3ff,stroke:#0d6efd
    style G fill:#e6f3ff,stroke:#0d6efd
    style F fill:#f0e6ff,stroke:#7c3aed
```

The agent **never generates DDL without first confirming the column list exists**. The reasoning loop between tool calls is where the intelligence lives — not in a bigger prompt, but in grounded, sequential verification.

---

## What This Looks Like Per Phase

Each phase in v3 makes one LLM call. Each agent in v4 makes multiple tool calls with reasoning between them:

```mermaid
flowchart TB
    subgraph V3["v3 — Stored Procedure Pipeline"]
        direction LR
        SA3[Schema Analyst\n1 LLM call] --> PL3[Planner\n1 LLM call per table]
        PL3 --> EX3[Executor\n1 LLM call + retries]
        EX3 --> VA3[Validator\n1 LLM call]
        VA3 --> RE3[Reflector\n1 LLM call]
    end

    subgraph V4["v4 — Cortex Agents Layer"]
        direction LR
        SA4[Schema Analyst\nDiscover → Sample → Verify\n→ Record] --> PL4[Planner\nSearch priors → Read context\n→ Decide → Save]
        PL4 --> EX4[Executor\nGet columns → Validate\n→ Generate → Execute]
        EX4 --> VA4[Validator\nCount → Check PK\n→ Compare → Sample]
        VA4 --> RE4[Reflector\nSearch learnings → Extract\n→ Deduplicate → Save]
    end

    V3 -.->|"Same tables\nSame outputs\nSame data layer"| V4

    style V3 fill:#f8f9fa,stroke:#6c757d
    style V4 fill:#f0e6ff,stroke:#7c3aed
```

---

## The Dual-Path Architecture

Both paths write to the same data layer. The SP pipeline is the fast, reliable, batch path. The Agent path is the interactive, exploratory, grounded path. You can mix and match — run the SP Planner for speed, then hand off to the Executor Agent for a table that keeps failing.

```mermaid
flowchart TB
    UI["Streamlit App"]

    UI --> |"Pipeline Tab\nbatch runs"| SP
    UI --> |"Agent Hub\nOrchestrate Tab"| AG

    subgraph SP["SP Pipeline  (v3+)"]
        direction LR
        sp1[WORKFLOW_SCHEMA_ANALYST] --> sp2[WORKFLOW_PLANNER]
        sp2 --> sp3[WORKFLOW_EXECUTOR]
        sp3 --> sp4[WORKFLOW_VALIDATOR]
        sp4 --> sp5[WORKFLOW_REFLECTOR]
    end

    subgraph AG["Cortex Agents Layer  (v4)"]
        direction LR
        ag1[ATS_SCHEMA_ANALYST_AGENT] --> ag2[ATS_PLANNER_AGENT]
        ag2 --> ag3[ATS_EXECUTOR_AGENT]
        ag3 --> ag4[ATS_VALIDATOR_AGENT]
        ag4 --> ag5[ATS_REFLECTOR_AGENT]
    end

    SP --> DATA
    AG --> DATA

    subgraph DATA["Shared Data Layer"]
        direction LR
        d1[WORKFLOW_EXECUTIONS\nWORKFLOW_LOG]
        d2[PLANNER_DECISIONS\nSCHEMA_RELATIONSHIPS]
        d3[WORKFLOW_LEARNINGS\nCOST_ATTRIBUTION]
    end

    DATA --> INTEL

    subgraph INTEL["Cortex Intelligence"]
        cs[ATS_KNOWLEDGE_SEARCH\nCortex Search]
        sv[ATS_PIPELINE_SEMANTICS\nSemantic View]
    end

    style SP fill:#e8f4f8,stroke:#4a90d9
    style AG fill:#f0e6ff,stroke:#7c3aed
    style DATA fill:#f8f9fa,stroke:#6c757d
    style INTEL fill:#fff3e0,stroke:#fd7e14
```

---

## The Tool Layer: How Agents Access Data

The 35 `ATS_TOOL_*` stored procedures are the connective tissue between the agents and the data layer. Every tool follows the same contract: named input parameters, JSON output, callable by both agents and SPs directly.

```mermaid
flowchart LR
    subgraph AGENTS["Cortex Agents"]
        a1[Schema Analyst]
        a2[Planner]
        a3[Executor]
        a4[Validator]
        a5[Reflector]
        a6[Orchestrator]
    end

    subgraph TOOLS["ATS_TOOL_* Layer  (35 SPs)"]
        t1["Schema\ndiscover_schema\nsample_data\nget_columns\nlist_tables"]
        t2["Planning\nget_pipeline_context\nget_contracts\nget_directives\nsearch_prior_decisions"]
        t3["Execution\nexecute_ddl\nvalidate_column\ncheck_table_exists"]
        t4["Validation\ncount_rows\ncheck_pk_uniqueness\ncompare_counts"]
        t5["Knowledge\nsearch_learnings\nsave_learning\nlog_workflow_event"]
    end

    a1 --> t1
    a2 --> t2
    a3 --> t1
    a3 --> t3
    a4 --> t4
    a4 --> t2
    a5 --> t5
    a6 --> t5
    a6 --> t1

    t1 & t2 & t3 & t4 & t5 --> DB[("AGENT_FRAMEWORK\ntables")]

    style AGENTS fill:#f0e6ff,stroke:#7c3aed
    style TOOLS fill:#e6f3ff,stroke:#0d6efd
    style DB fill:#f8f9fa,stroke:#6c757d
```

Adding a new capability means adding one `ATS_TOOL_*` SP. Every agent that references it gets the capability immediately — no changes to agent logic required.

---

## Prevent vs. Recover

The clearest way to see the architectural impact is the retry count:

| Version | Column hallucination approach | Avg retries/table | Clean run result |
|---------|-------------------------------|------------------|-----------------|
| v2 | LLM guesses from training patterns | 2.4 | 15% first-run accuracy |
| v3 | Inject column list into prompt — LLM still interprets it | 0.8 | 75% first-run accuracy |
| v4 | Agent calls `GET_COLUMNS` tool → only knows columns that exist | **0.0** | 100% (5/5 tables) |

v3 tells the LLM what columns exist. v4 makes it impossible for the agent to reference a column it hasn't confirmed through a tool call first.

```mermaid
flowchart LR
    subgraph V3R["v3 — Recover"]
        direction TB
        r1[Generate DDL\ncolumns from prompt] --> r2{Execute}
        r2 -- Error --> r3[Inject error\ninto prompt]
        r3 --> r1
        r2 -- OK --> r4([Done])
    end

    subgraph V4P["v4 — Prevent"]
        direction TB
        p1[GET_COLUMNS\ntool call] --> p2[Only these\ncolumns exist]
        p2 --> p3[Generate DDL\ngrounded on p2]
        p3 --> p4{Execute}
        p4 -- OK --> p5([Done])
    end

    style V3R fill:#fff3cd,stroke:#ffc107
    style V4P fill:#d4edda,stroke:#28a745
```

---

## Summary

| Dimension | v3 | v4 |
|-----------|----|----|
| **Execution model** | One LLM call per phase | Agent loop — tool calls + reasoning steps |
| **Column accuracy** | Prompt injection (LLM interprets) | Tool-grounded (agent fetches, then generates) |
| **Error handling** | Retry after failure | Prevent before execution |
| **Entry points** | SP pipeline only | SP pipeline + Agent path (shared data layer) |
| **Extensibility** | Edit a stored procedure | Add one `ATS_TOOL_*` SP |
| **Retries on clean run** | 0.8 avg | 0.0 |
| **Interactive exploration** | None | Agent Hub — converse with any phase agent directly |
