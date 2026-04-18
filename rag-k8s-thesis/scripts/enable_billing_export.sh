#!/usr/bin/env bash
# Enables BigQuery billing export for the thesis project.
#
# Billing export is a one-time manual step in the Cloud Console that we cannot
# fully automate via gcloud (GCP requires a human to click through the billing
# UI for the initial hookup). This script:
#   1. Creates the destination BigQuery dataset `rag_thesis_billing`.
#   2. Prints the exact console URL / instructions the user needs to finish.
#
# Run once per project. After billing export is active, results start flowing
# into `rag_thesis_billing.gcp_billing_export_resource_v1_<BILLING_ACCOUNT>`
# within 24 hours; use `scripts/cost_per_1k_requests.sql` to query it.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
DATASET="${DATASET:-rag_thesis_billing}"
LOCATION="${LOCATION:-EU}"

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud services enable bigquery.googleapis.com cloudbilling.googleapis.com billingbudgets.googleapis.com

if bq --project_id="${PROJECT_ID}" ls -d "${DATASET}" >/dev/null 2>&1; then
  echo "Dataset ${PROJECT_ID}:${DATASET} already exists."
else
  bq --location="${LOCATION}" mk -d \
    --description "Billing export for RAG thesis cost analysis" \
    "${PROJECT_ID}:${DATASET}"
  echo "Created BigQuery dataset ${PROJECT_ID}:${DATASET} (${LOCATION})."
fi

BILLING_ACCOUNT="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingAccountName)' 2>/dev/null || true)"
echo
echo "Finish billing export manually:"
echo "  1. Open https://console.cloud.google.com/billing/${BILLING_ACCOUNT##*/}/export"
echo "  2. Click 'Edit settings' under 'Detailed usage cost'"
echo "  3. Set:"
echo "        Project:  ${PROJECT_ID}"
echo "        Dataset:  ${DATASET}"
echo "  4. Save. Data will start appearing within 24h."
echo
echo "Then in scripts/cost_per_1k_requests.sql replace the REPLACE_ME placeholders"
echo "with the auto-generated table name (gcp_billing_export_resource_v1_<id>)."
