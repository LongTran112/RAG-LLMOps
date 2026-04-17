#!/usr/bin/env bash
set -euo pipefail

# ========= Override via env if needed =========
PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
# GKE rule: node pools must live in the same region as the cluster. This script creates both in REGION.
# (You cannot attach a GPU pool in one region to a cluster in another.)
REGION="${REGION:-europe-west3}"
CLUSTER="${CLUSTER:-rag-thesis-gpu}"
REPO="${REPO:-rag-thesis}"
IMAGE_TAG="${IMAGE_TAG:-gcp-gpu-v2}"
# Space-separated zones to try, in order (L4 + g2 often hits GCE_STOCKOUT in one zone but not another).
# Override with: GPU_POOL_ZONES="europe-west3-b" ./scripts/deploy_gcp_gpu.sh
# Or legacy single zone: GPU_ZONE=europe-west3-a (only that zone is tried).
GPU_POOL_ZONES="${GPU_POOL_ZONES:-europe-west3-a europe-west3-b europe-west3-c}"
GPU_ZONE="${GPU_ZONE:-}"
GPU_MACHINE_TYPE="${GPU_MACHINE_TYPE:-g2-standard-8}"
RECREATE_GPU_POOL="${RECREATE_GPU_POOL:-false}"
# GPU pool: cap at one node so cluster autoscaler never requests a second GPU VM (quota / scheduling).
GPU_POOL_MIN_NODES="${GPU_POOL_MIN_NODES:-1}"
GPU_POOL_MAX_NODES="${GPU_POOL_MAX_NODES:-1}"
# If set (e.g. gs://my-bucket/sec_rag_dataset_50), ingestion Job downloads from GCS (needs bucket IAM for the GKE node SA).
# If empty, the one-off ingestion Job is disabled; run ./scripts/ingest_local_to_qdrant.sh from your laptop instead.
INGESTION_GCS_URI="${INGESTION_GCS_URI:-}"
# =============================================

gpu_pool_status() {
  gcloud container node-pools describe gpu-pool \
    --cluster "${CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" \
    --format='value(status)' 2>/dev/null || echo "MISSING"
}

remove_gpu_pool_if_present() {
  if ! gcloud container node-pools describe gpu-pool \
    --cluster "${CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Deleting gpu-pool (replace or cleanup)"
  gcloud container node-pools delete gpu-pool \
    --cluster "${CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" \
    --quiet
  echo "==> Waiting for gpu-pool deletion to finish..."
  local n=0
  while gcloud container node-pools describe gpu-pool \
    --cluster "${CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1; do
    sleep 10
    n=$((n + 1))
    if [[ "${n}" -gt 120 ]]; then
      echo "ERROR: timed out waiting for gpu-pool deletion" >&2
      return 1
    fi
  done
}

ensure_gpu_pool() {
  if [[ "${RECREATE_GPU_POOL}" == "true" ]]; then
    remove_gpu_pool_if_present || return 1
  fi

  local st
  st="$(gpu_pool_status)"
  if [[ "${st}" == "RUNNING" ]]; then
    echo "==> gpu-pool already RUNNING"
    return 0
  fi

  if [[ "${st}" == "PROVISIONING" ]] || [[ "${st}" == "RECONCILING" ]]; then
    echo "==> gpu-pool is ${st}, waiting (up to ~45m)..."
    local n=0
    while true; do
      sleep 20
      st="$(gpu_pool_status)"
      [[ "${st}" == "RUNNING" ]] && { echo "==> gpu-pool is RUNNING"; return 0; }
      [[ "${st}" == "ERROR" ]] || [[ "${st}" == "MISSING" ]] && break
      n=$((n + 1))
      if [[ "${n}" -gt 135 ]]; then
        echo "WARN: still ${st} after long wait; will recreate" >&2
        break
      fi
    done
    if [[ "$(gpu_pool_status)" != "RUNNING" ]]; then
      remove_gpu_pool_if_present || return 1
    else
      return 0
    fi
  elif [[ "${st}" != "MISSING" ]]; then
    echo "==> gpu-pool status=${st}, replacing pool"
    remove_gpu_pool_if_present || return 1
  fi

  local -a zones=()
  if [[ -n "${GPU_ZONE}" ]]; then
    zones=("${GPU_ZONE}")
  else
    read -r -a zones <<< "${GPU_POOL_ZONES}"
  fi

  for zone in "${zones[@]}"; do
    [[ -z "${zone}" ]] && continue
    echo "==> Create GPU node pool in ${zone} (${GPU_MACHINE_TYPE}, nvidia-l4 x1)"
    if gcloud container node-pools create gpu-pool \
      --cluster "${CLUSTER}" \
      --region "${REGION}" \
      --project "${PROJECT_ID}" \
      --node-locations "${zone}" \
      --machine-type "${GPU_MACHINE_TYPE}" \
      --accelerator type=nvidia-l4,count=1 \
      --num-nodes 1 \
      --disk-size 80 \
      --node-labels=accelerator=nvidia \
      --node-taints=nvidia.com/gpu=present:NoSchedule; then
      echo "==> gpu-pool created successfully in ${zone}"
      return 0
    fi
    echo "WARN: create failed in ${zone} (quota/stockout/other); removing partial pool if any"
    remove_gpu_pool_if_present || true
  done

  echo "ERROR: GPU node pool could not be created. Set GPU_POOL_ZONES, try GPU_MACHINE_TYPE=g2-standard-4, or another REGION." >&2
  return 1
}

echo "==> Configure project (REGION=${REGION}, cluster=${CLUSTER})"
gcloud config set project "${PROJECT_ID}"

echo "==> Enable required APIs"
gcloud services enable \
  artifactregistry.googleapis.com \
  container.googleapis.com \
  compute.googleapis.com \
  containerregistry.googleapis.com \
  cloudbuild.googleapis.com \
  dns.googleapis.com

echo "==> Ensure Artifact Registry repo exists"
gcloud artifacts repositories create "${REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="RAG thesis images" || true

echo "==> Build and push images via Google Cloud Build (no local docker push)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

BASE_TAG="${BASE_TAG:-v1}"
BASE_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/rag-base:${BASE_TAG}"
BACKEND_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/backend:${IMAGE_TAG}"
FRONTEND_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/frontend:${IMAGE_TAG}"
INGESTION_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/ingestion:${IMAGE_TAG}"

GCB_MACHINE="${GCB_MACHINE:-e2-highcpu-8}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/tmp/rag-build-logs}"
mkdir -p "${BUILD_LOG_DIR}"

# --- Step 1: base image (only rebuilt when its tag is missing, or REBUILD_BASE=true). ---
# Heavy deps (torch CPU + sentence-transformers + langchain + qdrant-client + ...) live here
# so app builds below touch only a few MB of code.
base_exists() {
  gcloud artifacts docker images describe "${BASE_IMG}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1
}

if [[ "${REBUILD_BASE:-false}" == "true" ]] || ! base_exists; then
  echo "==> Building base image ${BASE_IMG} (heavy deps; one-time)"
  gcloud builds submit ./base \
    --tag="${BASE_IMG}" \
    --machine-type="${GCB_MACHINE}" --timeout=1800s
else
  echo "==> Base image ${BASE_IMG} already exists; skipping (set REBUILD_BASE=true to force)"
fi

# --- Step 2: app images in PARALLEL, each FROM the shared base. ---
# Write inline cloudbuild configs so backend+ingestion can pass --build-arg BASE_IMAGE.
CB_DIR="$(mktemp -d)"
trap 'rm -rf "${CB_DIR}"' EXIT

cat >"${CB_DIR}/backend.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: ['build', '--build-arg', 'BASE_IMAGE=${BASE_IMG}', '-t', '${BACKEND_IMG}', '.']
  - name: gcr.io/cloud-builders/docker
    args: ['push', '${BACKEND_IMG}']
images: ['${BACKEND_IMG}']
options:
  machineType: E2_HIGHCPU_8
timeout: 1800s
EOF

cat >"${CB_DIR}/ingestion.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: ['build', '--build-arg', 'BASE_IMAGE=${BASE_IMG}', '-t', '${INGESTION_IMG}', '.']
  - name: gcr.io/cloud-builders/docker
    args: ['push', '${INGESTION_IMG}']
images: ['${INGESTION_IMG}']
options:
  machineType: E2_HIGHCPU_8
timeout: 1800s
EOF

echo "==> Submitting backend/frontend/ingestion builds to Cloud Build in PARALLEL"
gcloud builds submit ./backend --config="${CB_DIR}/backend.yaml" \
  >"${BUILD_LOG_DIR}/backend.log" 2>&1 &
BACKEND_PID=$!

gcloud builds submit ./ingestion --config="${CB_DIR}/ingestion.yaml" \
  >"${BUILD_LOG_DIR}/ingestion.log" 2>&1 &
INGESTION_PID=$!

gcloud builds submit ./frontend \
  --tag="${FRONTEND_IMG}" \
  --machine-type="${GCB_MACHINE}" --timeout=1800s \
  >"${BUILD_LOG_DIR}/frontend.log" 2>&1 &
FRONTEND_PID=$!

BUILD_FAIL=0
for name in backend ingestion frontend; do
  case "${name}" in
    backend)   pid="${BACKEND_PID}"   ;;
    ingestion) pid="${INGESTION_PID}" ;;
    frontend)  pid="${FRONTEND_PID}"  ;;
  esac
  if wait "${pid}"; then
    echo "==> ${name} image built OK"
  else
    echo "==> ${name} build FAILED (see ${BUILD_LOG_DIR}/${name}.log)" >&2
    tail -40 "${BUILD_LOG_DIR}/${name}.log" >&2 || true
    BUILD_FAIL=1
  fi
done

if [[ "${BUILD_FAIL}" -ne 0 ]]; then
  echo "ERROR: one or more image builds failed; aborting deploy." >&2
  exit 1
fi

echo "==> Ensure base cluster exists"
if ! gcloud container clusters describe "${CLUSTER}" --region "${REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud container clusters create "${CLUSTER}" \
    --region "${REGION}" \
    --num-nodes 1 \
    --machine-type e2-standard-4 \
    --disk-size 50 \
    --project "${PROJECT_ID}"
fi

ensure_gpu_pool

echo "==> GPU pool autoscaling bounds (min=${GPU_POOL_MIN_NODES} max=${GPU_POOL_MAX_NODES})"
# gcloud no longer accepts --disable-autoscaling on node-pools update; min==max pins size (e.g. 1 GPU node).
gcloud container node-pools update gpu-pool \
  --cluster "${CLUSTER}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --enable-autoscaling \
  --min-nodes "${GPU_POOL_MIN_NODES}" \
  --max-nodes "${GPU_POOL_MAX_NODES}"

echo "==> Get kubectl credentials"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True
gcloud container clusters get-credentials "${CLUSTER}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

echo "==> Install NVIDIA device plugin"
kubectl apply -f k8s/llm-inference/nvidia-device-plugin.yaml

echo "==> Deploy app with Helm"
HELM_INGEST=(--set "ingestion.image=${INGESTION_IMG}")
if [[ -n "${INGESTION_GCS_URI}" ]]; then
  echo "==> Ingestion: GCS dataset ${INGESTION_GCS_URI}"
  HELM_INGEST+=(
    --set ingestion.enabled=true
    --set ingestion.job.enabled=true
    --set ingestion.dataset.enabled=true
    --set ingestion.dataset.source=gcs
    --set "ingestion.dataset.gcsUri=${INGESTION_GCS_URI}"
  )
else
  echo "==> Ingestion: skipping in-cluster Job (no INGESTION_GCS_URI). Run ./scripts/ingest_local_to_qdrant.sh to create thesis_docs."
  HELM_INGEST+=(
    --set ingestion.job.enabled=false
    --set ingestion.dataset.enabled=false
  )
fi

helm upgrade --install rag-poc ./helm/rag-k8s-thesis \
  --namespace rag-thesis --create-namespace \
  --set backend.image="${BACKEND_IMG}" \
  --set frontend.image="${FRONTEND_IMG}" \
  --set ollama.replicaCount=1 \
  --set ollama.gpu.enabled=true \
  --set ollama.gpu.count=1 \
  --set ollama.gpu.nodeSelector.accelerator=nvidia \
  --set 'ollama.gpu.tolerations[0].key=nvidia.com/gpu' \
  --set 'ollama.gpu.tolerations[0].operator=Exists' \
  --set 'ollama.gpu.tolerations[0].effect=NoSchedule' \
  --set backend.autoscaling.enabled=true \
  --set backend.autoscaling.minReplicas=2 \
  --set backend.autoscaling.maxReplicas=12 \
  --set backend.autoscaling.targetCPUUtilizationPercentage=65 \
  --set ollama.autoscaling.enabled=true \
  --set ollama.autoscaling.minReplicas=1 \
  --set ollama.autoscaling.maxReplicas=6 \
  --set ollama.autoscaling.targetCPUUtilizationPercentage=70 \
  --set backend.env.llmProvider=ollama \
  --set backend.env.llmBaseUrl=http://ollama:11434 \
  --set backend.env.llmModel=phi3:mini \
  "${HELM_INGEST[@]}"

echo "==> Verify"
kubectl get nodes -o wide
kubectl get nodes -l accelerator=nvidia -o wide || true
kubectl get pods -n rag-thesis -o wide
kubectl get hpa -n rag-thesis
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu"
kubectl exec -n rag-thesis deployment/ollama -- ollama ps || true

echo "==> Done"
echo "Backend image:   ${BACKEND_IMG}"
echo "Frontend image:  ${FRONTEND_IMG}"
echo "Ingestion image: ${INGESTION_IMG}"
