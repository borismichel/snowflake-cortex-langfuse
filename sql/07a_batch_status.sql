-- v1.2 monitoring only. Safe for upgrades: no task creation or activation.
USE ROLE LANGFUSE_EXPORTER_ROLE;
USE WAREHOUSE LANGFUSE_EXPORTER_WH;
USE SCHEMA LANGFUSE_EXPORTER.CORE;
-- v1.2 queue monitoring; install this view without replacing an existing task graph.
CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.PUBLISH_QUEUE_V AS
SELECT destination_id,item_type,status,COUNT(*) AS items,
       MIN(created_at) AS oldest_created_at,
       DATEDIFF('second',MIN(created_at),CURRENT_TIMESTAMP()) AS oldest_age_seconds
FROM LANGFUSE_EXPORTER.CORE.DELIVERIES
WHERE status <> 'ACCEPTED'
GROUP BY destination_id,item_type,status;
