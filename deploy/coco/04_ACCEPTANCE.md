# Fresh-account acceptance

Run with the task graph suspended and one publisher. Use synthetic/non-sensitive browser questions selected by the user. Avoid building a second test stack unless an agent/data source is genuinely missing. No assertion about the new account is pre-passed.

## Minimum for the chosen configuration

1. Infrastructure and compilation: configured roles/objects owned correctly; all procedure definitions compile on Snowflake; normalizer fixtures pass. Source events readable under runtime role. Missing billing can be pending.
2. Connectivity: EACH destination's health and authenticated project result succeed and match the intended host/project ID. Empty or mismatched identity is failure.
3. Source canary: user makes a new two-turn conversation in a selected Cortex Agent's Snowflake browser preview. Record exact agent, source request/trace IDs and session/thread association, source counts and timestamps. Wait for source rows to appear and for the configured quiet threshold. No source rows means pending, not a successful empty export.
4. Stage only after scope agreement. Inspect TRACES plus ROUTE_PREVIEW_V; verify the canary's frozen destination and absence of errors. The view shows unresolved routes; the TRACES row proves the frozen decision. Build its payload and inspect roles, hierarchy, anomalies and root I/O before POST.
5. Dry run for the chosen trace. Then publish ONLY that fresh trace by supplying TRACE_ID, reconcile and run VERIFY_TRACE_SEMANTICS. Check results and observation identities/counts, not just successful SQL execution or HTTP acceptance.
6. Langfuse UI: the session shows each current user question/assistant answer once, in order. System context stays system context, not a user bubble. Generations can retain full prior messages; tool call/result pairs and actual parent IDs are intact. Do not invent parent links to make a nicer tree. Record whether UI evidence was directly observed or user-reported.
7. Billing: when the source row/components arrive, stage and publish the SAME trace normally for score delivery, without resending accepted observations. Verify every produced score ID with VERIFY_SCORE; check root observation subject, numeric value and credit units against source. Mark pending if billing hasn't arrived. COST_READY must actually wait for its configured components.
8. Final scope: apply the complete final map, then use FRESH conversations to test selected agents and exclusions. For multiple projects, verify shared agents land in the same project, the separate agent lands only in its intended project, and no unintended project contains those canaries. Partial/capped/empty readback does not establish isolation.
9. Scheduling: use the interview's activation/billing choice. Before activation, report passed/pending checks. Create the publisher child explicitly; resume child then root only when criteria and authorisation are satisfied. Observe a graph run and inspect destination/delivery status in addition to task success. Otherwise leave tasks suspended and report why.

## Canary worksheet pattern

Generate concrete statements in separate steps, adapting database/role names. Placeholders below must be resolved. Sending is a deliberate stage; do not execute this whole document as one SQL script.

```sql
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;
SET canary_destination = '<actual destination alias>';
SET canary_trace = '<fresh source trace ID>';
CALL STAGE_AND_ROUTE();
SELECT trace_id, route_status, destination_id, route_error,
       frozen_host, frozen_project_id, trace_status
FROM TRACES WHERE trace_id = $canary_trace;
CALL BUILD_TRACE_PAYLOAD($canary_trace, TRUE);
CALL PUBLISH_DESTINATION($canary_destination, 1, TRUE, $canary_trace);
```

After inspecting the source, routing and payload:
```sql
CALL PUBLISH_DESTINATION($canary_destination, 1, FALSE, $canary_trace);
CALL RECONCILE_DELIVERIES($canary_destination, 20);
CALL VERIFY_TRACE_SEMANTICS($canary_destination, $canary_trace);
```

After billing is available, with publishing still serialised:
```sql
CALL STAGE_AND_ROUTE();
CALL PUBLISH_DESTINATION($canary_destination, 20, FALSE, $canary_trace);
SELECT score_id, observation_id, name, value
FROM SCORES WHERE trace_id = $canary_trace AND destination_id = $canary_destination;
-- For EACH returned score ID:
-- CALL VERIFY_SCORE($canary_destination, '<actual score ID>');
```

Reconciliation can inspect other queued deliveries for the same destination; keep this a dedicated validation environment. Unknown/uncertain results require investigation, not forced replay. Retain counters and identifiers in evidence without copying raw sensitive payloads.

## Broader release qualification

reference/docs/STATUS.md contains further routing-failure, identity-tampering and interrupted-score-recovery tests. These belong in disposable infrastructure, not a user's live project. Report which were actually run. A working single-project canary does not validate multi-project routing or every recovery boundary. Neither a CoCo install nor the offline suite proves the independent manual replay requested for a future cookbook.

## v1.2 batch acceptance

After single-trace canaries pass, deliberately select at least two fresh READY traces
in one disposable destination and use a bounded invocation without ONLY_TRACE_ID.
Preview every eligible candidate first: the unfiltered call may export historical work.
Verify one HTTP_BATCHES row contains multiple delivery IDs and distinct trace IDs;
reconcile each member separately and verify sessions and credits. Exercise byte/span
boundaries and partial/uncertain results in a disposable fixture environment. A single
trace cannot demonstrate multi-trace batching. Complete the explicit volume benchmark
in reference/docs/SCALING.md if high-volume use was requested; otherwise mark it NOT RUN.
