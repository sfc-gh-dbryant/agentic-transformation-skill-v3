# ATS → Snowpark ML: End-to-End Pipeline Design
## From Raw Bronze Tables to a Deployed Prediction Model

---

## Overview

The Agentic Transformation Skill (ATS) and Snowpark ML are complementary — they
cover adjacent phases of the data-to-model lifecycle with a clean handoff at the
Gold layer.

```
┌─────────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
│         AGENTIC TRANSFORMATION SKILL        │   │            SNOWPARK ML                   │
│                                             │   │                                          │
│  Bronze (raw)                               │   │  Feature Dataset                         │
│      ↓  Schema Analyst                      │   │      ↓  Snowpark DataFrame               │
│  Silver (cleaned, joined, typed)            │   │  Train / Evaluate                        │
│      ↓  Planner → Executor → Validator      │   │      ↓  Snowflake ML Registry            │
│  Gold  (aggregated, business-ready)  ───────┼───┼→ ML Model                                │
│      ↓  DCM Export                          │   │      ↓  Inference UDF / Stored Proc      │
│  Production DDL                             │   │  Predictions back into Snowflake         │
└─────────────────────────────────────────────┘   └──────────────────────────────────────────┘
                                        ↑ HANDOFF POINT
```

**ATS stops at Gold.** Snowpark ML picks up from Gold.

---

## Concrete Use Case: Payment Fraud Prediction

Using the regional bank scenario from the Analytics TTV POC:

| Layer | Owner | Contents |
|-------|-------|----------|
| Bronze | Source systems | Raw transactions, merchant data, customer profiles |
| Silver | ATS | Cleaned transactions, joined merchant + customer attributes |
| Gold | ATS | Aggregated features: velocity, merchant risk score, amount z-score |
| **Feature Dataset** | **Bridge** | **Labeled training set: Gold features + fraud label** |
| Model | Snowpark ML | XGBoost / Random Forest fraud classifier |
| Predictions | Inference UDF | `PREDICT_FRAUD(transaction_id)` → probability score |

---

## Phase 1: ATS Setup — Produce the Gold Feature Tables

### Step 1 — Set pipeline context with ML intent

In the ATS Streamlit app, Tab 2 → Context, set:

```
Business:    Regional bank processing 2M daily transactions across 40K merchants.
Domain:      Financial Services / Payment Fraud
Gold Goals:  Transaction-level fraud probability features for ML model training.
             Merchant velocity, customer spend patterns, amount deviation scores.
             Feature table must be joinable on TRANSACTION_ID with a fraud label.
Constraints: No PII in Gold (mask card numbers, anonymize customer IDs).
             Reproduce features deterministically — no randomness in aggregations.
Output Type: CTAS  (static snapshot for model training)
```

### Step 2 — Run the agentic workflow

ATS Schema Analyst → Planner → Executor → Validator produces Silver and Gold.

The Gold Builder should be directed toward feature-oriented aggregations. Add
a Transformation Directive (Tab 4) to steer it:

```sql
-- In ATS: Tab 4 → Add Directive for TRANSACTIONS table
INSERT INTO AGENT_FRAMEWORK.TRANSFORMATION_DIRECTIVES
    (table_name, directive, priority)
VALUES (
    'TRANSACTIONS',
    'Build a Gold feature table that aggregates: (1) 24h transaction count per card, 
     (2) 7-day spend velocity per card, (3) merchant average transaction amount, 
     (4) z-score of current amount vs. card 30-day history, 
     (5) hour-of-day and day-of-week as integer features. 
     Exclude PII fields. Alias output as GOLD.TRANSACTION_FEATURES.',
    1
);
```

### Step 3 — Verify Gold output

After the workflow completes, Gold should contain a table resembling:

```sql
SELECT * FROM GOLD.TRANSACTION_FEATURES LIMIT 5;
```

```
TRANSACTION_ID | MERCHANT_ID | TXN_COUNT_24H | SPEND_7D | MERCHANT_AVG_AMT | AMOUNT_ZSCORE | HOUR_OF_DAY | DOW
---------------|-------------|---------------|----------|------------------|---------------|-------------|----
TXN_001        | MCH_042     | 3             | 1250.00  | 87.50            | 2.31          | 14          | 2
TXN_002        | MCH_017     | 1             | 340.00   | 120.00           | -0.45         | 9           | 4
```

---

## Phase 2: Bridge — Build the Labeled Training Dataset

This is the **handoff step** — the only manual work between ATS and Snowpark ML.
ATS produces features; the fraud label (`IS_FRAUD`) must come from the customer's
ground truth source (chargebacks, disputes, manual review outcomes).

```sql
-- Join ATS Gold features with customer's fraud labels
CREATE OR REPLACE TABLE GOLD.FRAUD_TRAINING_SET AS
SELECT
    f.TRANSACTION_ID,
    f.MERCHANT_ID,
    f.TXN_COUNT_24H,
    f.SPEND_7D,
    f.MERCHANT_AVG_AMT,
    f.AMOUNT_ZSCORE,
    f.HOUR_OF_DAY,
    f.DOW,
    COALESCE(l.IS_FRAUD, 0)  AS IS_FRAUD      -- label: 1 = fraud, 0 = legitimate
FROM GOLD.TRANSACTION_FEATURES f
LEFT JOIN BRONZE.FRAUD_LABELS l
    ON f.TRANSACTION_ID = l.TRANSACTION_ID;
```

> **Note for ATS v3:** A future enhancement could add a `pipeline_output_type = 'ML_FEATURES'`
> mode that prompts the user for a label source and auto-generates this join as part of
> the Gold Builder workflow.

---

## Phase 3: Snowpark ML — Train and Register the Model

### Notebook or Stored Procedure

```python
from snowflake.snowpark.session import Session
from snowflake.ml.modeling.ensemble import RandomForestClassifier
from snowflake.ml.registry import Registry
import snowflake.ml.modeling.preprocessing as pp

session = Session.builder.config("connection_name", "<YOUR_CONNECTION>").create()

# ── Load training data from ATS Gold output ───────────────────────────────────
df = session.table("GOLD.FRAUD_TRAINING_SET")

FEATURE_COLS = [
    "TXN_COUNT_24H", "SPEND_7D", "MERCHANT_AVG_AMT",
    "AMOUNT_ZSCORE", "HOUR_OF_DAY", "DOW"
]
LABEL_COL  = "IS_FRAUD"
OUTPUT_COL = "PREDICTED_FRAUD"

train_df, test_df = df.random_split([0.8, 0.2], seed=42)

# ── Train ─────────────────────────────────────────────────────────────────────
model = RandomForestClassifier(
    n_estimators=100,
    input_cols=FEATURE_COLS,
    label_cols=[LABEL_COL],
    output_cols=[OUTPUT_COL],
)
model.fit(train_df)

# ── Evaluate ──────────────────────────────────────────────────────────────────
predictions = model.predict(test_df)
from snowflake.ml.modeling.metrics import accuracy_score, f1_score
accuracy = accuracy_score(df=predictions, y_true_col_names=[LABEL_COL],
                          y_pred_col_names=[OUTPUT_COL])
f1       = f1_score(df=predictions, y_true_col_names=[LABEL_COL],
                    y_pred_col_names=[OUTPUT_COL], average="binary")
print(f"Accuracy: {accuracy:.4f}  |  F1: {f1:.4f}")

# ── Register in Snowflake ML Registry ────────────────────────────────────────
registry = Registry(session=session, database_name="GOLD", schema_name="ML_MODELS")

mv = registry.log_model(
    model=model,
    model_name="FRAUD_CLASSIFIER",
    version_name="V1_ATS_FEATURES",
    comment="Trained on ATS-generated Gold features from TRANSACTION_FEATURES table.",
    metrics={"accuracy": accuracy, "f1": f1},
    sample_input_data=train_df.select(FEATURE_COLS).limit(100),
)
print(f"Registered: {mv.model_name} / {mv.version_name}")
```

### Deploy as SQL-callable UDF

```python
# Deploy model for SQL inference — callable from any Snowflake query
mv.create_service(
    service_name="FRAUD_CLASSIFIER_SVC",
    target_platforms=["WAREHOUSE"],
)
```

```sql
-- Score live transactions using the registered model
SELECT
    t.TRANSACTION_ID,
    t.AMOUNT,
    t.MERCHANT_ID,
    f.AMOUNT_ZSCORE,
    FRAUD_CLASSIFIER_SVC!PREDICT(
        f.TXN_COUNT_24H,
        f.SPEND_7D,
        f.MERCHANT_AVG_AMT,
        f.AMOUNT_ZSCORE,
        f.HOUR_OF_DAY,
        f.DOW
    ):PREDICTED_FRAUD::NUMBER(5,4) AS FRAUD_PROBABILITY
FROM SILVER.TRANSACTIONS t
JOIN GOLD.TRANSACTION_FEATURES f ON t.TRANSACTION_ID = f.TRANSACTION_ID
ORDER BY FRAUD_PROBABILITY DESC
LIMIT 100;
```

---

## Phase 4: Close the Loop — Predictions Back into ATS Gold

Register the prediction output as a Gold table so the ATS lineage and DCM
export include it:

```sql
-- Add predictions as a Gold table — visible in ATS Registry (Tab 7)
CREATE OR REPLACE TABLE GOLD.TRANSACTION_FRAUD_SCORES AS
SELECT
    f.*,
    FRAUD_CLASSIFIER_SVC!PREDICT(
        f.TXN_COUNT_24H, f.SPEND_7D, f.MERCHANT_AVG_AMT,
        f.AMOUNT_ZSCORE, f.HOUR_OF_DAY, f.DOW
    ):PREDICTED_FRAUD::NUMBER(5,4) AS FRAUD_PROBABILITY,
    CASE WHEN FRAUD_PROBABILITY > 0.75 THEN 'HIGH'
         WHEN FRAUD_PROBABILITY > 0.40 THEN 'MEDIUM'
         ELSE 'LOW' END            AS RISK_TIER,
    CURRENT_TIMESTAMP()            AS SCORED_AT
FROM GOLD.TRANSACTION_FEATURES f;
```

ATS Tab 7 (Registry) will pick this up in the next workflow run as a Gold
artifact — giving you lineage from Bronze all the way through to the scored output.

---

## Full End-to-End Flow

```
Bronze.TRANSACTIONS  ──┐
Bronze.MERCHANTS     ──┤  ATS Schema Analyst
Bronze.CUSTOMERS     ──┘       ↓
                        Silver.TRANSACTIONS_CLEAN
                        Silver.MERCHANT_PROFILES
                               ↓
                         ATS Planner / Executor
                               ↓
                        Gold.TRANSACTION_FEATURES       ← ATS stops here
                               ↓
                   (Bridge: join with fraud labels)
                               ↓
                        Gold.FRAUD_TRAINING_SET
                               ↓
                    Snowpark ML: train + evaluate
                               ↓
                    ML Registry: FRAUD_CLASSIFIER / V1
                               ↓
                    SQL UDF: FRAUD_CLASSIFIER_SVC
                               ↓
                        Gold.TRANSACTION_FRAUD_SCORES   ← back in ATS lineage
                               ↓
                    Streamlit Dashboard / Downstream BI
```

---

## What Needs to Be Built for a Full Demo

| Component | Status | Owner |
|-----------|--------|-------|
| ATS Bronze → Gold (TRANSACTION_FEATURES) | ATS skill handles this | ATS |
| Fraud label source / synthetic labels | Needs synthetic data | Demo setup |
| Bridge join (FRAUD_TRAINING_SET) | 1 SQL statement | Manual / bridge script |
| Snowpark ML training notebook | Design above | Snowpark ML skill |
| Model registry registration | Included in notebook | Snowpark ML skill |
| Inference UDF deployment | Included in notebook | Snowpark ML skill |
| TRANSACTION_FRAUD_SCORES Gold table | 1 SQL statement | Manual |
| ATS Registry updated with scored table | Automatic on next workflow run | ATS |

The only gap between "ATS done" and "model trained" is the fraud label join —
which for a demo can be satisfied with a synthetic label generator
(e.g., flag top 1% by AMOUNT_ZSCORE as fraud).

---

## ATS Enhancement Opportunity

This flow exposes a natural v3 enhancement: an **ML Features** pipeline output type.

```
Context Tab → Output Format:
  ○ CTAS          (current)
  ○ DYNAMIC TABLE (current)
  ● ML FEATURES   (proposed)
```

When `ML_FEATURES` is selected, the Gold Builder would:
1. Generate feature-oriented aggregations rather than reporting aggregations
2. Prompt for a label column and label source table
3. Auto-generate the training set join
4. Export a `features.yaml` manifest (column names, types, label) that Snowpark ML
   can consume directly — eliminating the bridge step entirely
