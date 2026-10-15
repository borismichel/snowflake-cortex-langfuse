# Configuration → executable SQL

The JSON describes installation choices. It does not run anything and the exporter never reads it. CoCo writes a resolved JSON and configured SQL. The template's route_row_shape is an example, not an active route; remove it from the resolved document. Preserve null for unknown answers. A destination cannot be published until its identity is verified.

## Parameter map

| Choice | Required adaptation |
| --- | --- |
| Runtime role, warehouse, database, schema | 01 and every USE/qualified identifier across all SQL; also string constants and embedded queries in Python handlers, helper procedures, views, tasks, checks and cleanup. Keep Snowflake's source databases unchanged. Defaults minimise this work. |
| Administrative role | Account-level portions of 01/03; verify its actual grants. Being able to query is not proof of permission to grant or transfer ownership. |
| Warehouse size/auto-suspend | 01 CREATE WAREHOUSE; IF NOT EXISTS does not reconfigure an existing warehouse. Existing shared objects require explicit review. |
| First destination alias/host/secret/integration | Seed in 02, network/secret/integration/check in 03, destination rows in 03a, every network procedure binding and sample calls. Remove or replace the broad seed route before staging. |
| All other destinations | One secret per project; 03 network-rule host allowlist, integration allowed-secret list and grants; 03a destination rows; all five procedure SECRETS clauses. Table values alone do not establish bindings. |
| Final routes | Entire DESIRED_ROUTES table in 03a. It disables omitted active rules. Keep initial canary and final variants as separate saved files. |
| Publication mode | DESIRED_DESTINATIONS publication_mode in 03a (TRACE_FIRST or COST_READY). |
| Billing components, quiet threshold, overdue threshold, environment | Explicit destination UPDATE statements after 03a and before first staging; these fields are not exposed by 03a's six-column VALUES table. Keep publication_mode and required_billing consistent; selected policy is frozen at routing for relevant fields. |
| Publisher limits | Run 02d before 05b. Apply destination publisher_limits as explicit UPDATEs after 03a and before staging/dispatch; see reference/docs/SCALING.md for ranges. They are not part of 03a VALUES. |
| Schedule | 07 SCHEDULE for the root and explicit publisher child creation; activation in a separate stage. |
| History cutoff/redaction | Not implemented as configuration. Route scope does not filter raw staging. Discuss a code change before promising these behaviours. |

New infrastructure names/aliases should use simple unquoted uppercase identifiers (letters, digits, underscore, beginning with a letter) where possible. Validate each; reject statement delimiters and escape SQL string literals with doubled apostrophes. Existing agent selectors are data strings and retain their exact recorded case, including characters such as `$`. Do not upper-case source selector values or use a blind whole-document prefix replacement. Review transformations of embedded Python/SQL as code.

A Langfuse host is the HTTPS base URL, without credentials, query/fragment or /api/public suffix. Network rules need the corresponding hostname and port. Preserve any supported deployment base path deliberately; test it. Credentials and base64 authorization strings never go into config files or logs.

## Binding checklist

Every alias must appear in the SECRETS clause of all five procedures:

| File | Procedure |
| --- | --- |
| 03_network_secret_integration.sql | LANGFUSE_CONNECTIVITY_CHECK |
| 05b_sender.sql | PUBLISH_DESTINATION |
| 05b_sender.sql | RECONCILE_DELIVERIES |
| 05c_verify_scores.sql | VERIFY_SCORE |
| 05d_verify_semantics.sql | VERIFY_TRACE_SEMANTICS |

Add all required external access integrations to those procedures too. Their alias string equals destination_id exactly. Keep all existing bindings if this turns out to be an upgrade. Use one stable alias for one host/project; new projects get new aliases. Verify every destination independently.

## Route choices

- One shared project: one destination plus ACCOUNT route (all current/future visible agents).
- Selected agents only: AGENT rows, each with exact database/schema/name; all other agents remain UNROUTED.
- Several agents sharing: their AGENT rows reference the same destination_id.
- Separate projects: different destination IDs and separate secrets/bindings.
- Shared default plus exception: ACCOUNT route plus a more specific AGENT/SCHEMA/DATABASE route.
- Exclusion: a specific EXCLUDE row with destination_id NULL. A still more specific route can override a broader exclusion.

Precedence: AGENT > SCHEMA > DATABASE > ACCOUNT. Conflicting equal-specificity routes are errors; invalid winning destinations never fall through to a default. Use NULL in unused selector fields. One trace has one destination; fan-out is not supported. Review effective outcomes for all known selected/excluded agents before publication.

## Policy update example (template only)

```sql
-- Substitute actual selected identifiers/alias; run BEFORE first STAGE_AND_ROUTE.
UPDATE LANGFUSE_EXPORTER.CORE.DESTINATIONS
SET required_billing = ARRAY_CONSTRUCT('TOKEN_CREDITS'),
    quiet_minutes = 5,
    billing_overdue_hours = 24,
    environment = 'development'
WHERE destination_id = '<selected alias>';
```

Environment is an optional label; choose it in the interview rather than assuming production. Keep publish_anomalies FALSE. Default source overlap is 120 minutes; it does not guarantee eventual delivery of arbitrarily late source rows. The quiet threshold measures age since span end, not time since ingestion.

## Credential handoff

Generate a separate private worksheet template per project after schema creation, using the chosen role and secret FQN:

```sql
USE ROLE LANGFUSE_EXPORTER_ROLE;
CREATE SECRET LANGFUSE_EXPORTER.CORE.<SECRET_NAME>
TYPE = PASSWORD
USERNAME = '<LANGFUSE_PUBLIC_KEY>'
PASSWORD = '<LANGFUSE_SECRET_KEY>';
```

The human privately substitutes and executes it. For existing secrets, inspect ownership/type and ask for the appropriate reuse or rotation decision; do not replace silently. Removing a worksheet does not erase Snowflake query history. Follow the account's secret-handling policy. Return only secret names/readiness and authentication result, never secret values.

## Canonical references checked 15 October 2026

- https://langfuse.com/integrations/native/opentelemetry — OTLP HTTP endpoint, v4 header and authentication. The bundled sender uses direct HTTP/JSON, not a Langfuse SDK.
- https://docs.snowflake.com/en/developer-guide/external-network-access/creating-using-external-network-access — network rules, secrets and external access integrations.
- https://docs.snowflake.com/en/sql-reference/account-usage/cortex_agent_usage_history — usage/credit fields and latency. The view can lag up to one hour; SQL credits can arrive up to eight hours after the rest of the row. Do not represent absent billing as zero.

Preserve the pinned Python 3.11 procedure runtime and existing package declarations unless a real account compatibility issue requires a recorded change. Snowflake resolves unpinned snowpark/requests packages; record resolved versions if available. This is not a claim of byte-for-byte reproducible dependencies.

Runtime uses frozen per-trace rows plus multi-trace HTTP_BATCHES. Preserve both during upgrades and uncertain-send recovery.
