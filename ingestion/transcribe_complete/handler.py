# Lambda handler triggered by EventBridge on Transcribe job COMPLETED/FAILED state change
# On COMPLETED: chunks transcript into 60-90s windows, writes JSONL to GCS, imports to media datastore
