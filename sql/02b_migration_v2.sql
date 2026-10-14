/* =============================================================================
   02b_migration_v2.sql
   Langfuse exporter - schema migration v2 (non-destructive, additive only)

   PREREQUISITES: step 02 VERIFIED. Run as LANGFUSE_EXPORTER_ROLE.
   SAFE ON POPULATED TABLES: only ADD COLUMN IF NOT EXISTS / CREATE TABLE IF NOT
   EXISTS / guarded UPDATEs. Nothing is dropped, replaced or truncated.

   WHY
     - A destination's identity is (host, Langfuse project id), not its label or
       secret alias. The project id is verified live by the sender before use.
     - Each trace freezes host, project id, publication mode and route at routing
       time; later spans, billing and feedback follow that snapshot.
     - Billing components are tracked separately (SQL credits can lag the rest
       of the usage row by up to 8 h per Snowflake docs).
     - Delivery identity = source account + trace id (+ span id for late spans)
       + host + project id. Frozen payload, claim and backoff live on the row.
     - Scores (credits now, feedback later) get stable persisted ids.

   Project identity is intentionally not seeded. Configure it in 03a before staging.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE TABLE IF NOT EXISTS SCHEMA_VERSION (
  version     NUMBER NOT NULL,
  applied_at  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  description VARCHAR
);

-- Destinations ------------------------------------------------------------------
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS project_id    VARCHAR;  -- verified Langfuse project id
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS environment   VARCHAR;  -- langfuse.environment (optional)
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_attempts  NUMBER DEFAULT 5;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS paused_reason VARCHAR;  -- set by sender on auth failure / project mismatch
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS paused_at     TIMESTAMP_LTZ;

-- Project identity is configured explicitly in 03a; never seed an example project ID.
UPDATE DESTINATIONS SET max_attempts = 5 WHERE max_attempts IS NULL;

-- Routes: optional immutable agent object id ------------------------------------
ALTER TABLE ROUTES ADD COLUMN IF NOT EXISTS agent_object_id VARCHAR;  -- AGENT level: if set, must also match

-- Traces: frozen routing snapshot + derived facts --------------------------------
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS source_account          VARCHAR;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS agent_object_id         VARCHAR;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS frozen_host             VARCHAR;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS frozen_project_id       VARCHAR;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS frozen_publication_mode VARCHAR;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS frozen_required_billing ARRAY;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS trace_start_utc         TIMESTAMP_NTZ;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS trace_end_utc           TIMESTAMP_NTZ;
ALTER TABLE TRACES ADD COLUMN IF NOT EXISTS sql_billing_applicable  BOOLEAN;  -- trace ran >= 1 SQL execution

-- Backfill the snapshot for traces already ROUTED before v2 (destination unchanged).
UPDATE TRACES t
   SET frozen_host = d.langfuse_host, frozen_project_id = d.project_id,
       frozen_publication_mode = d.publication_mode, frozen_required_billing = d.required_billing,
       source_account = COALESCE(t.source_account, CURRENT_ACCOUNT())
  FROM DESTINATIONS d
 WHERE t.destination_id = d.destination_id AND t.route_status = 'ROUTED' AND t.frozen_host IS NULL;

-- Billing: component refresh -----------------------------------------------------
ALTER TABLE BILLING ADD COLUMN IF NOT EXISTS last_refreshed_at TIMESTAMP_LTZ;

-- Deliveries: identity, frozen payload, claim, backoff -----------------------------
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS source_account  VARCHAR;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS host            VARCHAR;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS project_id      VARCHAR;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS payload         VARIANT;   -- frozen request body (no credentials)
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS claim_id        VARCHAR;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS claimed_at      TIMESTAMP_LTZ;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMP_LTZ;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS reconciled_at   TIMESTAMP_LTZ;
ALTER TABLE DELIVERIES ADD COLUMN IF NOT EXISTS reconcile_result VARIANT;

ALTER TABLE DELIVERY_ATTEMPTS ADD COLUMN IF NOT EXISTS state       VARCHAR;  -- STARTED | FINISHED
ALTER TABLE DELIVERY_ATTEMPTS ADD COLUMN IF NOT EXISTS error_class VARCHAR;  -- exception class only

-- Scores: stable id/name/timestamp persisted BEFORE first send ---------------------
CREATE TABLE IF NOT EXISTS SCORES (
  score_id        VARCHAR NOT NULL,      -- deterministic UUIDv5; reused for corrections
  destination_id  VARCHAR NOT NULL,
  host            VARCHAR NOT NULL,
  project_id      VARCHAR NOT NULL,
  trace_id        VARCHAR NOT NULL,
  observation_id  VARCHAR NOT NULL,      -- actual root span id
  name            VARCHAR NOT NULL,      -- e.g. snowflake.token_credits
  data_type       VARCHAR NOT NULL,      -- NUMERIC | BOOLEAN
  value           FLOAT,
  score_ts        VARCHAR NOT NULL,      -- persisted ISO-8601 UTC timestamp
  comment         VARCHAR,
  source_ref      VARCHAR,               -- request_id or feedback event_key
  created_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO SCHEMA_VERSION (version, description)
SELECT 2, 'destination identity, frozen trace snapshot, billing refresh, delivery claim/payload, scores'
 WHERE NOT EXISTS (SELECT 1 FROM SCHEMA_VERSION WHERE version = 2);

/* =============================================================================
   VERIFICATION
   ========================================================================== */
-- V1: expect version 2 present once
SELECT * FROM SCHEMA_VERSION ORDER BY version;
-- V2: new installs have project_id NULL until 03a; max_attempts 5, paused_reason NULL
SELECT destination_id, langfuse_host, project_id, publication_mode, max_attempts, paused_reason FROM DESTINATIONS;
-- V3: inspect existing snapshots; new installations may have no traces
SELECT trace_id, route_status, destination_id, frozen_host, frozen_project_id, frozen_publication_mode FROM TRACES;
-- V4: staged data untouched (expect 16)
SELECT COUNT(*) FROM STAGED_EVENTS;

/* =============================================================================
   ROLLBACK: not needed for additive columns; they are ignored by v1 code.
   ========================================================================== */
