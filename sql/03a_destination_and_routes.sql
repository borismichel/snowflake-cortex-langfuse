-- OPERATOR CONFIGURATION: edit these two tables. No credentials belong here.
-- Run after 02c and credential/network setup, before the first staging pass.
-- This sample sends A and B to the shared project and C to a separate project.
-- Replace placeholders, register both secret bindings, then run this file.
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE TEMPORARY TABLE DESIRED_DESTINATIONS AS
SELECT column1::VARCHAR destination_id, column2::VARCHAR langfuse_host,
       column3::VARCHAR project_id, column4::VARCHAR secret_name,
       column5::VARCHAR integration_name, column6::VARCHAR publication_mode
FROM VALUES
 ('LANGFUSE_TEST', 'https://cloud.langfuse.com', '<verified-shared-project-id>',
  'LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS', 'LANGFUSE_CLOUD_EAI', 'TRACE_FIRST'),
 ('LANGFUSE_TEAM_B', 'https://cloud.langfuse.com', '<verified-team-b-project-id>',
  'LANGFUSE_EXPORTER.CORE.LANGFUSE_TEAM_B_CREDENTIALS', 'LANGFUSE_CLOUD_EAI', 'TRACE_FIRST');

CREATE OR REPLACE TEMPORARY TABLE DESIRED_ROUTES AS
SELECT column1::VARCHAR route_id, column2::VARCHAR match_level,
       column3::VARCHAR agent_database, column4::VARCHAR agent_schema,
       column5::VARCHAR agent_name, column6::VARCHAR action,
       column7::VARCHAR destination_id
FROM VALUES
 ('AGENT_A_SHARED', 'AGENT', '<database>', '<schema>', '<agent-a>', 'ROUTE', 'LANGFUSE_TEST'),
 ('AGENT_B_SHARED', 'AGENT', '<database>', '<schema>', '<agent-b>', 'ROUTE', 'LANGFUSE_TEST'),
 ('AGENT_C_TEAM_B', 'AGENT', '<database>', '<schema>', '<agent-c>', 'ROUTE', 'LANGFUSE_TEAM_B');
-- For the whole account in a shared project, replace the three rows above with:
-- ('ACCOUNT_DEFAULT', 'ACCOUNT', NULL, NULL, NULL, 'ROUTE', 'LANGFUSE_TEST')
-- and remove the unused TEAM_B destination row.
-- EXCLUDE example: ('SANDBOX', 'SCHEMA', 'SANDBOX', 'PUBLIC', NULL, 'EXCLUDE', NULL)
-- Exact stored names/case, no wildcard parsing; each route resolves one project.

EXECUTE IMMEDIATE $$
DECLARE
  invalid_config EXCEPTION (-20001, 'Invalid routing configuration, duplicate keys, placeholders or destination identity change. Inspect desired tables.');
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO :n FROM DESIRED_DESTINATIONS
   WHERE project_id IS NULL OR TRIM(project_id) = '' OR project_id LIKE '%<%'
      OR destination_id IS NULL OR TRIM(destination_id) = ''
      OR langfuse_host IS NULL OR langfuse_host NOT LIKE 'https://%' OR langfuse_host LIKE '%<%'
      OR secret_name IS NULL OR integration_name IS NULL
      OR publication_mode IS NULL OR publication_mode NOT IN ('TRACE_FIRST', 'COST_READY');
  IF (n > 0) THEN RAISE invalid_config; END IF;
  SELECT COUNT(*) INTO :n FROM (
    SELECT destination_id FROM DESIRED_DESTINATIONS GROUP BY destination_id HAVING COUNT(*) > 1
    UNION ALL SELECT destination_id FROM DESTINATIONS GROUP BY destination_id HAVING COUNT(*) > 1
    UNION ALL SELECT route_id FROM DESIRED_ROUTES GROUP BY route_id HAVING COUNT(*) > 1
    UNION ALL SELECT route_id FROM ROUTES GROUP BY route_id HAVING COUNT(*) > 1);
  IF (n > 0) THEN RAISE invalid_config; END IF;
  SELECT COUNT(*) INTO :n FROM DESIRED_ROUTES r
   WHERE r.route_id IS NULL OR r.route_id LIKE '%<%'
      OR r.match_level NOT IN ('ACCOUNT', 'DATABASE', 'SCHEMA', 'AGENT') OR r.match_level IS NULL
      OR r.action NOT IN ('ROUTE', 'EXCLUDE') OR r.action IS NULL
      OR (r.match_level <> 'ACCOUNT' AND (r.agent_database IS NULL OR r.agent_database LIKE '%<%'))
      OR (r.match_level IN ('SCHEMA', 'AGENT') AND (r.agent_schema IS NULL OR r.agent_schema LIKE '%<%'))
      OR (r.match_level = 'AGENT' AND (r.agent_name IS NULL OR r.agent_name LIKE '%<%'))
      OR (r.action = 'ROUTE' AND NOT EXISTS (
          SELECT 1 FROM DESIRED_DESTINATIONS d WHERE d.destination_id = r.destination_id));
  IF (n > 0) THEN RAISE invalid_config; END IF;
  SELECT COUNT(*) INTO :n FROM (
    SELECT match_level, agent_database, agent_schema, agent_name
    FROM DESIRED_ROUTES GROUP BY match_level, agent_database, agent_schema, agent_name
    HAVING COUNT(*) > 1);
  IF (n > 0) THEN RAISE invalid_config; END IF;
  -- An existing identity is immutable. A never-routed seed may acquire its first project ID.
  SELECT COUNT(*) INTO :n FROM DESTINATIONS d JOIN DESIRED_DESTINATIONS s USING (destination_id)
   WHERE RTRIM(d.langfuse_host, '/') <> RTRIM(s.langfuse_host, '/')
      OR (d.project_id IS NOT NULL AND d.project_id <> s.project_id)
      OR (d.project_id IS NULL AND (
          EXISTS (SELECT 1 FROM TRACES t WHERE t.destination_id = d.destination_id)
          OR EXISTS (SELECT 1 FROM DELIVERIES x WHERE x.destination_id = d.destination_id)));
  IF (n > 0) THEN RAISE invalid_config; END IF;

  BEGIN TRANSACTION;
  MERGE INTO DESTINATIONS d USING DESIRED_DESTINATIONS s ON d.destination_id = s.destination_id
  WHEN MATCHED THEN UPDATE SET
    project_id = s.project_id, secret_name = s.secret_name, integration_name = s.integration_name,
    publication_mode = s.publication_mode, updated_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (destination_id, langfuse_host, project_id, secret_name, integration_name,
     publication_mode, required_billing)
  VALUES (s.destination_id, RTRIM(s.langfuse_host, '/'), s.project_id, s.secret_name,
          s.integration_name, s.publication_mode, ARRAY_CONSTRUCT('TOKEN_CREDITS'));
  -- This file owns the complete active routing map. Retired rows remain for audit.
  UPDATE ROUTES SET enabled = FALSE
   WHERE NOT EXISTS (SELECT 1 FROM DESIRED_ROUTES s WHERE s.route_id = ROUTES.route_id);
  MERGE INTO ROUTES r USING DESIRED_ROUTES s ON r.route_id = s.route_id
  WHEN MATCHED THEN UPDATE SET
    match_level = s.match_level, agent_database = s.agent_database, agent_schema = s.agent_schema,
    agent_name = s.agent_name, agent_object_id = NULL, action = s.action,
    destination_id = s.destination_id, enabled = TRUE
  WHEN NOT MATCHED THEN INSERT
    (route_id, match_level, agent_database, agent_schema, agent_name, action, destination_id, enabled)
  VALUES (s.route_id, s.match_level, s.agent_database, s.agent_schema, s.agent_name,
          s.action, s.destination_id, TRUE);
  COMMIT;
EXCEPTION WHEN OTHER THEN
  ROLLBACK;
  RAISE;
END;
$$;
SELECT destination_id, langfuse_host, project_id, publication_mode, enabled, paused_reason FROM DESTINATIONS;
SELECT * FROM ROUTES WHERE enabled ORDER BY route_id;
-- Before staging, call LANGFUSE_CONNECTIVITY_CHECK for every configured destination.
-- Its projects response must include exactly the intended project ID. The sender
-- repeats project verification. Table fields do not bind secrets to procedures.
