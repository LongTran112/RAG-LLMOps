#!/usr/bin/env bash

set -euo pipefail

# One-command profile comparison for thesis reporting.
# Runs the same model/prompt set twice:
# 1) fast profile   (interactive/product-style)
# 2) quality profile (less constrained output)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-rag-thesis}"
MODELS_CSV="${MODELS_CSV:-phi3:mini,granite3.3:8b,deepseek-r1:8b}"
PROMPT_IDS_CSV="${PROMPT_IDS_CSV:-P1,P2,P3}"
REPETITIONS="${REPETITIONS:-2}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-300}"
CURL_MAX_TIME="${CURL_MAX_TIME:-300}"
LLM_PROVIDER="${LLM_PROVIDER:-ollama}"
LLM_BASE_URL="${LLM_BASE_URL:-http://ollama:11434}"

echo "== Profile benchmark: FAST =="
NAMESPACE="${NAMESPACE}" \
MODELS_CSV="${MODELS_CSV}" \
PROMPT_IDS_CSV="${PROMPT_IDS_CSV}" \
REPETITIONS="${REPETITIONS}" \
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS}" \
CURL_MAX_TIME="${CURL_MAX_TIME}" \
LLM_PROVIDER="${LLM_PROVIDER}" \
LLM_BASE_URL="${LLM_BASE_URL}" \
BENCHMARK_PRODUCT_LATENCY_MODE=true \
BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS=192 \
BENCHMARK_QDRANT_TOP_K=3 \
"${SCRIPT_DIR}/benchmark.sh"

echo "== Profile benchmark: QUALITY =="
NAMESPACE="${NAMESPACE}" \
MODELS_CSV="${MODELS_CSV}" \
PROMPT_IDS_CSV="${PROMPT_IDS_CSV}" \
REPETITIONS="${REPETITIONS}" \
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS}" \
CURL_MAX_TIME="${CURL_MAX_TIME}" \
LLM_PROVIDER="${LLM_PROVIDER}" \
LLM_BASE_URL="${LLM_BASE_URL}" \
BENCHMARK_PRODUCT_LATENCY_MODE=false \
BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS=0 \
BENCHMARK_QDRANT_TOP_K=4 \
"${SCRIPT_DIR}/benchmark.sh"

echo "Done. Check newest files in benchmarks/:"
echo "  - results_*.csv"
echo "  - run_*.log"
