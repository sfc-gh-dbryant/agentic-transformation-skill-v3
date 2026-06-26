# ADR 002 — DCM Integration Pattern

**Status:** Accepted  
**Date:** April 2026  
**Context:** Agentic Transformation Skill — where DCM fits in the agentic workflow

---

## Problem

Database Change Management (DCM) is Snowflake's schema infrastructure-as-code tool. The question
is whether DCM should be the execution engine for agent-generated DDL, or whether it serves a
different role in this skill.

---

## Decision

**DCM is NOT the runtime execution engine for the agentic workflow.**  
**DCM IS the production handoff artifact from the Gold Builder.**

The two parts of this skill operate at different phases:

| Phase | Execution Model | Why |
|---|---|---|
| Silver layer (agentic loop) | Direct SQL via `EXECUTE IMMEDIATE` | The agent iterates, self-corrects, retries — needs programmatic execution at SP speed, not a human-gated CLI workflow |
| Gold layer (proposal) | SA reviews DDL before execution | Explicit review gate; agent generates, human approves |
| Gold layer (production deploy) | **DCM project** | Customer gets versioned, git-trackable schema definitions they can manage long-term |

---

## Why DCM Does Not Fit the Agentic Loop

DCM's workflow is: **analyze → plan → human confirmation → deploy** (CLI-driven).

This is incompatible with agentic execution because:

1. DCM commands run via `snow dcm` CLI — they cannot be called from inside a Snowflake stored procedure
2. The Planner → Executor → Validator → Reflector loop may CREATE, ALTER, and DROP tables tens of times per run as it self-corrects
3. DCM's declarative model expects a known desired end-state; the agentic loop is discovering the end-state iteratively
4. The latency of analyze → plan → human confirm → deploy would make the workflow unusable as an automated loop

---

## Where DCM Fits: The Exit Ramp

Once the agent has proposed Gold DDLs and the SA has reviewed and approved them in Tab 5, the
system offers two execution paths:

```
Gold DDLs proposed by agent
        │
        ├─→ "Execute directly"     — GOLD_AGENTIC_EXECUTOR(ddl)
        │                            Good for: dev, demo, exploration
        │
        └─→ "Export as DCM Project" — EXPORT_DCM_PROJECT(output_stage)
                                      Good for: production handoff to customer
```

### What EXPORT_DCM_PROJECT generates

A fully deployable DCM project written to a Snowflake stage:

```
@<stage>/dcm_export/
├── manifest.yml              # DCM project manifest
└── definitions/
    ├── gold_tables.sql       # DEFINE TABLE statements for all approved Gold tables
    └── access.sql            # GRANT statement stubs for consumer roles
```

The SA downloads this, commits it to the customer's git repository, and the customer deploys
and manages it with standard DCM CLI going forward.

---

## Why This Is The Right Story

The two-path model gives the SA a compelling delivery narrative:

> "The agent does the creative, exploratory work — building Silver, proposing Gold schemas,
> learning from each run. Once you're happy with what it's built, you export it as a DCM project.
> From that point forward, your Gold layer is infrastructure-as-code: versioned, auditable,
> deployable via CI/CD, and rollback-capable."

The customer gets both the speed of the agentic approach AND the operational maturity of DCM —
without having to choose between them.

---

## Consequences

- `EXPORT_DCM_PROJECT` SP must generate syntactically correct DCM DEFINE statements from Snowflake table DDL
- DCM templates live in `dcm/templates/` as Jinja2 files that the SP populates
- The skill does not manage the DCM lifecycle after export — that is the customer's responsibility
- DCM must be available in the customer's Snowflake account (GA feature — no additional licensing required)
