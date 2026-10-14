/* =============================================================================
   05a_payload_builder.sql
   Langfuse exporter - step 05a: build the OTLP/JSON payload for one staged trace.
   NO network access; sends nothing. Step 05b (sender) reuses this procedure.

   PREREQUISITES
     - Step 04 VERIFIED (STAGED_EVENTS / TRACES populated).
     - 05_message_normalizer.sql run first (FUNCTION NORMALIZE_GENERATION_IO).
     - Run as LANGFUSE_EXPORTER_ROLE.

   MAPPING VERSION 3 (2026-10-13): generation input/output are role-typed chat
     messages from NORMALIZE_GENERATION_IO - Snowflake "User:"/"Assistant:" prefixes
     become roles, injected <system-reminder> blocks become system messages, tool
     results become tool messages, tool selections become assistant tool_calls.
     v2 exported the raw prefixed string array (all shown as user messages) and used
     tool arguments as generation output; traces already sent with v2 keep that
     form in Langfuse (observations are immutable) - see STATUS.md remediation.

   CREATES (schema-level): PROCEDURE BUILD_TRACE_PAYLOAD(TRACE_ID, INCLUDE_PAYLOAD)

   MAPPING RULES (source is never altered)
     - One OTLP span per staged SPAN row: traceId, spanId, parentSpanId, name, kind,
       start/end timestamps and status are copied exactly. Duplicate span ids and
       end-before-start timestamps are NOT corrected (step 04 holds such traces).
     - Every source record_attribute is forwarded unchanged as an OTLP attribute.
       Resource attributes and instrumentation scope are forwarded per span group.
     - CORTEX_AGENT_REQUEST rows become span EVENTS on the root span, never spans.
     - Langfuse mapping attributes are ADDED alongside the source attributes.

   LANGFUSE ATTRIBUTE NAMES
     From the Langfuse OTel docs as summarised in the handoff contract (checked
     2026-10-13); live acceptance is confirmed only by the step 06 canary.
     - langfuse.observation.type: agent (true root "Agent") | generation (model
       steps) | tool | span. Source span names and hierarchy unchanged.
     - Usage: ONLY langfuse.observation.usage_details (stored without
       normalisation by Langfuse) with exclusive buckets input,
       input_cache_read, input_cache_write, output, total. No gen_ai.usage.*.
       Source counters stay as snow.ai.observability.* attributes.
       claude-opus-5-5 is inclusive_input (development verification; see docs/STATUS.md); any other
       model -> usage_semantics=unknown and no usage_details.
     - Trace context (name, user, scoped session, tags, version, release,
       environment, metadata) is copied to every span.
     - Root I/O from AgentV2RequestResponseInfo only with the same request id;
       provenance in langfuse.observation.metadata.root_io_source.
     OTLP/JSON: hex ids, decimal-string unixNano, integer enums, AnyValue.

   RE-RUNNABLE: yes (CREATE OR REPLACE; read-only procedure).
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE PROCEDURE LANGFUSE_EXPORTER.CORE.BUILD_TRACE_PAYLOAD(TRACE_ID VARCHAR, INCLUDE_PAYLOAD BOOLEAN)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
  EXECUTE AS OWNER
AS
$$
import json

DB = "LANGFUSE_EXPORTER.CORE"
MAPPING_VERSION = "3"
EXPORTER_RELEASE = "snowflake-langfuse-exporter/3"

# --- Langfuse OTLP attribute names (handoff 01_LANGFUSE_CONTRACT, Langfuse docs
#     checked 2026-10-13; live acceptance confirmed only by step 06) ------------
OBS_TYPE        = "langfuse.observation.type"        # agent | generation | tool | span
OBS_INPUT       = "langfuse.observation.input"
OBS_OUTPUT      = "langfuse.observation.output"
OBS_MODEL       = "langfuse.observation.model.name"
OBS_USAGE       = "langfuse.observation.usage_details"  # sole usage field; stored as-is
OBS_LEVEL       = "langfuse.observation.level"
OBS_STATUS_MSG  = "langfuse.observation.status_message"
OBS_META        = "langfuse.observation.metadata."
TRACE_NAME      = "langfuse.trace.name"
TRACE_USER      = "langfuse.user.id"
TRACE_SESSION   = "langfuse.session.id"
TRACE_TAGS      = "langfuse.trace.tags"
TRACE_META      = "langfuse.trace.metadata."
TRACE_VERSION   = "langfuse.version"
TRACE_RELEASE   = "langfuse.release"
TRACE_ENV       = "langfuse.environment"

# --- Token semantics per source model (development verification; see docs/STATUS.md) --------
# inclusive_input: source input includes cache_read + cache_write; verified for
# claude-opus-5-5 against CORTEX_AGENT_USAGE_HISTORY on 2 requests / 6 steps.
# Any model not listed -> "unknown": raw counters kept, no normalized usage.
INPUT_SEMANTICS = {"claude-opus-5-5": "inclusive_input"}

P = "snow.ai.observability."
SPAN_KIND = {"SPAN_KIND_UNSPECIFIED": 0, "SPAN_KIND_INTERNAL": 1, "SPAN_KIND_SERVER": 2,
             "SPAN_KIND_CLIENT": 3, "SPAN_KIND_PRODUCER": 4, "SPAN_KIND_CONSUMER": 5}
STATUS_CODE = {"STATUS_CODE_UNSET": 0, "STATUS_CODE_OK": 1, "STATUS_CODE_ERROR": 2}


def any_value(v):
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    if isinstance(v, tuple):  # explicit OTLP string array (used for tags)
        return {"arrayValue": {"values": [{"stringValue": str(x)} for x in v]}}
    if isinstance(v, (dict, list)):
        return {"stringValue": json.dumps(v, ensure_ascii=False, separators=(",", ":"))}
    return {"stringValue": str(v)}


def kv(d):
    return [{"key": k, "value": any_value(v)} for k, v in d.items() if v is not None]


def first(ra, *keys):
    for k in keys:
        v = ra.get(k)
        if v not in (None, ""):
            return v, k
    return None, None


def classify(name, is_root):
    if is_root and name == "Agent":
        return "agent"
    if name.startswith("ReasoningAgentStep") or name == "LLM Suggested Queries" \
            or name.startswith("CodingAgent.Step"):
        return "generation"
    if "Tool" in name or name.startswith("SqlExecution") or name.startswith("ToolCall"):
        return "tool"
    return "span"


def normalize_usage(*, source_input, source_output, cache_read, cache_write,
                    semantics, source_total=None):
    """Adapted from handoff 03_usage_contract.py (10 offline tests pass).
    Returns exclusive buckets, or None for unknown semantics. Raises on
    missing/invalid counters, negative remainder or total mismatch."""
    if semantics == "unknown":
        return None
    if semantics not in ("inclusive_input", "exclusive_input"):
        raise ValueError("unsupported input semantics")
    counters = dict(source_input=source_input, source_output=source_output,
                    cache_read=cache_read, cache_write=cache_write)
    if source_total is not None:
        counters["source_total"] = source_total
    for name, value in counters.items():
        if type(value) is not int or value < 0:
            raise ValueError(f"{name} must be an explicit non-negative integer")
    ordinary = source_input - (cache_read + cache_write if semantics == "inclusive_input" else 0)
    if ordinary < 0:
        raise ValueError("cache exceeds inclusive input")
    usage = dict(input=ordinary, input_cache_read=cache_read,
                 input_cache_write=cache_write, output=source_output)
    usage["total"] = sum(usage.values())
    if source_total is not None and usage["total"] != source_total:
        raise ValueError("source total disagrees with normalized buckets")
    return usage


def usage_for(ra, model):
    """-> (usage | None, semantics, problem | None)"""
    for prefix in (P + "agent.planning.token_count.", P + "agent.suggested_queries.token_count."):
        raw = {k: ra.get(prefix + k) for k in
               ("input", "output", "cache_read_input", "cache_write_input", "total")}
        if all(v is None for v in raw.values()):
            continue
        semantics = INPUT_SEMANTICS.get(model, "unknown")
        try:
            u = normalize_usage(source_input=raw["input"], source_output=raw["output"],
                                cache_read=raw["cache_read_input"],
                                cache_write=raw["cache_write_input"],
                                semantics=semantics, source_total=raw["total"])
            return u, semantics, None
        except ValueError as e:
            return None, semantics, str(e)
    return None, None, None


def as_json_text(v):
    """Structured I/O: keep JSON strings as-is, encode objects; plain text stays text."""
    return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def observation_attrs(name, ra, rec, is_root, norm):
    m = {}
    t = classify(name, is_root)
    m[OBS_TYPE] = t
    status = rec.get("status") or {}
    if t == "generation":
        model = ra.get(P + "agent.planning.model")
        m[OBS_MODEL] = model
        # Mapping v3: role-typed messages from NORMALIZE_GENERATION_IO (05_message_normalizer.sql).
        # Tool arguments are never exported as spoken assistant text.
        norm = norm or {}
        if norm.get("input") is not None:
            m[OBS_INPUT] = as_json_text(norm["input"])
        if norm.get("output") is not None:
            m[OBS_OUTPUT] = as_json_text(norm["output"])
        nm = norm.get("meta") or {}
        m[OBS_META + "message_format"] = nm.get("message_format")
        m[OBS_META + "normalizer_version"] = nm.get("normalizer_version")
        m[OBS_META + "system_reminder_blocks"] = nm.get("n_system_reminder_blocks")
        m[OBS_META + "tool_context_source"] = nm.get("tool_context_source")
        if nm.get("ambiguous"):
            m[OBS_META + "normalization_ambiguous"] = json.dumps(nm["ambiguous"])
        if nm.get("tool_issues"):
            m[OBS_META + "normalization_tool_issues"] = json.dumps(nm["tool_issues"])
        if nm.get("reason"):
            m[OBS_META + "normalization_reason"] = nm["reason"]
        u, semantics, problem = usage_for(ra, model)
        if u is not None:
            m[OBS_USAGE] = json.dumps(u, separators=(",", ":"))
        if semantics:
            m[OBS_META + "usage_semantics"] = semantics if problem is None else "invalid"
        if problem:
            m[OBS_META + "usage_problem"] = problem
    elif t == "tool":
        inp, _ = first(ra, P + "agent.tool.sql_execution.query",
                       P + "agent.tool.semantic_context.user_question",
                       P + "agent.tool.code_execution.argument.value",
                       P + "agent.tool.chart_generation.input_chart_spec")
        out, _ = first(ra, P + "agent.tool.sql_execution.result",
                       P + "agent.tool.semantic_context.tables",
                       P + "agent.tool.code_execution.result",
                       P + "agent.tool.chart_generation.response")
        m[OBS_INPUT] = as_json_text(inp) if inp is not None else None
        m[OBS_OUTPUT] = as_json_text(out) if out is not None else None
    if status.get("code") == "STATUS_CODE_ERROR":
        m[OBS_LEVEL] = "ERROR"
        msg, _ = first(ra, P + "agent.status.description", P + "agent.planning.status",
                       P + "agent.tool.sql_execution.status.description")
        m[OBS_STATUS_MSG] = status.get("message") or msg
    return m


def run(session, trace_id, include_payload):
    tr = session.sql(
        f"SELECT t.trace_id, t.request_id, t.agent_database, t.agent_schema, t.agent_name, "
        f"t.root_span_id, t.destination_id, t.route_status, t.trace_status, TO_JSON(t.anomalies), "
        f"t.source_account, d.environment, b.metadata:interaction_interface::string "
        f"FROM {DB}.TRACES t "
        f"LEFT JOIN {DB}.DESTINATIONS d ON d.destination_id = t.destination_id "
        f"LEFT JOIN {DB}.BILLING b ON b.request_id = t.request_id "
        f"WHERE t.trace_id = ?", params=[trace_id]).collect()
    if not tr:
        return {"ok": False, "error": "trace not staged", "trace_id": trace_id}
    tr = tr[0]
    request_id, root_span_id = tr[1], tr[5]
    agent_fqn = f"{tr[2]}.{tr[3]}.{tr[4]}"
    anomalies = json.loads(tr[9]) if tr[9] else []
    source_account, environment, interface = tr[10], tr[11], tr[12]

    # Timestamps are converted to epoch nanoseconds in SQL: the source carries
    # nanosecond precision and Python datetime would truncate to microseconds.
    spans = session.sql(
        f"SELECT event_key, span_id, parent_span_id, record_name, "
        f"TO_VARCHAR(DATE_PART(epoch_nanosecond, start_ts)), "
        f"TO_VARCHAR(DATE_PART(epoch_nanosecond, end_ts)), "
        f"TO_JSON(record), TO_JSON(record_attributes), TO_JSON(resource_attributes), TO_JSON(scope), "
        f"TO_JSON({DB}.NORMALIZE_GENERATION_IO(record_name, record_attributes)) "
        f"FROM {DB}.STAGED_EVENTS WHERE trace_id = ? AND record_type = 'SPAN' "
        f"AND event_key NOT IN (SELECT event_key FROM {DB}.OMITTED_SPANS_V) "
        f"ORDER BY start_ts, event_key", params=[trace_id]).collect()
    # Known source defect spans (see 04 OMITTED_SPANS_V): not exported, but listed
    # with original values in root metadata so the omission is visible in Langfuse.
    omitted = [{"span_id": o[0], "name": o[1], "parent_span_id": o[2],
                "start_unix_nano": o[3], "end_unix_nano": o[4], "reason": o[5]}
               for o in session.sql(
                   f"SELECT span_id, record_name, parent_span_id, "
                   f"TO_VARCHAR(DATE_PART(epoch_nanosecond, start_ts)), "
                   f"TO_VARCHAR(DATE_PART(epoch_nanosecond, end_ts)), reason "
                   f"FROM {DB}.OMITTED_SPANS_V WHERE trace_id = ? ORDER BY span_id",
                   params=[trace_id]).collect()]
    # Known source defect 2 (see 04 REIDENTIFIED_SPANS_V): SemanticContextTool spans
    # that share their id with a planning span are exported under a deterministic new id.
    reid = {r[0]: {"new_span_id": r[1], "original_span_id": r[2], "reason": r[3]}
            for r in session.sql(
                f"SELECT event_key, new_span_id, original_span_id, reason "
                f"FROM {DB}.REIDENTIFIED_SPANS_V WHERE trace_id = ?", params=[trace_id]).collect()}
    events = session.sql(
        f"SELECT event_key, record_name, TO_VARCHAR(DATE_PART(epoch_nanosecond, end_ts)), "
        f"TO_JSON(record_attributes) "
        f"FROM {DB}.STAGED_EVENTS WHERE record_type = 'EVENT' "
        f"AND record_name = 'CORTEX_AGENT_REQUEST' AND request_id = ? "
        f"ORDER BY end_ts, event_key", params=[request_id]).collect() if request_id else []

    # Root I/O comes from the AgentV2RequestResponseInfo span only when it is in
    # this trace AND carries the same request id (proven join); provenance recorded.
    root_in = root_out = root_io_source = None
    thread_id = user_name = agent_version = None
    for s in spans:
        ra = json.loads(s[7]) if s[7] else {}
        if (s[3] == "AgentV2RequestResponseInfo"
                and ra.get("ai.observability.record_id") == request_id and root_io_source is None):
            root_in = ra.get("ai.observability.record_root.input")
            root_out = ra.get("ai.observability.record_root.output")
            if root_in not in (None, "") or root_out not in (None, ""):
                root_io_source = f"AgentV2RequestResponseInfo:{s[1]}"
        if thread_id is None and ra.get(P + "agent.thread_id") is not None:
            thread_id = ra.get(P + "agent.thread_id")
        if user_name is None and s[8]:
            user_name = json.loads(s[8]).get("snow.user.name")
        if s[1] == root_span_id and s[2] is None:
            agent_version = ra.get(P + "object.version.name")

    # Trace context copied to EVERY span (Langfuse propagates per observation).
    trace_ctx = {
        TRACE_NAME: agent_fqn,
        TRACE_USER: user_name,
        # Scoped so threads from different accounts/agents never collide in a project.
        TRACE_SESSION: f"{source_account}:{agent_fqn}:{thread_id}" if thread_id is not None else None,
        TRACE_TAGS: ("snowflake-cortex-agent",),
        TRACE_VERSION: agent_version,
        TRACE_RELEASE: EXPORTER_RELEASE,
        TRACE_ENV: environment,
        TRACE_META + "snowflake_account": source_account,
        TRACE_META + "snowflake_agent": agent_fqn,
        TRACE_META + "snowflake_request_id": request_id,
        TRACE_META + "snowflake_thread_id": str(thread_id) if thread_id is not None else None,
        TRACE_META + "snowflake_interface": interface,
        TRACE_META + "exporter_mapping_version": MAPPING_VERSION,
        TRACE_META + "exporter_anomalies": json.dumps(anomalies) if anomalies else None,
        TRACE_META + "exporter_omitted_spans": json.dumps(omitted) if omitted else None,
        TRACE_META + "exporter_reidentified_spans": json.dumps(
            [{"original_span_id": v["original_span_id"], "new_span_id": v["new_span_id"],
              "reason": v["reason"]} for v in reid.values()]) if reid else None,
    }

    groups = {}          # (resource json, scope name) -> [span]
    event_keys = []
    counts = {"agent": 0, "generation": 0, "tool": 0, "span": 0}
    usage_semantics = {}
    for s in spans:
        rec = json.loads(s[6]) if s[6] else {}
        ra = json.loads(s[7]) if s[7] else {}
        status = rec.get("status") or {}
        status_code = status.get("code", "STATUS_CODE_UNSET")
        is_root = s[2] is None and s[1] == root_span_id
        attrs = dict(ra)                       # every source attribute, unchanged
        m = observation_attrs(s[3], ra, rec, is_root, json.loads(s[10]) if s[10] else None)
        counts[m[OBS_TYPE]] += 1
        sem = m.get(OBS_META + "usage_semantics")
        if sem:
            usage_semantics[sem] = usage_semantics.get(sem, 0) + 1
        if is_root:
            m[OBS_INPUT] = root_in if root_in not in (None, "") else None
            m[OBS_OUTPUT] = root_out if root_out not in (None, "") else None
            m[OBS_META + "root_io_source"] = root_io_source
        attrs.update(trace_ctx)
        attrs.update(m)
        r_info = reid.get(s[0])
        if r_info:
            attrs[OBS_META + "exporter_original_span_id"] = r_info["original_span_id"]
            attrs[OBS_META + "exporter_id_reason"] = r_info["reason"]
        attrs = {k: v for k, v in attrs.items() if v is not None}

        span = {
            "traceId": trace_id,
            "spanId": r_info["new_span_id"] if r_info else s[1],
            "name": s[3],
            "kind": SPAN_KIND.get(rec.get("kind"), 0),
            "startTimeUnixNano": s[4],
            "endTimeUnixNano": s[5],
            "attributes": kv(attrs),
            "status": {"code": STATUS_CODE.get(status_code, 0)},
        }
        if status.get("message"):
            span["status"]["message"] = status["message"]
        if s[2] is not None:
            span["parentSpanId"] = s[2]
        if rec.get("dropped_attributes_count"):
            span["droppedAttributesCount"] = rec["dropped_attributes_count"]
        if is_root and events:
            span["events"] = [{"timeUnixNano": e[2], "name": e[1],
                               "attributes": kv(json.loads(e[3]) if e[3] else {})} for e in events]
            event_keys.extend(e[0] for e in events)
        event_keys.append(s[0])

        res = s[8] or "{}"
        scope = (json.loads(s[9]) if s[9] else {}).get("name", "snow.cortex.agent")
        groups.setdefault((res, scope), []).append(span)

    resource_spans = []
    for (res, scope), group in groups.items():
        rattrs = json.loads(res)
        rattrs.setdefault("service.name", "snowflake.cortex.agent")
        resource_spans.append({"resource": {"attributes": kv(rattrs)},
                               "scopeSpans": [{"scope": {"name": scope}, "spans": group}]})
    payload = {"resourceSpans": resource_spans}
    body = json.dumps(payload, separators=(",", ":"))

    out = {
        "ok": True,
        "trace_id": trace_id,
        "request_id": request_id,
        "destination_id": tr[6],
        "route_status": tr[7],
        "trace_status": tr[8],
        "anomalies": anomalies,
        "n_spans": len(spans),
        "n_omitted_spans": len(omitted),
        "n_span_events": len(events),
        "observation_types": counts,
        "usage_semantics": usage_semantics,
        "root_io_source": root_io_source,
        "mapping_version": MAPPING_VERSION,
        "payload_bytes": len(body.encode("utf-8")),
        "event_keys": event_keys,
    }
    if include_payload:
        out["payload"] = payload
    return out
$$;

-- Definitions only. Use a fresh canary as described in docs/INSTALL.md.
