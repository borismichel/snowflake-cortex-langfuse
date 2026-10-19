# CoCo v1.2 setup package: Snowflake Cortex → Langfuse

Prepared 15 October 2026. Fresh-account installation using configurable destinations and routes.
Custom community project, MIT licensed, provided as is; not an officially supported Langfuse or Snowflake component.

## Give CoCo this instruction

Read 01_COCO_RUNBOOK.md first. Interview me in short rounds, discover what you can from this new account, and record the answers in a completed copy of 02_CONFIG.template.json. Use the bundled, pinned scripts to prepare a configuration-specific installation. I want configurable agent-to-project routing, including several agents sharing one project and separate projects for other agents. Keep credentials out of chat. Follow the deployment and verification sequence, keep scheduling suspended until the agreed checks pass, and return the exact configured SQL plus an evidence report. Begin with account discovery and your first interview questions; do not run the unconfigured reference scripts.

## Contents

- 01_COCO_RUNBOOK.md: interview, preparation, installation and handoff.
- 02_CONFIG.template.json: non-secret answers, initially incomplete; CoCo fills this in with you.
- 03_PARAMETER_MAP.md: how answers map to SQL, Python bodies, credentials and routing.
- 04_ACCEPTANCE.md: new-account checks, including browser conversations and project isolation.
- 05_EVIDENCE.template.md: deployment receipt for the later reproducible guide.
- reference/: unchanged SQL, documentation, offline tests and licence from the public repository.
- SOURCE.json and SHA256SUMS: exact source revision and file integrity.

CoCo does not accept ZIP uploads. Upload COCO_UPLOAD.txt, which contains the same text files with BEGIN/END FILE boundaries. The text bundle is reference material, not one executable SQL script. If files are truncated or inaccessible, CoCo must identify the missing file before using it.

## What “variable path” means here

The interview resolves named installation settings and a complete destination/route map. The JSON is a configuration worksheet for CoCo, not a runtime config loader. The current exporter does not automatically consume JSON or SQL session variables inside stored Python. CoCo must generate and verify the actual configured SQL files. No new runtime or external worker is required.

## Current verification

The original V1 was demonstrated with live browser runs. This source revision adds bounded multi-trace batching and routing safeguards; its offline regression suite passes. CoCo reported deploying v1.2; independent manual replay and live routing acceptance remain to be performed. This package is designed to collect that evidence. An AI-assisted run is not automatically evidence that a human has replayed the manual path.

No previous account credentials, historical traces, raw screenshots or private project archive are included. Reference README image links are intentionally not bundled; they are not needed for setup. SQL 99_uninstall is included only as destructive recovery reference, never an installation step.

## Build the current package

From a clean repository checkout: `python3 tools/build_coco_package.py --output /tmp/coco-v1.2`.
Upload the generated COCO_UPLOAD.txt. The ZIP is only an offline archive; do not upload it to CoCo. This replaces the older unversioned CoCo
package; do not mix its scripts with v1.2. Read reference/docs/SCALING.md before sizing.
The reference tree in an upload is generated from this repo, not duplicated in Git.

Deployment evidence update: CoCo reported a v1.2 installation and supplied matching core upgrade files. The 1.2.1 patch includes generic installation fixes and score connection reuse; it has offline checks, with independent live/manual acceptance pending. See reference/docs/STATUS.md.
