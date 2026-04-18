#!/usr/bin/env bash
set -euo pipefail

# Tear down everything provisioned by scripts/deploy_gcp_cloudrun.sh.
# Does NOT touch Artifact Registry (shared with the GKE deploy) unless
# DELETE_ARTIFACT_REPO=true.

PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
REGION="${REGION:-europe-west3}"
QDRANT_VM_NAME="${QDRANT_VM_NAME:-qdrant-shared}"
QDRANT_VM_ZONE="${QDRANT_VM_ZONE:-${REGION}-a}"
VPC_CONNECTOR="${VPC_CONNECTOR:-rag-cr-connector}"
OLLAMA_SERVICE="${OLLAMA_SERVICE:-ollama-gpu}"
BACKEND_SERVICE="${BACKEND_SERVICE:-rag-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-rag-frontend}"
OLLAMA_MODEL_BUCKET="${OLLAMA_MODEL_BUCKET:-${PROJECT_ID}-rag-ollama-models}"
DELETE_MODEL_BUCKET="${DELETE_MODEL_BUCKET:-false}"
DELETE_ARTIFACT_REPO="${DELETE_ARTIFACT_REPO:-false}"
REPO="${REPO:-rag-thesis}"

gcloud config set project "${PROJECT_ID}" >/dev/null

echo "==> Delete Cloud Run services"
for svc in "${FRONTEND_SERVICE}" "${BACKEND_SERVICE}" "${OLLAMA_SERVICE}"; do
  if gcloud run services describe "${svc}" \
    --project="${PROJECT_ID}" --region="${REGION}" >/dev/null 2>&1; then
    gcloud run services delete "${svc}" \
      --project="${PROJECT_ID}" --region="${REGION}" --quiet
  else
    echo "    ${svc} not found, skipping"
  fi
done

echo "==> Delete Qdrant VM ${QDRANT_VM_NAME} (${QDRANT_VM_ZONE})"
gcloud compute instances delete "${QDRANT_VM_NAME}" \
  --project="${PROJECT_ID}" --zone="${QDRANT_VM_ZONE}" --quiet || true

echo "==> Delete firewall rule allow-qdrant-from-cr"
gcloud compute firewall-rules delete allow-qdrant-from-cr \
  --project="${PROJECT_ID}" --quiet || true

echo "==> Delete Serverless VPC connector ${VPC_CONNECTOR}"
gcloud compute networks vpc-access connectors delete "${VPC_CONNECTOR}" \
  --project="${PROJECT_ID}" --region="${REGION}" --quiet || true

if [[ "${DELETE_MODEL_BUCKET}" == "true" ]]; then
  echo "==> Delete Ollama model bucket gs://${OLLAMA_MODEL_BUCKET}"
  gcloud storage rm -r "gs://${OLLAMA_MODEL_BUCKET}" --project="${PROJECT_ID}" || true
else
  echo "==> Keeping bucket gs://${OLLAMA_MODEL_BUCKET} (set DELETE_MODEL_BUCKET=true to remove)"
fi

if [[ "${DELETE_ARTIFACT_REPO}" == "true" ]]; then
  echo "==> Delete Artifact Registry repo ${REPO}"
  gcloud artifacts repositories delete "${REPO}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
fi

echo "==> Cloud Run teardown finished"
