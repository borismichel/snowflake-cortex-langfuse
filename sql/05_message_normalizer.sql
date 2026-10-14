/* =============================================================================
   05_message_normalizer.sql
   Langfuse exporter - message normalizer for generation observations (mapping v3)
   + regression tests. Run BEFORE 05a. Run as LANGFUSE_EXPORTER_ROLE.
   No network access; sends nothing.

   CREATES (schema-level, LANGFUSE_EXPORTER.CORE)
     FUNCTION NORMALIZE_GENERATION_IO(RECORD_NAME VARCHAR, ATTRS VARIANT) RETURNS VARIANT
       -> {"input": ..., "output": ..., "meta": {...}}   (one source of truth for
          BUILD_TRACE_PAYLOAD and for the tests below)

   SOURCE FORMAT (verified 2026-10-13 on three development traces)
     snow.ai.observability.agent.planning.messages = JSON array of STRINGS, each
       starting with a role prefix "User: " or "Assistant: ". Every "User:" element
       starts with a contiguous run of <system-reminder>...</system-reminder>
       blocks (7 observed) injected by Snowflake, followed by the human question.
     planning.tool_selection.{id,name,argument.name,argument.value} = parallel
       arrays: the tool calls THIS step emits (its output).
       argument.name is comma-joined; argument.value is comma-joined JSON values.
     planning.tool_execution.{id,name,argument.*,results} = tool calls (ids match
       earlier steps' tool_selection ids) and their results fed INTO this step.
     planning.response = final answer text (response-generation steps).
     planning.thinking_response = reasoning text actually present in the source.

   NORMALIZATION RULES
     1. Structured messages (array of objects with a string "role") are passed
        through; roles lower-cased; only user/assistant/system/developer/tool accepted.
     2. Flattened strings: ALL elements must start with a recognized prefix
        (User|Assistant|System|Developer|Tool + ": "). Prefix -> role, rest -> content.
        No other text is used to infer roles.
     3. User content: only a LEADING contiguous run of complete
        <system-reminder>...</system-reminder> blocks is split off into one
        "system" message placed before the user message. The human text after the
        run stays the user message, unchanged. Ambiguous cases are kept as user
        text and reported in meta.ambiguous:
          reminder_tag_not_leading   tag appears but not as a leading block (quotation)
          reminder_tag_in_user_text  tag appears in the human text after the run
          nested_reminder_tag / unclosed_reminder
          empty_user_text            nothing left after the reminder run
     4. Anything else -> message_format "unknown": input is exported as
        {"unparsed_source_messages": <raw>} - never as chat messages, never as user.
     5. Tool context in input: tool_execution entries become one assistant message
        with tool_calls followed by one "tool" message per call (tool_call_id =
        source id). Output of a planning step = assistant message with tool_calls
        from tool_selection (arguments as a JSON string) and NO tool arguments as
        spoken content. Response steps output = assistant message with the response.
        Reasoning is kept only if present (field "reasoning").
     6. Array length mismatches or undecodable arguments are reported in meta and
        the affected tool data is NOT turned into tool_calls.
     The original source attributes are always exported unchanged as
     snow.ai.observability.* attributes, and STAGED_EVENTS is never modified.
   ========================================================================== */

USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;

CREATE OR REPLACE FUNCTION LANGFUSE_EXPORTER.CORE.NORMALIZE_GENERATION_IO(RECORD_NAME VARCHAR, ATTRS VARIANT)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  HANDLER = 'normalize'
AS
$$
import json
import re

NORMALIZER_VERSION = "1"
P = "snow.ai.observability.agent.planning."
SQ = "snow.ai.observability.agent.suggested_queries"
ROLES = {"User": "user", "Assistant": "assistant", "System": "system",
         "Developer": "developer", "Tool": "tool"}
PREFIX_RE = re.compile(r"^(User|Assistant|System|Developer|Tool): ?")
BLOCK_RE = re.compile(r"\s*<system-reminder>(.*?)</system-reminder>", re.S)
OPEN, CLOSE = "<system-reminder>", "</system-reminder>"


def parse_json(v):
    if isinstance(v, (list, dict)):
        return v
    if isinstance(v, str):
        try:
            return json.loads(v)
        except ValueError:
            return None
    return None


def split_reminders(text):
    """-> ((blocks, human_text), issue) or (None, issue) when ambiguous."""
    pos, blocks = 0, []
    while True:
        m = BLOCK_RE.match(text, pos)
        if not m:
            break
        if OPEN in m.group(1):
            return None, "nested_reminder_tag"
        blocks.append(m.group(1).strip())
        pos = m.end()
    rest = text[pos:]
    if not blocks:
        if OPEN in text or CLOSE in text:
            return None, "reminder_tag_not_leading"
        return ([], text), None
    if rest.lstrip().startswith(OPEN):
        return None, "unclosed_reminder"
    human = rest.strip()
    if not human:
        return (blocks, human), "empty_user_text"
    if OPEN in human or CLOSE in human:
        return (blocks, human), "reminder_tag_in_user_text"
    return (blocks, human), None


def normalize_messages(raw):
    msgs = parse_json(raw)
    if not isinstance(msgs, list) or not msgs:
        return None, {"message_format": "unknown", "reason": "not a non-empty JSON array"}
    if all(isinstance(m, dict) and isinstance(m.get("role"), str) for m in msgs):
        out = []
        for m in msgs:
            role = m["role"].lower()
            if role not in ROLES.values():
                return None, {"message_format": "unknown", "reason": f"unrecognized role {m['role']!r}"}
            out.append(dict(m, role=role))
        return out, {"message_format": "structured", "n_source_messages": len(msgs)}
    if all(isinstance(m, str) and PREFIX_RE.match(m) for m in msgs):
        out, ambiguous, n_blocks = [], [], 0
        for i, m in enumerate(msgs):
            p = PREFIX_RE.match(m)
            role, body = ROLES[p.group(1)], m[p.end():]
            if role != "user":
                out.append({"role": role, "content": body})
                continue
            res, issue = split_reminders(body)
            if issue:
                ambiguous.append({"index": i, "issue": issue})
            if res is None:
                out.append({"role": "user", "content": body})
                continue
            blocks, human = res
            if blocks:
                out.append({"role": "system", "content": "\n\n".join(blocks)})
                n_blocks += len(blocks)
            out.append({"role": "user", "content": human})
        return out, {"message_format": "snowflake_flattened_role_prefix",
                     "n_source_messages": len(msgs), "n_system_reminder_blocks": n_blocks,
                     "ambiguous": ambiguous}
    return None, {"message_format": "unknown", "reason": "elements without a recognized role prefix"}


def decode_args(names_csv, values):
    try:
        vals = json.loads("[" + values + "]") if isinstance(values, str) else None
    except ValueError:
        return None
    keys = names_csv.split(",") if isinstance(names_csv, str) and names_csv else []
    if vals is None or len(keys) != len(vals):
        return None
    return dict(zip(keys, vals))


def tool_calls(attrs, kind):
    """-> (calls, results | None, issue | None) from parallel source arrays."""
    ids = parse_json(attrs.get(P + kind + ".id"))
    if not isinstance(ids, list) or not ids:
        return [], None, None
    names = parse_json(attrs.get(P + kind + ".name"))
    anames = parse_json(attrs.get(P + kind + ".argument.name"))
    avals = parse_json(attrs.get(P + kind + ".argument.value"))
    results = parse_json(attrs.get(P + kind + ".results")) if kind == "tool_execution" else None
    arrays = [names, anames, avals] + ([results] if kind == "tool_execution" else [])
    if not all(isinstance(a, list) and len(a) == len(ids) for a in arrays):
        return [], None, f"{kind}_array_length_mismatch"
    calls, issue = [], None
    for i, cid in enumerate(ids):
        args = decode_args(anames[i], avals[i])
        if args is None:
            return [], None, f"{kind}_arguments_undecodable"
        calls.append({"id": cid, "type": "function",
                      "function": {"name": names[i],
                                   "arguments": json.dumps(args, ensure_ascii=False)}})
    return calls, results, issue


def normalize(record_name, attrs):
    if not isinstance(attrs, dict):
        return {}
    is_model = record_name.startswith("ReasoningAgentStep") or record_name.startswith("CodingAgent.Step")
    if not is_model and record_name != "LLM Suggested Queries":
        return {}
    meta = {"normalizer_version": NORMALIZER_VERSION}
    issues = []

    if record_name == "LLM Suggested Queries":
        sq = attrs.get(SQ)
        meta["message_format"] = "none"
        return {"input": None,
                "output": {"suggested_queries": parse_json(sq) if parse_json(sq) is not None else sq}
                          if sq is not None else None,
                "meta": meta}

    # ---- input --------------------------------------------------------------
    messages, mmeta = normalize_messages(attrs.get(P + "messages"))
    meta.update(mmeta)
    if messages is None:
        raw = attrs.get(P + "messages")
        query = attrs.get(P + "query")
        inp = {"unparsed_source_messages": raw} if raw is not None else (
              {"query": query} if query is not None else None)
    else:
        inp = list(messages)
        exec_calls, exec_results, issue = tool_calls(attrs, "tool_execution")
        if issue:
            issues.append(issue)
        if exec_calls:
            inp.append({"role": "assistant", "content": None, "tool_calls": exec_calls})
            for c, r in zip(exec_calls, exec_results):
                inp.append({"role": "tool", "tool_call_id": c["id"], "name": c["function"]["name"],
                            "content": r if isinstance(r, str) else json.dumps(r, ensure_ascii=False)})
            meta["tool_context_source"] = "planning.tool_execution"

    # ---- output -------------------------------------------------------------
    out = None
    response = attrs.get(P + "response")
    thinking = attrs.get(P + "thinking_response")
    sel_calls, _, issue = tool_calls(attrs, "tool_selection")
    if issue:
        issues.append(issue)
    if response not in (None, "") or sel_calls:
        out = {"role": "assistant", "content": response if response not in (None, "") else None}
        if sel_calls:
            out["tool_calls"] = sel_calls
        if thinking not in (None, ""):
            out["reasoning"] = thinking
    elif thinking not in (None, ""):
        out = {"role": "assistant", "content": None, "reasoning": thinking}
    if issues:
        meta["tool_issues"] = issues
    return {"input": inp, "output": out, "meta": meta}
$$;

/* =============================================================================
   REGRESSION TESTS (expect every row PASS). Fixtures are synthetic.
   Note: a JSON null inside a VARIANT is not SQL NULL; assertions use IS_NULL_VALUE.
   ========================================================================== */
WITH cases AS (
  SELECT column1 AS case_name, column2 AS record_name, PARSE_JSON(column3) AS attrs FROM VALUES
  ('structured', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[{\\"role\\":\\"user\\",\\"content\\":\\"hi\\"},{\\"role\\":\\"Assistant\\",\\"content\\":\\"hello\\"}]","snow.ai.observability.agent.planning.response":"ok"}'),
  ('flattened_history', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: first\\",\\"Assistant: earlier reply\\",\\"User: second\\"]","snow.ai.observability.agent.planning.response":"answer"}'),
  ('reminders_and_question', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: <system-reminder>\\\\nA\\\\n</system-reminder> <system-reminder>B</system-reminder> What is X?\\"]","snow.ai.observability.agent.planning.response":"X"}'),
  ('quoted_tag_only', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: What does <system-reminder> mean?\\"]"}'),
  ('reminder_then_quoted_tag', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: <system-reminder>A</system-reminder> Explain the </system-reminder> tag\\"]"}'),
  ('unknown_no_prefix', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"hello\\",\\"world\\"]"}'),
  ('unknown_bad_prefix', 'ReasoningAgentStepResponseGeneration-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"Bot: hi\\"]"}'),
  ('tool_selection_output', 'ReasoningAgentStepPlanning-1',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: q\\"]","snow.ai.observability.agent.planning.thinking_response":"think","snow.ai.observability.agent.planning.tool_selection.id":"[\\"c2\\"]","snow.ai.observability.agent.planning.tool_selection.name":"[\\"system_execute_sql\\"]","snow.ai.observability.agent.planning.tool_selection.argument.name":"[\\"semantic_model,sql\\"]","snow.ai.observability.agent.planning.tool_selection.argument.value":"[\\"\\\\\\"m\\\\\\",\\\\\\"SELECT 1\\\\\\"\\"]"}'),
  ('tool_execution_input', 'ReasoningAgentStepPlanning-1',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: q\\"]","snow.ai.observability.agent.planning.tool_execution.id":"[\\"c1\\"]","snow.ai.observability.agent.planning.tool_execution.name":"[\\"tpch_sales\\"]","snow.ai.observability.agent.planning.tool_execution.argument.name":"[\\"pruning_question\\"]","snow.ai.observability.agent.planning.tool_execution.argument.value":"[\\"\\\\\\"rev\\\\\\"\\"]","snow.ai.observability.agent.planning.tool_execution.results":"[\\"RESULT\\"]"}'),
  ('tool_length_mismatch', 'ReasoningAgentStepPlanning-0',
   '{"snow.ai.observability.agent.planning.messages":"[\\"User: q\\"]","snow.ai.observability.agent.planning.tool_selection.id":"[\\"c1\\",\\"c2\\"]","snow.ai.observability.agent.planning.tool_selection.name":"[\\"a\\"]","snow.ai.observability.agent.planning.tool_selection.argument.name":"[\\"x\\"]","snow.ai.observability.agent.planning.tool_selection.argument.value":"[\\"1\\"]"}'),
  ('non_model_span', 'SqlExecution_SystemSQL', '{}')
),
r AS (SELECT case_name, LANGFUSE_EXPORTER.CORE.NORMALIZE_GENERATION_IO(record_name, attrs) AS n FROM cases)
SELECT case_name,
       IFF(CASE case_name
         WHEN 'structured' THEN n:meta:message_format = 'structured' AND n:input[1]:role = 'assistant'
                                AND n:output:content = 'ok'
         WHEN 'flattened_history' THEN n:meta:message_format = 'snowflake_flattened_role_prefix'
                                AND ARRAY_SIZE(n:input) = 3 AND n:input[0]:role = 'user'
                                AND n:input[1]:role = 'assistant' AND n:input[1]:content = 'earlier reply'
                                AND n:input[2]:content = 'second'
         WHEN 'reminders_and_question' THEN n:input[0]:role = 'system' AND CONTAINS(n:input[0]:content, 'A')
                                AND CONTAINS(n:input[0]:content, 'B') AND n:input[1]:role = 'user'
                                AND n:input[1]:content = 'What is X?' AND n:meta:n_system_reminder_blocks = 2
                                AND ARRAY_SIZE(n:meta:ambiguous) = 0
         WHEN 'quoted_tag_only' THEN ARRAY_SIZE(n:input) = 1 AND n:input[0]:role = 'user'
                                AND n:input[0]:content = 'What does <system-reminder> mean?'
                                AND n:meta:ambiguous[0]:issue = 'reminder_tag_not_leading'
         WHEN 'reminder_then_quoted_tag' THEN n:input[0]:role = 'system' AND n:input[1]:role = 'user'
                                AND CONTAINS(n:input[1]:content, '</system-reminder>')
                                AND n:meta:ambiguous[0]:issue = 'reminder_tag_in_user_text'
         WHEN 'unknown_no_prefix' THEN n:meta:message_format = 'unknown'
                                AND n:input:unparsed_source_messages IS NOT NULL AND IS_ARRAY(n:input) = FALSE
         WHEN 'unknown_bad_prefix' THEN n:meta:message_format = 'unknown' AND IS_ARRAY(n:input) = FALSE
         WHEN 'tool_selection_output' THEN n:output:role = 'assistant' AND IFNULL(IS_NULL_VALUE(n:output:content), TRUE)
                                AND n:output:tool_calls[0]:id = 'c2'
                                AND n:output:tool_calls[0]:function:name = 'system_execute_sql'
                                AND PARSE_JSON(n:output:tool_calls[0]:function:arguments::string):sql = 'SELECT 1'
                                AND n:output:reasoning = 'think'
         WHEN 'tool_execution_input' THEN n:input[1]:role = 'assistant' AND n:input[1]:tool_calls[0]:id = 'c1'
                                AND n:input[2]:role = 'tool' AND n:input[2]:tool_call_id = 'c1'
                                AND n:input[2]:content = 'RESULT' AND IFNULL(IS_NULL_VALUE(n:output), TRUE)
         WHEN 'tool_length_mismatch' THEN IFNULL(IS_NULL_VALUE(n:output), TRUE)
                                AND n:meta:tool_issues[0] = 'tool_selection_array_length_mismatch'
         WHEN 'non_model_span' THEN n = OBJECT_CONSTRUCT()
       END, 'PASS', 'FAIL') AS result,
       n
  FROM r ORDER BY case_name;

/* Real-data check (expect 0 rows): no exported user message starts with a
   reminder block, and every assistant history message keeps its role. */
SELECT s.trace_id, s.record_name, m.index, m.value:role::string AS role, LEFT(m.value:content::string, 80) AS content_head
  FROM LANGFUSE_EXPORTER.CORE.STAGED_EVENTS s,
       LATERAL FLATTEN(LANGFUSE_EXPORTER.CORE.NORMALIZE_GENERATION_IO(s.record_name, s.record_attributes):input) m
 WHERE s.record_type = 'SPAN' AND s.record_name LIKE 'ReasoningAgentStep%'
   AND m.value:role::string = 'user' AND STARTSWITH(LTRIM(m.value:content::string), '<system-reminder>');

/* CLEANUP: DROP FUNCTION IF EXISTS LANGFUSE_EXPORTER.CORE.NORMALIZE_GENERATION_IO(VARCHAR, VARIANT); */
