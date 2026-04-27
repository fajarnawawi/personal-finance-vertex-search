-- Analytics events from the Telegram bot, forwarded via Google Tag Gateway
-- Partitioned by date; clustered by event_name for usage analysis queries
-- Schema is append-only — destructive changes require an ADR (see CLAUDE.md)
CREATE TABLE IF NOT EXISTS `${PROJECT_ID}.finance_brain.events` (
  event_id STRING NOT NULL,
  event_timestamp TIMESTAMP NOT NULL,
  event_name STRING NOT NULL,
  user_id STRING,
  session_id STRING,
  properties JSON,
  source STRING
)
PARTITION BY DATE(event_timestamp)
CLUSTER BY event_name;
