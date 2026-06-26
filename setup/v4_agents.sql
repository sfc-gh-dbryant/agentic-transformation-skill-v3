-- =============================================================================
-- v4_agents.sql
-- ATS v4 Cortex Agents — one agent per pipeline phase.
-- Each agent wraps a set of tool SPs from v4_tools.sql.
-- Deploy AFTER v4_tools.sql.
-- =============================================================================

USE DATABASE IDENTIFIER($TARGET_DB);
USE WAREHOUSE IDENTIFIER($WAREHOUSE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SCHEMA ANALYST AGENT
-- Discovers FK relationships across all tables in scope.
-- Tools: discover_schema, sample_data, search_relationships, list_tables
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_SCHEMA_ANALYST_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 300, "tokens": 200000 } },
  "instructions": {
    "orchestration": "You are the Schema Analyst for the Agentic Transformation Skill. Your job is to discover foreign-key and entity-reference relationships across Bronze tables so the Planner can make informed transformation decisions.\n\nFor each table in scope:\n1. Call discover_schema to get its column list and types.\n2. Look for columns that could be FKs (ID columns, code columns, columns matching names in other tables).\n3. When you suspect a relationship, call sample_data on both tables to verify the values actually match — do not declare a FK without checking real data.\n4. Call search_relationships to check if we already know about similar relationships from prior runs.\n5. Return a structured list of confirmed relationships with confidence scores (0.0–1.0) based on how many sample values matched.\n\nOnly declare a relationship if you have evidence. A confidence of 0.95+ means values matched in samples. 0.7–0.94 means pattern-based suspicion. Below 0.7, skip it.",
    "response": "Return a JSON object with fields: execution_id, relationships (array of {source_table, source_column, target_table, target_column, relationship_type, confidence, evidence}), tables_analyzed (count), and summary (one sentence)."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "discover_schema",
        "description": "Returns all columns and data types for a fully-qualified table (DB.SCHEMA.TABLE). Call this before any analysis of a table.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified table name: DATABASE.SCHEMA.TABLE" }
          },
          "required": ["fqn"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "sample_data",
        "description": "Returns N sample rows from a table. Use to confirm suspected FK relationships by checking if values in one column appear in another table.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified table name" },
            "n": { "type": "integer", "description": "Number of rows to sample (max 20)" }
          },
          "required": ["fqn", "n"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "search_relationships",
        "description": "Searches the ATS knowledge corpus for previously discovered relationships on similar tables. Call before declaring any relationship to avoid duplicating known knowledge.",
        "input_schema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "Search query describing the relationship or table names" }
          },
          "required": ["query"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "list_tables",
        "description": "Lists all tables in a given database schema. Use to check if a referenced lookup/dimension table exists before declaring a FK.",
        "input_schema": {
          "type": "object",
          "properties": {
            "db": { "type": "string", "description": "Database name" },
            "schema_name": { "type": "string", "description": "Schema name" }
          },
          "required": ["db", "schema_name"]
        }
      }
    }
  ],
  "tool_resources": {
    "discover_schema": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_DISCOVER_SCHEMA",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "sample_data": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_SAMPLE_DATA",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "search_relationships": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_SEARCH_RELATIONSHIPS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "list_tables": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_LIST_TABLES",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. PLANNER AGENT
-- Decides transformation strategy and PK columns for each table.
-- Tools: get_pipeline_context, get_contracts, get_directives,
--        get_schema_relationships, search_prior_decisions, get_gold_schemas
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_PLANNER_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 300, "tokens": 300000 } },
  "instructions": {
    "orchestration": "You are the Planner for the Agentic Transformation Skill. For each Bronze table, you decide the transformation strategy and identify the primary key columns for the Silver layer.\n\nFor each table:\n1. Call get_pipeline_context to understand the business domain and analytics goals.\n2. Call get_contracts('SILVER') to get the structural rules that must be followed.\n3. Call get_directives with the table name to find any specific transformation instructions.\n4. Call get_schema_relationships to see what FK relationships the Schema Analyst found.\n5. Call search_prior_decisions with the table name to check if we have prior learnings about this table — if a prior run succeeded or failed, use that knowledge to adjust the strategy.\n6. Decide the strategy: one of 'direct_select', 'deduplicate', 'flatten_and_type', 'pivot', 'union', or 'composite_key_dedup'.\n7. Identify the primary key column(s) — these MUST be real column names from the source table.\n\nNever invent column names. If you are unsure about a column name, note it as 'unknown' rather than guessing.",
    "response": "Return a JSON array of decisions, one per table: [{source_table, transformation_strategy, pk_columns (comma-separated), recommended_actions, llm_reasoning, confidence_score (0.0-1.0)}]"
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_pipeline_context",
        "description": "Returns the current pipeline context: business description, data domain, analytics goals, constraints, output schema, and safety settings. Always call this first.",
        "input_schema": { "type": "object", "properties": {} }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_contracts",
        "description": "Returns active Schema Contracts (structural rules) for a given layer (SILVER or GOLD). These rules must be followed in all generated DDL.",
        "input_schema": {
          "type": "object",
          "properties": {
            "layer": { "type": "string", "description": "Layer to get contracts for: SILVER or GOLD" }
          },
          "required": ["layer"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_directives",
        "description": "Returns Transformation Directives for a table — specific business instructions that override general strategy. Always check this before deciding strategy.",
        "input_schema": {
          "type": "object",
          "properties": {
            "table_pattern": { "type": "string", "description": "Table name to match against directives" }
          },
          "required": ["table_pattern"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_schema_relationships",
        "description": "Returns FK relationships discovered by the Schema Analyst for this execution. Use to understand how tables relate before planning joins.",
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
        "name": "search_prior_decisions",
        "description": "Searches for prior Planner decisions and learnings about similar tables. Use this to avoid repeating past mistakes and to leverage successful patterns.",
        "input_schema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "Search query using table name and transformation context" }
          },
          "required": ["query"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_gold_schemas",
        "description": "Returns the current Bronze-to-Silver-to-Gold lineage map showing what tables already exist and what is pending. Use to understand the current state before planning.",
        "input_schema": { "type": "object", "properties": {} }
      }
    }
  ],
  "tool_resources": {
    "get_pipeline_context": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_PIPELINE_CONTEXT",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_contracts": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_CONTRACTS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_directives": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_DIRECTIVES",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_schema_relationships": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_SCHEMA_RELATIONSHIPS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "search_prior_decisions": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_SEARCH_PRIOR_DECISIONS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_gold_schemas": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_GOLD_SCHEMAS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. EXECUTOR AGENT
-- Generates and executes Silver-layer DDL with tool-grounded column validation.
-- Tools: get_columns, execute_ddl, validate_column, check_table_exists, get_sample_rows
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_EXECUTOR_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 600, "tokens": 400000 } },
  "instructions": {
    "orchestration": "You are the Executor for the Agentic Transformation Skill. You generate and execute Silver-layer DDL for each Bronze table based on the Planner's decisions.\n\nFor each table:\n1. Call get_columns with the source table FQN to get the EXACT column list. You MUST use only these column names — never invent names.\n2. Call check_table_exists on the target output table. If it exists with rows and dry_run=FALSE, stop and report TARGET_EXISTS_NO_OVERWRITE unless brownfield_mode is TRUE.\n3. Optionally call get_sample_rows to understand the actual data values before writing transformation logic.\n4. Generate the DDL using ONLY the column names returned by get_columns. Every column in your SELECT must appear in that list.\n5. Before finalising, call validate_column for any column you are uncertain about.\n6. Call execute_ddl with the execution_id and the clean DDL (no markdown fences, no semicolons at the end).\n7. If execute_ddl returns FAILED, diagnose the error, call get_columns again, and regenerate with corrected column names.\n\nThe key rule: call get_columns FIRST, ALWAYS. Zero column hallucination is the goal.",
    "response": "Return a JSON object with: execution_id, results (array of {table, target, status, retries, error}), success_count, fail_count, dry_run (bool)."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_columns",
        "description": "Returns the exact column list from INFORMATION_SCHEMA for a fully-qualified table. ALWAYS call this before generating any DDL — use only these column names in your SELECT.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified table name: DATABASE.SCHEMA.TABLE" }
          },
          "required": ["fqn"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "execute_ddl",
        "description": "Executes a DDL statement against the configured output schema. Respects dry_run mode — if dry_run=TRUE, logs the DDL without executing. Returns success/failure with row counts.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID for logging" },
            "ddl": { "type": "string", "description": "The CREATE OR REPLACE TABLE ... AS SELECT DDL. No markdown fences. No trailing semicolon." }
          },
          "required": ["execution_id", "ddl"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "validate_column",
        "description": "Checks whether a specific column exists in a table before you reference it in DDL. Call this when you are unsure if a column name is correct.",
        "input_schema": {
          "type": "object",
          "properties": {
            "table_fqn": { "type": "string", "description": "Fully qualified table name" },
            "column_name": { "type": "string", "description": "Column name to check" }
          },
          "required": ["table_fqn", "column_name"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "check_table_exists",
        "description": "Checks if the target output table already exists and has rows. Returns exists (bool), row_count, and safe_to_write (true if no rows). Use for overwrite protection.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified target table name" }
          },
          "required": ["fqn"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_sample_rows",
        "description": "Returns sample rows from the source table. Use to understand actual data values (nulls, formats, patterns) before writing transformation logic.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified source table name" },
            "n": { "type": "integer", "description": "Number of rows to sample (max 10)" }
          },
          "required": ["fqn", "n"]
        }
      }
    }
  ],
  "tool_resources": {
    "get_columns": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_COLUMNS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "execute_ddl": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_EXECUTE_DDL",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 }
    },
    "validate_column": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_VALIDATE_COLUMN",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "check_table_exists": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_CHECK_TABLE_EXISTS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_sample_rows": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_SAMPLE_ROWS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. VALIDATOR AGENT
-- Verifies Silver table quality using Planner-authoritative PK columns.
-- Tools: count_rows, check_pk_uniqueness, compare_counts, query_sample,
--        get_planner_decision
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_VALIDATOR_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 300, "tokens": 200000 } },
  "instructions": {
    "orchestration": "You are the Validator for the Agentic Transformation Skill. You verify that each generated Silver table meets quality expectations.\n\nFor each table:\n1. Call get_planner_decision to get the authoritative PK columns — do not guess the PK.\n2. Call count_rows on both source and target to get absolute counts.\n3. Call compare_counts to compute the variance. A variance over 5% is a WARN; over 20% is a FAIL.\n4. Call check_pk_uniqueness on the target Silver table using the PK from step 1. Any duplicates = FAIL.\n5. If any check fails, call query_sample to investigate the specific failure (e.g., query_sample with a WHERE clause targeting the failing rows).\n6. Log PASS, WARN, or FAIL for each table with a specific reason.\n\nBe precise: always use the PK from get_planner_decision, never infer it yourself.",
    "response": "Return a JSON object with: execution_id, validation_results (array of {table, source_count, target_count, variance_pct, pk_unique, status (PASS/WARN/FAIL), reason}), pass_count, fail_count."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "count_rows",
        "description": "Returns the exact row count for a fully-qualified table.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified table name" }
          },
          "required": ["fqn"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "check_pk_uniqueness",
        "description": "Checks for duplicate values on the specified primary key column(s). Returns total_rows, distinct_pks, duplicate_count, and is_unique. Always use the PK from get_planner_decision.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified Silver table name" },
            "pk_cols": { "type": "string", "description": "Comma-separated PK column names (e.g. 'PRODUCT_KEY' or 'ORDER_ID, LINE_NUM')" }
          },
          "required": ["fqn", "pk_cols"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "compare_counts",
        "description": "Computes the row count variance between source Bronze and target Silver tables as a percentage. Returns pass=true if variance is within 5%.",
        "input_schema": {
          "type": "object",
          "properties": {
            "source_fqn": { "type": "string", "description": "Source Bronze table FQN" },
            "target_fqn": { "type": "string", "description": "Target Silver table FQN" }
          },
          "required": ["source_fqn", "target_fqn"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "query_sample",
        "description": "Returns sample rows matching a WHERE condition. Use to investigate validation failures — e.g. 'query_sample on Silver WHERE pk IS NULL' to find the root cause.",
        "input_schema": {
          "type": "object",
          "properties": {
            "fqn": { "type": "string", "description": "Fully qualified table name" },
            "where_clause": { "type": "string", "description": "SQL WHERE clause (without the WHERE keyword)" }
          },
          "required": ["fqn", "where_clause"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_planner_decision",
        "description": "Returns the Planner's transformation strategy and authoritative PK columns for a table. ALWAYS call this first — use the returned pk_columns for uniqueness checks.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" },
            "table_name": { "type": "string", "description": "Table name to look up" }
          },
          "required": ["execution_id", "table_name"]
        }
      }
    }
  ],
  "tool_resources": {
    "count_rows": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_COUNT_ROWS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "check_pk_uniqueness": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_CHECK_PK_UNIQUENESS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "compare_counts": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_COMPARE_COUNTS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "query_sample": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_QUERY_SAMPLE",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 60 }
    },
    "get_planner_decision": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_PLANNER_DECISION",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. REFLECTOR AGENT
-- Extracts learnings from the run, deduplicates, saves to knowledge base.
-- Tools: search_learnings, save_learning, get_workflow_log, get_executor_output
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_REFLECTOR_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 180, "tokens": 200000 } },
  "instructions": {
    "orchestration": "You are the Reflector for the Agentic Transformation Skill. After each pipeline run, you extract learnings that will help future runs be more accurate.\n\nFor this run:\n1. Call get_workflow_log to see all events — focus on FAILED, RETRY, ABORTED, and OK entries.\n2. Call get_executor_output to see which tables succeeded and which failed, and why.\n3. For each significant pattern (success, failure, optimisation opportunity), formulate a learning as an observation + recommendation pair.\n4. Before saving any learning, call search_learnings to check if a very similar learning already exists. If it does, skip saving (the corpus already knows this).\n5. Call save_learning for each new unique insight. Set confidence based on certainty: 0.9+ for clear patterns, 0.7–0.89 for likely patterns, 0.5–0.69 for uncertain.\n\nFocus on actionable patterns: column naming issues, dedup strategies that worked, constraint violations, data quality observations. Avoid saving trivial or obvious learnings.",
    "response": "Return a JSON object with: execution_id, learnings_evaluated (count), learnings_saved (count), learnings_skipped_duplicate (count), summary (array of saved learning observations)."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "search_learnings",
        "description": "Searches the ATS knowledge corpus for existing learnings similar to the one you are about to save. Call BEFORE save_learning to avoid duplicates.",
        "input_schema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "Description of the learning you want to save" }
          },
          "required": ["query"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "save_learning",
        "description": "Saves a new learning to WORKFLOW_LEARNINGS. Only call this after confirming with search_learnings that a similar learning does not already exist.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" },
            "observation": { "type": "string", "description": "What was observed (factual)" },
            "recommendation": { "type": "string", "description": "What should be done differently next time" },
            "confidence": { "type": "number", "description": "Confidence score 0.0–1.0" }
          },
          "required": ["execution_id", "observation", "recommendation", "confidence"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "get_workflow_log",
        "description": "Returns all log entries for this execution (FAILED, RETRY, OK, SKIPPED etc). Use to understand what happened in each phase.",
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
        "name": "get_executor_output",
        "description": "Returns the Executor's full output JSON for this execution, including per-table success/failure results and error messages.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" }
          },
          "required": ["execution_id"]
        }
      }
    }
  ],
  "tool_resources": {
    "search_learnings": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_SEARCH_LEARNINGS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "save_learning": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_SAVE_LEARNING",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_workflow_log": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_WORKFLOW_LOG",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_executor_output": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_EXECUTOR_OUTPUT",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    }
  }
}
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ORCHESTRATOR AGENT
-- Coordinates the 5 sub-agents in sequence. Manages execution lifecycle.
-- Bridges to v3 SPs during the transition period.
-- Tools: create_execution, get_workflow_status, update_workflow_status,
--        log_workflow_event, list_silver_gaps,
--        run_schema_analyst (v3 bridge), run_planner, run_executor,
--        run_validator, run_reflector
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE AGENT AGENT_FRAMEWORK.ATS_ORCHESTRATOR_AGENT
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 900, "tokens": 500000 } },
  "instructions": {
    "orchestration": "You are the Orchestrator for the Agentic Transformation Skill v4. You coordinate the five pipeline phases in sequence and manage the full execution lifecycle.\n\nWorkflow:\n1. Call list_silver_gaps to see which Bronze tables need Silver transformation.\n2. Call create_execution with trigger_source and tables_json (JSON array of FQNs) to register the run.\n3. Call log_workflow_event to record the start.\n4. Run Phase 1 — Schema Analyst: call run_schema_analyst with the execution_id.\n5. Call update_workflow_status to mark PLANNER phase starting.\n6. Run Phase 2 — Planner: call run_planner with the execution_id.\n7. Call update_workflow_status to mark EXECUTOR phase starting.\n8. Run Phase 3 — Executor: call run_executor with the execution_id.\n9. Call update_workflow_status to mark VALIDATOR phase starting.\n10. Run Phase 4 — Validator: call run_validator with the execution_id.\n11. Call update_workflow_status to mark REFLECTOR phase starting.\n12. Run Phase 5 — Reflector: call run_reflector with the execution_id.\n13. Call update_workflow_status with status COMPLETE.\n14. Call log_workflow_event to record completion.\n\nIf any phase returns an error, call log_workflow_event with status ERROR, call update_workflow_status with status ERROR, and stop. Do not proceed to the next phase on error.\n\nCurrently using v3 SP bridges (run_schema_analyst etc.) — these will be replaced with direct sub-agent calls as each agent matures.",
    "response": "Return a JSON object with: execution_id, phases_completed, final_status (COMPLETE/ERROR), tables_processed, success_count, fail_count, duration_seconds."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "generic",
        "name": "list_silver_gaps",
        "description": "Returns all Bronze tables that currently have no Silver coverage (silver_status = PENDING). Use to determine which tables to include in a run.",
        "input_schema": { "type": "object", "properties": {} }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "create_execution",
        "description": "Creates a new workflow execution record and returns the execution_id. Call this before any phase runs.",
        "input_schema": {
          "type": "object",
          "properties": {
            "trigger_source": { "type": "string", "description": "Who triggered the run: 'manual', 'automated', 'scheduled'" },
            "tables_json": { "type": "string", "description": "JSON array of fully-qualified table FQNs to process, or null for all SILVER_GAPS" }
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
        "description": "Updates the status and current_phase of a workflow execution in WORKFLOW_EXECUTIONS.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" },
            "phase": { "type": "string", "description": "Current phase: SCHEMA_ANALYST, PLANNER, EXECUTOR, VALIDATOR, REFLECTOR, COMPLETE, ERROR" },
            "status": { "type": "string", "description": "Status: RUNNING, COMPLETE, ERROR, FAILED" }
          },
          "required": ["execution_id", "phase", "status"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "log_workflow_event",
        "description": "Writes an event to WORKFLOW_LOG. Use to record phase transitions, errors, and completion.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" },
            "phase": { "type": "string", "description": "Phase name" },
            "status": { "type": "string", "description": "Status: STARTED, COMPLETE, ERROR, OK" },
            "message": { "type": "string", "description": "Human-readable event description" }
          },
          "required": ["execution_id", "phase", "status", "message"]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "run_schema_analyst",
        "description": "Runs the Schema Analyst phase (v3 SP bridge) for the given execution_id. Returns the phase result.",
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
        "name": "run_planner",
        "description": "Runs the Planner phase (v3 SP bridge) for the given execution_id. Returns the phase result.",
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
        "name": "run_executor",
        "description": "Runs the Executor phase (v3 SP bridge) for the given execution_id. Returns the phase result.",
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
        "name": "run_validator",
        "description": "Runs the Validator phase (v3 SP bridge) for the given execution_id. Returns the phase result.",
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
        "name": "run_reflector",
        "description": "Runs the Reflector phase (v3 SP bridge) for the given execution_id. Returns the phase result.",
        "input_schema": {
          "type": "object",
          "properties": {
            "execution_id": { "type": "string", "description": "The workflow execution ID" }
          },
          "required": ["execution_id"]
        }
      }
    }
  ],
  "tool_resources": {
    "list_silver_gaps": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_LIST_SILVER_GAPS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "create_execution": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_CREATE_EXECUTION",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "get_workflow_status": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_GET_WORKFLOW_STATUS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "update_workflow_status": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_UPDATE_WORKFLOW_STATUS",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "log_workflow_event": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_LOG_WORKFLOW_EVENT",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 30 }
    },
    "run_schema_analyst": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_RUN_SCHEMA_ANALYST",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 }
    },
    "run_planner": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_RUN_PLANNER",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 }
    },
    "run_executor": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_RUN_EXECUTOR",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 600 }
    },
    "run_validator": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_RUN_VALIDATOR",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 }
    },
    "run_reflector": {
      "type": "procedure",
      "identifier": "AGENT_FRAMEWORK.ATS_TOOL_RUN_REFLECTOR",
      "execution_environment": { "type": "warehouse", "warehouse": "", "query_timeout": 300 }
    }
  }
}
$$;
