/* =============================================================================
   07_tasks_status.sql
   Langfuse exporter - step 07: scheduled tasks (created SUSPENDED), status views

   PREREQUISITES
     - Steps 01, 02, 04 VERIFIED. Run as LANGFUSE_EXPORTER_ROLE.
     - Part B (publish task) requires step 05b. Both tasks are created suspended.

   CREATES (schema-level, LANGFUSE_EXPORTER.CORE)
     TASK  STAGE_AND_ROUTE_TASK       every 15 min -> CALL STAGE_AND_ROUTE()  (SUSPENDED)
     VIEW  DELIVERY_STATUS_V          one row per delivery (destination, item, status, attempts)
     VIEW  BILLING_OVERDUE_V          traces whose billing is OVERDUE, with age in hours
     VIEW  EXPORTER_HEALTH_V          one row per destination: trace/billing/delivery counts

   TASK POLICY
     Tasks are created SUSPENDED and must stay suspended until canary acceptance has
     verified one real browser-UI run in Langfuse (hierarchy, content, timings,
     usage, destination). Resuming is a manual, deliberate step (see OPERATIONS).

   COST NOTE
     Each task run resumes LANGFUSE_EXPORTER_WH (XSMALL, 60 s auto-suspend).
     Every 15 min = up to 96 short runs/day. Lengthen SCHEDULE to reduce cost.

   Fresh installation only. Use the upgrade guide for an existing task graph.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

/* ---------------------------------------------------------------------------
   PART A - staging task (no network access)
   ------------------------------------------------------------------------- */
CREATE OR REPLACE TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK
  WAREHOUSE = LANGFUSE_EXPORTER_WH
  SCHEDULE = '15 MINUTE'
  ALLOW_OVERLAPPING_EXECUTION = FALSE
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Langfuse exporter: stage Cortex Agent telemetry, route, billing, anomalies'
AS
  CALL LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE();

/* ---------------------------------------------------------------------------
   PART B - publish task, created after the root. Child tasks are created suspended; activation is in
   08_activate.sql only.
   ------------------------------------------------------------------------- */
CREATE OR REPLACE TASK LANGFUSE_EXPORTER.CORE.PUBLISH_TASK
  WAREHOUSE = LANGFUSE_EXPORTER_WH
  COMMENT = 'Langfuse exporter: publish READY traces and billing scores'
  AFTER LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK
AS
  CALL LANGFUSE_EXPORTER.CORE.PUBLISH_ALL_DESTINATIONS();

/* ---------------------------------------------------------------------------
   PART C - status views
   ------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.DELIVERY_STATUS_V AS
SELECT d.destination_id, d.item_type, d.item_key, d.trace_id, d.status,
       d.attempt_count, d.last_http_status, d.last_error,
       d.created_at, d.updated_at,
       COUNT(i.event_key) AS n_items
  FROM LANGFUSE_EXPORTER.CORE.DELIVERIES d
  LEFT JOIN LANGFUSE_EXPORTER.CORE.DELIVERY_ITEMS i ON i.delivery_id = d.delivery_id
 GROUP BY ALL;

CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.BILLING_OVERDUE_V AS
SELECT v.trace_id, v.request_id, v.agent_fqn, v.destination_id, v.trace_status,
       v.trace_end_utc,
       DATEDIFF(hour, v.trace_end_utc,
                CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ) AS hours_since_trace_end
  FROM LANGFUSE_EXPORTER.CORE.TRACE_STATUS_V v
 WHERE v.billing_status = 'OVERDUE';

CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.EXPORTER_HEALTH_V AS
WITH t AS (
  SELECT COALESCE(destination_id, '(' || route_status || ')') AS destination_id,
         COUNT(*)                                 AS traces,
         COUNT_IF(trace_status = 'COLLECTING')    AS collecting,
         COUNT_IF(trace_status = 'READY')         AS ready,
         COUNT_IF(trace_status = 'ANOMALY')       AS anomaly,
         COUNT_IF(trace_status = 'HELD_FOR_BILLING') AS held_for_billing,
         COUNT_IF(trace_status = 'CONFIG_ERROR')  AS config_error,
         COUNT_IF(trace_status = 'PUBLISHED')     AS published,
         COUNT_IF(trace_status = 'PARTIAL')       AS partial,
         COUNT_IF(billing_status = 'PENDING')     AS billing_pending,
         COUNT_IF(billing_status = 'OVERDUE')     AS billing_overdue
    FROM LANGFUSE_EXPORTER.CORE.TRACES GROUP BY 1
),
d AS (
  SELECT destination_id,
         COUNT_IF(status = 'UNCERTAIN') AS deliveries_uncertain,
         COUNT_IF(status = 'RETRYABLE') AS deliveries_retryable,
         COUNT_IF(status = 'REJECTED')  AS deliveries_rejected,
         COUNT_IF(status = 'PARTIAL')   AS deliveries_partial
    FROM LANGFUSE_EXPORTER.CORE.DELIVERIES GROUP BY 1
)
SELECT t.*,
       COALESCE(d.deliveries_uncertain, 0) AS deliveries_uncertain,
       COALESCE(d.deliveries_retryable, 0) AS deliveries_retryable,
       COALESCE(d.deliveries_rejected, 0)  AS deliveries_rejected,
       COALESCE(d.deliveries_partial, 0)   AS deliveries_partial,
       (SELECT MAX(last_run_at) FROM LANGFUSE_EXPORTER.CORE.INGEST_STATE) AS last_staging_run
  FROM t LEFT JOIN d ON d.destination_id = t.destination_id;

/* =============================================================================
   VERIFICATION (expected results in comments)
   ========================================================================== */
-- V1: expect both tasks suspended; root schedule = 15 MINUTE.
SHOW TASKS IN SCHEMA LANGFUSE_EXPORTER.CORE;
-- V2: inspect per-destination counts; values depend on staged runs.
SELECT * FROM LANGFUSE_EXPORTER.CORE.EXPORTER_HEALTH_V;
-- V3: inspect delivery states, including any canary sends.
SELECT * FROM LANGFUSE_EXPORTER.CORE.DELIVERY_STATUS_V;
-- V4: inspect overdue billing; zero rows is not proof of delivery.
SELECT * FROM LANGFUSE_EXPORTER.CORE.BILLING_OVERDUE_V;
-- V5: one manual run of the task body works (expect EXECUTE TASK to succeed;
--     then TASK_HISTORY shows SUCCEEDED within ~1 min). Runs once; does not resume.
-- EXECUTE TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK;
-- (re-run after ~1 min)
SELECT name, state, scheduled_time, completed_time, error_message
  FROM TABLE(LANGFUSE_EXPORTER.INFORMATION_SCHEMA.TASK_HISTORY(
         TASK_NAME => 'STAGE_AND_ROUTE_TASK', RESULT_LIMIT => 5))
 ORDER BY scheduled_time DESC;

/* =============================================================================
   OPERATIONS
     Resume (ONLY after canary acceptance is VERIFIED; see 08_activate.sql):
       ALTER TASK LANGFUSE_EXPORTER.CORE.PUBLISH_TASK RESUME;          -- child first
       ALTER TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK RESUME;  -- then root
     Pause everything:
       ALTER TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK SUSPEND;
     Change cadence (task must be suspended):
       ALTER TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK SET SCHEDULE = '60 MINUTE';
     Daily checks:
       SELECT * FROM EXPORTER_HEALTH_V;     -- anomaly / uncertain / overdue counts
       SELECT * FROM BILLING_OVERDUE_V;     -- billing older than billing_overdue_hours
       SELECT * FROM DELIVERY_STATUS_V WHERE status IN ('UNCERTAIN','REJECTED','PARTIAL');

   TROUBLESHOOTING
     V5 "Cannot execute task, EXECUTE TASK privilege must be granted"
         -> step 01 GRANT EXECUTE TASK ON ACCOUNT not applied.
     Task auto-suspended -> 3 consecutive failures; see TASK_HISTORY error_message,
         fix, then ALTER TASK ... RESUME.

   CLEANUP (this step only; full uninstall: 99_uninstall.sql)
     DROP TASK IF EXISTS LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK;
     DROP VIEW IF EXISTS LANGFUSE_EXPORTER.CORE.EXPORTER_HEALTH_V;
     DROP VIEW IF EXISTS LANGFUSE_EXPORTER.CORE.BILLING_OVERDUE_V;
     DROP VIEW IF EXISTS LANGFUSE_EXPORTER.CORE.DELIVERY_STATUS_V;
   ========================================================================== */

-- Install 07a_batch_status.sql for the bounded HTTP queue view.
