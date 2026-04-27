-- Podcast episode metadata and indexing status tracker
-- Partitioned by publish date; used by /podcasts command and RSS deduplication
CREATE TABLE IF NOT EXISTS `${PROJECT_ID}.finance_brain.podcasts` (
  episode_id STRING NOT NULL,
  feed_name STRING NOT NULL,
  feed_language STRING NOT NULL,
  episode_title STRING,
  episode_description STRING,
  publish_date TIMESTAMP,
  duration_seconds INT64,
  mp3_s3_uri STRING,
  transcript_gcs_uri STRING,
  indexed_at TIMESTAMP,
  status STRING,
  transcript_word_count INT64,
  transcribe_confidence_avg FLOAT64,
  transcribe_job_id STRING,
  error_message STRING
)
PARTITION BY DATE(publish_date);
