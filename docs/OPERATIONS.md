# Operations and recovery

Complete the [fresh canary checks](INSTALL.md#preview-and-canary) before scheduling.
Use one publisher; do not combine manual publishing with a running task graph.

## Scheduled publication

Run `07_tasks_status.sql` only when creating a new graph. It creates the suspended
root `STAGE_AND_ROUTE_TASK`, publisher child `PUBLISH_TASK` and health views. Its one-off `EXECUTE TASK` is commented. Verify both tasks and their dependency. After canary acceptance, run `08_activate.sql`, which resumes the child before the root:

```sql
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;
SHOW TASKS IN SCHEMA LANGFUSE_EXPORTER.CORE;
ALTER TASK LANGFUSE_EXPORTER.CORE.PUBLISH_TASK RESUME;
ALTER TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK RESUME;
```

The supplied schedule is every 15 minutes. To stop new scheduled runs:

```sql
ALTER TASK LANGFUSE_EXPORTER.CORE.STAGE_AND_ROUTE_TASK SUSPEND;
```

An already-running graph can finish. Wait for it before configuration changes,
procedure replacement or manual publishing. Do not recreate an active graph as an
upgrade shortcut; follow [upgrade instructions](INSTALL.md#upgrade-the-existing-v1-account).

## Health and delivery

```sql
SELECT * FROM LANGFUSE_EXPORTER.CORE.EXPORTER_HEALTH_V;
SELECT * FROM LANGFUSE_EXPORTER.CORE.TRACE_STATUS_V ORDER BY trace_start_utc DESC;
SELECT * FROM LANGFUSE_EXPORTER.CORE.DELIVERY_STATUS_V
 WHERE status IN ('UNCERTAIN', 'REJECTED', 'PARTIAL');
SELECT * FROM LANGFUSE_EXPORTER.CORE.BILLING_OVERDUE_V;
SELECT * FROM LANGFUSE_EXPORTER.CORE.LATE_SPANS_V;
SELECT * FROM TABLE(LANGFUSE_EXPORTER.INFORMATION_SCHEMA.TASK_HISTORY(
 TASK_NAME => 'PUBLISH_TASK', RESULT_LIMIT => 20));
```

Inspect procedure results, delivery attempts, paused destinations and backlog as well
as task history. `PUBLISH_ALL_DESTINATIONS` catches destination errors, so a successful
task can contain failed publication. Health views are not automatic alerts.

## Recovery

- `CONFIG_ERROR`: inspect `route_error` and `route_candidates`, fix the active map,
  then stage again. Already-resolved routes stay frozen.
- `HELD_IDENTITY_MISMATCH`: restore the original alias host/project and matching keys.
  Do not repoint queued work or change frozen payloads to bypass the check.
- `UNCERTAIN` or `PARTIAL`: call `RECONCILE_DELIVERIES('<alias>', 20)` and inspect the
  full result. Missing or capped readback does not justify replay. `MARK_FOR_REPLAY`
  is a deliberate operator action, not a standard retry shortcut.
- Orphan credit scores without a delivery are recovered on a later publisher pass
  from persisted IDs, values and timestamps. Existing deliveries are not recreated.

For key rotation, suspend scheduling, wait for current runs, replace the secret for
the **same host/project**, run connectivity and a dry run, then clear any resolved
pause and resume. Preserve all procedure secret bindings:

```sql
CALL LANGFUSE_EXPORTER.CORE.LANGFUSE_CONNECTIVITY_CHECK('<alias>');
CALL LANGFUSE_EXPORTER.CORE.PUBLISH_DESTINATION('<alias>', 20, TRUE);
-- Only after fixing and verifying the reason for the pause:
UPDATE LANGFUSE_EXPORTER.CORE.DESTINATIONS
 SET paused_reason = NULL, paused_at = NULL WHERE destination_id = '<alias>';
```

## Cleanup

`99_uninstall.sql` is destructive. Review it, stop scheduling and wait for active work
before executing it as `ACCOUNTADMIN`. It drops exporter infrastructure, staged data,
secrets and delivery history. Source telemetry and data already in Langfuse remain.
Revoke project API keys separately in Langfuse. Any additional integrations, network
rules or secrets you created outside this script’s default objects need separate cleanup.
This is not a rollback procedure.

## v1.2 batching and queue monitoring

Read [SCALING.md](SCALING.md) before tuning limits. `PUBLISH_DESTINATION(alias, NULL,
FALSE)` uses the destination's trace limit; an explicit MAX_ITEMS only reduces that
limit. Scores have a separate cap. Use ONLY_TRACE_ID for a single-canary publication.
Partial HTTP batches are reconciled per trace by the existing reconciler. HTTP_BATCHES
is an immutable-body transport audit; its status need not change when individual
members later reconcile successfully. There is no automatic replay of an entire partial batch.

```sql
SELECT * FROM LANGFUSE_EXPORTER.CORE.PUBLISH_QUEUE_V;
SELECT destination_id,status,COUNT(*) AS requests,
       SUM(OCTET_LENGTH(request_body)) AS request_bytes
FROM LANGFUSE_EXPORTER.CORE.HTTP_BATCHES GROUP BY 1,2;
```

The audit stores another copy of exported content; apply appropriate access and retention.
No automatic pruning is provided. Monitor both backlog depth and oldest age. Source
READY traces not yet queued are separate from pending deliveries; inspect TRACE_STATUS_V
as well. `max_run_seconds` is cooperative, not a guarantee of warehouse runtime.
