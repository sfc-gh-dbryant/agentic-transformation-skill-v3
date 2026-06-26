# ATS v3 — Customer Engagement Guide

**Date:** June 2026  
**Status:** Current — reflects v3 production-ready state  
**Audience:** SAs delivering ATS v3 to customers

---

## What v3 Is Today

A deployable Snowflake-native framework that automates the Bronze → Silver → Gold transformation layer. An SA deploys it in 2 minutes against a customer's existing Bronze tables and drives it through a 10-tab Streamlit app. The customer's data engineer picks it up after the engagement and runs it themselves.

**It is not a pitch. It is a working tool you leave behind.**

---

## The Problem It Solves

Every PS engagement involving data in Snowflake hits the same bottleneck. Data arrives in Bronze — CDC feed, Fivetran, OpenFlow — and then engineering work stops for 2–4 weeks while someone manually writes deduplication logic, figures out type casting, builds SCD2 history, and defines Gold aggregations. For a 20-table schema that is a sprint of work before a single analytics query can run.

v3 compresses that to an afternoon. The SA sets the rules, the agent does the SQL, and the customer inherits a working, tested, documented pipeline.

---

## Current State Architecture

```
Customer Bronze Tables (any DB, any schema)
           │
           │  BOOTSTRAP('CUSTOMER_DB.BRONZE')
           ▼
┌─────────────────────────────────────────────────────────┐
│              AGENT_FRAMEWORK (framework DB)              │
│                                                          │
│  Schema Contracts   +   Transformation Directives        │
│  (structural rules)     (per-table business intent)      │
│           │                      │                       │
│           └──────────┬───────────┘                       │
│                      ▼                                   │
│     ┌─────────────── Pipeline ────────────────────┐     │
│     │  Schema Analyst → Planner → Executor         │     │
│     │       → Validator → Reflector                │     │
│     └───────────────────────────────────────────── ┘     │
│                      │                                   │
│            AGENT_FRAMEWORK_OUTPUT.*                      │
│            (enriched tables — never SILVER/GOLD)         │
│                      │                                   │
│     Cortex Search ◄──┘──► Semantic View                  │
│     (prior decisions)     (text-to-SQL)                  │
└─────────────────────────────────────────────────────────┘
           │
           ▼  Analytics Builder (human DDL review gate)
┌──────────────────┐      ┌────────────────────────────┐
│  Gold Tables     │  OR  │  DCM Project               │
│  (direct exec)   │      │  (versioned IaC handoff)   │
└──────────────────┘      └────────────────────────────┘
```

### Five-Phase Pipeline

| Phase | What it does | Human touchpoint |
|-------|-------------|-----------------|
| Schema Analyst | Cross-DB FK discovery across all Bronze tables in scope | Approval gate — SA reviews relationships before Planner sees them |
| Planner | LLM decides transformation strategy + PK columns, informed by Contracts, Directives, and Cortex Search prior learnings | None — fully automated |
| Executor | Generates DDL, executes or logs (dry run), self-corrects up to 3 retries | SA reviewed DDL in prior dry run |
| Validator | Row count validation using Planner-identified PK columns | None |
| Reflector | Captures learnings into Cortex Search — improves with each run | Can promote any learning to a Contract or Directive in one click |

---

## How v3 Accelerates the DE Pipeline

**Before v3 — a typical engagement:**

```
Week 1: SA manually inspects Bronze schemas, writes dedup logic per table
Week 2: SA builds Silver CTAS statements, reviews with customer DE team
Week 3: Customer DE team runs statements, fixes column type errors, reruns
Week 4: Gold aggregations scoped, proposed, reviewed, built
         → 4 weeks to first analytics query
```

**With v3 — same engagement:**

```
Day 1 morning:    SA deploys framework (2 min), sets Pipeline Context
Day 1 afternoon:  Dry run — LLM generates DDL for all Bronze tables
                  SA reviews generated SQL against customer schema
Day 1 late:       Live run — Silver tables built in AGENT_FRAMEWORK_OUTPUT
                  Validator confirms row counts
Day 2 morning:    Analytics Builder proposes Gold DDLs, SA reviews
Day 2 afternoon:  Gold tables built or exported as DCM project
                  Customer DE team inherits versioned IaC

→ 2 days to first analytics query
```

The compression is not magic — it is task delegation. The SA spends time on judgment (what are the rules, what does this table mean, does this DDL look right) not on mechanics (write the CTAS, figure out the dedup key, handle the NULL case). v3 handles the mechanics.

---

## The Three Conversations v3 Enables

### 1. Safety First — "No Surprises"

> "Before we touch anything, let me show you the three safety layers. Dry run is on by default — the LLM generates SQL, we log it, nothing gets executed. The output schema is isolated from your SILVER and GOLD schemas entirely. And if a target table already has rows, we abort with a message showing you exactly how many rows are at risk. You can watch the whole first run without risking a single production table."

**Demo path:** Tab 2 → dry run toggle → Tab 5 → run workflow → Tab 8 → review DRY_RUN log entries → show ABORTED entry when overwrite is attempted.

---

### 2. Human in the Loop — "You Stay in Control"

> "The agent never makes a structural decision alone. Before the Planner runs, I review the FK relationships it discovered. Before Gold tables are created, I review every DDL proposal. The Contracts tab lets me add a rule right now — 'never drop the IMAGES column' — and that rule is injected into every LLM call from this point forward. The agent works within the boundaries I set."

**Demo path:** Tab 3 → add a contract live → Tab 4 → add a directive → Tab 5 → approval gate → Tab 6 → review Gold DDL before executing.

---

### 3. This Becomes Your Infrastructure — "The Handoff"

> "At the end of the engagement, I export everything as a DCM project. Six files — manifest, table definitions, access grants, data quality expectations. Your DE team commits that to git and deploys it with a single CLI command. From that point forward, your Gold layer is infrastructure-as-code. The agent did the exploratory, creative work. The DCM project is what you manage long-term."

**Demo path:** Tab 6 → execute Gold tables → Tab 10 → generate DCM project → show 6 files → show deploy command.

---

## SA Delivery Motion (~40 minutes total)

| Step | Tab | Time | What to do |
|------|-----|------|-----------|
| Pre-call | — | 15 min | Deploy, bootstrap, verify model = `llama3.3-70b`, tables registered |
| Context | Tab 2 | 5 min | Fill in business description, analytics goals, constraints **with the customer present** — this is the highest-value 5 minutes, better context = better DDL |
| Contracts + Directives | Tabs 3 + 4 | 5 min | Show defaults, add 1–2 customer-specific rules live |
| Workflow — dry run | Tab 5 | 5 min | Run with dry run ON, walk through the phase diagram live |
| Workflow — review DDL | Tab 8 | 3 min | Open DRY_RUN log entries, review generated SQL with customer |
| Workflow — live run | Tab 5 | 5 min | Flip dry run OFF, run live, show Validator passing |
| Observe | Tab 8 | 3 min | Show learnings captured, ABORTED overwrite protection, Cortex Search query |
| Gold + DCM | Tabs 6 + 10 | 5 min | Propose Gold DDLs, review together, execute, generate DCM project, hand files to DE lead |

**Total: ~40 minutes.** Customer leaves with working Silver and Gold tables and a DCM project in their hands.

---

## Current Limitations — Communicate Honestly

| Limitation | How to handle in a demo |
|-----------|------------------------|
| **No brownfield mode** — if customer has existing Silver/Gold tables, v3 will try to rebuild rather than validate | Keep `output_schema = AGENT_FRAMEWORK_OUTPUT` (default). Frame the run as a parallel build, not a replacement. Show the customer the isolated output before any decisions about production. |
| **One LLM call per phase** — Executor can hallucinate columns it cannot verify mid-generation | Column list is injected from `INFORMATION_SCHEMA` before each call. Show the dry run DDL — if a column is wrong it is visible before execution. Self-correction retries up to 3× on SQL errors. |
| **No document ingestion** — Planner only knows what you tell it via Pipeline Context, Contracts, and Directives | Spend 5 minutes on Tabs 2 and 4 before running. The more specific the Directives, the better the output. This is a conversation, not a limitation. |
| **Cross-DB data** — framework DB separate from customer data DB | This is the expected pattern — `BOOTSTRAP('CUSTOMER_DB.BRONZE')` handles it natively. Not a limitation. |

---

## Partner Routing — When to Use Tab 9

Tab 9 (Partner Routing) is relevant when the customer has one Silver staging table that fans out to multiple Gold tables based on a dimension value. This is common in:

- **Grocery / Retail:** store banner, store format, region
- **Media:** content type, product category
- **Financial services:** product line, customer segment

If the customer mentions "we have different analytics tables per banner/region/format", open Tab 9 before Tab 6. Configure the routing rules, then validate with `VALIDATE_MULTI_BANNER` before building Gold.

---

## Backlog — What v3 Cannot Do Yet

| Item | Priority | Impact if missing | Workaround |
|------|----------|------------------|-----------|
| **B-01 Document Ingestion** | High | Planner lacks domain knowledge from customer docs (ERDs, naming conventions, data dictionaries) | Manually translate document rules into Contracts and Directives in Tabs 3 + 4 |
| **B-03 Brownfield Mode** | High | Cannot safely run against accounts with live Silver/Gold | Use `output_schema = AGENT_FRAMEWORK_OUTPUT`, build in parallel, customer reviews diff before promoting |
| **B-06 Gold Awareness** | High | Analytics Builder ignores existing Gold when proposing new tables — may propose overlapping coverage | Review Gold proposals carefully before executing; remove duplicates manually |
| **B-07 Output Models (Star Schema, Data Vault, OBT)** | High | `gold_output_mode` column exists but STAR_SCHEMA/DATA_VAULT/OBT generation not yet implemented | FLAT mode only in v3 |
| **B-02 Industry Packs** | Medium | SA must build Contracts/Directives from scratch per vertical | Use walkthrough examples as starting templates |
| **B-05 Rollback Script** | Low | Partial deploys require manual cleanup | `RESET_FRAMEWORK('YES')` clears runtime state; schema objects need manual DROP if deploy fails mid-way |

**B-01 and B-03 are being targeted for a v3 patch before v4 ships** — both are customer blockers and self-contained (estimated 3 days combined). B-06, B-07, B-02 land more naturally in v4's Cortex Agents architecture.

---

## v3 → v4 Direction

v4 replaces the SP pipeline with Cortex Agents — each phase becomes an agent with tools. This removes the one-LLM-call-per-phase ceiling: agents can check `INFORMATION_SCHEMA` mid-generation, confirm FK assumptions by sampling data, and recover intelligently from bad output.

The Cortex Search service and Semantic View built in v3 are the primary tool backends for v4 agents — no changes required. The `AGENT_FRAMEWORK` schema and all its tables are forward-compatible.

**Design:** `docs/v4_architecture.md`
