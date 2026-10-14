/* =============================================================================
   02_core_tables.sql
   Langfuse exporter - step 02: configuration, staging and delivery tables

   PREREQUISITES
     - Step 01 VERIFIED.
     - Run as LANGFUSE_EXPORTER_ROLE (owns the database; no ACCOUNTADMIN needed).

   CONFIGURATION PLACEHOLDERS: none. The seed rows below define the initial
     destination LANGFUSE_TEST (https://cloud.langfuse.com, TRACE_FIRST) and one
     account-default route. Secret and integration names referenced here are
     created in step 03; nothing is sent until step 05.

   RE-RUNNABLE: yes. Tables use CREATE TABLE IF NOT EXISTS; seeds use MERGE.
     Re-running never deletes staged data or delivery history.

   NOTE: Snowflake does not enforce PRIMARY KEY / UNIQUE on standard tables.
     They document intent; all writers (steps 04/05) use MERGE on those keys.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

-- ---------------------------------------------------------------------------
-- Destinations: one Langfuse host/project + its Snowflake secret binding.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DESTINATIONS (
  destination_id         VARCHAR      NOT NULL PRIMARY KEY,
  langfuse_host          VARCHAR      NOT NULL,   -- e.g. https://cloud.langfuse.com
  project_label          VARCHAR,                 -- human label only
  secret_name            VARCHAR      NOT NULL,   -- FQN of GENERIC_STRING / PASSWORD secret
  integration_name       VARCHAR      NOT NULL,   -- external access integration (account-level)
  publication_mode       VARCHAR      NOT NULL,   -- TRACE_FIRST | COST_READY
  required_billing       ARRAY        NOT NULL,   -- e.g. ['TOKEN_CREDITS']; used by COST_READY + overdue
  billing_overdue_hours  NUMBER       NOT NULL DEFAULT 24,
  quiet_minutes          NUMBER       NOT NULL DEFAULT 5,  -- trace considered complete after N min without new rows
  publish_anomalies      BOOLEAN      NOT NULL DEFAULT FALSE,
  enabled                BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at             TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
  -- publication_mode is validated by the procedures (Snowflake has no CHECK constraints).
);

-- ---------------------------------------------------------------------------
-- Routes. Precedence: AGENT > SCHEMA > DATABASE > ACCOUNT.
-- action = ROUTE (needs destination_id) or EXCLUDE. Unmatched -> UNROUTED.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ROUTES (
  route_id        VARCHAR NOT NULL PRIMARY KEY,
  match_level     VARCHAR NOT NULL,     -- AGENT | SCHEMA | DATABASE | ACCOUNT
  agent_database  VARCHAR,              -- required for AGENT/SCHEMA/DATABASE
  agent_schema    VARCHAR,              -- required for AGENT/SCHEMA
  agent_name      VARCHAR,              -- required for AGENT
  action          VARCHAR NOT NULL,     -- ROUTE | EXCLUDE
  destination_id  VARCHAR,
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  comment         VARCHAR,
  created_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Staged source rows (copy of AI_OBSERVABILITY_EVENTS, Cortex Agent only).
-- event_key = stable hash of the source row; dedupes overlapping re-reads.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS STAGED_EVENTS (
  event_key            VARCHAR NOT NULL PRIMARY KEY,
  record_type          VARCHAR,          -- SPAN | EVENT
  record_name          VARCHAR,
  trace_id             VARCHAR,
  span_id              VARCHAR,
  parent_span_id       VARCHAR,
  start_ts             TIMESTAMP_NTZ,    -- source START_TIMESTAMP (UTC), unchanged
  end_ts               TIMESTAMP_NTZ,    -- source TIMESTAMP (UTC), unchanged
  request_id           VARCHAR,          -- ai.observability.record_id
  agent_database       VARCHAR,
  agent_schema         VARCHAR,
  agent_name           VARCHAR,
  record               OBJECT,
  record_attributes    OBJECT,
  resource_attributes  OBJECT,
  scope                OBJECT,
  value                VARIANT,
  staged_at            TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- One row per trace: routing is resolved ONCE and persisted here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS TRACES (
  trace_id            VARCHAR NOT NULL PRIMARY KEY,
  request_id          VARCHAR,
  agent_database      VARCHAR,
  agent_schema        VARCHAR,
  agent_name          VARCHAR,
  root_span_id        VARCHAR,
  first_staged_at     TIMESTAMP_LTZ,
  last_staged_at      TIMESTAMP_LTZ,
  route_status        VARCHAR,          -- ROUTED | EXCLUDED | UNROUTED
  destination_id      VARCHAR,          -- resolved destination (frozen)
  resolved_route_id   VARCHAR,
  resolved_at         TIMESTAMP_LTZ,
  anomalies           ARRAY,            -- e.g. DUPLICATE_SPAN_ID, END_BEFORE_START, MISSING_PARENT, NO_ROOT
  trace_status        VARCHAR,          -- COLLECTING | READY | ANOMALY | HELD_FOR_BILLING | PUBLISHED | PARTIAL
  billing_status      VARCHAR,          -- PENDING | AVAILABLE | OVERDUE
  updated_at          TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Billing (CORTEX_AGENT_USAGE_HISTORY), keyed by REQUEST_ID. Values in CREDITS.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS BILLING (
  request_id            VARCHAR NOT NULL PRIMARY KEY,
  usage_start_time      TIMESTAMP_LTZ,
  usage_end_time        TIMESTAMP_LTZ,
  token_credits         NUMBER(38,9),   -- model token charges (credits)
  tokens                NUMBER(38,0),
  tokens_granular       ARRAY,
  credits_granular      ARRAY,
  sql_query_credits     VARIANT,        -- separate charge; NULL when not reported
  ai_functions_credits  VARIANT,        -- separate charge; NULL when not reported
  metadata              OBJECT,
  fetched_at            TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Feedback (CORTEX_AGENT_FEEDBACK events). Linking attributes are not yet
-- observed in this account; raw attributes are kept so linking can be fixed later.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FEEDBACK (
  event_key            VARCHAR NOT NULL PRIMARY KEY,   -- same key as STAGED_EVENTS
  request_id           VARCHAR,
  trace_id             VARCHAR,        -- resolved trace (may be NULL until linked)
  root_span_id         VARCHAR,        -- resolved root/response observation
  observed_ts          TIMESTAMP_NTZ,
  record_attributes    OBJECT,
  link_status          VARCHAR,        -- LINKED | UNLINKED
  staged_at            TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- Delivery tracking: one row per (destination, item). Attempts logged separately.
-- item_type: TRACE_BATCH | LATE_SPANS | BILLING_SCORE | FEEDBACK_SCORE
-- status:    PENDING | IN_FLIGHT | ACCEPTED | PARTIAL | REJECTED | RETRYABLE | UNCERTAIN
-- UNCERTAIN is never retried automatically.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DELIVERIES (
  delivery_id      VARCHAR NOT NULL PRIMARY KEY,
  destination_id   VARCHAR NOT NULL,
  item_type        VARCHAR NOT NULL,
  item_key         VARCHAR NOT NULL,   -- trace_id, trace_id:batchN, request_id:score, feedback event_key
  trace_id         VARCHAR,
  payload_hash     VARCHAR,
  status           VARCHAR NOT NULL,
  attempt_count    NUMBER  NOT NULL DEFAULT 0,
  last_http_status NUMBER,
  last_error       VARCHAR,            -- truncated; never contains credentials
  created_at       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_delivery UNIQUE (destination_id, item_type, item_key)
);

-- Which staged rows were included in which delivery (prevents re-sending accepted spans).
CREATE TABLE IF NOT EXISTS DELIVERY_ITEMS (
  delivery_id  VARCHAR NOT NULL,
  event_key    VARCHAR NOT NULL,
  CONSTRAINT pk_delivery_items PRIMARY KEY (delivery_id, event_key)
);

CREATE TABLE IF NOT EXISTS DELIVERY_ATTEMPTS (
  attempt_id        VARCHAR NOT NULL PRIMARY KEY,
  delivery_id       VARCHAR NOT NULL,
  started_at        TIMESTAMP_LTZ,
  finished_at       TIMESTAMP_LTZ,
  http_status       NUMBER,
  outcome           VARCHAR,          -- ACCEPTED | PARTIAL | REJECTED | RETRYABLE | UNCERTAIN
  response_excerpt  VARCHAR           -- first 2000 chars of response body; no request headers
);

-- Ingestion bookkeeping (re-read window start; NOT a delivery guarantee).
CREATE TABLE IF NOT EXISTS INGEST_STATE (
  source          VARCHAR NOT NULL PRIMARY KEY,   -- AI_OBSERVABILITY_EVENTS | CORTEX_AGENT_USAGE_HISTORY
  high_water_ts   TIMESTAMP_NTZ,
  overlap_minutes NUMBER NOT NULL DEFAULT 120,
  last_run_at     TIMESTAMP_LTZ,
  last_run_rows   NUMBER
);

-- ---------------------------------------------------------------------------
-- Seed configuration
-- ---------------------------------------------------------------------------
MERGE INTO DESTINATIONS t
USING (SELECT 'LANGFUSE_TEST' destination_id, 'https://cloud.langfuse.com' langfuse_host,
              'Test project' project_label,
              'LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS' secret_name,
              'LANGFUSE_CLOUD_EAI' integration_name,
              'TRACE_FIRST' publication_mode, ARRAY_CONSTRUCT('TOKEN_CREDITS') required_billing) s
ON t.destination_id = s.destination_id
WHEN NOT MATCHED THEN INSERT (destination_id, langfuse_host, project_label, secret_name, integration_name, publication_mode, required_billing)
  VALUES (s.destination_id, s.langfuse_host, s.project_label, s.secret_name, s.integration_name, s.publication_mode, s.required_billing);

MERGE INTO ROUTES t
USING (SELECT 'ACCOUNT_DEFAULT' route_id, 'ACCOUNT' match_level, 'ROUTE' action, 'LANGFUSE_TEST' destination_id) s
ON t.route_id = s.route_id
WHEN NOT MATCHED THEN INSERT (route_id, match_level, action, destination_id, comment)
  VALUES (s.route_id, s.match_level, s.action, s.destination_id, 'Initial account default');

MERGE INTO INGEST_STATE t
USING (SELECT column1 source FROM VALUES ('AI_OBSERVABILITY_EVENTS'), ('CORTEX_AGENT_USAGE_HISTORY')) s
ON t.source = s.source
WHEN NOT MATCHED THEN INSERT (source) VALUES (s.source);

/* =============================================================================
   VERIFICATION (expected results in comments)
   ========================================================================== */
-- V1: expect 10 tables
SELECT COUNT(*) AS tables_ FROM LANGFUSE_EXPORTER.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'CORE';
-- V2: expect 1 row LANGFUSE_TEST, TRACE_FIRST, ["TOKEN_CREDITS"]
SELECT destination_id, langfuse_host, publication_mode, required_billing, enabled FROM DESTINATIONS;
-- V3: expect 1 row ACCOUNT_DEFAULT, ACCOUNT, ROUTE, LANGFUSE_TEST
SELECT route_id, match_level, action, destination_id, enabled FROM ROUTES;
-- V4: expect 2 rows, high_water_ts NULL
SELECT * FROM INGEST_STATE;

/* =============================================================================
   TROUBLESHOOTING
     "Insufficient privileges" -> you are not LANGFUSE_EXPORTER_ROLE, or step 01
                                 ownership transfer did not run.
   ROUTING CHANGES (examples, run as LANGFUSE_EXPORTER_ROLE)
     -- exclude one agent:
     INSERT INTO ROUTES (route_id, match_level, agent_database, agent_schema, agent_name, action)
       VALUES ('EXCL_X', 'AGENT', 'DB', 'SCH', 'AGENT_X', 'EXCLUDE');
     Routing changes affect only traces not yet routed; routed traces keep their destination.
   CLEANUP (drops exporter state for this step only)
     DROP TABLE IF EXISTS DELIVERY_ATTEMPTS; DROP TABLE IF EXISTS DELIVERY_ITEMS;
     DROP TABLE IF EXISTS DELIVERIES; DROP TABLE IF EXISTS BILLING;
     DROP TABLE IF EXISTS TRACES; DROP TABLE IF EXISTS STAGED_EVENTS;
     DROP TABLE IF EXISTS ROUTES; DROP TABLE IF EXISTS DESTINATIONS;
     DROP TABLE IF EXISTS INGEST_STATE;
   ========================================================================== */
