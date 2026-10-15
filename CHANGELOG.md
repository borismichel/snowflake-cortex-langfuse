# Changelog

## 1.2.0 — 15 October 2026

Repository version; no GitHub Release is created. Experimental, offline validated; live Snowflake compilation and scale testing pending.

- Bound OTLP requests by whole-trace count, span count and actual UTF-8 JSON bytes, per destination.
- Retain per-trace deliveries; persist HTTP request bodies and membership before POST. Claim and finalise members in scoped transactions with bulk SQL. Partial or uncertain outcomes require per-trace readback.
- Replace per-span membership inserts with one FLATTEN insert per trace; make delivery/member creation atomic.
- Replace the scheduled publisher's hard-coded 20-delivery cap with destination settings; separate trace-request and score budgets. Reuse HTTP connections within each invocation.
- Select only published traces with missing available billing components, cap score preparation/recovery, and reserve dispatch time for traces. Scores remain individual API requests.
- Add additive `02d_migration_v12.sql`, performance/credit benchmark instructions, updated architecture, and versioned CoCo interview sources plus a reproducible ZIP/text package builder.
- Hold malformed successful OTLP acknowledgements as uncertain instead of assuming acceptance.

Still single-publisher. Payload building remains per trace; queue inserts remain per trace/score. No concurrent workers, exactly-once guarantee, late-span export, automatic oversized-trace splitting or measured 60k–80k/window capacity is added.

## Earlier snapshot

The unversioned public snapshot added configurable routing and delivery safeguards to the original V1 browser-run demonstration. v1.2 upgrades that snapshot without rewriting accepted payloads or frozen project identities.
