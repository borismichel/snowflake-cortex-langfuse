-- v1.2 additive migration. Run after 02c, before the v1.2 sender; publisher idle.
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_traces_per_run NUMBER DEFAULT 1000;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_traces_per_request NUMBER DEFAULT 100;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_spans_per_request NUMBER DEFAULT 1000;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_request_bytes NUMBER DEFAULT 1000000;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_trace_requests_per_run NUMBER DEFAULT 20;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_scores_per_run NUMBER DEFAULT 100;
ALTER TABLE DESTINATIONS ADD COLUMN IF NOT EXISTS max_run_seconds NUMBER DEFAULT 300;
-- Exact wire bodies and membership retained for audit; per-trace DELIVERIES stays canonical.
CREATE TABLE IF NOT EXISTS HTTP_BATCHES (
  batch_id VARCHAR NOT NULL,
  destination_id VARCHAR NOT NULL,
  host VARCHAR NOT NULL,
  project_id VARCHAR NOT NULL,
  delivery_ids ARRAY NOT NULL,
  request_body VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  http_status NUMBER,
  created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  finished_at TIMESTAMP_LTZ
);
INSERT INTO SCHEMA_VERSION (version,description)
SELECT 12,'v1.2 bounded OTLP envelopes and independent score budget'
WHERE NOT EXISTS (SELECT 1 FROM SCHEMA_VERSION WHERE version=12);
SELECT destination_id,max_traces_per_run,max_traces_per_request,max_spans_per_request,
       max_request_bytes,max_trace_requests_per_run,max_scores_per_run,max_run_seconds
FROM DESTINATIONS;
