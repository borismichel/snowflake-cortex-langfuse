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

## v1.2 deployment artifacts

Keep VERSION, CHANGELOG, install/upgrade order and deploy/coco and deploy/coco-upgrade instructions in sync
when changing procedures or settings. Commit before running
`python3 tools/build_coco_package.py --output /tmp/coco-v1.2`. The ZIP/text bundle
pins HEAD and copies only allowlisted source files. CI publishes the same package
as a workflow artifact; this does not create a GitHub Release. Generated binaries
stay out of Git. Preserve a manual SQL path and label unverified scale claims.

Build the separate existing-installation package with `--mode upgrade`; it must not inherit the fresh-install interview or rerun seeds.

CoCo does not accept ZIP uploads. All handoffs must direct users to `COCO_UPLOAD.txt` (new installation) or `COCO_UPDATE.txt` (existing installation). ZIP files are offline archives only; extract text files from downloaded CI artifacts before uploading to CoCo.
