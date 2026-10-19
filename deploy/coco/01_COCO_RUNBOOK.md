# CoCo runbook

## 1. Orient and discover

Read 00_START_HERE.md, SOURCE.json, reference/docs/INSTALL.md and reference/docs/STATUS.md. Use the exact bundled revision. Preserve reference/ unchanged and generate an account-specific configured/ copy. If you cannot access attachments or execute SQL, say exactly what is unavailable and provide the equivalent worksheet instructions. Never report a proposed action as executed.

Start with read-only account discovery using available tools. Record current account, region, role and warehouse privately; list accessible Cortex Agents and inspect whether the proposed exporter database, role, warehouse, integration and secrets already exist. Use names and counts in summaries, not raw prompts or unrelated rows. SHOW results only establish objects visible to the active role. Verify source access and attribute shapes as privileges permit; a pre-grant permissions failure is not proof that telemetry is absent.

Read-only starting queries:
```sql
SELECT CURRENT_ACCOUNT(), CURRENT_REGION(), CURRENT_ROLE(), CURRENT_WAREHOUSE();
SHOW AGENTS IN ACCOUNT;
SHOW DATABASES LIKE 'LANGFUSE_EXPORTER';
SHOW ROLES LIKE 'LANGFUSE_EXPORTER_ROLE';
SHOW WAREHOUSES LIKE 'LANGFUSE_EXPORTER_WH';
SHOW INTEGRATIONS LIKE 'LANGFUSE_CLOUD_EAI';
```
Use selected names instead of defaults if supplied. Confirm that this is the intended NEW account. If matching infrastructure exists, inspect ownership and purpose before using it; step 01 transfers database ownership. A name collision is not permission to replace or take ownership. Offer a fresh namespace or use the documented upgrade path when it really is an existing exporter.

Done: account context and access limits recorded; reference package readable; fresh-install versus existing-install status established.

## 2. Interview in short rounds

Ask at most three questions per round. Offer concrete choices and defaults, allow free text, and carry forward answers already given. Resolve discoverable details yourself. Explain consequences with the question. Record unresolved values as null, never invent them.

Round A — scope:
1. Which discovered agent(s) should we use for a fresh browser canary? If none exist, should we create a minimal test agent using available authorised data, or will you supply one? Creating an agent and choosing data is a separate agreed subtask; do not invent semantic models or assume sample data exists.
2. Final mapping: all agents to one project; explicitly selected agents; or a shared default with exceptions/separate projects? Ask for excluded databases/schemas/agents. Recommend an explicit canary agent during initial validation, with the requested final map recorded separately.
3. May selected agents' historical runs also be exported? The first staging pass reads available history, and account routes include future agents. The exporter also stages account-wide raw telemetry even when routes export only selected agents. It has no first-class “new runs only” switch or general redaction. If those constraints conflict with requirements, hold staging and propose a separately reviewed code change; do not fake a cutoff by advancing a watermark.

Round B — Langfuse destinations:
1. For each destination: exact HTTPS base URL, project label and actual project ID (from project settings/URL). Public labels and IDs are configuration, never credentials. Confirm v4 compatibility for self-hosted installations.
2. Should multiple agents share a destination? Collect exact database/schema/agent names and exclusions. Return a small mapping table for review.
3. Are credentials already in Snowflake secrets, or will the user create one secret per project privately? Ask for secret object names and readiness, never keys. Project IDs supplied by the user remain unverified until authenticated connectivity confirms them. If the user cannot find an ID, guide private retrieval from their project settings or authenticated project API; do not put a fabricated ID into 03a.

Round C — volume (before sizing):
1. How many traces arrive per window, and how long is that window? Is 60k–80k a one-off backlog or sustained traffic? Gather average/p95 spans per trace and payload bytes where measurable; record unknowns, not guesses.
2. What export latency and exporter compute budget are acceptable? Collect warehouse type/generation/size and desired schedule. Read reference/docs/SCALING.md; defaults do not guarantee high-volume throughput.
3. Start with functional validation only, or also an agreed synthetic/representative load test in disposable projects? Record a volume/cost cap before generating load. No real account or Langfuse performance has been pre-verified.

Round D — operation:
1. TRACE_FIRST (recommended): publish eligible traces without waiting for billing, then credit scores later; or COST_READY: wait for the selected billing components? Both are polling-based. Default required component is TOKEN_CREDITS. Optionally include SQL_QUERY_CREDITS if required, with its extra latency; never require AI_FUNCTIONS_CREDITS. Credits are not USD, and cost-ready scores still travel separately.
2. Keep default dedicated objects, XSMALL warehouse, 60-second auto-suspend, 15-minute schedule and five-minute quiet threshold? Offer 60-minute scheduling or manual-only for lower exporter activity. At 15 minutes the schedule can wake the warehouse 96 times/day. Read 03_PARAMETER_MAP.md before accepting alternate names.
3. Can an authorised role create the account-level grants/integration, and is outbound telemetry permitted? Confirm full-content export for the chosen scope and whether scheduling should start automatically after the agreed acceptance checks pass, or remain manual. Record this once; do not ask the same approval again later unless scope changes.

Done: completed config has the intended account, object plan, every destination, initial and final routes, historical-data decision, publication policy, scheduling preference and credential handoff. Summarise the concrete objects, privileges, outbound data scope and cadence before the first mutation. Respect permissions already granted by the user; ask only for genuinely missing decisions or elevated actions.

## 3. Prepare configured scripts

Follow 03_PARAMETER_MAP.md. Produce configured/ SQL, a config.resolved.json without keys and a concise changes.md listing each adaptation from the pinned source. Keep transport/payload semantics intact unless a demonstrated compatibility error requires a documented fix.

Use the same scripts for both CoCo execution and a human worksheet replay. Prefer default infrastructure names when acceptable, but make destination and agent mappings explicit. Remove unused example destinations and placeholder routes. Review seeded destinations and the initial account-wide route in 02 before executing any staging. Use 03a as the complete active route map. Do not create a partially configured account-wide default as a shortcut.

Create separate install, credential-template, canary and activation stages. Each stage has a stop boundary; never concatenate everything into Run All. Keep 99_uninstall outside execution stages. Source comments containing old expected row counts, “TEST” or “step 06” are historical notes, not this account's acceptance targets. There is no shipped 06 file: 04_ACCEPTANCE.md provides that step. Feedback export is not implemented despite old comments.

Keep placeholders only in the private credential worksheet template and any explicitly unexecuted future stage. Before each executable stage, check that its required identifiers, URLs, project IDs and routes are concrete and correctly escaped. If shell tools are available, run the bundled tests before adaptation and equivalent tests against the configured copy; distinguish offline from Snowflake compilation. Review every changed embedded SQL/Python reference if names changed.

Add configured v1.2 limit UPDATEs after 03a, using the resolved configuration. Keep
COUNT, SPAN, BYTE, REQUEST, SCORE and TIME limits explicit. Keep single-publisher
execution. Distinguish per-trace delivery rows from multi-trace HTTP envelopes.

Done: configured scripts are reviewable, complete for the selected stage, with no real credentials, no unintended scope and consistent secret bindings across all five network procedures.

Run SET and dependent statements in one Snowflake session. If tool calls do not preserve sessions, use a verified, correctly quoted explicit user identifier for the role grant and retain that executed statement in the receipt.

## 4. Install in dependency order

Use reference/docs/INSTALL.md as the canonical sequence. Inspect statement results, including procedure-returned JSON, at each boundary. Record SQL query IDs and errors. Stop dependent work on a failure; correct the minimum necessary change and preserve its diff.

1. Run configured 01, then 02, 02b, 02c, 02d. Verify role, ownership, warehouse, source permissions and schema. Skip unnecessary content samples in chat; retain only proof needed for setup.
2. After schema creation, provide private credential worksheet templates for the selected secret names. The user enters credentials outside this conversation and reports completion. Run configured 03 after the secrets exist: network rules, external access integration, grants and connectivity definition. Check the first seeded destination. Account eligibility may prevent external access (509009 occurred previously); surface the exact error without claiming every new account has the same restriction.
3. Apply configured 03a with the initial canary map and real project IDs. Call LANGFUSE_CONNECTIVITY_CHECK for EVERY destination, requiring successful health/authentication and the actual expected project identity. Confirm aliases and allowed hosts before any publication. A settings-provided ID is now verified only if the authenticated result matches.
4. Install configured 04, 05_message_normalizer, 05a, 05b, 05c and 05d in order. Apply selected destination policy fields before staging. Run normalizer fixtures; inspect compilation and return values. Scheduling remains suspended/absent.
5. Execute the fresh canary procedure in 04_ACCEPTANCE.md. All initial sends must specify a single fresh TRACE_ID. An unfiltered PUBLISH_DESTINATION call or PUBLISH_ALL_DESTINATIONS can publish older routed history.
6. Apply the user's final route map only after initial validation, with publishing idle. Resolved ROUTED/EXCLUDED traces are frozen; changing routes does not move those historical decisions. Validate final routing with fresh conversations. Do not add blanket exclusion rules during canary setup merely to suppress other agents: EXCLUDED decisions also freeze. Unmatched agents can remain UNROUTED until the final map is applied.
7. Install configured 07 only for a new task graph, then 07a for its queue view. Both tasks are created suspended; verify their dependency. Follow the agreed activation choice once required checks pass. Use configured 08_activate.sql to resume child then root. If manual-only, leave both suspended. Verify task history AND delivery results; task success alone is insufficient. Do not run a manual publisher while the graph is active.

Done: procedures compiled, exact canaries have readback evidence, final scope verified and tasks in the agreed state. For high-volume use, complete the agreed benchmark from reference/docs/SCALING.md before calling capacity accepted. Billing still pending is recorded as pending; use the agreed acceptance criteria to decide whether activation must wait.

## 5. Handoff and evidence

Return the configured SQL, non-secret configuration, changes.md, filled 05_EVIDENCE report and a manual installation sequence. Include precise pending items with the next query/action. If CoCo cannot read Langfuse's UI, ask the user for the narrowly specified UI verification and label it USER-REPORTED, not independently observed.

Use PASSED, FAILED, PENDING, NOT RUN, USER-REPORTED per check. Keep observed, inferred and proposed claims separate. Never equate an offline pass, an HTTP status or an empty source query with complete deployment acceptance. Explicitly report “AI-assisted installation” unless a human independently replayed the manual route.

For uncertainty/retries, consult reference/docs/OPERATIONS.md and LIMITATIONS.md. Reconcile uncertain/partial deliveries; missing readback does not prove non-delivery. Never resend accepted immutable observations to change roles, cost, hierarchy or metadata. Use fresh conversations after a mapping fix. Scores must target actual root observation IDs. Do not manufacture hierarchy or claim exactly-once delivery.

Finish with: what runs where; final route table; cadence; checks passed/pending; suspension command; cleanup file and its consequences. Uninstall requires a separate explicit request and does not erase data already sent to Langfuse.

Version check: SOURCE.json and reference/VERSION must agree on 1.2.1. Do not use an older 05b with new deployment assumptions.
