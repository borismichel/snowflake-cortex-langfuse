# CoCo update package · v1.2

For an EXISTING Snowflake Cortex → Langfuse exporter. This is not a fresh installation.
Custom community software, MIT licence, provided as is; live v1.2 validation remains pending.

Upload COCO_UPDATE.txt and say:

> Upgrade my existing exporter to v1.2 using this package. Read 01_COCO_RUNBOOK.md.
> First inspect the live installation and interview me only for missing upgrade decisions.
> Preserve my existing routes, projects, secrets, custom object names, task schedule and
> delivery history. Prepare backups and the exact change plan before mutation. Apply the
> additive migration and adapted sender, verify fresh batched canaries, and restore the
> previous schedule only when the agreed checks pass. Do not rerun fresh-install seeds.
> Return the configured upgrade SQL, rollback instructions and evidence report.

Build from a clean repo checkout:
`python3 tools/build_coco_package.py --mode upgrade --output /tmp/coco-v1.2-update`

CoCo does not accept ZIP uploads. Use the generated COCO_UPDATE.txt; the ZIP is only an offline archive. The reference tree contains canonical source
files for inspection; it is NOT an instruction to execute every file. The routine upgrade
from the routing-safety snapshot is **02d → 05b → 07a**, with snapshots, suspension and
validation boundaries described in the runbook. Older/custom deployments need compatibility
review before that path can be used. No keys belong in this upload or the conversation.

Files: 01_COCO_RUNBOOK.md, 02_CONFIG.template.json, 03_ACCEPTANCE.md,
04_EVIDENCE.template.md, reference/, SOURCE.json, SHA256SUMS.

Deployment evidence update: CoCo reported a v1.2 installation and supplied matching core upgrade files. The 1.2.1 patch includes generic installation fixes and score connection reuse; it has offline checks, with independent live/manual acceptance pending. See reference/docs/STATUS.md.
