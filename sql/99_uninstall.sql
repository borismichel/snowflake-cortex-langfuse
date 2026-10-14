/* =============================================================================
   99_uninstall.sql
   Langfuse exporter - full uninstall. DESTROYS all exporter state (staged
   telemetry copies, routing config, delivery history). Source telemetry in
   SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS and data already in Langfuse are
   NOT affected.

   Run as ACCOUNTADMIN. Each statement is IF EXISTS, so partial installs are fine.
   ========================================================================== */

USE ROLE ACCOUNTADMIN;

-- 1. Stop scheduled work first
ALTER TASK IF EXISTS LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK SUSPEND;
ALTER TASK IF EXISTS LANGFUSE_EXPORTER.CORE.PUBLISH_TASK SUSPEND;

-- 2. Account-level integration(s) (not removed by DROP DATABASE)
DROP INTEGRATION IF EXISTS LANGFUSE_CLOUD_EAI;

-- 3. Database: tables, views, procedures, tasks, secrets, network rules
DROP DATABASE IF EXISTS LANGFUSE_EXPORTER;

-- 4. Warehouse and role
DROP WAREHOUSE IF EXISTS LANGFUSE_EXPORTER_WH;
DROP ROLE IF EXISTS LANGFUSE_EXPORTER_ROLE;

-- VERIFICATION: expect 0 rows each
SHOW DATABASES  LIKE 'LANGFUSE_EXPORTER';
SHOW WAREHOUSES LIKE 'LANGFUSE_EXPORTER_WH';
SHOW ROLES      LIKE 'LANGFUSE_EXPORTER_ROLE';
SHOW INTEGRATIONS LIKE 'LANGFUSE_CLOUD_EAI';

-- NOTE: Langfuse API keys stored in the secret are destroyed with the database.
-- Revoke/rotate them in Langfuse as well if they should no longer be valid.
