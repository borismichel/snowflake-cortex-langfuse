# Behaviour and limitations

This is an experimental community exporter. See [validation status](STATUS.md) for
what has actually been checked. The original V1 results do not validate the newer
routing safeguards in this snapshot.

## Timing and coverage

- Scheduling defaults to every 15 minutes. The default five-minute quiet threshold
  measures age since the latest non-omitted span ended, not silence since row arrival.
  Source lag, retries and task duration add delay. There is no worst-case latency guarantee.
- An overlapping source read reduces missed rows but is not a delivery guarantee.
  Rows older than its overlap window can be missed. Late spans after publication are
  reported through `LATE_SPANS_V` but are not exported.
- The first staging pass can include historical source rows. Account-wide routes
  also cover future agents whose events become visible. Configure scope first.
- Feedback/thumbs-up/down export is not implemented, despite the reserved staging table.

## Delivery and identity

Use **one publisher at a time**. Standard-table uniqueness is not an enforced lock.
Concurrent writers, exactly-once delivery and every crash boundary are not solved.
Accepted Langfuse v4 spans must not be resent to update their contents; duplicate
re-ingestion can produce duplicate observations.

Uncertain or partially accepted sends need readback and review. Missing readback is
not proof of non-delivery. Capped readback is inconclusive. Task success does not mean
all destinations delivered successfully, and the task graph does not verify readback.

A destination alias has one host and project. A trace freezes that identity and its
routing configuration. Use a new alias for a new project; do not edit frozen delivery
identities. Route edits only affect unresolved traces. One trace cannot fan out to
several projects. Configure routes while publishing and scheduling are quiescent.

## Messages, hierarchy and usage

The adapter reconstructs role-typed messages from recorded Snowflake attributes. It
is not proof of exact provider-prompt chronology. Full model context can repeat across
steps; the agent root contains the current turn’s question and answer.

Recognised leading `<system-reminder>` blocks become system messages. A complete
user-authored block at the beginning is indistinguishable from injected context in
this parser and can be classified as system without an ambiguity flag. Unknown formats
are preserved under `unparsed_source_messages` and may not render as chat. API role
checks do not establish session-view rendering; inspect the UI on a fresh canary.

Only the `claude-opus-5-5` inclusive-input token convention was checked against source
billing during development. For other models, raw counters remain metadata and
normalised usage is omitted until the convention is verified. Model names and source
attribute shapes can change; extend with evidence and regression fixtures.

Two source exceptions are handled under strict conditions: negative-duration
`UserMemoryInjection` spans are omitted with metadata, and certain duplicate tool span
IDs are deterministically re-identified with the original ID retained in metadata.
Other anomalies hold the trace. Inspect `OMITTED_SPANS_V`, `REIDENTIFIED_SPANS_V` and
`ANOMALY_DETAIL_V` when comparing hierarchy; these are adapter decisions, not repaired
source data.

## Billing and content

Snowflake token and SQL-query credits are exported as separate root observation scores,
not USD and not an atomic part of the trace send. `COST_READY` waits for configured
components; the default requirement is token credits only. Do not require
`AI_FUNCTIONS_CREDITS`: this implementation does not export it and an unused value can
legitimately be NULL. SQL credits may arrive much later; Adaptive Warehouse queries are
not included in the referenced usage view’s SQL-query credit reporting.

The code does not provide general content redaction. Prompts, responses, tool results,
SQL and identifiers can leave Snowflake. Review data handling before broadening scope.

References: [Langfuse v4 ingestion](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4),
[Snowflake usage view](https://docs.snowflake.com/en/sql-reference/account-usage/cortex_agent_usage_history).
