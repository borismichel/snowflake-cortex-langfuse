/* =============================================================================
   01_role_warehouse_database.sql
   Langfuse exporter - step 01: runtime role, warehouse, database/schema, grants

   PREREQUISITES
     - Run as ACCOUNTADMIN (account-level objects and account privileges).
     - No configuration placeholders in this script.

   CREATES
     Account-level : ROLE LANGFUSE_EXPORTER_ROLE
                     WAREHOUSE LANGFUSE_EXPORTER_WH (XSMALL, auto-suspend 60 s)
                     DATABASE LANGFUSE_EXPORTER (owned by the runtime role)
                     Account grants: EXECUTE TASK,
                       READ UNREDACTED AI OBSERVABILITY EVENTS TABLE
                     Application roles: SNOWFLAKE.AI_OBSERVABILITY_READER
                     Database roles: SNOWFLAKE.CORTEX_USER, SNOWFLAKE.USAGE_VIEWER
     Schema-level  : LANGFUSE_EXPORTER.CORE (owned by the runtime role)

   NOTE
     External access integrations (account-level) are created in step 03.
     The runtime role is granted to the current user so you can verify it.
     If your org requires custom role hierarchy, also grant it to SYSADMIN.

   RE-RUNNABLE: yes (IF NOT EXISTS / idempotent grants).
   ========================================================================== */

USE ROLE ACCOUNTADMIN;

-- 1. Runtime role --------------------------------------------------------------
CREATE ROLE IF NOT EXISTS LANGFUSE_EXPORTER_ROLE
  COMMENT = 'Runtime role for the Cortex Agent -> Langfuse exporter';
GRANT ROLE LANGFUSE_EXPORTER_ROLE TO ROLE SYSADMIN;
SET my_user = CURRENT_USER();
GRANT ROLE LANGFUSE_EXPORTER_ROLE TO USER IDENTIFIER($my_user);

-- 2. Warehouse ------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS LANGFUSE_EXPORTER_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Langfuse exporter procedures and tasks';
GRANT USAGE, OPERATE ON WAREHOUSE LANGFUSE_EXPORTER_WH TO ROLE LANGFUSE_EXPORTER_ROLE;

-- 3. Database and schema (owned by the runtime role) ----------------------------
CREATE DATABASE IF NOT EXISTS LANGFUSE_EXPORTER
  COMMENT = 'Cortex Agent telemetry staging and Langfuse delivery tracking';
GRANT OWNERSHIP ON DATABASE LANGFUSE_EXPORTER TO ROLE LANGFUSE_EXPORTER_ROLE COPY CURRENT GRANTS;
USE ROLE LANGFUSE_EXPORTER_ROLE;
CREATE SCHEMA IF NOT EXISTS LANGFUSE_EXPORTER.CORE;
USE ROLE ACCOUNTADMIN;

-- 4. Telemetry / billing access -------------------------------------------------
-- Account-wide raw read of SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
-- (covers current and future agents without per-agent MONITOR grants).
GRANT APPLICATION ROLE SNOWFLAKE.AI_OBSERVABILITY_READER TO ROLE LANGFUSE_EXPORTER_ROLE;
-- Without this, prompts/responses/tool I/O/feedback text are redacted.
GRANT READ UNREDACTED AI OBSERVABILITY EVENTS TABLE ON ACCOUNT TO ROLE LANGFUSE_EXPORTER_ROLE;
-- Cortex features + ACCOUNT_USAGE views (CORTEX_AGENT_USAGE_HISTORY, QUERY_HISTORY).
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE LANGFUSE_EXPORTER_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE LANGFUSE_EXPORTER_ROLE;

-- 5. Tasks ----------------------------------------------------------------------
GRANT EXECUTE TASK ON ACCOUNT TO ROLE LANGFUSE_EXPORTER_ROLE;

/* =============================================================================
   VERIFICATION (run each; expected results in comments)
   ========================================================================== */
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;

-- V1: expect CURRENT_ROLE = LANGFUSE_EXPORTER_ROLE, DB owner = runtime role
SELECT CURRENT_ROLE() AS role, CURRENT_WAREHOUSE() AS wh;
SHOW SCHEMAS IN DATABASE LANGFUSE_EXPORTER;          -- expect CORE, owner LANGFUSE_EXPORTER_ROLE

-- V2: account-wide telemetry visible; expect >= 1 row per agent that has run
SELECT record_attributes:"snow.ai.observability.database.name"::string AS db,
       record_attributes:"snow.ai.observability.schema.name"::string   AS sch,
       record_attributes:"snow.ai.observability.object.name"::string   AS agent,
       COUNT(*) AS rows_, COUNT(DISTINCT trace:trace_id) AS traces
FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
WHERE record_attributes:"snow.ai.observability.object.type"::string = 'Cortex Agent'
GROUP BY 1,2,3;

-- V3: unredacted content visible; expect non-NULL, non-redacted text
SELECT LEFT(record_attributes:"ai.observability.record_root.input"::string, 120) AS input_sample
FROM SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS
WHERE record:name::string = 'AgentV2RequestResponseInfo'
  AND record_attributes:"snow.ai.observability.object.type"::string = 'Cortex Agent'
LIMIT 2;

-- V4: billing visible; expect rows for each agent request older than the view latency
SELECT request_id, agent_name, token_credits, metadata:interaction_interface::string AS iface
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
ORDER BY start_time DESC LIMIT 5;

/* =============================================================================
   TROUBLESHOOTING
     V2 error "does not exist or not authorized"  -> re-run the AI_OBSERVABILITY_READER grant.
     V3 shows redacted/NULL text                   -> re-run the READ UNREDACTED grant
                                                      (ACCOUNTADMIN only).
     V4 error on ACCOUNT_USAGE                      -> grant SNOWFLAKE.USAGE_VIEWER, or as a
                                                      fallback: GRANT IMPORTED PRIVILEGES ON
                                                      DATABASE SNOWFLAKE TO ROLE LANGFUSE_EXPORTER_ROLE;
     V4 returns 0 rows but V2 has traces           -> billing latency; re-check later.

   CLEANUP (destroys all exporter state; run only to uninstall)
     USE ROLE ACCOUNTADMIN;
     DROP DATABASE IF EXISTS LANGFUSE_EXPORTER;
     DROP WAREHOUSE IF EXISTS LANGFUSE_EXPORTER_WH;
     DROP ROLE IF EXISTS LANGFUSE_EXPORTER_ROLE;
   ========================================================================== */
