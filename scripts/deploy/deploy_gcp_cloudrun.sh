#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cloud Run (serverless) deployment for the RAG thesis.
#
# Companion to scripts/deploy/deploy_gcp_gpu.sh. Reuses the same Artifact Registry
# images, but deploys on:
#
#   - Cloud Run with GPU (nvidia-l4) for ollama-gpu  (min-instances=0 for true
#     cold-start behaviour)
#   - Cloud Run for rag-backend and rag-frontend
#   - Compute Engine VM running Qdrant Docker (shared with GKE deployment)
#
# Qdrant is NOT on Cloud Run because it is stateful (persistent volume is
# required). Keeping Qdrant on a dedicated VM means the backend+LLM layer is
# the only independent variable when comparing GKE vs. Cloud Run.
#
# Prereqs (re-used from the GKE deploy):
#   - PROJECT_ID billing enabled
#   - Artifact Registry repo with backend/frontend/ingestion images from the GKE deploy
#   - gcloud components: beta, run
# =============================================================================

# ---- Overridable ----
PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
REGION="${REGION:-europe-west3}"
REPO="${REPO:-rag-thesis}"
IMAGE_TAG="${IMAGE_TAG:-gcp-gpu-v2}"

# Qdrant VM
QDRANT_VM_NAME="${QDRANT_VM_NAME:-qdrant-shared}"
QDRANT_VM_MACHINE="${QDRANT_VM_MACHINE:-e2-standard-4}"
QDRANT_VM_DISK_GB="${QDRANT_VM_DISK_GB:-100}"
QDRANT_VM_ZONE="${QDRANT_VM_ZONE:-${REGION}-a}"

# VPC + connector (Cloud Run -> Qdrant VM over private IP)
NETWORK="${NETWORK:-default}"
VPC_CONNECTOR="${VPC_CONNECTOR:-rag-cr-connector}"
VPC_CONNECTOR_RANGE="${VPC_CONNECTOR_RANGE:-10.8.0.0/28}"

# Ollama GPU on Cloud Run
OLLAMA_SERVICE="${OLLAMA_SERVICE:-ollama-gpu}"
OLLAMA_CPU="${OLLAMA_CPU:-8}"
OLLAMA_MEMORY="${OLLAMA_MEMORY:-32Gi}"
OLLAMA_GPU_TYPE="${OLLAMA_GPU_TYPE:-nvidia-l4}"
OLLAMA_MAX_INSTANCES="${OLLAMA_MAX_INSTANCES:-3}"
OLLAMA_MIN_INSTANCES="${OLLAMA_MIN_INSTANCES:-0}"
OLLAMA_TIMEOUT="${OLLAMA_TIMEOUT:-3600}"
OLLAMA_MODEL_BUCKET="${OLLAMA_MODEL_BUCKET:-${PROJECT_ID}-rag-ollama-models}"

# Backend / frontend on Cloud Run
BACKEND_SERVICE="${BACKEND_SERVICE:-rag-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-rag-frontend}"
BACKEND_MIN_INSTANCES="${BACKEND_MIN_INSTANCES:-0}"
BACKEND_MAX_INSTANCES="${BACKEND_MAX_INSTANCES:-10}"
BACKEND_CONCURRENCY="${BACKEND_CONCURRENCY:-8}"
BACKEND_CPU="${BACKEND_CPU:-2}"
BACKEND_MEMORY="${BACKEND_MEMORY:-2Gi}"
BACKEND_TIMEOUT="${BACKEND_TIMEOUT:-900}"
FRONTEND_MIN_INSTANCES="${FRONTEND_MIN_INSTANCES:-0}"
FRONTEND_MAX_INSTANCES="${FRONTEND_MAX_INSTANCES:-3}"
FRONTEND_CPU="${FRONTEND_CPU:-1}"
FRONTEND_MEMORY="${FRONTEND_MEMORY:-1Gi}"

LLM_MODEL="${LLM_MODEL:-granite3.3:8b}"
PRELOAD_MODELS_CSV="${PRELOAD_MODELS_CSV:-phi3:mini,granite3.3:8b,deepseek-r1:8b}"

# =============================================================================

BACKEND_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/backend:${IMAGE_TAG}"
FRONTEND_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/frontend:${IMAGE_TAG}"
OLLAMA_IMG="${OLLAMA_IMG:-ollama/ollama:latest}"

echo "==> Configure project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo "==> Enable APIs required for Cloud Run + VPC connector + GCS Fuse volumes"
gcloud services enable \
  run.googleapis.com \
  compute.googleapis.com \
  vpcaccess.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com

# ---------- 1) Qdrant VM (shared with GKE deploy for fair comparisons) -------

qdrant_vm_exists() {
  gcloud compute instances describe "${QDRANT_VM_NAME}" \
    --zone="${QDRANT_VM_ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1
}

if qdrant_vm_exists; then
  echo "==> Qdrant VM ${QDRANT_VM_NAME} (zone=${QDRANT_VM_ZONE}) already exists; reusing"
else
  echo "==> Create Qdrant VM ${QDRANT_VM_NAME} in ${QDRANT_VM_ZONE}"
  # Startup script: install Docker if missing and run qdrant with a named volume.
  STARTUP="#!/usr/bin/env bash
set -eux
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker.io
  systemctl enable --now docker
fi
mkdir -p /var/qdrant-storage
docker rm -f qdrant 2>/dev/null || true
docker run -d --restart=always --name qdrant \\
  -p 6333:6333 -p 6334:6334 \\
  -v /var/qdrant-storage:/qdrant/storage \\
  qdrant/qdrant:latest
"
  STARTUP_FILE="$(mktemp)"
  printf '%s' "${STARTUP}" > "${STARTUP_FILE}"
  gcloud compute instances create "${QDRANT_VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${QDRANT_VM_ZONE}" \
    --machine-type="${QDRANT_VM_MACHINE}" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size="${QDRANT_VM_DISK_GB}GB" \
    --tags=qdrant-shared \
    --network="${NETWORK}" \
    --metadata-from-file "startup-script=${STARTUP_FILE}"
  rm -f "${STARTUP_FILE}"

  echo "==> Firewall rule: allow Cloud Run VPC connector range -> Qdrant VM:6333"
  gcloud compute firewall-rules create allow-qdrant-from-cr \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:6333,tcp:6334 \
    --source-ranges="${VPC_CONNECTOR_RANGE}" \
    --target-tags=qdrant-shared || true
fi

QDRANT_INTERNAL_IP="$(gcloud compute instances describe "${QDRANT_VM_NAME}" \
  --zone="${QDRANT_VM_ZONE}" --project="${PROJECT_ID}" \
  --format='value(networkInterfaces[0].networkIP)')"
echo "==> Qdrant internal IP: ${QDRANT_INTERNAL_IP}"

# ---------- 2) Serverless VPC Connector -------------------------------------

if gcloud compute networks vpc-access connectors describe "${VPC_CONNECTOR}" \
  --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "==> VPC connector ${VPC_CONNECTOR} already exists"
else
  echo "==> Create VPC connector ${VPC_CONNECTOR} (range=${VPC_CONNECTOR_RANGE})"
  gcloud compute networks vpc-access connectors create "${VPC_CONNECTOR}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --network="${NETWORK}" \
    --range="${VPC_CONNECTOR_RANGE}" \
    --min-instances=2 --max-instances=3
fi

# ---------- 3) Ollama model cache bucket (GCS Fuse) -------------------------

if gcloud storage buckets describe "gs://${OLLAMA_MODEL_BUCKET}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "==> Ollama model bucket gs://${OLLAMA_MODEL_BUCKET} already exists"
else
  echo "==> Create bucket gs://${OLLAMA_MODEL_BUCKET} for shared ollama model cache"
  gcloud storage buckets create "gs://${OLLAMA_MODEL_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}"
fi

# ---------- 4) Ollama on Cloud Run with GPU ---------------------------------

echo "==> Deploy ${OLLAMA_SERVICE} on Cloud Run with ${OLLAMA_GPU_TYPE} GPU (min=${OLLAMA_MIN_INSTANCES} max=${OLLAMA_MAX_INSTANCES})"
# Notes:
#   - --no-cpu-throttling so the container can pull / load the model during
#     cold start without being throttled to 0 CPU.
#   - GCS Fuse mount at /root/.ollama: first pull caches to GCS, subsequent
#     cold starts reuse the cached models (massively reduces cold start).
#   - --no-allow-unauthenticated: service is private; the backend authenticates
#     via its Cloud Run service account.
gcloud beta run deploy "${OLLAMA_SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${OLLAMA_IMG}" \
  --no-allow-unauthenticated \
  --port=11434 \
  --cpu="${OLLAMA_CPU}" \
  --memory="${OLLAMA_MEMORY}" \
  --gpu=1 \
  --gpu-type="${OLLAMA_GPU_TYPE}" \
  --no-cpu-throttling \
  --concurrency=1 \
  --timeout="${OLLAMA_TIMEOUT}" \
  --min-instances="${OLLAMA_MIN_INSTANCES}" \
  --max-instances="${OLLAMA_MAX_INSTANCES}" \
  --execution-environment=gen2 \
  --add-volume="name=ollama-models,type=cloud-storage,bucket=${OLLAMA_MODEL_BUCKET}" \
  --add-volume-mount="volume=ollama-models,mount-path=/root/.ollama" \
  --set-env-vars="OLLAMA_KEEP_ALIVE=24h,OLLAMA_NUM_PARALLEL=1,OLLAMA_CONTEXT_LENGTH=2048"

OLLAMA_URL="$(gcloud run services describe "${OLLAMA_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --format='value(status.url)')"
echo "==> ${OLLAMA_SERVICE} URL: ${OLLAMA_URL}"

# ---------- 5) Pull the model into the GCS cache (one-off) ------------------

echo "==> Preloading model cache: ${PRELOAD_MODELS_CSV}"
OLLAMA_ID_TOKEN="$(gcloud auth print-identity-token --audiences="${OLLAMA_URL}")"
IFS=',' read -r -a PRELOAD_MODELS <<< "${PRELOAD_MODELS_CSV}"
for preload_model in "${PRELOAD_MODELS[@]}"; do
  preload_model="$(echo "${preload_model}" | xargs)"
  [ -z "${preload_model}" ] && continue
  echo "==> Pulling ${preload_model} into Ollama cache (one-off, may take several minutes)"
  curl -sS -X POST "${OLLAMA_URL}/api/pull" \
    -H "Authorization: Bearer ${OLLAMA_ID_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${preload_model}\",\"stream\":false}" \
    --max-time 1800 | tail -n 5 || echo "WARN: model pull call failed for ${preload_model} (can rerun later)"
done

# ---------- 6) Backend on Cloud Run -----------------------------------------

echo "==> Deploy ${BACKEND_SERVICE} on Cloud Run"
gcloud run deploy "${BACKEND_SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${BACKEND_IMG}" \
  --allow-unauthenticated \
  --port=8000 \
  --cpu="${BACKEND_CPU}" \
  --memory="${BACKEND_MEMORY}" \
  --concurrency="${BACKEND_CONCURRENCY}" \
  --timeout="${BACKEND_TIMEOUT}" \
  --min-instances="${BACKEND_MIN_INSTANCES}" \
  --max-instances="${BACKEND_MAX_INSTANCES}" \
  --execution-environment=gen2 \
  --vpc-connector="${VPC_CONNECTOR}" \
  --vpc-egress=private-ranges-only \
  --set-env-vars="QDRANT_HOST=${QDRANT_INTERNAL_IP},QDRANT_PORT=6333,QDRANT_COLLECTION=thesis_docs_active,LLM_PROVIDER=ollama,LLM_BASE_URL=${OLLAMA_URL},LLM_MODEL=${LLM_MODEL},LLM_FALLBACK_MODEL=phi3:mini,LLM_MAX_RETRIES=2,LLM_RETRY_BACKOFF_SECONDS=1.5,QDRANT_MAX_RETRIES=1,QDRANT_RETRY_BACKOFF_SECONDS=0.5,REQUEST_TIMEOUT_SECONDS=900,WARMUP_LLM_ON_STARTUP=false,PRODUCT_LATENCY_MODE=true,OLLAMA_MAX_OUTPUT_TOKENS=256,OLLAMA_TEMPERATURE=0.1,QDRANT_TOP_K=4,QDRANT_TOP_K_PRODUCT=3"

BACKEND_URL="$(gcloud run services describe "${BACKEND_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --format='value(status.url)')"
echo "==> ${BACKEND_SERVICE} URL: ${BACKEND_URL}"

# Grant the backend's runtime SA permission to invoke the private Ollama service.
BACKEND_SA="$(gcloud run services describe "${BACKEND_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --format='value(spec.template.spec.serviceAccountName)')"
if [[ -z "${BACKEND_SA}" ]]; then
  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  BACKEND_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi
echo "==> Allow ${BACKEND_SA} to invoke ${OLLAMA_SERVICE}"
gcloud run services add-iam-policy-binding "${OLLAMA_SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --member="serviceAccount:${BACKEND_SA}" \
  --role="roles/run.invoker" >/dev/null

# ---------- 7) Frontend on Cloud Run ----------------------------------------

echo "==> Deploy ${FRONTEND_SERVICE} on Cloud Run"
gcloud run deploy "${FRONTEND_SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${FRONTEND_IMG}" \
  --allow-unauthenticated \
  --port=8501 \
  --cpu="${FRONTEND_CPU}" \
  --memory="${FRONTEND_MEMORY}" \
  --concurrency=20 \
  --min-instances="${FRONTEND_MIN_INSTANCES}" \
  --max-instances="${FRONTEND_MAX_INSTANCES}" \
  --execution-environment=gen2 \
  --set-env-vars="RAG_BACKEND_URL=${BACKEND_URL}"

FRONTEND_URL="$(gcloud run services describe "${FRONTEND_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --format='value(status.url)')"

cat <<EOF

==> Cloud Run deployment complete.

Ollama GPU:  ${OLLAMA_URL}     (private, min-instances=${OLLAMA_MIN_INSTANCES})
Backend:     ${BACKEND_URL}
Frontend:    ${FRONTEND_URL}
Qdrant VM:   ${QDRANT_VM_NAME} @ ${QDRANT_INTERNAL_IP}:6333 (zone ${QDRANT_VM_ZONE})
VPC connector: ${VPC_CONNECTOR} (${VPC_CONNECTOR_RANGE})
Model bucket: gs://${OLLAMA_MODEL_BUCKET}

Smoke test:
  curl -sS -X POST "${BACKEND_URL}/query" \\
    -H "Content-Type: application/json" \\
    -d '{"query":"What is SEC filing?"}'

Remember: Qdrant must be populated. If this is a fresh Qdrant VM, run
scripts/ingestion/ingest_local_to_qdrant.sh (or the in-cluster ingestion Job pointing at
the same QDRANT_HOST=${QDRANT_INTERNAL_IP}) before querying.
EOF
