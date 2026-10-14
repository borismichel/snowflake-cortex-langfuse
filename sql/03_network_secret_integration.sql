/* =============================================================================
   03_network_secret_integration.sql
   Langfuse exporter - step 03: network rule, credentials secret, external
   access integration, connectivity check

   PREREQUISITES
     - Steps 01 and 02 VERIFIED.
     - Langfuse project API keys (public key "pk-lf-...", secret key "sk-lf-...")
       from Langfuse > Project settings > API keys.

   OBJECTS
     Schema-level (owned by LANGFUSE_EXPORTER_ROLE, in LANGFUSE_EXPORTER.CORE):
       NETWORK RULE  LANGFUSE_CLOUD_EGRESS      (cloud.langfuse.com:443)
       SECRET        LANGFUSE_TEST_CREDENTIALS  (TYPE=PASSWORD: username=public key, password=secret key)
       PROCEDURE     LANGFUSE_CONNECTIVITY_CHECK(destination_id)
     Account-level (created by ACCOUNTADMIN):
       EXTERNAL ACCESS INTEGRATION LANGFUSE_CLOUD_EAI

   CREDENTIAL HANDLING - READ FIRST
     This file never contains real keys. Part B is run in a SEPARATE, temporary
     worksheet: paste it, replace the two placeholders, run it, then delete
     that worksheet. Do not paste keys into this file, chat, or tickets.

   RUN ORDER
     1. Part B FIRST, in a temporary worksheet (secret).
     2. Then Run All on this file: Part A (network rule), Part C (integration,
        as ACCOUNTADMIN), Part D (check procedure + verification).
     Part B's secret alias in the procedures equals the destination_id
     ('LANGFUSE_TEST'), which is how a procedure finds a destination's keys.
   ========================================================================== */

/* ---------------------------------------------------------------------------
   PART A - network rule (schema-level)
   ------------------------------------------------------------------------- */
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE NETWORK RULE IF NOT EXISTS LANGFUSE_CLOUD_EGRESS
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('cloud.langfuse.com:443')
  COMMENT = 'Egress to Langfuse Cloud';

/* ---------------------------------------------------------------------------
   PART B - secret. COPY THESE 3 LINES INTO A NEW TEMPORARY WORKSHEET.
   Replace the placeholders there, run, then delete that worksheet.
   (Kept commented here so this file never holds credentials.)

   USE ROLE LANGFUSE_EXPORTER_ROLE;
   CREATE OR REPLACE SECRET LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS
     TYPE = PASSWORD USERNAME = '<LANGFUSE_PUBLIC_KEY>' PASSWORD = '<LANGFUSE_SECRET_KEY>'
     COMMENT = 'Langfuse project LANGFUSE_TEST: username=public key, password=secret key';

   Key rotation: re-run the same statement with new keys (same name; no other change).
   ------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   PART C - external access integration (account-level). Run AFTER Part B.
   ------------------------------------------------------------------------- */
USE ROLE ACCOUNTADMIN;

-- If Part B was run with ACCOUNTADMIN selected, the secret is owned by
-- ACCOUNTADMIN; the procedures (owner's rights) need the runtime role to own it.
-- Safe to run when the runtime role already owns it.
GRANT OWNERSHIP ON SECRET LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS
  TO ROLE LANGFUSE_EXPORTER_ROLE COPY CURRENT GRANTS;

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS LANGFUSE_CLOUD_EAI
  ALLOWED_NETWORK_RULES = (LANGFUSE_EXPORTER.CORE.LANGFUSE_CLOUD_EGRESS)
  ALLOWED_AUTHENTICATION_SECRETS = (LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS)
  ENABLED = TRUE
  COMMENT = 'Langfuse exporter egress to cloud.langfuse.com';

GRANT USAGE ON INTEGRATION LANGFUSE_CLOUD_EAI TO ROLE LANGFUSE_EXPORTER_ROLE;

/* ---------------------------------------------------------------------------
   PART D - connectivity check procedure (schema-level)
   Calls GET /api/public/health (no auth) and GET /api/public/projects (Basic
   auth with the secret). Returns status codes and the project id/name only.
   The secret is never returned or logged.
   ------------------------------------------------------------------------- */
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE PROCEDURE LANGFUSE_CONNECTIVITY_CHECK(DESTINATION_ID VARCHAR)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (LANGFUSE_CLOUD_EAI)
  SECRETS = ('LANGFUSE_TEST' = LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS)
  EXECUTE AS OWNER
AS
$$
import requests
import _snowflake

def run(session, destination_id):
    rows = session.sql(
        "SELECT langfuse_host FROM LANGFUSE_EXPORTER.CORE.DESTINATIONS WHERE destination_id = ?",
        params=[destination_id]).collect()
    if not rows:
        return {"ok": False, "error": f"unknown destination {destination_id}"}
    host = rows[0][0].rstrip("/")
    out = {"destination_id": destination_id, "host": host}
    try:
        r = requests.get(f"{host}/api/public/health", timeout=15)
        out["health_status"] = r.status_code
        out["health_body"] = r.text[:300]
    except Exception as e:
        out["health_error"] = type(e).__name__
    try:
        cred = _snowflake.get_username_password(destination_id)
        r = requests.get(f"{host}/api/public/projects",
                         auth=(cred.username, cred.password), timeout=15)
        out["auth_status"] = r.status_code
        if r.ok:
            data = r.json().get("data", [])
            out["projects"] = [{"id": p.get("id"), "name": p.get("name")} for p in data]
        else:
            out["auth_body"] = r.text[:300]
    except Exception as e:
        out["auth_error"] = type(e).__name__
    out["ok"] = out.get("health_status") == 200 and out.get("auth_status") == 200
    return out
$$;

/* =============================================================================
   VERIFICATION (expected results in comments)
   ========================================================================== */
-- V1: expect 1 row, VALUE_LIST cloud.langfuse.com:443
SHOW NETWORK RULES LIKE 'LANGFUSE_CLOUD_EGRESS' IN SCHEMA LANGFUSE_EXPORTER.CORE;
-- V2: expect 1 row, secret_type PASSWORD, owner LANGFUSE_EXPORTER_ROLE (values are never shown)
SHOW SECRETS LIKE 'LANGFUSE_TEST_CREDENTIALS' IN SCHEMA LANGFUSE_EXPORTER.CORE;
-- V3: expect 1 row, enabled true
SHOW INTEGRATIONS LIKE 'LANGFUSE_CLOUD_EAI';
-- V4: expect {"ok": true, "health_status": 200, "auth_status": 200, "projects": [{id, name}]}
CALL LANGFUSE_CONNECTIVITY_CHECK('LANGFUSE_TEST');

/* =============================================================================
   TROUBLESHOOTING
     Part C "secret does not exist"     -> Part B not run (or run in another schema).
     CREATE PROCEDURE "not authorized"  -> Part C GRANT USAGE not run.
     V4 health_error ConnectionError     -> network rule host/port wrong.
     V4 auth_status 401                  -> wrong keys or keys swapped; re-run Part B.
     V4 auth_status 403/404              -> wrong region host for this project
                                            (EU = cloud.langfuse.com,
                                             US = us.cloud.langfuse.com).

   ADDING ANOTHER DESTINATION (summary; full steps in step 05 notes)
     Same host : new secret (Part B, new name) ->
                 ALTER EXTERNAL ACCESS INTEGRATION LANGFUSE_CLOUD_EAI SET
                   ALLOWED_AUTHENTICATION_SECRETS = (<existing>, <new>);  -- ACCOUNTADMIN
                 add the secret to the procedures' SECRETS list (re-create them);
                 INSERT into DESTINATIONS + ROUTES.
     New host  : additionally a new NETWORK RULE, and either add it to
                 ALLOWED_NETWORK_RULES or create a new integration and add it to
                 the procedures' EXTERNAL_ACCESS_INTEGRATIONS.

   CLEANUP
     USE ROLE ACCOUNTADMIN;  DROP INTEGRATION IF EXISTS LANGFUSE_CLOUD_EAI;
     USE ROLE LANGFUSE_EXPORTER_ROLE;
     DROP PROCEDURE IF EXISTS LANGFUSE_EXPORTER.CORE.LANGFUSE_CONNECTIVITY_CHECK(VARCHAR);
     DROP SECRET IF EXISTS LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS;
     DROP NETWORK RULE IF EXISTS LANGFUSE_EXPORTER.CORE.LANGFUSE_CLOUD_EGRESS;
   ========================================================================== */
