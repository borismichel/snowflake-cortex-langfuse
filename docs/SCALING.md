# v1.2 batching, throughput and Snowflake credits

## Architecture and limits

Each `DELIVERIES` TRACE_BATCH row still represents ONE trace. The sender groups those frozen rows into an OTLP envelope whose resourceSpans contain multiple traces. It does not merge trace IDs, parents or sessions. `HTTP_BATCHES` records the exact request body, destination and member delivery IDs. Billing scores retain their own endpoint and persisted IDs.

Before POST, one scoped transaction claims every member, writes the envelope and starts per-trace attempts. If any claim fails, the transaction rolls back and nothing is posted. Final state and attempts update in another transaction. A process failure after POST leaves claims uncertain on recovery, never silently eligible for resend. The system still requires ONE publisher; standard-table uniqueness is not a distributed lock. Invoke publisher procedures outside a caller-managed transaction.

A partial OTLP acknowledgement does not identify rejected trace members. All members stay PARTIAL until each trace is reconciled against its original per-trace payload. Do not split and retry a partially accepted request. A malformed acknowledgement is UNCERTAIN. Readback promotion changes delivery/trace state; HTTP_BATCHES remains the historical transport outcome, not current per-member acceptance. Authentication failure pauses that destination.

Whole traces larger than configured limits are REJECTED with OVERSIZED_TRACE before POST. Inspect them, adjust reviewed limits if appropriate and use deliberate operator recovery. They are not automatically split or silently discarded. A trace rejected without POST is distinct from an uncertain send; preserve that evidence before any replay action.

## Configuration

Run 02d after 02c, before installing the v1.2 sender. Fields are on DESTINATIONS, independent of route selection:

| Field | Default | Valid range | Meaning |
| --- | ---: | ---: | --- |
| max_traces_per_run | 1000 | 1–10000 | New trace candidates / due trace selection per invocation |
| max_traces_per_request | 100 | 1–1000 | Whole traces in one OTLP request |
| max_spans_per_request | 1000 | 1–100000 | Spans across those traces |
| max_request_bytes | 1000000 | 1024–4000000 | Final uncompressed UTF-8 JSON envelope bytes |
| max_trace_requests_per_run | 20 | 1–1000 | Trace HTTP requests per destination invocation |
| max_scores_per_run | 100 | 1–10000 | Separate score creation/recovery/send caps |
| max_run_seconds | 300 | 10–3600 | Cooperative wall-clock budget per destination |

Ranges are local guardrails, not promises that a particular host accepts their maximum. Check your Langfuse endpoint/proxy limits. A manual non-NULL MAX_ITEMS further caps trace candidates; it does not override the independent score cap. ONLY_TRACE_ID restricts both trace and score work. Scheduled calls use NULL MAX_ITEMS, selecting destination limits.

Due trace payloads materialised in one pass are additionally capped at 16 MB (using stored JSON byte size). Requests use the actual combined UTF-8 size. Existing due trace work is drained before building new payloads. The budget reserves up to 40% for payload building, up to 60% cumulatively for score preparation, up to 75% for score sending and the remainder for trace requests. These are checks between operations, not hard query cancellation; a slow SQL statement or HTTP request can exceed them. Configure a suitable Snowflake task timeout separately. Several destinations run serially, so total graph time can exceed one destination's budget; missed schedule slots reduce throughput.

Use conservative defaults for functional canaries. Change settings while publishing is idle:

```sql
UPDATE LANGFUSE_EXPORTER.CORE.DESTINATIONS
SET max_traces_per_run=1000, max_traces_per_request=100,
    max_spans_per_request=1000, max_request_bytes=1000000,
    max_trace_requests_per_run=20, max_scores_per_run=100,
    max_run_seconds=300
WHERE destination_id='<reviewed alias>';
```

03a does not expose these fields; new destination rows inherit defaults. A separate reviewed UPDATE owns overrides. Do not set 80,000 as MAX_ITEMS and assume the window will drain.

## 60,000–80,000 traces per window

If the window is 15 minutes, arrival rates are 66.7, 77.8 and 88.9 traces/second respectively. Sustained export must exceed arrivals, with room for retries and delayed scores. At exactly 100 fitting traces per request, those volumes would require 600, 700 and 800 trace requests instead of 60k, 70k and 80k. This is request-count arithmetic, NOT measured throughput: span/byte caps often reduce traces per request, and score requests remain separate.

Default 1,000-trace selection every 15 minutes is at most 4,000 traces/hour per destination before time/byte limits and overhead. v1.2 is therefore not ready-made sizing for 80k every 15 minutes. The old 20-delivery default is removed, but capacity still needs measurement and further optimisation if the benchmark fails.

Remaining bottlenecks: BUILD_TRACE_PAYLOAD runs once per new trace with SQL reads; delivery enqueue is per trace with bulk span membership; score IDs/persistence are processed per missing component. The anti-join avoids returning already-scored history to Python, but the SQL engine may still scan history. Source staging/billing joins and anomaly views also revisit growing tables. No claim is made that all database work is set-based or bounded by the dispatch caps. Future work may require bulk payload reads, incremental billing/work queues and a different execution model; preserve identity and uncertainty handling through those changes.

## Credit measurement

Exporter warehouse credits are separate from Cortex model credits, tool-query credits and Langfuse charges. Snowflake charges warehouse compute by running time and configuration, with a minimum on resume; SQL and time spent awaiting external responses can extend the active procedure/warehouse interval. Batching can reduce network and bookkeeping overhead, but there is no guaranteed credit saving without a benchmark. Storage of staged events, frozen deliveries and HTTP audit bodies also grows; this version does not automatically purge them. Review storage and any applicable network/service charges separately.

Use a dedicated warehouse and record test start/end in UTC. Inspect actual warehouse metering (which has reporting latency), including idle time, rather than treating query-attributed credits or agent usage scores as exporter cost. Hour-level metering cannot precisely isolate a short shared-warehouse run.

```sql
-- Adjust time bounds and warehouse name. Run after metering data is available.
SELECT start_time,end_time,credits_used_compute,credits_used_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name='LANGFUSE_EXPORTER_WH'
  AND start_time >= '<UTC test-hour start>'::TIMESTAMP_LTZ
  AND start_time < '<UTC test-hour end>'::TIMESTAMP_LTZ
ORDER BY start_time;
```

Report exporter compute credits / 1,000 fully verified traces, with score delivery included or explicitly excluded, warehouse type/generation/size, elapsed time, bytes, spans, retries, remaining backlog and observation counts. Do not convert to money without the account's actual credit price.

## Live benchmark acceptance

1. Fresh installation and two-project canaries first. Keep manual and scheduled publishers mutually exclusive.
2. Use approved disposable projects and representative data distributions: spans/trace, payload bytes, model/tool types, billing delays. Synthetic volumes require explicit agreement on costs and data creation.
3. Ramp 100 → 1,000 → 10,000, then 60k/70k/80k only within the agreed budget. Compare request counts, SQL statement counts, duration and warehouse metering. Test several windows, not one burst.
4. Verify all expected traces/observations and project isolation with exhaustive readback. Validate root scores, sessions and message roles. Empty/capped readback is inconclusive.
5. Exercise byte/span caps, oversized traces, 429/backoff, partial acceptance and a crash after POST. Accepted data must not be automatically re-ingested.
6. Prove queue depth/oldest-age remain bounded at the target arrival rate; track both trace and score queues. Compare larger warehouse choices only if CPU/SQL, rather than network waits, is limiting.
7. Publish the evidence and remaining failures before asserting capacity. All of these live throughput/credit checks are currently NOT RUN.

Sources: [Langfuse OTLP](https://langfuse.com/integrations/native/opentelemetry), [OTLP partial success](https://opentelemetry.io/docs/specs/otlp/), [Snowflake warehouse billing](https://docs.snowflake.com/en/user-guide/warehouses-considerations), [warehouse metering](https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history).
