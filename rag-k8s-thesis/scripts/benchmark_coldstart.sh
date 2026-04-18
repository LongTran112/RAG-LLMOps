#!/usr/bin/env bash

# =============================================================================
# Cold-start latency benchmark.
#
# Measures the time between "scale-to-zero" and the first successful
# /query response, broken down where possible into:
#   - container image pull / cold provision
#   - container started
#   - first /healthz 200
#   - first /query 200
#
# Two targets (pick with TARGET=gke|cloudrun):
#
#   TARGET=gke (default):
#     Uses kubectl to scale the Ollama Deployment 0 -> 1 and records Pod
#     events + Ollama log lines. Backend stays up so we isolate LLM cold
#     start; for a joint cold start of backend+ollama, set
#     INCLUDE_BACKEND=true.
#
#   TARGET=cloudrun:
#     Uses `gcloud run services update` to switch min-instances to 0 and
#     waits for the instance to retire (idle), then fires a request and
#     records total wall-clock. Instance startup latency is also pulled
#     from Cloud Logging (run.googleapis.com/varlog/system) if
#     QUERY_COLD_LOGS=true.
#
# All runs write CSV rows to benchmarks/coldstart_results_<ts>.csv with
# the same schema so GKE vs Cloud Run can be compared directly.
# =============================================================================

set -euo pipefail

TARGET="${TARGET:-gke}"
NAMESPACE="${NAMESPACE:-rag-thesis}"
OLLAMA_DEPLOY="${OLLAMA_DEPLOY:-ollama}"
BACKEND_DEPLOY="${BACKEND_DEPLOY:-rag-backend}"
INCLUDE_BACKEND="${INCLUDE_BACKEND:-false}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
REMOTE_PORT="${REMOTE_PORT:-80}"
SMOKE_PROMPT="${SMOKE_PROMPT:-What is SEC filing?}"
CURL_MAX_TIME="${CURL_MAX_TIME:-1800}"
IDLE_WAIT_SECONDS="${IDLE_WAIT_SECONDS:-900}"
REPETITIONS="${REPETITIONS:-3}"
MODEL_TAG="${MODEL_TAG:-$(kubectl get deploy/${BACKEND_DEPLOY} -n ${NAMESPACE} -o=jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLM_MODEL")].value}' 2>/dev/null || echo unknown)}"

# Cloud Run
PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
REGION="${REGION:-europe-west3}"
CR_BACKEND_SERVICE="${CR_BACKEND_SERVICE:-rag-backend}"
CR_OLLAMA_SERVICE="${CR_OLLAMA_SERVICE:-ollama-gpu}"
CR_BACKEND_URL="${CR_BACKEND_URL:-}"
CR_AUDIENCE="${CR_AUDIENCE:-}"
QUERY_COLD_LOGS="${QUERY_COLD_LOGS:-false}"

RESULT_DIR="${RESULT_DIR:-benchmarks}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_DIR}/coldstart_results_${TIMESTAMP}.csv"
LOG_FILE="${RESULT_DIR}/coldstart_run_${TIMESTAMP}.log"
mkdir -p "${RESULT_DIR}"

echo "timestamp,target,repetition,model,scale_up_s,pod_ready_s,health_200_s,query_200_s,total_s,notes" > "${RESULT_FILE}"
log() { echo "[$(date)] $*" | tee -a "${LOG_FILE}"; }

now_ns() { python3 -c 'import time; print(time.monotonic_ns())'; }

# ---------- GKE path ----------
gke_cold_start_once() {
  local rep="$1"
  local notes=""

  log "GKE rep=${rep}: scaling ${OLLAMA_DEPLOY} down"
  kubectl scale deploy/"${OLLAMA_DEPLOY}" -n "${NAMESPACE}" --replicas=0 >/dev/null
  kubectl wait --for=delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=ollama --timeout=180s >/dev/null 2>&1 || true

  if [[ "${INCLUDE_BACKEND}" == "true" ]]; then
    kubectl scale deploy/"${BACKEND_DEPLOY}" -n "${NAMESPACE}" --replicas=0 >/dev/null
    kubectl wait --for=delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=rag-backend --timeout=120s >/dev/null 2>&1 || true
    kubectl scale deploy/"${BACKEND_DEPLOY}" -n "${NAMESPACE}" --replicas=1 >/dev/null
  fi

  local t0
  t0="$(now_ns)"

  log "GKE rep=${rep}: scaling ${OLLAMA_DEPLOY} up"
  kubectl scale deploy/"${OLLAMA_DEPLOY}" -n "${NAMESPACE}" --replicas=1 >/dev/null

  # Pod ready
  local t_pod_ready=0
  if kubectl wait --for=condition=Ready pod -n "${NAMESPACE}" -l app.kubernetes.io/name=ollama --timeout=1200s >/dev/null 2>&1; then
    t_pod_ready="$(now_ns)"
  else
    notes="pod_wait_timeout"
  fi

  # Backend healthz
  local pf_pid=""
  kubectl port-forward -n "${NAMESPACE}" "svc/${BACKEND_DEPLOY}" "${LOCAL_PORT}:${REMOTE_PORT}" >/dev/null 2>&1 &
  pf_pid=$!
  sleep 2

  local t_health=0
  local attempt=0
  while [ "${attempt}" -lt 600 ]; do
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${LOCAL_PORT}/healthz" || echo 000)"
    if [ "${code}" = "200" ]; then
      t_health="$(now_ns)"
      break
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  # First /query 200
  local t_query=0
  local q_code
  q_code="$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${CURL_MAX_TIME}" \
    -X POST "http://127.0.0.1:${LOCAL_PORT}/query" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"${SMOKE_PROMPT}\"}" || echo 000)"
  if [ "${q_code}" = "200" ]; then
    t_query="$(now_ns)"
  else
    notes="${notes};query_code=${q_code}"
  fi

  kill "${pf_pid}" >/dev/null 2>&1 || true

  # Durations (seconds)
  local scale_up_s pod_ready_s health_s query_s total_s
  scale_up_s=$(awk -v a="${t_pod_ready}" -v b="${t0}" 'BEGIN{ if (a==0) print -1; else printf "%.3f", (a-b)/1e9 }')
  pod_ready_s="${scale_up_s}"
  health_s=$(awk -v a="${t_health}" -v b="${t0}" 'BEGIN{ if (a==0) print -1; else printf "%.3f", (a-b)/1e9 }')
  query_s=$(awk -v a="${t_query}" -v b="${t0}" 'BEGIN{ if (a==0) print -1; else printf "%.3f", (a-b)/1e9 }')
  total_s="${query_s}"
  echo "$(date +%Y-%m-%dT%H:%M:%S),gke,${rep},${MODEL_TAG},${scale_up_s},${pod_ready_s},${health_s},${query_s},${total_s},${notes}" >> "${RESULT_FILE}"
  log "GKE rep=${rep} pod_ready=${pod_ready_s}s health=${health_s}s query=${query_s}s notes=${notes}"
}

# ---------- Cloud Run path ----------
cloudrun_cold_start_once() {
  local rep="$1"
  local notes=""

  if [ -z "${CR_BACKEND_URL}" ]; then
    CR_BACKEND_URL="$(gcloud run services describe "${CR_BACKEND_SERVICE}" \
      --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"
  fi
  if [ -z "${CR_AUDIENCE}" ]; then
    CR_AUDIENCE="${CR_BACKEND_URL}"
  fi

  log "CloudRun rep=${rep}: ensuring min-instances=0 on ${CR_OLLAMA_SERVICE} & ${CR_BACKEND_SERVICE}"
  gcloud run services update "${CR_OLLAMA_SERVICE}" --min-instances=0 \
    --project="${PROJECT_ID}" --region="${REGION}" --quiet >/dev/null
  gcloud run services update "${CR_BACKEND_SERVICE}" --min-instances=0 \
    --project="${PROJECT_ID}" --region="${REGION}" --quiet >/dev/null

  log "CloudRun rep=${rep}: idling ${IDLE_WAIT_SECONDS}s (wait for Cloud Run to scale to zero)"
  sleep "${IDLE_WAIT_SECONDS}"

  local t0 t_health=0 t_query=0 tok
  t0="$(now_ns)"

  tok=""
  if [ -n "${CR_AUDIENCE}" ]; then
    tok="$(gcloud auth print-identity-token --audiences="${CR_AUDIENCE}" 2>/dev/null || true)"
  fi

  local attempt=0
  while [ "${attempt}" -lt 600 ]; do
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      ${tok:+-H "Authorization: Bearer ${tok}"} \
      "${CR_BACKEND_URL}/healthz" || echo 000)"
    if [ "${code}" = "200" ]; then
      t_health="$(now_ns)"
      break
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  local q_code
  q_code="$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${CURL_MAX_TIME}" \
    ${tok:+-H "Authorization: Bearer ${tok}"} \
    -X POST "${CR_BACKEND_URL}/query" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"${SMOKE_PROMPT}\"}" || echo 000)"
  if [ "${q_code}" = "200" ]; then
    t_query="$(now_ns)"
  else
    notes="query_code=${q_code}"
  fi

  # Cloud Run doesn't expose pod_ready from the outside; leave -1.
  local scale_up_s="-1"
  local pod_ready_s="-1"
  local health_s query_s total_s
  health_s=$(awk -v a="${t_health}" -v b="${t0}" 'BEGIN{ if (a==0) print -1; else printf "%.3f", (a-b)/1e9 }')
  query_s=$(awk -v a="${t_query}" -v b="${t0}" 'BEGIN{ if (a==0) print -1; else printf "%.3f", (a-b)/1e9 }')
  total_s="${query_s}"

  if [[ "${QUERY_COLD_LOGS}" == "true" ]]; then
    log "CloudRun rep=${rep}: pulling last startup latency log"
    local sl
    sl="$(gcloud logging read \
      "resource.type=cloud_run_revision AND resource.labels.service_name=${CR_OLLAMA_SERVICE} AND jsonPayload.message:startupLatency" \
      --project="${PROJECT_ID}" --limit=1 --format='value(jsonPayload.message)' 2>/dev/null || true)"
    notes="${notes};startupLog=${sl:0:80}"
  fi

  echo "$(date +%Y-%m-%dT%H:%M:%S),cloudrun,${rep},${MODEL_TAG},${scale_up_s},${pod_ready_s},${health_s},${query_s},${total_s},${notes}" >> "${RESULT_FILE}"
  log "CloudRun rep=${rep} health=${health_s}s query=${query_s}s notes=${notes}"
}

for rep in $(seq 1 "${REPETITIONS}"); do
  if [[ "${TARGET}" == "gke" ]]; then
    gke_cold_start_once "${rep}"
  elif [[ "${TARGET}" == "cloudrun" ]]; then
    cloudrun_cold_start_once "${rep}"
  else
    echo "ERROR: unknown TARGET=${TARGET} (use gke or cloudrun)" >&2
    exit 2
  fi
done

log "Cold start benchmark complete -> ${RESULT_FILE}"
