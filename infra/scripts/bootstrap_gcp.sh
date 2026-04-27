#!/usr/bin/env bash
# Creates all GCP resources for Milestone 1: GCS buckets, BigQuery dataset/tables,
# service account, Secret Manager secrets. Idempotent — safe to run twice.
# Usage: PROJECT_ID=finance-brain-yourname ./infra/scripts/bootstrap_gcp.sh
