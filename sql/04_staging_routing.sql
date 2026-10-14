-- Candidate requires additive migration 02c. Install definitions before calling staging.
/* =============================================================================
   04_staging_routing.sql
   Langfuse exporter - step 04: stage source telemetry, route traces, detect
   anomalies, fetch billing, stage feedback. NO network access; sends nothing.

   PREREQUISITES
     - Steps 01 and 02 VERIFIED. (Step 03 is NOT required for this step.)
     - Run as LANGFUSE_EXPORTER_ROLE.

   CREATES (schema-level, LANGFUSE_EXPORTER.CORE)
     PROCEDURE STAGE_AND_ROUTE()   - one idempotent pass, returns a summary
     VIEW      TRACE_STATUS_V      - one row per trace: route, status, billing, anomalies
     VIEW      ANOMALY_DETAIL_V    - the source spans behind each anomaly

   WHAT ONE PASS DOES
     1. Stage   : copies Cortex Agent rows (object.type = 'Cortex Agent') and
                  CORTEX_AGENT_FEEDBACK rows from SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
                  into STAGED_EVENTS, unchanged. Re-reads from (high-water - overlap)
                  and de-duplicates on event_key, so late-arriving rows inside the
                  overlap window are picked up and nothing is staged twice.
     2. Traces  : one TRACES row per trace_id; root agent = agent on the root span.
     3. Route   : resolves AGENT > SCHEMA > DATABASE > ACCOUNT (EXCLUDE wins at the
                  same level). Destination is frozen once ROUTED/EXCLUDED.
                  No match -> UNROUTED (data kept; re-evaluated every pass).
     4. Billing : copies matching CORTEX_AGENT_USAGE_HISTORY rows (REQUEST_ID =
                  ai.observability.record_id). Values are credits.
     5. Status  : anomalies are DETECTED, never corrected:
                    NO_ROOT, MULTIPLE_ROOTS, DUPLICATE_SPAN_ID, END_BEFORE_START,
                    MISSING_PARENT
                  trace_status: COLLECTING (newer than quiet_minutes) | ANOMALY
                    (NO_ROOT, MULTIPLE_ROOTS, DUPLICATE_SPAN_ID, END_BEFORE_START are
                    ALWAYS blocking; destination.publish_anomalies can only release
                    MISSING_PARENT) | HELD_FOR_BILLING (frozen mode COST_READY and a
                    required component missing) | READY | CONFIG_ERROR.
                    PUBLISHED / PARTIAL are set only by step 05 and never reset here.
                  billing_status (over the trace's frozen required components):
                    AVAILABLE | PENDING | OVERDUE (still incomplete billing_overdue_hours
                    after trace end). SQL_QUERY_CREDITS counts as not applicable when
                    the trace ran no SQL. Billing rows are refreshed while a component
                    is missing (Snowflake: usage view <= 1 h; SQL credits <= 8 h more).
                  Routing freezes host, project id, mode and required billing on the
                    trace; AGENT routes may also pin agent_object_id.
     6. Feedback: stages CORTEX_AGENT_FEEDBACK rows; links by request id.
                  The feedback attribute layout has NOT been observed in this
                  account yet; linking is provisional (link_status shows result).

   KNOWN LIMITS
     - The source table has no ingestion-time column, so a row that arrives later
       than overlap_minutes (default 120) after its own TIMESTAMP is missed.
       Raise INGEST_STATE.overlap_minutes if that is observed.
     - A NULL sql_query_credits / ai_functions_credits means "not reported yet",
       not "zero". SQL credits exclude Adaptive Warehouse queries (Snowflake docs),
       so such traces may stay OVERDUE if SQL_QUERY_CREDITS is required.
     - Identifier matching is exact and case-sensitive on the names as recorded
       in the source (e.g. EXAMPLE_DB, quoted mixed-case names as written).

   RE-RUNNABLE: yes. CREATE OR REPLACE for code objects; the procedure only
     inserts/updates by key and never deletes.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

-- ---------------------------------------------------------------------------
-- Known source defect (user decision 2026-10-13): Snowflake browser-UI runs emit
-- a UserMemoryInjection span whose START and END are swapped (observed in every
-- browser run so far, always memory.injection.state = 'empty', count 0). Such a
-- span is OMITTED from export - never corrected - only when ALL hold:
--   name = UserMemoryInjection, end < start, has a parent, has no children,
--   and its span id is not shared by another row in the trace.
-- It stays in STAGED_EVENTS; the payload lists it in root metadata
-- (langfuse.trace.metadata.exporter_omitted_spans) with original timestamps.
-- Any other END_BEFORE_START remains a blocking anomaly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.OMITTED_SPANS_V AS
SELECT s.event_key, s.trace_id, s.span_id, s.parent_span_id, s.record_name, s.start_ts, s.end_ts,
       'KNOWN_DEFECT: UserMemoryInjection start/end swapped in source' AS reason
  FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS s
 WHERE s.record_type = 'SPAN'
   AND s.record_name = 'UserMemoryInjection'
   AND s.end_ts < s.start_ts
   AND s.parent_span_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS c
                    WHERE c.trace_id = s.trace_id AND c.parent_span_id = s.span_id)
   AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS d
                    WHERE d.trace_id = s.trace_id AND d.span_id = s.span_id
                      AND d.event_key <> s.event_key);

-- ---------------------------------------------------------------------------
-- Known source defect 2 (user decisions 2026-10-13): a tool span can share ONE
-- span id with the ReasoningAgentStepPlanning-N span that called it. Observed for
-- SemanticContextTool_* (every Cortex Analyst run) and ServerSkillTool_* (chart
-- skill, trace d853bbc4...). Generalized to tool spans (name contains "Tool_" or
-- "ToolImpl-"). The planning span keeps the source id; the tool span is exported
-- under a deterministic new id, ONLY when ALL hold:
--   exactly 2 rows share the id in the trace, one ReasoningAgentStepPlanning-*,
--   one tool span, same parent, no other row uses the id as parent,
--   and the new id collides with no span id in the trace.
-- new id = first 16 hex chars of SHA2(trace_id:original_span_id:record_name).
-- The original id is exported as langfuse.observation.metadata.exporter_original_span_id.
-- Any other duplicate span id remains a blocking anomaly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.REIDENTIFIED_SPANS_V AS
WITH g AS (
  SELECT trace_id, span_id,
         COUNT(*)                                                     AS n,
         COUNT_IF(record_name LIKE 'ReasoningAgentStepPlanning-%')    AS n_plan,
         COUNT_IF(record_name LIKE '%Tool\\_%' ESCAPE '\\' OR record_name LIKE '%ToolImpl-%') AS n_ctx,
         COUNT(DISTINCT COALESCE(parent_span_id, '<root>'))           AS n_parents,
         MIN(parent_span_id)                                          AS parent_span_id
    FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS
   WHERE record_type = 'SPAN' AND trace_id IS NOT NULL
   GROUP BY trace_id, span_id
  HAVING COUNT(*) > 1
)
SELECT s.event_key, s.trace_id, s.span_id AS original_span_id,
       SUBSTR(SHA2(s.trace_id || ':' || s.span_id || ':' || s.record_name, 256), 1, 16) AS new_span_id,
       s.record_name,
       'KNOWN_DEFECT: tool span shares span id with ReasoningAgentStepPlanning in source' AS reason
  FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS s
  JOIN g ON g.trace_id = s.trace_id AND g.span_id = s.span_id
 WHERE s.record_type = 'SPAN'
   AND (s.record_name LIKE '%Tool\\_%' ESCAPE '\\' OR s.record_name LIKE '%ToolImpl-%')
   AND g.n = 2 AND g.n_plan = 1 AND g.n_ctx = 1 AND g.n_parents = 1
   AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS c
                    WHERE c.trace_id = s.trace_id AND c.parent_span_id = s.span_id)
   AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS x
                    WHERE x.trace_id = s.trace_id
                      AND x.span_id = SUBSTR(SHA2(s.trace_id || ':' || s.span_id || ':' || s.record_name, 256), 1, 16));

CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.ROUTE_PREVIEW_V AS
WITH matching AS (
  SELECT tr.trace_id, r.route_id, r.action, r.destination_id, r.match_level,
         r.agent_database, r.agent_schema, r.agent_name, r.agent_object_id,
         d.langfuse_host, d.project_id, d.publication_mode, d.required_billing,
         d.enabled AS destination_enabled, d.paused_reason,
         CASE r.match_level WHEN 'AGENT' THEN 1 WHEN 'SCHEMA' THEN 2
                            WHEN 'DATABASE' THEN 3 ELSE 4 END AS specificity
  FROM LANGFUSE_EXPORTER.CORE.TRACES tr
  JOIN LANGFUSE_EXPORTER.CORE.ROUTES r ON r.enabled AND (
       r.match_level = 'ACCOUNT'
    OR (r.match_level = 'DATABASE' AND r.agent_database = tr.agent_database)
    OR (r.match_level = 'SCHEMA' AND r.agent_database = tr.agent_database
        AND r.agent_schema = tr.agent_schema)
    OR (r.match_level = 'AGENT' AND r.agent_database = tr.agent_database
        AND r.agent_schema = tr.agent_schema AND r.agent_name = tr.agent_name
        AND (r.agent_object_id IS NULL OR r.agent_object_id = tr.agent_object_id)))
  LEFT JOIN LANGFUSE_EXPORTER.CORE.DESTINATIONS d ON d.destination_id = r.destination_id
  WHERE COALESCE(tr.route_status, 'UNROUTED') IN ('UNROUTED', 'CONFIG_ERROR')
), best_level AS (
  SELECT trace_id, MIN(specificity) AS best FROM matching GROUP BY trace_id
), candidates AS (
  SELECT m.* FROM matching m JOIN best_level b
    ON b.trace_id = m.trace_id AND b.best = m.specificity
), summary AS (
  SELECT trace_id, COUNT(*) AS n_candidates,
         SUM(CASE WHEN action = 'EXCLUDE' THEN 1 ELSE 0 END) AS n_excludes,
         ARRAY_AGG(route_id) AS candidate_ids
  FROM candidates GROUP BY trace_id
), ranked AS (
  SELECT c.*, s.n_candidates, s.n_excludes, s.candidate_ids,
         ROW_NUMBER() OVER (PARTITION BY c.trace_id
           ORDER BY CASE WHEN c.action = 'EXCLUDE' THEN 0 ELSE 1 END, c.route_id) AS pick
  FROM candidates c JOIN summary s ON s.trace_id = c.trace_id
), decision AS (
  SELECT *, CASE
    WHEN n_excludes > 0 THEN NULL
    WHEN n_candidates <> 1 THEN 'AMBIGUOUS_RULES_OR_DUPLICATE_CONFIG'
    WHEN action <> 'ROUTE' OR action IS NULL THEN 'INVALID_ACTION'
    WHEN langfuse_host IS NULL OR project_id IS NULL OR TRIM(project_id) = ''
      THEN 'DESTINATION_NOT_CONFIGURED'
    WHEN NOT COALESCE(destination_enabled, FALSE) OR paused_reason IS NOT NULL
      THEN 'DESTINATION_DISABLED_OR_PAUSED'
    WHEN publication_mode NOT IN ('TRACE_FIRST', 'COST_READY') OR publication_mode IS NULL
      THEN 'INVALID_PUBLICATION_MODE'
    ELSE NULL END AS resolution_error
  FROM ranked WHERE pick = 1
)
SELECT *, CASE WHEN n_excludes > 0 THEN 'EXCLUDED'
               WHEN resolution_error IS NOT NULL THEN 'CONFIG_ERROR'
               ELSE 'ROUTED' END AS resolution_status
FROM decision;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE()
  RETURNS VARIANT
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  hw        TIMESTAMP_NTZ;
  ov        NUMBER;
  since     TIMESTAMP_NTZ;
  now_utc   TIMESTAMP_NTZ;
  new_max   TIMESTAMP_NTZ;
  n_before  NUMBER;
  n_after   NUMBER;
  b_before  NUMBER;
  b_after   NUMBER;
BEGIN
  now_utc := CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ;

  SELECT high_water_ts, overlap_minutes INTO :hw, :ov
    FROM LANGFUSE_EXPORTER.CORE.INGEST_STATE WHERE source = 'AI_OBSERVABILITY_EVENTS';
  since := COALESCE(DATEADD(minute, -ov, hw), '1970-01-01'::TIMESTAMP_NTZ);

  -- 1. Stage -------------------------------------------------------------------
  SELECT COUNT(*) INTO :n_before FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS;

  MERGE INTO LANGFUSE_EXPORTER.CORE.STAGED_EVENTS t
  USING (
    SELECT
      SHA2(CONCAT_WS('|',
        COALESCE(e.trace:trace_id::string, ''), COALESCE(e.trace:span_id::string, ''),
        COALESCE(e.record_type, ''), COALESCE(e.record:name::string, ''),
        COALESCE(TO_VARCHAR(e.start_timestamp), ''), COALESCE(TO_VARCHAR(e.timestamp), ''),
        COALESCE(e.record_attributes:"ai.observability.record_id"::string, ''),
        MD5(TO_JSON(e.record_attributes)))) AS event_key,
      e.record_type,
      e.record:name::string                                                AS record_name,
      e.trace:trace_id::string                                             AS trace_id,
      e.trace:span_id::string                                              AS span_id,
      e.record:parent_span_id::string                                      AS parent_span_id,
      e.start_timestamp                                                    AS start_ts,
      e.timestamp                                                          AS end_ts,
      e.record_attributes:"ai.observability.record_id"::string             AS request_id,
      e.record_attributes:"snow.ai.observability.database.name"::string    AS agent_database,
      e.record_attributes:"snow.ai.observability.schema.name"::string      AS agent_schema,
      e.record_attributes:"snow.ai.observability.object.name"::string      AS agent_name,
      e.record, e.record_attributes, e.resource_attributes, e.scope, e.value
    FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS e
    WHERE e.timestamp >= :since
      AND (e.record_attributes:"snow.ai.observability.object.type"::string = 'Cortex Agent'
           OR e.record:name::string = 'CORTEX_AGENT_FEEDBACK')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY event_key ORDER BY e.timestamp) = 1
  ) s
  ON t.event_key = s.event_key
  WHEN NOT MATCHED THEN INSERT
    (event_key, record_type, record_name, trace_id, span_id, parent_span_id, start_ts, end_ts,
     request_id, agent_database, agent_schema, agent_name,
     record, record_attributes, resource_attributes, scope, value)
  VALUES
    (s.event_key, s.record_type, s.record_name, s.trace_id, s.span_id, s.parent_span_id, s.start_ts, s.end_ts,
     s.request_id, s.agent_database, s.agent_schema, s.agent_name,
     s.record, s.record_attributes, s.resource_attributes, s.scope, s.value);

  SELECT COUNT(*) INTO :n_after FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS;

  SELECT MAX(e.timestamp) INTO :new_max
    FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS e
   WHERE e.timestamp >= :since
     AND (e.record_attributes:"snow.ai.observability.object.type"::string = 'Cortex Agent'
          OR e.record:name::string = 'CORTEX_AGENT_FEEDBACK');

  UPDATE LANGFUSE_EXPORTER.CORE.INGEST_STATE
     SET high_water_ts = GREATEST(COALESCE(:hw, :new_max), COALESCE(:new_max, :hw)),
         last_run_at   = CURRENT_TIMESTAMP(),
         last_run_rows = :n_after - :n_before
   WHERE source = 'AI_OBSERVABILITY_EVENTS';

  -- 2. Traces --------------------------------------------------------------------
  MERGE INTO LANGFUSE_EXPORTER.CORE.TRACES t
  USING (
    SELECT trace_id,
           MAX(request_id)                                                     AS request_id,
           COALESCE(MAX(IFF(parent_span_id IS NULL, agent_database, NULL)), MAX(agent_database)) AS agent_database,
           COALESCE(MAX(IFF(parent_span_id IS NULL, agent_schema,   NULL)), MAX(agent_schema))   AS agent_schema,
           COALESCE(MAX(IFF(parent_span_id IS NULL, agent_name,     NULL)), MAX(agent_name))     AS agent_name,
           MAX(IFF(parent_span_id IS NULL, span_id, NULL))                     AS root_span_id,
           MIN(staged_at) AS first_staged_at,
           MAX(staged_at) AS last_staged_at,
           MAX(IFF(parent_span_id IS NULL, record_attributes:"snow.ai.observability.object.id"::string, NULL)) AS agent_object_id,
           MIN(LEAST(start_ts, end_ts))    AS trace_start_utc,
           MAX(GREATEST(start_ts, end_ts)) AS trace_end_utc,
           BOOLOR_AGG(record_attributes:"snow.ai.observability.agent.tool.sql_execution.query_id" IS NOT NULL) AS sql_billing_applicable
      FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS
     WHERE record_type = 'SPAN' AND trace_id IS NOT NULL
     GROUP BY trace_id
  ) s
  ON t.trace_id = s.trace_id
  WHEN MATCHED THEN UPDATE SET
    request_id     = COALESCE(t.request_id, s.request_id),
    root_span_id   = COALESCE(t.root_span_id, s.root_span_id),
    agent_database = IFF(t.route_status IN ('ROUTED','EXCLUDED'), t.agent_database, s.agent_database),
    agent_schema   = IFF(t.route_status IN ('ROUTED','EXCLUDED'), t.agent_schema,   s.agent_schema),
    agent_name     = IFF(t.route_status IN ('ROUTED','EXCLUDED'), t.agent_name,     s.agent_name),
    agent_object_id = COALESCE(t.agent_object_id, s.agent_object_id),
    source_account = COALESCE(t.source_account, CURRENT_ACCOUNT()),
    trace_start_utc = s.trace_start_utc,
    trace_end_utc  = s.trace_end_utc,
    sql_billing_applicable = s.sql_billing_applicable,
    last_staged_at = s.last_staged_at,
    updated_at     = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (trace_id, request_id, agent_database, agent_schema, agent_name, agent_object_id, source_account,
     root_span_id, first_staged_at, last_staged_at, trace_start_utc, trace_end_utc,
     sql_billing_applicable, billing_status)
  VALUES
    (s.trace_id, s.request_id, s.agent_database, s.agent_schema, s.agent_name, s.agent_object_id, CURRENT_ACCOUNT(),
     s.root_span_id, s.first_staged_at, s.last_staged_at, s.trace_start_utc, s.trace_end_utc,
     s.sql_billing_applicable, 'PENDING');

  -- 3. Rank before validating; failed overrides never fall through to defaults.
  -- CONFIG_ERROR is reconsidered after configuration repair. Final decisions stay frozen.
  UPDATE LANGFUSE_EXPORTER.CORE.TRACES t
     SET route_status = s.resolution_status,
         route_error = s.resolution_error,
         route_candidates = s.candidate_ids,
         destination_id = CASE WHEN s.resolution_status = 'ROUTED' THEN s.destination_id END,
         resolved_route_id = CASE WHEN s.resolution_status <> 'CONFIG_ERROR' THEN s.route_id END,
         resolved_at = CASE WHEN s.resolution_status <> 'CONFIG_ERROR' THEN CURRENT_TIMESTAMP() END,
         frozen_host = CASE WHEN s.resolution_status = 'ROUTED' THEN s.langfuse_host END,
         frozen_project_id = CASE WHEN s.resolution_status = 'ROUTED' THEN s.project_id END,
         frozen_publication_mode = CASE WHEN s.resolution_status = 'ROUTED' THEN s.publication_mode END,
         frozen_required_billing = CASE WHEN s.resolution_status = 'ROUTED' THEN s.required_billing END,
         frozen_route_config = CASE WHEN s.resolution_status <> 'CONFIG_ERROR' THEN
           OBJECT_CONSTRUCT_KEEP_NULL('route_id', s.route_id, 'action', s.action,
             'match_level', s.match_level, 'agent_database', s.agent_database,
             'agent_schema', s.agent_schema, 'agent_name', s.agent_name,
             'agent_object_id', s.agent_object_id, 'destination_id', s.destination_id) END,
         updated_at = CURRENT_TIMESTAMP()
    FROM LANGFUSE_EXPORTER.CORE.ROUTE_PREVIEW_V s
   WHERE t.trace_id = s.trace_id;

  -- Repair/removal can leave a formerly-invalid trace with no remaining rule.
  UPDATE LANGFUSE_EXPORTER.CORE.TRACES t
     SET route_status = 'UNROUTED', route_error = NULL, route_candidates = NULL,
         updated_at = CURRENT_TIMESTAMP()
   WHERE COALESCE(t.route_status, 'UNROUTED') IN ('UNROUTED', 'CONFIG_ERROR')
     AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.ROUTE_PREVIEW_V p
                     WHERE p.trace_id = t.trace_id);

  -- 4. Billing -------------------------------------------------------------------
  SELECT COUNT(*) INTO :b_before FROM LANGFUSE_EXPORTER.CORE.BILLING;

  MERGE INTO LANGFUSE_EXPORTER.CORE.BILLING b
  USING (
    SELECT u.*
      FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY u
      JOIN (SELECT DISTINCT request_id FROM LANGFUSE_EXPORTER.CORE.TRACES
             WHERE request_id IS NOT NULL) tr
        ON u.request_id = tr.request_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY u.request_id ORDER BY u.end_time DESC) = 1
  ) s
  ON b.request_id = s.request_id
  -- Refresh while a lagging component is still missing (SQL credits can lag the
  -- rest of the usage row by up to 8 h per Snowflake docs). METADATA holds JSON
  -- null for absent values; ::FLOAT turns that into SQL NULL.
  WHEN MATCHED AND (s.token_credits IS NOT NULL AND b.token_credits IS NULL
                    OR s.metadata:sql_query_credits::FLOAT IS NOT NULL AND b.sql_query_credits::FLOAT IS NULL
                    OR s.metadata:ai_functions_credits::FLOAT IS NOT NULL AND b.ai_functions_credits::FLOAT IS NULL)
  THEN UPDATE SET
    token_credits = s.token_credits, tokens = s.tokens,
    tokens_granular = s.tokens_granular, credits_granular = s.credits_granular,
    sql_query_credits = s.metadata:sql_query_credits::FLOAT,
    ai_functions_credits = s.metadata:ai_functions_credits::FLOAT,
    metadata = s.metadata, last_refreshed_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (request_id, usage_start_time, usage_end_time, token_credits, tokens,
     tokens_granular, credits_granular, sql_query_credits, ai_functions_credits, metadata)
  VALUES
    (s.request_id, s.start_time, s.end_time, s.token_credits, s.tokens,
     s.tokens_granular, s.credits_granular, s.metadata:sql_query_credits::FLOAT,
     s.metadata:ai_functions_credits::FLOAT, s.metadata);

  SELECT COUNT(*) INTO :b_after FROM LANGFUSE_EXPORTER.CORE.BILLING;

  -- 5. Anomalies, billing status, trace status -----------------------------------
  UPDATE LANGFUSE_EXPORTER.CORE.TRACES t
     SET anomalies      = s.new_anomalies,
         billing_status = s.new_billing_status,
         trace_status   = s.new_trace_status,
         updated_at     = CURRENT_TIMESTAMP()
    FROM (
      WITH sp AS (
        SELECT e.trace_id, COALESCE(r.new_span_id, e.span_id) AS span_id,
               e.parent_span_id, e.start_ts, e.end_ts
          FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS e
          LEFT JOIN LANGFUSE_EXPORTER.CORE.REIDENTIFIED_SPANS_V r ON r.event_key = e.event_key
         WHERE e.record_type = 'SPAN' AND e.trace_id IS NOT NULL
           AND e.event_key NOT IN (SELECT event_key FROM LANGFUSE_EXPORTER.CORE.OMITTED_SPANS_V)
      ),
      agg AS (
        SELECT trace_id,
               COUNT_IF(parent_span_id IS NULL)     AS n_roots,
               COUNT_IF(end_ts < start_ts)          AS n_end_before_start,
               MAX(GREATEST(start_ts, end_ts))      AS trace_end
          FROM sp GROUP BY trace_id
      ),
      dup AS (
        SELECT DISTINCT trace_id FROM sp GROUP BY trace_id, span_id HAVING COUNT(*) > 1
      ),
      mp AS (
        SELECT DISTINCT c.trace_id FROM sp c
         WHERE c.parent_span_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM sp p
                            WHERE p.trace_id = c.trace_id AND p.span_id = c.parent_span_id)
      )
      SELECT tr.trace_id,
             ARRAY_COMPACT(ARRAY_CONSTRUCT(
               IFF(a.n_roots = 0, 'NO_ROOT', NULL),
               IFF(a.n_roots > 1, 'MULTIPLE_ROOTS', NULL),
               IFF(d.trace_id IS NOT NULL, 'DUPLICATE_SPAN_ID', NULL),
               IFF(a.n_end_before_start > 0, 'END_BEFORE_START', NULL),
               IFF(m.trace_id IS NOT NULL, 'MISSING_PARENT', NULL))) AS new_anomalies,
             -- NOTE: computed columns are named new_* on purpose. A bare alias such as
             -- "anomalies" would resolve to the existing TRACES column (previous run's
             -- value) inside this SELECT - observed 2026-10-13: a trace with a duplicate
             -- span id was set READY on its first pass.
             -- Billing readiness over the trace's frozen required components.
             -- SQL_QUERY_CREDITS is "not applicable" when the trace ran no SQL; NULL
             -- otherwise means pending (or never, e.g. Adaptive Warehouses -> OVERDUE).
             COALESCE(tr.frozen_required_billing, ARRAY_CONSTRUCT('TOKEN_CREDITS')) AS req,
             (    (NOT ARRAY_CONTAINS('TOKEN_CREDITS'::VARIANT, req) OR b.token_credits IS NOT NULL)
              AND (NOT ARRAY_CONTAINS('SQL_QUERY_CREDITS'::VARIANT, req)
                   OR b.sql_query_credits::FLOAT IS NOT NULL
                   OR (b.request_id IS NOT NULL AND NOT COALESCE(tr.sql_billing_applicable, FALSE)))
              AND (NOT ARRAY_CONTAINS('AI_FUNCTIONS_CREDITS'::VARIANT, req)
                   OR b.ai_functions_credits::FLOAT IS NOT NULL)) AS billing_complete,
             CASE
               WHEN billing_complete THEN 'AVAILABLE'
               WHEN a.trace_end < DATEADD(hour, -COALESCE(ds.billing_overdue_hours, 24), :now_utc) THEN 'OVERDUE'
               ELSE 'PENDING'
             END AS new_billing_status,
             -- Blocking anomalies are never published (publish_anomalies cannot
             -- override conflicting ids, invalid timing or root ambiguity).
             ARRAYS_OVERLAP(new_anomalies, ARRAY_CONSTRUCT('NO_ROOT', 'MULTIPLE_ROOTS',
                            'DUPLICATE_SPAN_ID', 'END_BEFORE_START')) AS blocking,
             CASE
               WHEN tr.trace_status IN ('PUBLISHED', 'PARTIAL') THEN tr.trace_status
               WHEN tr.route_status = 'CONFIG_ERROR' THEN 'CONFIG_ERROR'
               WHEN COALESCE(tr.route_status, 'UNROUTED') <> 'ROUTED' THEN 'HELD_FOR_ROUTING'
               WHEN tr.route_status = 'ROUTED'
                    AND COALESCE(tr.frozen_publication_mode, '') NOT IN ('TRACE_FIRST', 'COST_READY') THEN 'CONFIG_ERROR'
               WHEN a.trace_end > DATEADD(minute, -COALESCE(ds.quiet_minutes, 5), :now_utc) THEN 'COLLECTING'
               WHEN blocking THEN 'ANOMALY'
               WHEN ARRAY_SIZE(new_anomalies) > 0 AND NOT COALESCE(ds.publish_anomalies, FALSE) THEN 'ANOMALY'
               WHEN tr.frozen_publication_mode = 'COST_READY' AND NOT billing_complete THEN 'HELD_FOR_BILLING'
               ELSE 'READY'
             END AS new_trace_status
        FROM LANGFUSE_EXPORTER.CORE.TRACES tr
        JOIN agg a ON a.trace_id = tr.trace_id
        LEFT JOIN dup d ON d.trace_id = tr.trace_id
        LEFT JOIN mp  m ON m.trace_id = tr.trace_id
        LEFT JOIN LANGFUSE_EXPORTER.CORE.BILLING b       ON b.request_id = tr.request_id
        LEFT JOIN LANGFUSE_EXPORTER.CORE.DESTINATIONS ds ON ds.destination_id = tr.destination_id
    ) s
   WHERE t.trace_id = s.trace_id;

  -- 6. Feedback ------------------------------------------------------------------
  MERGE INTO LANGFUSE_EXPORTER.CORE.FEEDBACK f
  USING (
    SELECT event_key, request_id, end_ts AS observed_ts, record_attributes
      FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS
     WHERE record_name = 'CORTEX_AGENT_FEEDBACK'
  ) s
  ON f.event_key = s.event_key
  WHEN NOT MATCHED THEN INSERT (event_key, request_id, observed_ts, record_attributes, link_status)
    VALUES (s.event_key, s.request_id, s.observed_ts, s.record_attributes, 'UNLINKED');

  UPDATE LANGFUSE_EXPORTER.CORE.FEEDBACK f
     SET trace_id = t.trace_id, root_span_id = t.root_span_id, link_status = 'LINKED'
    FROM LANGFUSE_EXPORTER.CORE.TRACES t
   WHERE f.link_status = 'UNLINKED' AND f.request_id = t.request_id;

  RETURN OBJECT_CONSTRUCT(
    'read_since_utc',   since,
    'high_water_utc',   GREATEST(COALESCE(hw, new_max), COALESCE(new_max, hw)),
    'new_staged_rows',  n_after - n_before,
    'new_billing_rows', b_after - b_before);
END;
$$;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.TRACE_STATUS_V AS
SELECT t.trace_id,
       t.request_id,
       t.agent_database || '.' || t.agent_schema || '.' || t.agent_name AS agent_fqn,
       t.route_status, t.destination_id, t.resolved_route_id,
       t.trace_status, t.billing_status, t.anomalies,
       b.token_credits,
       s.n_spans, s.trace_start_utc, s.trace_end_utc,
       ev.n_request_events,
       fb.n_feedback,
       e.interaction_interface
  FROM LANGFUSE_EXPORTER.CORE.TRACES t
  LEFT JOIN LANGFUSE_EXPORTER.CORE.BILLING b ON b.request_id = t.request_id
  LEFT JOIN (SELECT trace_id, COUNT(*) AS n_spans,
                    MIN(LEAST(start_ts, end_ts))    AS trace_start_utc,
                    MAX(GREATEST(start_ts, end_ts)) AS trace_end_utc
               FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS WHERE record_type = 'SPAN'
              GROUP BY trace_id) s ON s.trace_id = t.trace_id
  LEFT JOIN (SELECT request_id, COUNT(*) AS n_request_events
               FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS
              WHERE record_type = 'EVENT' AND record_name = 'CORTEX_AGENT_REQUEST'
              GROUP BY request_id) ev ON ev.request_id = t.request_id
  LEFT JOIN (SELECT trace_id, COUNT(*) AS n_feedback
               FROM LANGFUSE_EXPORTER.CORE.FEEDBACK GROUP BY trace_id) fb ON fb.trace_id = t.trace_id
  LEFT JOIN (SELECT request_id, metadata:interaction_interface::string AS interaction_interface
               FROM LANGFUSE_EXPORTER.CORE.BILLING) e ON e.request_id = t.request_id;

CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.ANOMALY_DETAIL_V AS
WITH sp AS (
  SELECT trace_id, span_id, parent_span_id, record_name, start_ts, end_ts, event_key
    FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS
   WHERE record_type = 'SPAN' AND trace_id IS NOT NULL
)
SELECT 'DUPLICATE_SPAN_ID' AS anomaly, trace_id, span_id, parent_span_id, record_name, start_ts, end_ts, event_key
  FROM sp
 QUALIFY COUNT(*) OVER (PARTITION BY trace_id, span_id) > 1
UNION ALL
SELECT 'END_BEFORE_START', trace_id, span_id, parent_span_id, record_name, start_ts, end_ts, event_key
  FROM sp WHERE end_ts < start_ts
UNION ALL
SELECT 'MISSING_PARENT', c.trace_id, c.span_id, c.parent_span_id, c.record_name, c.start_ts, c.end_ts, c.event_key
  FROM sp c
 WHERE c.parent_span_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sp p WHERE p.trace_id = c.trace_id AND p.span_id = c.parent_span_id);

-- Definitions only. See docs/INSTALL.md for deliberate staging and route preview.
