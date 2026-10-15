# Installation and upgrade · v1.2

> **Use at your own risk.** This experimental software is provided as is, without warranty, under the [MIT licence](../LICENSE). Read the [disclaimer and user responsibilities](../README.md#disclaimer-and-user-responsibilities) before running any script. You are responsible for testing, permissions, exported data and service charges.

This is a custom community project, not an officially supported Langfuse component.
All Snowflake installation scripts are under `sql/`; the optional package builder is under `tools/`. The original V1 was demonstrated in Snowflake;
v1.2 adds routing safeguards and bounded multi-trace batching validated offline. Snowflake compilation, live
multi-project canaries and a fresh-account manual replay are still required.

## Choose the mapping

Edit `sql/03a_destination_and_routes.sql`. It is the complete active routing map:
applying it disables routes absent from DESIRED_ROUTES, retaining their rows for audit.
Review the entire table, including account-wide defaults, before applying it.

| Intent | Destination rows | Route rows |
| --- | --- | --- |
| All agents in one project | One | ACCOUNT → that destination |
| Agents A and B share; C is separate | Two | A/B → shared; C → team B (supplied template) |
| One project per agent | One per project | One AGENT route per agent |
| Shared default with a team exception | Shared + team | ACCOUNT default + SCHEMA/AGENT exception |
| Exclude a sandbox | As needed | SCHEMA/AGENT EXCLUDE |

Selectors use the exact database, schema and agent names recorded by Snowflake,
including case. AGENT overrides SCHEMA, which overrides DATABASE, then ACCOUNT.
At the winning specificity, EXCLUDE wins; otherwise exactly one route is required.
Even redundant same-destination rules are treated as a configuration error.
An invalid/disabled/paused winning destination holds the trace as CONFIG_ERROR;
it never falls back to a broader route. No matching rule leaves it UNROUTED.
Secret availability and actual project ownership are checked by connectivity and
by the sender, not by the SQL resolver.

Each trace has one destination. Many agents can share it. Fan-out to multiple
projects is outside this implementation. Existing ROUTED/EXCLUDED traces stay frozen;
configuration edits affect only unresolved traces, including retried CONFIG_ERROR
traces. This is resolution-time selection, not an event-time cutover.

## Prerequisites and credentials

Follow [prerequisites and network setup](SETUP.md).
Use ACCOUNTADMIN for account objects, then LANGFUSE_EXPORTER_ROLE with
LANGFUSE_EXPORTER_WH and LANGFUSE_EXPORTER.CORE for routine setup.

Use one stable destination alias per Langfuse host/project. Obtain each actual
project ID from the project API/check; never retain template IDs. Replace every
`<...>` placeholder. `03a` refuses unresolved placeholders and identity changes.
An existing never-used destination with a NULL project may receive its first ID.
A used alias must not be repointed; create another alias. Unchanged aliases can rotate
keys within the same project. Enabled/paused state of existing destinations is preserved.

Create secrets privately. For each new alias, allow its secret in the external access
integration and bind it under exactly that alias in all five Python procedures:
03 connectivity, 05b sender and reconciler, 05c score check, 05d semantic check.
A new host additionally needs an allowed network rule/integration. `secret_name`
and `integration_name` in the configuration table are descriptive; they cannot grant
runtime bindings. Update the procedure SECRETS/EXTERNAL_ACCESS_INTEGRATIONS clauses.

Connectivity needs a destination table row. New aliases are registered by 03a; the
stock 03 file checks only the seeded LANGFUSE_TEST alias. After 03a, explicitly call
`LANGFUSE_CONNECTIVITY_CHECK('<alias>')` for every additional destination and compare
its returned project ID with the configured project. Do this before staging/publishing.

## New installation

Run v1.2 files sequentially, inspect each result, and keep the task schedule
suspended until the canary checks below pass:

1. `01_role_warehouse_database.sql`, `02_core_tables.sql`, `02b_migration_v2.sql`,
   then `02c_routing_safety.sql`, then `02d_migration_v12.sql`. The candidate 02b no longer seeds a test project ID.
2. Create each secret privately; configure integration/bindings in
   `03_network_secret_integration.sql` and run it.
3. Apply your edited `03a_destination_and_routes.sql`; verify connectivity/project
   identity for every destination. This changes configuration, not telemetry.
4. Install `04_staging_routing.sql`, `05_message_normalizer.sql`,
   `05a_payload_builder.sql`, `05b_sender.sql`, `05c_verify_scores.sql`,
   `05d_verify_semantics.sql`. Candidate 04/05a/05b/05c only define code; their old
   staging calls and account-specific canaries were removed. The normalizer's
   synthetic fixture checks remain.
5. Deliberately stage and inspect routes, then run fresh disposable canaries below.
6. Install 07 only when ready to create a new task graph; its one-time EXECUTE TASK
   is now commented. Part B still requires creating the publisher child task.
   Follow [task activation](OPERATIONS.md#scheduled-publication), child before root.
   Install 07a for the v1.2 queue view. Never include 99_uninstall.sql in an installation batch.

## Upgrade an existing exporter to v1.2

Use the [separate CoCo update workflow](../deploy/coco-upgrade/00_START_HERE.md)
for an already installed account. Build it with
`python3 tools/build_coco_package.py --mode upgrade --output /tmp/coco-v1.2-update`.
It inventories live DDL and preserves routes/secrets/tasks; it is not the fresh-install interview.

For an account already on the public routing-safety snapshot: suspend the root task,
wait for the active graph/manual publisher to finish, and capture current procedure DDL
and configuration. Apply **02d**, replace **05b**, then install **07a_batch_status.sql**
(the monitoring-only view). Do not run 07 to upgrade an existing task graph.
Keep the current task definitions and destination secret bindings. The existing scheduled
wrapper is replaced by 05b and now uses configured limits. Run the batching canaries in
[SCALING.md](SCALING.md) before resuming. Existing per-trace deliveries remain valid;
accepted spans are not re-enqueued. Tune per-destination limits before enabling scheduling.

To roll back code, suspend/drain first and inspect IN_FLIGHT/PARTIAL/UNCERTAIN members;
retain HTTP_BATCHES, DELIVERIES and attempts. Restore captured old 05b definitions only
after that review. The additive columns/table can remain. Never delete delivery records
to roll back. Old code sends pending per-trace rows individually and is not batch-aware
in its transport audit; do not claim an untested rollback is verified.

## Upgrade the original V1 account

Save your current procedure DDL and destination/route rows first. These local files
are the supplied baseline, not proof of current live DDL. Preserve all existing secret
bindings when installing changed procedures.

Suspend the root task to prevent new graph runs and wait for any running graph to
finish. Do not run a manual publisher concurrently. Inspect task history before
continuing. Suspending the root does not cancel an already-running graph.

```sql
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;
ALTER TASK IF EXISTS STAGE_AND_ROUTE_TASK SUSPEND;
SHOW TASKS IN SCHEMA LANGFUSE_EXPORTER.CORE;
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()), RESULT_LIMIT => 100))
WHERE DATABASE_NAME = 'LANGFUSE_EXPORTER' AND SCHEMA_NAME = 'CORE'
ORDER BY SCHEDULED_TIME DESC;
```

Apply 02c and 02d, your edited 03a (after any new credentials/bindings are prepared),
then 04, 05b, 05c, 05d. Do not re-run 01/02/02b seeds or recreate the task graph as an
upgrade shortcut. Do not reset routing or delivery state. Inspect queued work and
perform fresh canaries before explicitly resuming the existing task graph.
This guide does not resume anything automatically.

## Preview and canary

```sql
-- First staging call reads available source history; review scope before calling.
CALL LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE();
SELECT trace_id, route_status, destination_id, route_error, route_candidates,
       frozen_host, frozen_project_id, frozen_route_config
FROM LANGFUSE_EXPORTER.CORE.TRACES ORDER BY last_staged_at DESC;
-- Live view of unresolved decisions; resolved traces appear in TRACES above.
SELECT * FROM LANGFUSE_EXPORTER.CORE.ROUTE_PREVIEW_V;
CALL LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION('LANGFUSE_TEST', 20, TRUE);
```

Expected: each selected agent has its intended frozen project, excluded agents are
EXCLUDED, unmatched agents are UNROUTED, invalid configurations are CONFIG_ERROR.
Fix rules, then stage again to reconsider errors. ROUTED/EXCLUDED decisions do not move.
A dry run performs authenticated GETs but does not enqueue or POST data.

Use fresh conversations with A/B/C in two disposable projects. For each trace copy
its destination and trace ID into a separate worksheet:

```sql
SET canary_destination = '<destination alias>';
SET canary_trace = '<new trace ID>';
CALL LANGFUSE_EXPORTER.CORE.BUILD_TRACE_PAYLOAD($canary_trace, TRUE);
CALL LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION($canary_destination, 1, FALSE, $canary_trace);
CALL LANGFUSE_EXPORTER.CORE.RECONCILE_DELIVERIES($canary_destination, 20);
CALL LANGFUSE_EXPORTER.CORE.VERIFY_TRACE_SEMANTICS($canary_destination, $canary_trace);
-- Once billing arrives, stage and publish a second time for persisted credit scores.
CALL LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE();
CALL LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION($canary_destination, 20, FALSE, $canary_trace);
SELECT score_id FROM LANGFUSE_EXPORTER.CORE.SCORES WHERE trace_id = $canary_trace;
-- Repeat for each returned score ID:
-- CALL LANGFUSE_EXPORTER.CORE.VERIFY_SCORE($canary_destination, '<score ID>');
```

Check returned results, observation count/identity and session chat in Langfuse;
check both projects for isolation. Do not accept empty comparisons as success.
Use the complete acceptance list in STATUS.md. Never replay accepted spans to
correct their fields: Langfuse v4 observations are immutable and repeats can duplicate.

## Recovery and rollback

HELD_IDENTITY_MISMATCH leaves delivery state and payload intact. Restore the original
alias host/project and keys, then retry the normal procedure. Do not change frozen
identities or move old queued deliveries to a new project. Readback applies the same
identity check. UNCERTAIN/PARTIAL items require reconciliation; capped readback is
inconclusive and cannot promote a delivery.

A stored score lacking a delivery is picked up on the next publisher pass, using
its saved ID, root observation, value and timestamp. Existing deliveries in any state
are not recreated. This repair requires one publisher; concurrent writers remain unsupported.

If candidate deployment fails, keep scheduling suspended. Restore captured V1
procedure definitions only after deciding how to handle CONFIG_ERROR/HELD_FOR_ROUTING
rows; old routing logic will not automatically understand the new error state.
Prefer fixing configuration and re-running the candidate. Never roll back by deleting
SCORES, DELIVERIES or TRACES. The additive 02c columns may remain. The original full
99 uninstall drops the database, including the new view/columns; it is not a rollback.

## Optional AI-assisted path

Use the [versioned CoCo interview](../deploy/coco/00_START_HERE.md). Build its upload
package with `python3 tools/build_coco_package.py --output /tmp/coco-v1.2` from a clean
checkout; the package pins HEAD and contains the same scripts. Agents must interview
for volume/window length and limits as well as routes, credentials and cadence.
They must not assume this version supports 80k/window or that a canary proves capacity.


Give the Snowflake AI agent these same candidate files and the edited 03a mapping.
Ask it to follow this sequence, preserve bindings and existing accepted data, inspect
results after each dependent step, and stop before activating scheduling until the
fresh canaries pass. It should report exact scripts executed and checks observed;
it must not substitute an invented mapping or claim the manual path was replayed.
