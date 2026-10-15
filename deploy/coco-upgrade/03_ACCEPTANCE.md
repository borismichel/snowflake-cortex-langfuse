# v1.2 upgrade acceptance

All new-account and scale claims start NOT RUN. Record SQL query IDs, counts and
non-secret object names; keep raw payloads and identity snapshots private.

1. Compare before/after routes, destination host/project identities, existing secret
   bindings and task definitions. No unrequested changes. Accepted-delivery records and
   frozen payload hashes remain intact; newly sent records are accounted for separately.
2. Verify 02d columns, HTTP_BATCHES schema, 05b signatures/grants and queue view compile.
   Connectivity resolves the actual intended project for every destination. Existing
   aliases and custom bindings still work. No new credentials should be needed by default.
3. Use a new browser conversation. Stage, inspect its frozen route and payload, then call
   PUBLISH_DESTINATION(alias,1,TRUE,trace_id). Inspect the result; false/empty is not success.
   Publish with FALSE only for that trace, reconcile, and verify semantics/session UI.
4. Verify a multi-trace request with at least two fresh READY traces. A normal destination
   invocation can also send its existing queued backlog. Obtain/retain scope agreement;
   use a disposable destination if older dispatch is not permitted. Inspect HTTP_BATCHES
   member IDs and wire trace IDs, per-trace readback and absence from unintended projects.
5. Validate system/user roles, root current-turn input/output, actual hierarchy and timing.
   When billing arrives, verify score IDs, numeric credit values and actual root observation
   subjects. Score publishing does not resend accepted observations. Mark billing pending
   explicitly if it hasn't arrived; follow the pre-agreed resumption criterion.
6. Inspect pre-existing and new pending/uncertain/partial work. Never automatically replay
   accepted, partial or uncertain HTTP batches. Request body/membership audit survives
   reconciliation. Test failure paths only in an agreed disposable environment.
7. Compare final task state with the interview decision. Previously suspended graphs stay
   suspended. If resuming, observe a cycle and inspect destination/queue results. Record
   queue age/depth and next actions for any rejected or uncertain work.
8. Run the agreed live benchmark in reference/docs/SCALING.md for high-volume acceptance;
   otherwise leave it NOT RUN. A small canary does not demonstrate 80k/window or credit savings.

The exact canary SQL pattern is in reference/docs/INSTALL.md; substitute discovered
names and IDs. Preserve the v1.2 limits, never increase them solely to make a failed check
appear successful. Produce a report even if blocked, with an exact recovery/resume plan.
