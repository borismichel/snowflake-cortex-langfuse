# Validation status · v1.2.1

## Deployment evidence

On 15 October, the user supplied CoCo’s deployment receipt and configured SQL. CoCo reported that all running procedures, the function and both tasks matched its files; views were not checked. The supplied 02d migration, v1.2 sender and 07a view were byte-identical to public commit 6d9e3c3. This establishes source reconciliation and reported deployment, not an independent manual replay or live failure/scale acceptance.

Version 1.2.1 ports the generic installation corrections and fixes score HTTP-session reuse. These new changes still require live acceptance. Account/project-specific configuration and private deployment records are not published.

## Deployment corrections carried into 1.2.1

| Supplied deployment change | Canonical source |
| --- | --- |
| Remove automatic account-wide route | `sql/02_core_tables.sql`; explicit map remains in 03a |
| Correct task clause order; create publisher child suspended | `sql/07_tasks_status.sql` |
| Separate activation, child before root | `sql/08_activate.sql` |
| CoCo session-variable boundary | `docs/INSTALL.md` and the CoCo installation runbook |
| Individual score HTTP connection reuse | `sql/05b_sender.sql`, with a regression test |

The supplied initial/final route worksheets and policy/limits UPDATEs were deployment configuration, not portable code fixes. Their agent names, account identifiers and project ID are intentionally omitted. Configure the equivalent initial/final scope in 03a and record chosen policy/limits in the CoCo configuration and generated worksheets. Defaults remain TRACE_FIRST, TOKEN_CREDITS, five-minute span age, 24-hour overdue threshold and the documented v1.2 batch budgets.

## Implemented

- v1.2 multi-trace OTLP packing with UTF-8 byte, span and trace caps; frozen per-trace
  payloads remain the reconciliation source. HTTP batches persist exact bodies and
  membership, with atomic multi-member claim/finalisation and bulk attempt updates.
- Set-based per-trace span membership inserts with atomic enqueue; independent bounded
  score work and missing-component candidate selection; HTTP connection reuse.
- Version/migration, updated diagrams, sizing/credit benchmark and versioned CoCo package builder.


- Added 03a as the complete operator-owned active agent/project mapping. It supports
  shared projects, separate projects and exclusions; no credentials in configuration.
- Resolve specificity before destination validity. Invalid overrides and ambiguous
  winners are CONFIG_ERROR, with candidate IDs and a reason. Freeze the selected
  rule fields alongside the existing host/project/policy snapshot; no history rewrite.
- Enforce delivery host/project/alias before claim, also in the conditional claim.
  Held queued work cannot silently follow a repointed alias. Readback validates the
  frozen identity and credentials' actual project as well.
- Recover orphan credit-score deliveries from persisted score fields on later runs.
- Treat a remaining pagination cursor as incomplete readback; do not promote it.
  Reconciliation rejects empty expectations and unexpected observation IDs.
  Score checks refuse potentially capped results and assert unique ID, numeric type
  and observation subject. Semantic checks compare full generation input/output.
- Prepare standalone SQL from the routing safety candidate. Remove the sample
  project-ID seed and historical canary calls from the candidate definition files.
  Disable 07's implicit one-time task execution.

## Validation

Run from the repository root with Python 3.11 (local checks also run on 3.9):

```sh
python3 -m unittest discover -s tests -v
```

42 offline regression tests pass, including the eleven original normalizer fixtures and a
known leading-tag boundary probe. Tests execute the shipped resolver SELECT using SQLite with an ARRAY_AGG adapter,
and actual embedded Python handlers using mock Snowpark/HTTP interfaces. This checks
route decision behavior and local failure handling. It is not Snowflake compilation,
transaction/warehouse validation, HTTP integration or evidence of deployment.
The private archive checksum test is excluded from this standalone public snapshot. CI runs the same offline suite.

## Required live acceptance before promotion

- Compile 02d and changed 05b/07 in Snowflake; validate scoped transaction rollback and
  multi-trace member state under partial response, timeout and crash after POST.
- Verify byte/span caps and oversized-trace holds against real OTLP. Confirm backlog/score
  fairness and all scale/credit acceptance in [SCALING.md](SCALING.md). NOT RUN.


- Compile 02c/03a/04/05b/05c/05d in a disposable Snowflake environment. Confirm failed
  03a validation changes no persistent mapping rows and a valid apply is atomic.
- Replay a fresh manual install. A second person can use the AI path through the same files.
- A/B share project 1, C appears only in project 2; verify both positive and negative
  project readbacks. Test exact names, account/schema overrides and exclusions.
- Broken/paused destination and equal-specificity conflict: CONFIG_ERROR, no default
  routing and no POST. Repair then stage: unresolved trace resolves successfully.
- In a disposable setup, change a queued destination's host/project outside 03a:
  sender/readback refuse it. Restore original identity; no frozen payload changes.
- Interrupt after score persistence but before enqueue: next run creates one delivery
  with the same score identity/value/timestamp. Repeat after enqueue: no second delivery.
- Verify root scores, full generation messages/tool pairs and session chronology.
  Do not resend accepted spans for these tests; use fresh IDs.
- Inspect task graph status AND publisher results/delivery states before activation.

## Remaining limits

One publisher is still required. Standard-table uniqueness, concurrent writers,
exactly-once delivery and crash recovery across every HTTP boundary are not solved.
Route matching validates table configuration; runtime secret bindings require an
explicit connectivity check. Table edits must happen while scheduling/publishing
is quiescent; arbitrary concurrent configuration writers are not supported.

TRACE_FIRST is polled telemetry, not instant instrumentation. COST_READY waits for
configured billing components; scores are delivered separately. Credits are not USD.
Source overlap/quiet-window semantics, late spans, feedback export and leading literal
system-reminder ambiguity remain as documented in [LIMITATIONS.md](LIMITATIONS.md). Semantic
S8 is now honestly labelled as checking the sent mapping version, not remote metadata.
Score readback refuses 100-row results rather than claiming exhaustive pagination.

## Primary references checked

- [Langfuse v4 ingestion](https://langfuse.com/integrations/native/opentelemetry/migration-to-v4): immutable observations and project-authenticated OTLP.
- [Langfuse data model](https://langfuse.com/docs/observability/data-model): observation, trace and session identities.
- [Snowflake QUALIFY](https://docs.snowflake.com/en/sql-reference/constructs/qualify): window filtering in the existing staging code.

The transport uses the Langfuse v4 OTLP/HTTP contract. No SDK dependency was added.
The current live deployment was not queried when preparing this public snapshot.

The original V1 was exercised on browser runs. This repository contains the later
routing safety candidate, not a claim that those changes were deployed. Screenshots
show an earlier development run and are illustrative, not acceptance evidence for
this exact snapshot. The message adapter was checked on three development traces;
input-token semantics for `claude-opus-5-5` were compared with the usage view on two
requests / six model steps. Other models keep raw counters without normalised usage.

Local packaging and handler tests are not new-account or high-volume deployment evidence.
