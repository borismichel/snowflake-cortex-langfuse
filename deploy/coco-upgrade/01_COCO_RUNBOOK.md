# CoCo existing-installation update

## 1. Read and inventory — no mutations yet

Read SOURCE.json, reference/VERSION, reference/docs/INSTALL.md (upgrade sections),
SCALING.md, OPERATIONS.md and STATUS.md. Verify the package version is 1.2.0. Start with
read-only discovery; resolve existing names before executing any default-name query.
If you cannot inspect live objects, give precise read-only queries to the user and
label the results user-reported. Missing permissions are not proof an object is absent.

Record account/role/warehouse privately. Discover exporter database/schema, role and
warehouse properties; SCHEMA_VERSION; DESTINATIONS and ROUTES; source grants; existing
Python procedure DDL including runtime, packages, SECRETS and EXTERNAL_ACCESS_INTEGRATIONS;
network/integration object names and ownership; task definitions, dependency edges,
schedule, enabled/suspended state, task timeout and recent graph history. SHOW SECRETS
metadata is sufficient; never request or output secret values. Avoid logging raw payloads.

Inspect DELIVERY/TRACES counts and states, especially IN_FLIGHT, UNCERTAIN, PARTIAL,
RETRYABLE, rejected work, and unresolved routes. Record accepted-delivery counts and
existing host/project identities so later comparison cannot be mistaken for a reset.
Compare live definitions with the bundled baseline and identify local fixes. Existing
working normalizer/model adapters may differ; replacing 05b must not erase intentional
local fixes without a reviewed equivalent.

Determine compatibility from columns AND live procedure behaviour, not a version number
alone. The routine path assumes the public routing-safety baseline: 02b and 02c fields,
frozen host/project/route identities, the current builder's output contract, and existing
score/semantic verification procedures. If those are missing, use the original V1 upgrade
section of reference/docs/INSTALL.md to prepare an additional explicit migration plan.
Do not treat a custom or old V1 account as a fresh database, run seeds, or replace its
complete route map from examples. Obtain missing live DDL before proposing substitutions.

Done: inventory, compatibility assessment and local customisations recorded; actual
object names and current state known. No deployment has yet been claimed.

## 2. Short upgrade interview

Ask at most three questions at a time; infer existing settings from live objects.

1. What trace volume arrives in each time window, and is it sustained or a one-off backlog?
   Measure typical/p95 spans and payload bytes where possible. Ask desired delivery latency
   and exporter credit budget. Explain that 60k–80k/window capacity is still unverified.
2. Keep existing projects/routes/publication mode/warehouse/cadence? Recommend preservation.
   Ask for changes only if requested. New keys are unnecessary when existing secrets work.
3. Use conservative v1.2 limits initially, and can a small fresh browser canary be exported
   to the existing project, or should we use a separate disposable destination? Record the
   allowed canary scope. Ask once whether previously active schedules may resume after
   successful checks, or should remain suspended. A previously suspended graph stays
   suspended unless the user explicitly requests activation.

If an existing backlog must drain without delay, explain the pause and plan an appropriate
maintenance window. Record whether billing validation must finish before resumption. Heavy
load tests need an agreed trace/cost cap and disposable scope; do not generate 80k runs
merely because the target volume is 80k. Fill 02_CONFIG.template.json without credentials.

Done: concrete upgrade plan, destination limits, canary and schedule decisions are known.
No repeated approval requests for actions already authorised within this scope.

## 3. Prepare exact upgrade and recovery artifacts

Keep reference/ unchanged. Produce configured/02d_migration_v12.sql,
configured/05b_sender.sql and configured/07a_batch_status.sql plus a separate limits
UPDATE worksheet. Adapt existing namespace, role and warehouse in SQL AND embedded Python.
Retain the UNION of required existing secret aliases/integrations in BOTH network procedures
in 05b; default LANGFUSE_TEST is an example, not the installation's identity. If no new
project/host is requested, existing credentials/network setup need no replacement.

If HTTP_BATCHES or limit columns already exist, inspect their types/meaning before reuse;
IF NOT EXISTS is not a schema compatibility check. On a repeated v1.2 update, preserve
operator-tuned values rather than resetting defaults. Migration 02d's SCHEMA_VERSION 12
is a schema marker, not independent proof of deployed code version. Record the package
commit separately in the deployment receipt.

Save exact current procedure DDL and task DDL plus a non-secret configuration snapshot
before replacing anything. Prepare rollback SQL from those actual saved definitions,
not the original repository defaults. Backup artefacts may contain private identifiers;
keep them within the account/private workspace. Do not publish snapshots to GitHub.

Do not execute 01, 02 or 02b fresh-install seeds, 03 credential creation, example 03a
routes, or 07 task recreation as the routine upgrade. Do not run 99_uninstall. Use 07a
for the queue view without replacing the graph. Review any additional compatibility
changes separately, listing exact objects affected and why they are required.

Done: exact configured SQL, before snapshots, diff and recovery plan are ready; no
placeholder alias, lost binding, changed destination identity or hidden scope expansion.

## 4. Pause, drain, apply

Suspend the existing root task (using its actual name), preserve child states, and inspect
TASK_HISTORY/graph status until every active run has finished. Suspension does not cancel
running work. Ensure no manual publisher is running. Do not overlap publishers.

Reconcile pre-existing uncertain/partial deliveries where possible. If unresolved, retain
those rows and document them; they must remain held, never reset to pending or automatically
replayed. Snapshot counts immediately before the actual schema/code changes.

Apply configured 02d, then 05b, then 07a sequentially, inspecting every statement result.
Apply the reviewed limits UPDATE without changing routes, frozen project identities or
publication policy. Existing pending trace deliveries are still per-trace and can be
packed by the new sender. Accepted deliveries must stay accepted. Failure at a step holds
dependent work and scheduling; correct the minimum change and retain its diff/query ID.

Check secret bindings, owner/grants and connectivity for each existing destination. Some
Snowflake replacement behaviours depend on grants; restore the captured caller grants
as needed without broadening them. Check that PUBLISH_ALL_DESTINATIONS now calls the
configured limits rather than the legacy hard-coded 20. Confirm task definitions/cadence
are otherwise unchanged and both called procedures exist with expected signatures.

Done: additive schema and adapted procedures compile; state retained; scheduling still
suspended. A compile pass alone is not an accepted upgrade.

## 5. Verify and restore agreed operation

Follow 03_ACCEPTANCE.md. Start with a single NEW trace via ONLY_TRACE_ID. Then test multiple
fresh traces deliberately. An unfiltered destination publish can dispatch older queued
work; do not claim it is restricted to new canaries. If that backlog is not authorised
for dispatch during validation, use an explicitly agreed disposable destination or stop
before the batch-send step. Do not rewrite historical route decisions to manufacture it.

Restore task states according to the recorded decision: previously suspended tasks remain
suspended; if authorised and checks pass, required children resume before the previously
active root. Preserve cadence, graph shape and warehouse. Observe one scheduled cycle
and inspect publisher results AND per-destination delivery states, not just task success.

If validation fails, leave the root suspended. For rollback, inspect every new request and
member state; reconcile any possible sends. Restore saved old procedure DDL/bindings only
after reviewing those states. Keep the additive table/columns and all frozen deliveries,
HTTP bodies and attempts. No deletion/reset/replay is part of rollback. If a failure occurred
after POST, old code rollback cannot undo the external delivery. Resume only after recovery
criteria and the user's existing authorisation permit it.

Done: report UPGRADED AND VERIFIED for the exact tested scope, UPGRADED WITH PENDING CHECKS,
or BLOCKED/ROLLED BACK with reasons. Return configured upgrade SQL, limits, backup/recovery
location, before/after evidence, exact pause/resume commands and remaining scale validation.
AI-assisted execution does not establish an independent human manual replay.
