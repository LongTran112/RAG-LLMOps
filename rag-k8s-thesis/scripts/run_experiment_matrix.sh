#!/usr/bin/env bash
# Runs the full thesis benchmark matrix against ONE architecture (gke | cloudrun)
# for a given set of models. Writes all result CSVs to benchmarks/<arch>_<ts>/.
#
# Usage:
#   ARCH=gke MODELS="phi3:mini qwen2.5:7b qwen2.5:14b qwen2.5:32b" \
#     ./scripts/run_experiment_matrix.sh
#
#   ARCH=cloudrun BACKEND_URL=https://rag-backend-xxx.a.run.app \
#     MODELS="phi3:mini qwen2.5:7b" \
#     ./scripts/run_experiment_matrix.sh
#
# Assumes the target environment is already deployed (scripts/deploy_gcp_gpu.sh
# or scripts/deploy_gcp_cloudrun.sh, plus ingestion run against the shared
# Qdrant). This script orchestrates:
#   1. retrieval-only latency (/retrieve) via benchmark_retrieval.py
#   2. TTFT + token-per-second via benchmark_stream.py
#   3. full /query sync latency via benchmark.sh
#   4. 1->100 VU k6 ramp via rps_sweep.js
#   5. cold-start latency via benchmark_coldstart.sh
# per model.
set -euo pipefail

ARCH="${ARCH:-gke}"
MODELS="${MODELS:-phi3:mini qwen2.5:7b qwen2.5:14b qwen2.5:32b}"
NAMESPACE="${NAMESPACE:-rag-thesis}"
BACKEND_URL="${BACKEND_URL:-}"
AUDIENCE="${AUDIENCE:-}"
REPETITIONS="${REPETITIONS:-3}"
MAX_VUS="${MAX_VUS:-100}"
PROMPTS="${PROMPTS:-P1,P2,P3}"
SKIP_COLDSTART="${SKIP_COLDSTART:-false}"
SKIP_K6="${SKIP_K6:-false}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="benchmarks/${ARCH}_${TS}"
mkdir -p "${OUT_DIR}"

log() { echo "[$(date)] $*" | tee -a "${OUT_DIR}/run.log"; }

if [ "${ARCH}" = "gke" ] && [ -z "${BACKEND_URL}" ]; then
  log "ARCH=gke: starting kubectl port-forward on 127.0.0.1:8000"
  kubectl port-forward -n "${NAMESPACE}" svc/rag-backend 8000:80 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT
  sleep 3
  BACKEND_URL="http://127.0.0.1:8000"
fi

for model in ${MODELS}; do
  log ">>>>>>>> MODEL: ${model}"

  if [ "${ARCH}" = "gke" ]; then
    log "switching GKE rag-backend LLM_MODEL=${model}"
    kubectl exec -n "${NAMESPACE}" deployment/ollama -- ollama pull "${model}" || true
    kubectl set env deployment/rag-backend -n "${NAMESPACE}" "LLM_MODEL=${model}"
    kubectl rollout status deployment/rag-backend -n "${NAMESPACE}" --timeout=1200s
  else
    log "ARCH=cloudrun: update LLM_MODEL=${model} on rag-backend Cloud Run service"
    gcloud run services update rag-backend \
      --update-env-vars "LLM_MODEL=${model}" \
      --region="${REGION:-europe-west3}" --quiet >/dev/null
  fi

  log "[1/5] retrieval latency"
  python3 scripts/benchmark_retrieval.py \
    --base-url "${BACKEND_URL}" \
    --audience "${AUDIENCE}" \
    --prompts "${PROMPTS}" --repetitions 10 \
    --result-dir "${OUT_DIR}" ${ARCH:+--namespace ${NAMESPACE}} \
    ${ARCH:+--sample-qdrant-rss} || true

  log "[2/5] streaming TTFT"
  python3 scripts/benchmark_stream.py \
    --base-url "${BACKEND_URL}" \
    --audience "${AUDIENCE}" \
    --models "${model}" --prompts "${PROMPTS}" --repetitions "${REPETITIONS}" \
    --result-dir "${OUT_DIR}" || true

  log "[3/5] sync /query latency"
  MODELS_CSV="${model}" \
    PROMPT_IDS_CSV="${PROMPTS}" \
    REPETITIONS="${REPETITIONS}" \
    RESULT_DIR="${OUT_DIR}" \
    ./scripts/benchmark.sh || true

  if [ "${SKIP_K6}" != "true" ] && command -v k6 >/dev/null 2>&1; then
    log "[4/5] k6 ramp 1->${MAX_VUS} VUs"
    MODEL_SAFE="$(echo "${model}" | tr ':/' '_')"
    AUTH_TOKEN=""
    if [ -n "${AUDIENCE}" ]; then
      AUTH_TOKEN="$(gcloud auth print-identity-token --audiences="${AUDIENCE}" 2>/dev/null || true)"
    fi
    k6 run \
      -e BASE_URL="${BACKEND_URL}" \
      -e AUTH_TOKEN="${AUTH_TOKEN}" \
      -e ARCH="${ARCH}" \
      -e MODEL_TAG="${model}" \
      -e MAX_VUS="${MAX_VUS}" \
      --summary-export="${OUT_DIR}/k6_${MODEL_SAFE}_summary.json" \
      --out "csv=${OUT_DIR}/k6_${MODEL_SAFE}_raw.csv" \
      benchmarks/k6/rps_sweep.js || true
  else
    log "[4/5] skipping k6 (SKIP_K6=${SKIP_K6} or k6 not installed)"
  fi

  if [ "${SKIP_COLDSTART}" != "true" ]; then
    log "[5/5] cold-start benchmark"
    TARGET="${ARCH}" \
      NAMESPACE="${NAMESPACE}" \
      RESULT_DIR="${OUT_DIR}" \
      REPETITIONS=2 \
      CR_BACKEND_URL="${BACKEND_URL}" \
      CR_AUDIENCE="${AUDIENCE}" \
      ./scripts/benchmark_coldstart.sh || true
  else
    log "[5/5] skipping cold-start (SKIP_COLDSTART=true)"
  fi

done

log "Matrix done -> ${OUT_DIR}"
