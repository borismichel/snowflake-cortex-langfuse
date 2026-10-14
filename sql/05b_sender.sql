/* =============================================================================
   05b_sender.sql
   Langfuse exporter - step 05b: sender, delivery state machine, credit scores,
   reconciliation, manual replay. Requires steps 02b, 03, 04, 05a.

   RUN AS LANGFUSE_EXPORTER_ROLE (owns LANGFUSE_CLOUD_EAI usage and the secret).

   CREATES (schema-level, LANGFUSE_EXPORTER.CORE)
     PROCEDURE PUBLISH_DESTINATION(DESTINATION_ID, MAX_ITEMS, DRY_RUN)
     PROCEDURE RECONCILE_DELIVERIES(DESTINATION_ID, MAX_ITEMS)
     PROCEDURE MARK_FOR_REPLAY(DELIVERY_ID, REASON)        -- explicit human decision
     PROCEDURE PUBLISH_ALL_DESTINATIONS()                 -- used by PUBLISH_TASK (07)

   WIRE CONTRACT - Langfuse v4 ONLY (server reported 4.58.0 on 2026-10-13 via
   LANGFUSE_CONNECTIVITY_CHECK). No v2/v3 server compatibility is provided.
   (handoff 01_LANGFUSE_CONTRACT, Langfuse docs 2026-10-13)
     Traces : POST {host}/api/public/otel/v1/traces, Content-Type application/json,
              x-langfuse-ingestion-version: 4, HTTP Basic (public key / secret key).
     Scores : POST {host}/api/public/scores, JSON, persisted id/name/timestamp,
              traceId + observationId = actual root span.
     Readback: GET {host}/api/public/v2/observations?traceId=...&fields=core,basic
     Project : GET {host}/api/public/projects must list the destination project_id.

   DELIVERY STATE MACHINE (per destination; one row per item)
     PENDING -> IN_FLIGHT (conditional UPDATE = serialized claim; attempt row is
       committed BEFORE the HTTP call) -> one of:
       ACCEPTED   2xx and OTLP partialSuccess.rejectedSpans = 0
       PARTIAL    2xx with rejectedSpans > 0     (never auto-retried; reconcile)
       RETRYABLE  connect timeout (request not sent) or HTTP 429/502/503/504,
                  bounded backoff 1/5/15/60/240 min, max_attempts per destination
       REJECTED   other 4xx; 401/403 also PAUSE the destination
       UNCERTAIN  read timeout, connection lost after send, other 5xx, or a stale
                  IN_FLIGHT claim (> 15 min: possible crash after POST).
                  Never retried automatically: RECONCILE_DELIVERIES may promote it
                  to ACCEPTED on positive readback; otherwise MARK_FOR_REPLAY.
     HTTP client retries and redirects are disabled. Accepted spans are never
     re-sent (Langfuse v4 observations are immutable; repeated ids can duplicate).

   BILLING SCORES (credits, never USD)
     snowflake.token_credits, snowflake.sql_query_credits - NUMERIC scores on the
     root observation of PUBLISHED traces, one per component as it becomes
     available. The score id is a UUIDv5 of host|project|trace|name and is stored
     in SCORES before the first send; corrections reuse id, name and timestamp.

   NOT IMPLEMENTED IN THIS VERSION (explicitly)
     - Feedback scores: no CORTEX_AGENT_FEEDBACK event has been observed yet, so
       its join cannot be proven. FEEDBACK rows stay staged and unsent.
     - Late spans after a trace is PUBLISHED are detected (LATE_SPANS_V) but not
       sent; they need a reviewed policy first.

   ADDING A DESTINATION (secret alias in SECRETS must equal destination_id)
     1. Secret in LANGFUSE_EXPORTER.CORE (03 Part B pattern, new name).
     2. ACCOUNTADMIN: ALTER EXTERNAL ACCESS INTEGRATION LANGFUSE_CLOUD_EAI SET
        ALLOWED_AUTHENTICATION_SECRETS = (<all secrets>); new host -> new network
        rule in ALLOWED_NETWORK_RULES (or a new integration added below).
     3. Add the alias to SECRETS (and integration to EXTERNAL_ACCESS_INTEGRATIONS)
        in PUBLISH_DESTINATION and RECONCILE_DELIVERIES below; re-run this file.
     4. INSERT DESTINATIONS (with project_id from LANGFUSE_CONNECTIVITY_CHECK) + ROUTES.

   RE-RUNNABLE: yes (CREATE OR REPLACE code objects only; no state changes).
   SENDS NOTHING when run: this candidate file only defines procedures/views.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

-- v1 signature (3 args) is replaced by the 4-arg version with an optional trace filter.
DROP PROCEDURE IF EXISTS LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION(VARCHAR, NUMBER, BOOLEAN);

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION(
    DESTINATION_ID VARCHAR, MAX_ITEMS NUMBER, DRY_RUN BOOLEAN, ONLY_TRACE_ID VARCHAR DEFAULT NULL)
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
import hashlib
import json
import re
import uuid

import _snowflake
import requests

DB = "LANGFUSE_EXPORTER.CORE"
OTLP_PATH = "/api/public/otel/v1/traces"
SCORES_PATH = "/api/public/scores"
RETRYABLE_HTTP = {429, 502, 503, 504}
BACKOFF_MIN = [1, 5, 15, 60, 240]
TIMEOUT = (10, 60)                      # connect, read seconds
STALE_CLAIM_MIN = 15
SCORE_NS = uuid.UUID("6f1c2a52-6b1e-4d0e-9a1e-4c616e676675")   # fixed namespace for score ids
SCORE_COMPONENTS = [("snowflake.token_credits", "token_credits", "Snowflake token credits; not USD"),
                    ("snowflake.sql_query_credits", "sql_query_credits",
                     "Snowflake warehouse credits for SQL run by this request; not USD")]


def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()


# Langfuse's ingestion acknowledgement echoes the project public key; key material
# (public or secret) is never persisted in attempt logs.
_KEY_RE = re.compile(r"\b(pk|sk)-lf-[A-Za-z0-9-]+")


def redact(text):
    return _KEY_RE.sub(lambda m: m.group(1) + "-lf-<redacted>", text or "")


def delivery_id(*parts):
    return hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()


def pause(session, destination_id, reason):
    q(session, f"UPDATE {DB}.DESTINATIONS SET paused_reason = ?, paused_at = CURRENT_TIMESTAMP(), "
               f"updated_at = CURRENT_TIMESTAMP() WHERE destination_id = ?", [reason, destination_id])


def enqueue(session, dest, host, project_id, account, item_type, item_key, trace_id, payload, event_keys):
    did = delivery_id(account, host, project_id, item_type, item_key)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    q(session,
      f"INSERT INTO {DB}.DELIVERIES (delivery_id, destination_id, item_type, item_key, trace_id, "
      f"payload_hash, status, source_account, host, project_id, payload) "
      f"SELECT ?, ?, ?, ?, ?, SHA2(?), 'PENDING', ?, ?, ?, PARSE_JSON(?) "
      f"WHERE NOT EXISTS (SELECT 1 FROM {DB}.DELIVERIES WHERE delivery_id = ?)",
      [did, dest, item_type, item_key, trace_id, body, account, host, project_id, body, did])
    for ek in event_keys:
        q(session, f"INSERT INTO {DB}.DELIVERY_ITEMS (delivery_id, event_key) SELECT ?, ? "
                   f"WHERE NOT EXISTS (SELECT 1 FROM {DB}.DELIVERY_ITEMS WHERE delivery_id = ? AND event_key = ?)",
          [did, ek, did, ek])
    return did


def classify_response(item_type, r):
    """-> (outcome, note)"""
    code = r.status_code
    if 200 <= code < 300:
        if item_type != "TRACE_BATCH":
            return "ACCEPTED", None
        try:
            ps = (r.json() or {}).get("partialSuccess") or {}
        except ValueError:
            ps = {}
        rejected = int(ps.get("rejectedSpans") or 0)
        if rejected > 0:
            return "PARTIAL", f"rejectedSpans={rejected}"
        # A partialSuccess warning with zero rejections is not a rejection.
        return "ACCEPTED", ("warning: " + ps["errorMessage"][:500]) if ps.get("errorMessage") else None
    if code in (401, 403):
        return "REJECTED", "authentication"
    if code in RETRYABLE_HTTP:
        return "RETRYABLE", None
    if 400 <= code < 500:
        return "REJECTED", None
    return "UNCERTAIN", "server error after send"


def send_one(session, dest, host, project_id, auth, max_attempts, d_id):
    # Check again at the actual send boundary, including already-queued work.
    frozen = q(session, f"SELECT destination_id, host, project_id FROM {DB}.DELIVERIES "
                       f"WHERE delivery_id = ?", [d_id])
    if len(frozen) != 1 or frozen[0][0] != dest or not frozen[0][1] or (
            frozen[0][1].rstrip("/") != host or frozen[0][2] != project_id):
        return {"delivery_id": d_id, "outcome": "HELD_IDENTITY_MISMATCH", "http": None}
    claim = str(uuid.uuid4())
    upd = q(session,
            f"UPDATE {DB}.DELIVERIES SET status = 'IN_FLIGHT', claim_id = ?, claimed_at = CURRENT_TIMESTAMP(), "
            f"attempt_count = attempt_count + 1, updated_at = CURRENT_TIMESTAMP() "
            f"WHERE delivery_id = ? AND destination_id = ? AND RTRIM(host, '/') = ? AND project_id = ? "
            f"AND status IN ('PENDING', 'RETRYABLE') "
            f"AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP())",
            [claim, d_id, dest, host, project_id])
    if not upd or upd[0][0] != 1:
        return None                          # claimed elsewhere or not due
    attempt_id = str(uuid.uuid4())
    q(session, f"INSERT INTO {DB}.DELIVERY_ATTEMPTS (attempt_id, delivery_id, started_at, state) "
               f"VALUES (?, ?, CURRENT_TIMESTAMP(), 'STARTED')", [attempt_id, d_id])
    row = q(session, f"SELECT item_type, TO_JSON(payload), attempt_count, trace_id FROM {DB}.DELIVERIES "
                     f"WHERE delivery_id = ? AND claim_id = ?", [d_id, claim])[0]
    item_type, body, attempts, trace_id = row
    url = host + (OTLP_PATH if item_type == "TRACE_BATCH" else SCORES_PATH)
    headers = {"Content-Type": "application/json"}
    if item_type == "TRACE_BATCH":
        headers["x-langfuse-ingestion-version"] = "4"

    http = excerpt = err_class = note = None
    try:
        r = requests.post(url, data=body.encode("utf-8"), headers=headers, auth=auth,
                          timeout=TIMEOUT, allow_redirects=False)
        http, excerpt = r.status_code, redact(r.text)[:2000]
        outcome, note = classify_response(item_type, r)
    except requests.exceptions.ConnectTimeout as e:      # connection never established
        outcome, err_class = "RETRYABLE", type(e).__name__
    except Exception as e:                               # may have been sent
        outcome, err_class, note = "UNCERTAIN", type(e).__name__, "no response after send"

    if outcome == "RETRYABLE" and attempts >= max_attempts:
        outcome, note = "REJECTED", f"max_attempts {max_attempts} reached"
    backoff = BACKOFF_MIN[min(attempts - 1, len(BACKOFF_MIN) - 1)]
    last_error = "; ".join(x for x in (err_class, note) if x) or None

    q(session, f"UPDATE {DB}.DELIVERY_ATTEMPTS SET finished_at = CURRENT_TIMESTAMP(), state = 'FINISHED', "
               f"http_status = ?, outcome = ?, response_excerpt = ?, error_class = ? WHERE attempt_id = ?",
      [http, outcome, excerpt, err_class, attempt_id])
    q(session, f"UPDATE {DB}.DELIVERIES SET status = ?, last_http_status = ?, last_error = ?, "
               f"next_attempt_at = IFF(? = 'RETRYABLE', DATEADD(minute, ?, CURRENT_TIMESTAMP()), NULL), "
               f"updated_at = CURRENT_TIMESTAMP() WHERE delivery_id = ? AND claim_id = ?",
      [outcome, http, last_error, outcome, backoff, d_id, claim])
    if item_type == "TRACE_BATCH" and outcome in ("ACCEPTED", "PARTIAL"):
        q(session, f"UPDATE {DB}.TRACES SET trace_status = ?, updated_at = CURRENT_TIMESTAMP() "
                   f"WHERE trace_id = ?", ["PUBLISHED" if outcome == "ACCEPTED" else "PARTIAL", trace_id])
    if http in (401, 403):
        pause(session, dest, f"authentication failed HTTP {http}")
    return {"delivery_id": d_id, "item_type": item_type, "outcome": outcome, "http": http, "note": last_error}


def run(session, destination_id, max_items, dry_run, only_trace_id=None):
    max_items = int(max_items or 20)
    d = q(session, f"SELECT langfuse_host, project_id, enabled, paused_reason, COALESCE(max_attempts, 5) "
                   f"FROM {DB}.DESTINATIONS WHERE destination_id = ?", [destination_id])
    if len(d) != 1:
        return {"ok": False, "error": "unknown or duplicate destination", "destination_id": destination_id}
    host_cfg, project_id, enabled, paused, max_attempts = d[0]
    host = host_cfg.rstrip("/")
    out = {"destination_id": destination_id, "host": host, "project_id": project_id,
           "dry_run": bool(dry_run), "only_trace_id": only_trace_id}
    if not enabled or paused:
        return {**out, "ok": False, "skipped": True, "reason": paused or "disabled"}
    if not project_id:
        return {**out, "ok": False, "error": "destination has no verified project_id"}
    try:
        cred = _snowflake.get_username_password(destination_id)
    except Exception as e:
        return {**out, "ok": False, "error": f"no secret bound for alias {destination_id}: {type(e).__name__}"}
    auth = (cred.username, cred.password)

    # 1. Credentials must resolve to the frozen project (no silent project switch).
    try:
        r = requests.get(host + "/api/public/projects", auth=auth, timeout=TIMEOUT, allow_redirects=False)
    except Exception as e:
        return {**out, "ok": False, "error": "project check failed: " + type(e).__name__}
    if r.status_code in (401, 403):
        if not dry_run:
            pause(session, destination_id, f"authentication failed HTTP {r.status_code}")
        return {**out, "ok": False, "error": f"authentication failed HTTP {r.status_code}"}
    if r.status_code != 200:
        return {**out, "ok": False, "error": f"project check HTTP {r.status_code}"}
    if project_id not in [p.get("id") for p in r.json().get("data", [])]:
        if not dry_run:
            pause(session, destination_id, "credentials resolve to a different Langfuse project")
        return {**out, "ok": False, "error": "credentials resolve to a different Langfuse project"}
    out["project_verified"] = True
    account = q(session, "SELECT CURRENT_ACCOUNT()")[0][0]
    # Optional single-trace filter. Added only when given: binding Python None into
    # a NULL-check placeholder did not match as SQL NULL here (observed 2026-10-13).
    tf_t = "AND t.trace_id = ? " if only_trace_id else ""
    tf = "AND trace_id = ? " if only_trace_id else ""
    tp = [only_trace_id] if only_trace_id else []

    # A held delivery remains in its current state; restoring the original identity
    # permits normal recovery. Never rewrite its frozen host/project or payload.
    mismatches = q(session,
        f"SELECT delivery_id FROM {DB}.DELIVERIES WHERE destination_id = ? "
        f"AND status IN ('PENDING', 'RETRYABLE') {tf}"
        f"AND (host IS NULL OR project_id IS NULL OR RTRIM(host, '/') <> ? OR project_id <> ?)",
        [destination_id] + tp + [host, project_id])
    if mismatches:
        return {**out, "ok": False, "error": "HELD_IDENTITY_MISMATCH",
                "held_delivery_ids": [r[0] for r in mismatches]}

    # 2. Stale claims -> UNCERTAIN (a crash may have happened after the POST).
    if not dry_run:
        q(session, f"UPDATE {DB}.DELIVERIES SET status = 'UNCERTAIN', "
                   f"last_error = 'stale IN_FLIGHT claim: possible crash after send', updated_at = CURRENT_TIMESTAMP() "
                   f"WHERE destination_id = ? AND status = 'IN_FLIGHT' "
                   f"AND claimed_at < DATEADD(minute, -{STALE_CLAIM_MIN}, CURRENT_TIMESTAMP())", [destination_id])

    # 3. Enqueue READY traces routed to exactly this host/project (frozen snapshot).
    ready = q(session,
              f"SELECT t.trace_id FROM {DB}.TRACES t "
              f"WHERE t.destination_id = ? AND t.route_status = 'ROUTED' AND t.trace_status = 'READY' "
              f"AND RTRIM(t.frozen_host, '/') = ? AND t.frozen_project_id = ? "
              f"{tf_t}"
              f"AND NOT EXISTS (SELECT 1 FROM {DB}.DELIVERIES x WHERE x.destination_id = t.destination_id "
              f"AND x.item_type = 'TRACE_BATCH' AND x.item_key = t.trace_id) "
              f"ORDER BY t.trace_end_utc LIMIT {max_items}",
              [destination_id, host, project_id] + tp)
    queued, previews = [], []
    for (trace_id,) in ready:
        built = session.call(f"{DB}.BUILD_TRACE_PAYLOAD", trace_id, True)
        built = json.loads(built) if isinstance(built, str) else built
        if not built.get("ok") or built.get("trace_status") != "READY":
            previews.append({"trace_id": trace_id, "skipped": built.get("error") or built.get("trace_status")})
            continue
        if dry_run:
            previews.append({"trace_id": trace_id, "n_spans": built["n_spans"],
                             "payload_bytes": built["payload_bytes"],
                             "observation_types": built["observation_types"]})
            continue
        queued.append(enqueue(session, destination_id, host, project_id, account, "TRACE_BATCH",
                              trace_id, trace_id, built["payload"], built["event_keys"]))

    # 4. Enqueue credit scores for PUBLISHED traces, per available component.
    score_rows = q(session,
                   f"SELECT t.trace_id, t.root_span_id, t.request_id, "
                   f"TO_VARCHAR(t.trace_end_utc, 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"'), "
                   f"b.token_credits::FLOAT, b.sql_query_credits::FLOAT "
                   f"FROM {DB}.TRACES t JOIN {DB}.BILLING b ON b.request_id = t.request_id "
                   f"WHERE t.destination_id = ? AND t.trace_status = 'PUBLISHED' "
                   f"AND RTRIM(t.frozen_host, '/') = ? AND t.frozen_project_id = ? "
                   f"{tf_t}",
                   [destination_id, host, project_id] + tp)
    scores_new = 0
    for trace_id, root_id, request_id, ts, token_credits, sql_credits in score_rows:
        values = {"token_credits": token_credits, "sql_query_credits": sql_credits}
        for name, col, comment in SCORE_COMPONENTS:
            if values[col] is None:
                continue                       # pending / not applicable: no score yet
            sid = str(uuid.uuid5(SCORE_NS, f"{host}|{project_id}|{trace_id}|{name}"))
            if q(session, f"SELECT 1 FROM {DB}.SCORES WHERE score_id = ?", [sid]):
                continue
            if dry_run:
                previews.append({"score": name, "trace_id": trace_id, "value": values[col]})
                continue
            q(session, f"INSERT INTO {DB}.SCORES (score_id, destination_id, host, project_id, trace_id, "
                       f"observation_id, name, data_type, value, score_ts, comment, source_ref) "
                       f"VALUES (?, ?, ?, ?, ?, ?, ?, 'NUMERIC', ?, ?, ?, ?)",
              [sid, destination_id, host, project_id, trace_id, root_id, name, values[col], ts, comment, request_id])
            scores_new += 1

    # Repair the crash gap between persisting a score and creating its delivery.
    # Reconstruct only from saved fields, never refreshed billing or a new timestamp.
    recovered_scores = 0
    if not dry_run:
        orphan_scores = q(session,
            f"SELECT s.score_id, s.trace_id, s.observation_id, s.name, s.value, s.data_type, s.score_ts, s.comment "
            f"FROM {DB}.SCORES s WHERE s.destination_id = ? AND RTRIM(s.host, '/') = ? AND s.project_id = ? "
            + ("AND s.trace_id = ? " if only_trace_id else "") +
            f"AND NOT EXISTS (SELECT 1 FROM {DB}.DELIVERIES d WHERE d.destination_id = s.destination_id "
            f"AND d.item_type = 'BILLING_SCORE' AND d.item_key = s.score_id)",
            [destination_id, host, project_id] + tp)
        for sid, trace_id, obs_id, name, value, dtype, ts, comment in orphan_scores:
            payload = {"id": sid, "traceId": trace_id, "observationId": obs_id, "name": name,
                       "value": value, "dataType": dtype, "timestamp": ts, "comment": comment}
            enqueue(session, destination_id, host, project_id, account, "BILLING_SCORE", sid, trace_id, payload, [])
            recovered_scores += 1
    out["ensured_score_deliveries"] = recovered_scores

    out["previews" if dry_run else "queued_traces"] = previews if dry_run else len(queued)
    out["queued_scores"] = scores_new
    if dry_run:
        return {**out, "ok": True}

    # 5. Send due deliveries (oldest first). Trace batches before scores.
    due = q(session,
            f"SELECT delivery_id FROM {DB}.DELIVERIES WHERE destination_id = ? "
            f"AND status IN ('PENDING', 'RETRYABLE') "
            f"AND (next_attempt_at IS NULL OR next_attempt_at <= CURRENT_TIMESTAMP()) "
            f"{tf}"
            f"ORDER BY IFF(item_type = 'TRACE_BATCH', 0, 1), created_at LIMIT {max_items}",
            [destination_id] + tp)
    results = []
    for (d_id,) in due:
        res = send_one(session, destination_id, host, project_id, auth, max_attempts, d_id)
        if res:
            results.append(res)
            if res["http"] in (401, 403):
                break                           # destination paused; stop
    out["sent"] = results
    return {**out, "ok": not any(r.get("outcome") == "HELD_IDENTITY_MISMATCH" for r in results)}
$$;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.RECONCILE_DELIVERIES(DESTINATION_ID VARCHAR, MAX_ITEMS NUMBER)
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
from collections import Counter

import _snowflake
import requests

DB = "LANGFUSE_EXPORTER.CORE"
TIMEOUT = (10, 60)
MAX_PAGES = 20


def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()


def read_observations(host, auth, trace_id, start_iso, end_iso):
    """All pages of v2 observations for one trace -> Counter(id), first page shape."""
    ids, cursor, pages = Counter(), None, 0
    while pages < MAX_PAGES:
        params = {"traceId": trace_id, "fields": "core,basic", "limit": 100,
                  "fromStartTime": start_iso, "toStartTime": end_iso}
        if cursor:
            params["cursor"] = cursor
        r = requests.get(host + "/api/public/v2/observations", params=params, auth=auth,
                         timeout=TIMEOUT, allow_redirects=False)
        if r.status_code != 200:
            return None, f"HTTP {r.status_code}"
        body = r.json()
        for o in body.get("data", []):
            ids[o.get("id")] += 1
        meta = body.get("meta") or {}
        cursor = meta.get("cursor") or meta.get("nextCursor") or body.get("cursor")
        pages += 1
        if not cursor or not body.get("data"):
            break
    if cursor:
        return None, "incomplete pagination; no reconciliation decision"
    return ids, None


def run(session, destination_id, max_items):
    d = q(session, f"SELECT langfuse_host, project_id FROM {DB}.DESTINATIONS WHERE destination_id = ?",
          [destination_id])
    if len(d) != 1:
        return {"ok": False, "error": "unknown or duplicate destination"}
    host = d[0][0].rstrip("/")
    project_id = d[0][1]
    cred = _snowflake.get_username_password(destination_id)
    auth = (cred.username, cred.password)
    verified = requests.get(host + "/api/public/projects", auth=auth, timeout=TIMEOUT, allow_redirects=False)
    if verified.status_code != 200 or not project_id or project_id not in [
            p.get("id") for p in verified.json().get("data", [])]:
        return {"ok": False, "error": "project verification failed"}
    rows = q(session,
             f"SELECT d.delivery_id, d.status, d.trace_id, TO_JSON(d.payload), d.host, d.project_id, "
             f"TO_VARCHAR(DATEADD(minute, -1, t.trace_start_utc), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"'), "
             f"TO_VARCHAR(DATEADD(minute, 1, t.trace_end_utc), 'YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\"') "
             f"FROM {DB}.DELIVERIES d JOIN {DB}.TRACES t ON t.trace_id = d.trace_id "
             f"WHERE d.destination_id = ? AND d.item_type = 'TRACE_BATCH' "
             f"AND (d.status IN ('UNCERTAIN', 'PARTIAL') OR (d.status = 'ACCEPTED' AND d.reconciled_at IS NULL)) "
             f"ORDER BY d.updated_at LIMIT {int(max_items or 20)}", [destination_id])
    results = []
    for d_id, status, trace_id, payload, frozen_host, frozen_project, start_iso, end_iso in rows:
        if not frozen_host or frozen_host.rstrip("/") != host or frozen_project != project_id:
            results.append({"delivery_id": d_id, "error": "HELD_IDENTITY_MISMATCH"})
            continue
        payload = json.loads(payload)
        expected = Counter(sp["spanId"] for rs in payload["resourceSpans"]
                           for ss in rs["scopeSpans"] for sp in ss["spans"])
        found, err = read_observations(host, auth, trace_id, start_iso, end_iso)
        if err:
            results.append({"delivery_id": d_id, "error": err})
            continue
        missing = sorted(k for k in expected if found.get(k, 0) == 0)
        duplicated = sorted(k for k, n in found.items() if n > 1)
        unexpected = sorted(k for k in found if k not in expected)
        complete = bool(expected) and not missing and not duplicated and not unexpected
        result = {"expected": len(expected), "found_distinct": len(found), "missing": missing,
                  "duplicated": duplicated, "unexpected": unexpected, "complete": complete}
        # Positive evidence may promote UNCERTAIN/PARTIAL; missing rows are NOT proof of absence.
        new_status = "ACCEPTED" if complete else status
        q(session, f"UPDATE {DB}.DELIVERIES SET reconciled_at = IFF(?, CURRENT_TIMESTAMP(), reconciled_at), "
                   f"reconcile_result = PARSE_JSON(?), status = ?, updated_at = CURRENT_TIMESTAMP() "
                   f"WHERE delivery_id = ?", [complete, json.dumps(result), new_status, d_id])
        if complete:
            q(session, f"UPDATE {DB}.TRACES SET trace_status = 'PUBLISHED', updated_at = CURRENT_TIMESTAMP() "
                       f"WHERE trace_id = ?", [trace_id])
        results.append({"delivery_id": d_id, "trace_id": trace_id, "status_before": status,
                        "status_after": new_status, **result})
    return {"ok": not any(r.get("error") for r in results), "destination_id": destination_id, "reconciled": results}
$$;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.MARK_FOR_REPLAY(DELIVERY_ID VARCHAR, REASON VARCHAR)
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
BEGIN
  -- Explicit human decision after reviewing RECONCILE_DELIVERIES output.
  -- Replaying an UNCERTAIN item can create duplicate observations in Langfuse.
  UPDATE LANGFUSE_EXPORTER.CORE.DELIVERIES
     SET status = 'RETRYABLE', next_attempt_at = NULL,
         last_error = 'manual replay: ' || :REASON, updated_at = CURRENT_TIMESTAMP()
   WHERE delivery_id = :DELIVERY_ID AND status IN ('UNCERTAIN', 'REJECTED');
  RETURN 'rows updated: ' || SQLROWCOUNT;
END;
$$;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.PUBLISH_ALL_DESTINATIONS()
  RETURNS VARIANT
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  results ARRAY DEFAULT ARRAY_CONSTRUCT();
  r VARIANT;
  c CURSOR FOR SELECT destination_id FROM LANGFUSE_EXPORTER.CORE.DESTINATIONS
                WHERE enabled AND paused_reason IS NULL ORDER BY destination_id;
BEGIN
  FOR d IN c DO
    BEGIN
      LET dest VARCHAR := d.destination_id;
      CALL LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION(:dest, 20, FALSE) INTO :r;
      results := ARRAY_APPEND(results, OBJECT_CONSTRUCT('destination_id', dest, 'result', r));
    EXCEPTION
      WHEN OTHER THEN   -- one failing destination must not stop the others
        results := ARRAY_APPEND(results, OBJECT_CONSTRUCT('destination_id', d.destination_id,
                                                          'error', SQLERRM));
    END;
  END FOR;
  RETURN results;
END;
$$;

CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.LATE_SPANS_V AS
SELECT s.trace_id, s.span_id, s.record_name, s.staged_at, t.trace_status
  FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS s
  JOIN LANGFUSE_EXPORTER.CORE.TRACES t ON t.trace_id = s.trace_id
 WHERE s.record_type = 'SPAN' AND t.trace_status IN ('PUBLISHED', 'PARTIAL')
   AND s.event_key NOT IN (SELECT event_key FROM LANGFUSE_EXPORTER.CORE.OMITTED_SPANS_V)
   AND NOT EXISTS (SELECT 1 FROM LANGFUSE_EXPORTER.CORE.DELIVERY_ITEMS i
                     JOIN LANGFUSE_EXPORTER.CORE.DELIVERIES d ON d.delivery_id = i.delivery_id
                    WHERE d.trace_id = s.trace_id AND i.event_key = s.event_key);

-- Definitions only; no staging, sending or dry-run calls during installation.
