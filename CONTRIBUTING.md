# Contributing

This is a custom community project, not an officially supported Langfuse component.

For a bug report, include the script/version, expected behaviour, observed behaviour,
Snowflake/Langfuse versions where known, and a minimal synthetic reproduction. Keep
credentials, account identifiers and customer telemetry out of issues and attachments.
Use privately reported details for a suspected vulnerability; GitHub private vulnerability
reporting may be used when enabled on this repository.

Run `python3 -m unittest discover -s tests -v` before opening a pull request.
Describe offline checks separately from actual Snowflake execution and Langfuse readback.
Use fresh disposable canaries for live tests; never replay accepted observations as updates.
Do not enable task schedules, change project destinations or send customer data as part
of an unreviewed test. Preserve source message roles and distinguish credits from USD.

Runtime changes should include a meaningful regression check and any required changes to
installation, operations and limitations. Documentation and visual changes do not need
invented runtime tests. Third-party logos are not project branding or endorsement.
