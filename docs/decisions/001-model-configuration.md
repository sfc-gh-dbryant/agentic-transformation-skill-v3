# ADR 001 — Model Configuration Pattern

**Status:** Accepted  
**Date:** April 2026  
**Context:** Agentic Transformation Skill — avoiding hardcoded LLM model names

---

## Problem

During development of the Agentic Data Foundry (ADF), `claude-3-5-sonnet` was hardcoded in 31
places across 15 files. When Snowflake retired this model, every occurrence had to be manually
found and replaced, and all affected stored procedures had to be redeployed. This created
significant operational risk and toil.

---

## Decision

**Never hardcode a Cortex model name in any stored procedure, SQL script, or Streamlit app.**

All model references resolve at runtime from a single configuration table:

```sql
CREATE TABLE AGENT_FRAMEWORK.MODEL_CONFIG (
    config_key      VARCHAR         NOT NULL DEFAULT 'default',
    primary_model   VARCHAR         NOT NULL,
    fallback_model  VARCHAR,
    validated       BOOLEAN         DEFAULT FALSE,
    last_validated  TIMESTAMP_NTZ,
    updated_at      TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_by      VARCHAR         DEFAULT CURRENT_USER(),
    CONSTRAINT pk_model_config PRIMARY KEY (config_key)
);
```

Every SP that calls `SNOWFLAKE.CORTEX.COMPLETE` does:

```sql
LET model_name VARCHAR := (
    SELECT primary_model FROM AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE config_key = 'default' LIMIT 1
);
```

---

## Model Discovery at Bootstrap

The `BOOTSTRAP` SP does not accept a model name as input. Instead, it tests a priority-ordered
list of known Cortex models and registers the first one that responds successfully:

```
Priority order (updated as models release/retire):
  1. claude-3-7-sonnet
  2. claude-3-5-sonnet-v2  
  3. mistral-large2
  4. llama3.1-70b
```

Bootstrap marks `validated = TRUE` and records `last_validated` timestamp.

---

## Fallback Behavior

If the primary model fails at runtime, SPs fall back to `fallback_model` automatically:

```sql
LET model_name VARCHAR := (
    SELECT COALESCE(
        CASE WHEN validated THEN primary_model END,
        fallback_model
    )
    FROM AGENT_FRAMEWORK.MODEL_CONFIG
    WHERE config_key = 'default' LIMIT 1
);
```

---

## Updating the Active Model

### Via Streamlit (Tab 1 — Setup)
- "Re-validate Model" button calls `VALIDATE_MODEL()` SP
- Model selector dropdown lists known available models
- One-click update, no SP redeployment required

### Via SQL
```sql
CALL AGENT_FRAMEWORK.VALIDATE_MODEL('claude-3-7-sonnet');
```

The `VALIDATE_MODEL` SP:
1. Sends a lightweight test prompt to the specified model
2. On success: updates `MODEL_CONFIG.primary_model`, sets `validated = TRUE`
3. On failure: returns error details without changing config

---

## Consequences

- **Zero hardcoded model strings** anywhere in the codebase
- Model rotation requires one SQL UPDATE + no redeployment
- Bootstrap is self-healing — picks the best available model at deploy time
- Streamlit surfaces model status visibly so SA knows what's running
- Adds a runtime SELECT to every SP call (negligible cost vs. LLM call latency)
