/* =============================================================================
   05d_verify_semantics.sql
   Langfuse exporter - semantic readback of delivered traces (Langfuse v4).
   Run as LANGFUSE_EXPORTER_ROLE after 05b. GET requests only; sends nothing.

   CREATES: PROCEDURE VERIFY_TRACE_SEMANTICS(DESTINATION_ID, TRACE_ID)
     GET {host}/api/public/v2/observations?traceId=...&fields=core,basic,io,metadata
     (all pages) and checks, per observation, against the frozen payload in
     DELIVERIES (what we sent) and against chat-semantics rules:
       S1 every sent span id present exactly once
       S2 observation type matches langfuse.observation.type sent
       S3 generation input is a list of role-typed messages (not raw strings)
       S4 no user message content starts with <system-reminder>
       S5 role sequence of input equals the sent sequence (assistant history kept)
       S6 generation output never carries tool arguments as assistant content
          (tool selections must be in tool_calls)
       S7 root input/output equal the clean question/answer sent
       S8 exporter_mapping_version present in the SENT payload (not remote metadata)
     The ID-count reconciliation (RECONCILE_DELIVERIES, fields=core,basic) cannot
     detect S3-S7; this procedure exists for that reason.
     Response content is not returned in full: only roles, lengths and short
     heads; pk-lf-/sk-lf- strings are redacted.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.VERIFY_TRACE_SEMANTICS(DESTINATION_ID VARCHAR, TRACE_ID VARCHAR)
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
import json
import re
from collections import Counter

import _snowflake
import requests

DB = "LANGFUSE_EXPORTER.CORE"
_KEY_RE = re.compile(r"\b(pk|sk)-lf-[A-Za-z0-9-]+")
REMINDER = "<system-reminder>"


def as_obj(v):
    if isinstance(v, str):
        try:
            return json.loads(v)
        except ValueError:
            return v
    return v


def roles(msgs):
    if not isinstance(msgs, list):
        return None
    out = []
    for m in msgs:
        if not isinstance(m, dict) or not isinstance(m.get("role"), str):
            return None
        out.append(m["role"] + ("+tool_calls" if m.get("tool_calls") else ""))
    return out


def head(v, n=60):
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return _KEY_RE.sub("<redacted>", (s or "")[:n])


def attr_map(span):
    out = {}
    for a in span.get("attributes", []):
        v = a.get("value", {})
        out[a["key"]] = v.get("stringValue", v.get("intValue", v.get("boolValue", v.get("doubleValue"))))
    return out


def read_all(host, auth, trace_id):
    obs, cursor = [], None
    for _ in range(20):
        params = {"traceId": trace_id, "fields": "core,basic,io,metadata", "limit": 100}
        if cursor:
            params["cursor"] = cursor
        r = requests.get(host + "/api/public/v2/observations", params=params, auth=auth,
                         timeout=(10, 60), allow_redirects=False)
        if r.status_code != 200:
            return None, f"HTTP {r.status_code}: {_KEY_RE.sub('<redacted>', r.text[:300])}"
        body = r.json()
        obs.extend(body.get("data", []))
        meta = body.get("meta") or {}
        cursor = meta.get("cursor") or meta.get("nextCursor") or body.get("cursor")
        if not cursor or not body.get("data"):
            break
    if cursor:
        return None, "incomplete pagination; no verification decision"
    return obs, None


def run(session, destination_id, trace_id):
    d = session.sql(f"SELECT langfuse_host, project_id FROM {DB}.DESTINATIONS WHERE destination_id = ?",
                    params=[destination_id]).collect()
    row = session.sql(f"SELECT TO_JSON(payload), host, project_id FROM {DB}.DELIVERIES WHERE destination_id = ? "
                      f"AND item_type = 'TRACE_BATCH' AND trace_id = ? AND status = 'ACCEPTED'",
                      params=[destination_id, trace_id]).collect()
    if len(d) != 1 or len(row) != 1:
        return {"ok": False, "error": "no ACCEPTED delivery for this trace/destination"}
    host = d[0][0].rstrip("/")
    project_id = d[0][1]
    if not row[0][1] or row[0][1].rstrip("/") != host or row[0][2] != project_id:
        return {"ok": False, "error": "HELD_IDENTITY_MISMATCH"}
    payload = json.loads(row[0][0])
    sent = {}
    for rs in payload["resourceSpans"]:
        for ss in rs["scopeSpans"]:
            for sp in ss["spans"]:
                sent[sp["spanId"]] = {"name": sp["name"], "attrs": attr_map(sp)}
    cred = _snowflake.get_username_password(destination_id)
    verified = requests.get(host + "/api/public/projects", auth=(cred.username, cred.password),
                            timeout=(10, 60), allow_redirects=False)
    if verified.status_code != 200 or not project_id or project_id not in [
            p.get("id") for p in verified.json().get("data", [])]:
        return {"ok": False, "error": "project verification failed"}
    obs, err = read_all(host, (cred.username, cred.password), trace_id)
    if err:
        return {"ok": False, "error": err}

    counts = Counter(o.get("id") for o in obs)
    by_id = {o.get("id"): o for o in obs}
    failures, details = [], []
    missing = [k for k in sent if counts.get(k, 0) == 0]
    dup = [k for k, n in counts.items() if n > 1]
    unexpected = sorted(set(counts) - set(sent))
    if not sent or missing or dup or unexpected:
        failures.append({"check": "S1", "missing": missing, "duplicated": dup, "unexpected": unexpected})
    mapping_version = None
    for sid, s in sent.items():
        o = by_id.get(sid)
        if not o:
            continue
        a = s["attrs"]
        typ_sent = a.get("langfuse.observation.type")
        typ_got = (o.get("type") or "").lower()
        if typ_sent and typ_got != typ_sent:
            failures.append({"check": "S2", "span": s["name"], "sent": typ_sent, "got": typ_got})
        if a.get("langfuse.trace.metadata.exporter_mapping_version"):
            mapping_version = a["langfuse.trace.metadata.exporter_mapping_version"]
        inp_got, out_got = as_obj(o.get("input")), as_obj(o.get("output"))
        info = {"span": s["name"], "type": typ_got}
        if typ_sent == "generation":
            r_got = roles(inp_got)
            r_sent = roles(as_obj(a.get("langfuse.observation.input")))
            info["input_roles"] = r_got
            if inp_got is not None and r_got is None:
                failures.append({"check": "S3", "span": s["name"], "input_head": head(inp_got)})
            if isinstance(inp_got, list):
                bad = [i for i, m in enumerate(inp_got) if isinstance(m, dict) and m.get("role") == "user"
                       and isinstance(m.get("content"), str) and m["content"].lstrip().startswith(REMINDER)]
                if bad:
                    failures.append({"check": "S4", "span": s["name"], "user_indexes": bad})
            if r_sent is not None and r_got != r_sent:
                failures.append({"check": "S5", "span": s["name"], "sent": r_sent, "got": r_got})
            for field, got in (("input", inp_got), ("output", out_got)):
                if as_obj(a.get("langfuse.observation." + field)) != got:
                    failures.append({"check": "S5_CONTENT", "span": s["name"], "field": field})
            sel_vals = a.get("snow.ai.observability.agent.planning.tool_selection.argument.value")
            content = out_got.get("content") if isinstance(out_got, dict) else out_got
            # v2 sent the raw tool-argument array (as JSON text) as the output itself.
            if sel_vals and content is not None and (
                    content == sel_vals or as_obj(sel_vals) == content
                    or (isinstance(content, str) and content in sel_vals)):
                failures.append({"check": "S6", "span": s["name"], "output_head": head(content)})
            info["output_kind"] = ("tool_calls" if isinstance(out_got, dict) and out_got.get("tool_calls")
                                   else type(out_got).__name__)
        if typ_sent == "agent":
            for k, got in (("input", inp_got), ("output", out_got)):
                exp = a.get("langfuse.observation." + k)
                if exp is not None and (got if isinstance(got, str) else json.dumps(got)) != exp:
                    failures.append({"check": "S7", "field": k, "sent_head": head(exp), "got_head": head(got)})
            info["input_head"], info["output_head"] = head(inp_got), head(out_got)
        details.append(info)
    if mapping_version is None:
        failures.append({"check": "S8", "note": "no exporter_mapping_version in sent payload"})
    return {"ok": not failures, "trace_id": trace_id, "mapping_version_sent": mapping_version,
            "n_sent": len(sent), "n_returned": len(obs), "failures": failures, "observations": details}
$$;

/* VERIFICATION
   On a v2 trace (sent before the fix) expect ok false with S3/S5 failures:
     CALL VERIFY_TRACE_SEMANTICS('LANGFUSE_TEST', '<your-trace-id>');
   On a v3 trace expect ok true, failures []:
     CALL VERIFY_TRACE_SEMANTICS('LANGFUSE_TEST', '<fresh_v3_trace_id>');

   CLEANUP: DROP PROCEDURE IF EXISTS LANGFUSE_EXPORTER.CORE.VERIFY_TRACE_SEMANTICS(VARCHAR, VARCHAR); */
