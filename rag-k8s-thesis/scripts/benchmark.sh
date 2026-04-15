#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-rag-thesis}"
BACKEND_SERVICE="${BACKEND_SERVICE:-rag-backend}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
REMOTE_PORT="${REMOTE_PORT:-80}"
REPETITIONS="${REPETITIONS:-3}"
MODELS_CSV="${MODELS_CSV:-phi3:mini,qwen2.5:3b,granite3.3:8b}"
PROMPT_IDS_CSV="${PROMPT_IDS_CSV:-P1,P2,P3,P4,P5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-1800}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
REQUEST_RETRIES="${REQUEST_RETRIES:-3}"
RETRY_SLEEP_SECONDS="${RETRY_SLEEP_SECONDS:-5}"
# For thesis benchmarks, disable product caps so latency/quality comparisons are not truncated.
BENCHMARK_PRODUCT_LATENCY_MODE="${BENCHMARK_PRODUCT_LATENCY_MODE:-false}"
BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS="${BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS:-0}"
BENCHMARK_QDRANT_TOP_K="${BENCHMARK_QDRANT_TOP_K:-4}"

RESULT_DIR="${RESULT_DIR:-benchmarks}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_DIR}/results_${TIMESTAMP}.csv"
LOG_FILE="${RESULT_DIR}/run_${TIMESTAMP}.log"

mkdir -p "${RESULT_DIR}"

PROMPT_P1="What is SEC filing?"
PROMPT_P2="Summarize key risk factors discussed in these SEC filings."
PROMPT_P3="What recurring business risks are mentioned across multiple filings?"
PROMPT_P4="List important compliance or regulatory themes in the dataset."
PROMPT_P5="Give a concise 5-bullet summary of major concerns from the filings."

IFS=',' read -r -a MODELS <<< "${MODELS_CSV}"
IFS=',' read -r -a PROMPT_IDS <<< "${PROMPT_IDS_CSV}"

get_prompt() {
  case "$1" in
    P1) printf "%s" "${PROMPT_P1}" ;;
    P2) printf "%s" "${PROMPT_P2}" ;;
    P3) printf "%s" "${PROMPT_P3}" ;;
    P4) printf "%s" "${PROMPT_P4}" ;;
    P5) printf "%s" "${PROMPT_P5}" ;;
    *)  printf "%s" "${PROMPT_P1}" ;;
  esac
}

ensure_port_forward() {
  if [ -n "${PF_PID:-}" ] && kill -0 "${PF_PID}" >/dev/null 2>&1; then
    return
  fi
  kubectl port-forward -n "${NAMESPACE}" "svc/${BACKEND_SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
}

wait_backend_ready() {
  local ready="000"
  local attempt=1
  while [ "${attempt}" -le 60 ]; do
    ensure_port_forward
    ready="$(
      curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${CONNECT_TIMEOUT}" \
        "http://127.0.0.1:${LOCAL_PORT}/healthz" || true
    )"
    if [ "${ready}" = "200" ]; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

run_query_once() {
  local prompt="$1"
  local result
  local attempt=1
  while [ "${attempt}" -le "${REQUEST_RETRIES}" ]; do
    ensure_port_forward
    result="$(
      curl -s -o /dev/null -w "%{http_code},%{time_total}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -X POST "http://127.0.0.1:${LOCAL_PORT}/query" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"${prompt}\"}" || true
    )"
    if [ -z "${result}" ]; then
      result="000,${CURL_MAX_TIME}"
    fi
    if [ "${result%%,*}" = "200" ] || [ "${attempt}" -eq "${REQUEST_RETRIES}" ]; then
      printf "%s" "${result}"
      return 0
    fi
    sleep "${RETRY_SLEEP_SECONDS}"
    attempt=$((attempt + 1))
  done
}

echo "timestamp,model,prompt_id,repetition,http_code,total_time_s" > "${RESULT_FILE}"

echo "[$(date)] Starting benchmark run" | tee -a "${LOG_FILE}"
echo "[$(date)] Result CSV: ${RESULT_FILE}" | tee -a "${LOG_FILE}"
echo "[$(date)] Benchmark knobs: PRODUCT_LATENCY_MODE=${BENCHMARK_PRODUCT_LATENCY_MODE} OLLAMA_MAX_OUTPUT_TOKENS=${BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS} QDRANT_TOP_K=${BENCHMARK_QDRANT_TOP_K}" | tee -a "${LOG_FILE}"

kubectl get pods -n "${NAMESPACE}" >/dev/null

PF_PID=""
cleanup() {
  if [ -n "${PF_PID}" ]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_port_forward

for model in "${MODELS[@]}"; do
  echo "[$(date)] Switching model to ${model}" | tee -a "${LOG_FILE}"
  kubectl exec -n "${NAMESPACE}" deployment/ollama -- ollama pull "${model}" >/dev/null
  kubectl set env deployment/rag-backend -n "${NAMESPACE}" \
    OLLAMA_MODEL="${model}" \
    REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-1800}" \
    PRODUCT_LATENCY_MODE="${BENCHMARK_PRODUCT_LATENCY_MODE}" \
    OLLAMA_MAX_OUTPUT_TOKENS="${BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS}" \
    QDRANT_TOP_K="${BENCHMARK_QDRANT_TOP_K}" >/dev/null
  kubectl rollout status deployment/rag-backend -n "${NAMESPACE}" --timeout=1200s >/dev/null
  if ! wait_backend_ready; then
    echo "[$(date)] model=${model} backend_not_ready_after_switch" | tee -a "${LOG_FILE}"
  fi

  warmup_prompt="$(get_prompt P1)"
  run_query_once "${warmup_prompt}" >/dev/null || true

  for prompt_id in "${PROMPT_IDS[@]}"; do
    prompt="$(get_prompt "${prompt_id}")"
    for rep in $(seq 1 "${REPETITIONS}"); do
      result="$(run_query_once "${prompt}")"
      http_code="${result%%,*}"
      total_time="${result##*,}"
      echo "$(date +%Y-%m-%dT%H:%M:%S),${model},${prompt_id},${rep},${http_code},${total_time}" >> "${RESULT_FILE}"
      echo "[$(date)] model=${model} prompt=${prompt_id} rep=${rep} code=${http_code} time=${total_time}s" | tee -a "${LOG_FILE}"
    done
  done
done

echo "[$(date)] Benchmark run complete" | tee -a "${LOG_FILE}"
echo "[$(date)] Output: ${RESULT_FILE}" | tee -a "${LOG_FILE}"
