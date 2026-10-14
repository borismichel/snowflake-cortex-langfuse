# Prerequisites and network setup

Return to [the installation sequence](INSTALL.md) for file order. These steps require
no AI assistant and no external Python worker. Open scripts as Snowsight worksheets,
run dependent files sequentially and inspect each result. Do not run the uninstall file.

## Prerequisites

| Requirement | Check |
| --- | --- |
| Snowflake account eligible for external access | The development trial account rejected it with error `509009`; resolve account eligibility with Snowflake. |
| Account-level setup privileges | Scripts 01 and 03 use `ACCOUNTADMIN`. Adapt the role hierarchy if your organisation requires it. |
| A Cortex Agent with recorded runs | `SHOW AGENTS IN ACCOUNT;` and a browser conversation. Step 01 checks source visibility. |
| Langfuse v4 project and project API keys | Obtain keys and host from your project settings. |
| Intended export scope | Review unredacted content and routing before the first staging call. |

Step 01 creates `LANGFUSE_EXPORTER_ROLE`, `LANGFUSE_EXPORTER_WH` and
`LANGFUSE_EXPORTER.CORE`. It grants the runtime role account-wide AI observability
read access, unredacted event access, usage-view access and task execution privileges.
Review those grants. Routing limits what is exported, not what the role can read.

The XSMALL warehouse auto-suspends after 60 seconds. A 15-minute schedule can wake it
96 times per day. Exporter warehouse charges are additional to agent usage and Langfuse.

After 01, expect the role and schema to exist, agent event rows to be visible, and
unredacted input samples where the source contains them. Billing can be absent initially.
Run 02, 02b and 02c next as listed in INSTALL.md.

## Configure the host

The supplied default is `https://cloud.langfuse.com` (EU). For US use
`https://us.cloud.langfuse.com`; for self-hosting use your actual HTTPS host.

For a new installation, make the seeded host in `02_core_tables.sql`, the network
rule in 03 and destination rows in 03a agree before running them. `IF NOT EXISTS`
does not update an existing network rule, and the seed MERGE does not update an
existing host. Do not repoint a used alias to another host or project.

## Create secrets privately

After creating the database/schema, run Part B of
[`03_network_secret_integration.sql`](../sql/03_network_secret_integration.sql)
in a separate private worksheet:

```sql
USE ROLE LANGFUSE_EXPORTER_ROLE;
CREATE OR REPLACE SECRET LANGFUSE_EXPORTER.CORE.LANGFUSE_TEST_CREDENTIALS
  TYPE = PASSWORD
  USERNAME = '<LANGFUSE_PUBLIC_KEY>'
  PASSWORD = '<LANGFUSE_SECRET_KEY>';
```

Replace placeholders only in that worksheet. Do not commit it or paste keys into an
AI conversation. Remove the worksheet after use; this is not a claim that query
history or audit records are erased. Follow your organisation’s secret-handling rules.

Now run the remaining 03 script. It creates the network rule, external access
integration `LANGFUSE_CLOUD_EAI`, grants runtime access, and defines
`LANGFUSE_CONNECTIVITY_CHECK`. Expected check: health/auth status 200 and the intended
project in `projects`. Use its actual project ID in 03a before staging.

For additional destinations, create one secret per project, retain all needed secrets
in the integration’s allowed list, and bind the destination alias in all five Python
procedures: connectivity (03), sender/reconciler (05b), score check (05c), semantic
check (05d). A different host also requires its own permitted network rule. Table
configuration cannot create these procedure bindings for you.

03a requires the verified project ID. For a new alias, inspect its project settings or
check that key pair against the project API privately, then apply 03a and call
`LANGFUSE_CONNECTIVITY_CHECK('<alias>')` to compare the returned ID before publishing.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| External access error `509009` | Account eligibility; this occurred on the trial account. |
| Authentication 401 | Correct key pair and host; public key is the Basic auth username. |
| 403/404 or connectivity failure | Region, host, network rule, integration grants and secret binding. |
| Source missing or not authorised | Step 01 observability and usage grants. |
| Redacted prompts | Unredacted event privilege and source content availability. |
| Empty billing | Source usage latency; do not substitute zero. |
| Compilation error after a dependent step | Run definitions sequentially; keep scheduling suspended and inspect the failing statement. |

Continue with [destination mapping and installation](INSTALL.md).
