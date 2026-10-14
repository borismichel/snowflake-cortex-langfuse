/* =============================================================================
   05c_verify_scores.sql
   Langfuse exporter - read-only score readback (Langfuse v4 public API).
   Run as LANGFUSE_EXPORTER_ROLE after 05b. Sends nothing; GET requests only.

   CREATES: PROCEDURE VERIFY_SCORE(DESTINATION_ID, SCORE_ID)
     GET {host}/api/public/v3/scores?traceId=<trace>&fields=details,subject
     (scoreIds is NOT accepted: HTTP 400 unrecognized_keys, observed 2026-10-13)
     and compares the returned association with SCORES (persisted at send time):
     name, value, traceId, and subject = observation <root span id>.
     Response bodies are redacted of pk-lf-/sk-lf- strings before being returned.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.VERIFY_SCORE(DESTINATION_ID VARCHAR, SCORE_ID VARCHAR)
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
import re

import _snowflake
import requests

DB = "LANGFUSE_EXPORTER.CORE"
_KEY_RE = re.compile(r"\b(pk|sk)-lf-[A-Za-z0-9-]+")


def run(session, destination_id, score_id):
    exp = session.sql(
        f"SELECT host, trace_id, observation_id, name, value, project_id FROM {DB}.SCORES "
        f"WHERE destination_id = ? AND score_id = ?", params=[destination_id, score_id]).collect()
    if len(exp) != 1:
        return {"ok": False, "error": "score not in SCORES"}
    host, trace_id, obs_id, name, value, project_id = exp[0]
    cfg = session.sql(f"SELECT langfuse_host, project_id FROM {DB}.DESTINATIONS WHERE destination_id = ?",
                      params=[destination_id]).collect()
    if len(cfg) != 1 or not host or host.rstrip("/") != cfg[0][0].rstrip("/") or project_id != cfg[0][1]:
        return {"ok": False, "error": "HELD_IDENTITY_MISMATCH"}
    cred = _snowflake.get_username_password(destination_id)
    verified = requests.get(host.rstrip("/") + "/api/public/projects", auth=(cred.username, cred.password),
                            timeout=(10, 60), allow_redirects=False)
    if verified.status_code != 200 or not project_id or project_id not in [
            p.get("id") for p in verified.json().get("data", [])]:
        return {"ok": False, "error": "project verification failed"}
    r = requests.get(host.rstrip("/") + "/api/public/v3/scores",
                     params={"traceId": trace_id, "fields": "details,subject", "limit": 100},
                     auth=(cred.username, cred.password), timeout=(10, 60), allow_redirects=False)
    if r.status_code != 200:
        return {"ok": False, "http": r.status_code, "body": _KEY_RE.sub("<redacted>", r.text[:500])}
    body = r.json()
    meta = body.get("meta") or {}
    data = body.get("data") or []
    if meta.get("cursor") or meta.get("nextCursor") or body.get("cursor") or len(data) >= 100:
        return {"ok": False, "error": "potentially truncated score readback; no verification decision"}
    found = [d for d in data if d.get("id") == score_id]
    if not found:
        return {"ok": False, "http": 200, "found": 0, "scores_on_trace": len(data),
                "note": "not visible yet; retry later"}
    d = found[0]
    subject = d.get("subject") or {}
    got = {"name": d.get("name"), "value": d.get("value"),
           "traceId": d.get("traceId") or subject.get("traceId"),
           "observationId": d.get("observationId") or subject.get("id"),
           "subject_kind": subject.get("kind"), "dataType": d.get("dataType")}
    checks = {"unique": len(found) == 1, "subject_kind": got["subject_kind"] == "observation",
              "dataType": got["dataType"] == "NUMERIC", "name": got["name"] == name,
              "value": got["value"] is not None and abs(float(got["value"]) - float(value)) < 1e-12,
              "traceId": got["traceId"] == trace_id,
              "observationId": got["observationId"] == obs_id}
    return {"ok": all(checks.values()), "found": len(found), "checks": checks, "got": got,
            "expected": {"name": name, "value": value, "traceId": trace_id, "observationId": obs_id}}
$$;
