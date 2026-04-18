#!/usr/bin/env bash
# =============================================================================
# Automates the four resilience scenarios documented in RESULTS.md §5.
# Produces one CSV row per scenario so the thesis numbers are reproducible
# on demand instead of being hand-written TBDs.
#
# Scenarios (same order as RESULTS.md):
#   A) baseline             -- healthy cluster, sanity probe
#   B) primary_bad          -- set LLM_MODEL to a bogus tag, expect
#                              llm.fallback=true and the fallback model's
#                              answer (proves the retry + fallback chain)
#   C) ollama_down          -- scale ollama to 0, expect a 200 response
#                              containing the LLM_UNAVAILABLE_MARKER but
#                              still with `sources` populated
#   D) qdrant_down          -- scale qdrant to 0, expect HTTP 503 with
#                              body "Qdrant unavailable: ..."
#
# Safe to re-run: the script restores the original LLM_MODEL + replica counts
# after each destructive step, and exits non-zero if any restore fails so you
# notice a half-broken cluster before the matrix runs.
#
# Usage:
#   kubectl port-forward -n rag-thesis svc/rag-backend 8000:80 &
#   BASE_URL=http://127.0.0.1:8000 ./scripts/measure_resilience.sh
#
# Overridable env:
#   BASE_URL           (default http://127.0.0.1:8000)
#   NAMESPACE          (default rag-thesis)
#   OLLAMA_DEPLOY      (default ollama)
#   QDRANT_STS         (default qdrant)
#   BACKEND_DEPLOY     (default rag-backend)
#   PRIMARY_MODEL      (read from current Deployment if unset)
#   PROMPT             (default "What is SEC filing?")
#   OUT                (default benchmarks/resilience_<ts>.csv)
#   CURL_MAX_TIME      (default 900)
# =============================================================================

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
NAMESPACE="${NAMESPACE:-rag-thesis}"
OLLAMA_DEPLOY="${OLLAMA_DEPLOY:-ollama}"
QDRANT_STS="${QDRANT_STS:-qdrant}"
BACKEND_DEPLOY="${BACKEND_DEPLOY:-rag-backend}"
PROMPT="${PROMPT:-What is SEC filing?}"
CURL_MAX_TIME="${CURL_MAX_TIME:-900}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT:-benchmarks/resilience_${TS}.csv}"

mkdir -p "$(dirname "${OUT}")"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1' on PATH" >&2; exit 2; }
}
require kubectl
require curl
require jq

# Discover the currently-configured primary LLM so we can restore it later.
PRIMARY_MODEL="${PRIMARY_MODEL:-$(kubectl get deploy "${BACKEND_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLM_MODEL")].value}' \
  2>/dev/null || echo "qwen2.5:3b")}"
if [ -z "${PRIMARY_MODEL}" ]; then
  PRIMARY_MODEL="qwen2.5:3b"
fi
echo "[info] primary model to restore at exit: ${PRIMARY_MODEL}"

# Capture the current Ollama replica count (HPA might set it >1) so we
# restore to that, not hard-coded 1.
OLLAMA_REPLICAS="$(kubectl get deploy "${OLLAMA_DEPLOY}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
OLLAMA_REPLICAS="${OLLAMA_REPLICAS:-1}"
QDRANT_REPLICAS="$(kubectl get statefulset "${QDRANT_STS}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
QDRANT_REPLICAS="${QDRANT_REPLICAS:-1}"

restore_cluster() {
  echo "[info] restoring cluster state"
  kubectl set env "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" \
    "LLM_MODEL=${PRIMARY_MODEL}" >/dev/null 2>&1 || true
  kubectl scale "deploy/${OLLAMA_DEPLOY}" -n "${NAMESPACE}" \
    --replicas="${OLLAMA_REPLICAS}" >/dev/null 2>&1 || true
  kubectl scale "statefulset/${QDRANT_STS}" -n "${NAMESPACE}" \
    --replicas="${QDRANT_REPLICAS}" >/dev/null 2>&1 || true
  kubectl rollout status "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" --timeout=600s || true
  kubectl rollout status "deployment/${OLLAMA_DEPLOY}" -n "${NAMESPACE}" --timeout=1200s || true
  kubectl rollout status "statefulset/${QDRANT_STS}" -n "${NAMESPACE}" --timeout=600s || true
}
trap restore_cluster EXIT

echo "scenario,http_code,fallback,model_used,attempts,answer_marker,sources_count,notes" > "${OUT}"

probe() {
  local scenario="$1"
  local notes="${2:-}"
  local resp code body fb model att marker src_count
  resp="/tmp/rag_resp_${scenario}.json"
  code="$(curl -s -o "${resp}" -w "%{http_code}" \
    --max-time "${CURL_MAX_TIME}" \
    -X POST "${BASE_URL}/query" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"${PROMPT}\"}" || echo 000)"
  if [ -s "${resp}" ]; then
    body="$(cat "${resp}")"
    fb="$(echo "${body}" | jq -r '.llm.fallback // false' 2>/dev/null || echo n/a)"
    model="$(echo "${body}" | jq -r '.llm.model_used // "n/a"' 2>/dev/null || echo n/a)"
    att="$(echo "${body}" | jq -r '.llm.attempts // "n/a"' 2>/dev/null || echo n/a)"
    marker="$(echo "${body}" | jq -r '.answer // ""' 2>/dev/null \
      | grep -c "LLM unavailable" || true)"
    src_count="$(echo "${body}" | jq -r '.sources // [] | length' 2>/dev/null || echo 0)"
  else
    fb="n/a"; model="n/a"; att="n/a"; marker="0"; src_count="0"
  fi
  echo "${scenario},${code},${fb},${model},${att},${marker},${src_count},${notes}" >> "${OUT}"
  echo "[probe] ${scenario}: code=${code} fallback=${fb} model=${model} attempts=${att} marker_hits=${marker} sources=${src_count}"
}

# --- A) baseline ------------------------------------------------------------
probe baseline "primary=${PRIMARY_MODEL}"

# --- B) bogus primary model -> fallback must answer --------------------------
echo "[scn] primary_bad: switching LLM_MODEL to bogus:tag"
kubectl set env "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" \
  LLM_MODEL="bogus:tag" >/dev/null
kubectl rollout status "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" --timeout=600s
probe primary_bad "expected: fallback=true, model_used=<fallback>"
kubectl set env "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" \
  "LLM_MODEL=${PRIMARY_MODEL}" >/dev/null
kubectl rollout status "deployment/${BACKEND_DEPLOY}" -n "${NAMESPACE}" --timeout=600s

# --- C) Ollama down -> LLM_UNAVAILABLE_MARKER, sources still populated -------
echo "[scn] ollama_down: scaling ${OLLAMA_DEPLOY} to 0"
kubectl scale "deploy/${OLLAMA_DEPLOY}" -n "${NAMESPACE}" --replicas=0
kubectl wait --for=delete pod -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=ollama --timeout=180s >/dev/null 2>&1 || true
probe ollama_down "expected: 200 with LLM_UNAVAILABLE marker and sources>0"
kubectl scale "deploy/${OLLAMA_DEPLOY}" -n "${NAMESPACE}" \
  --replicas="${OLLAMA_REPLICAS}"
kubectl rollout status "deployment/${OLLAMA_DEPLOY}" -n "${NAMESPACE}" --timeout=1200s

# --- D) Qdrant down -> HTTP 503 ---------------------------------------------
echo "[scn] qdrant_down: scaling ${QDRANT_STS} to 0"
kubectl scale "statefulset/${QDRANT_STS}" -n "${NAMESPACE}" --replicas=0
kubectl wait --for=delete pod -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=qdrant --timeout=180s >/dev/null 2>&1 || true
probe qdrant_down "expected: HTTP 503"
kubectl scale "statefulset/${QDRANT_STS}" -n "${NAMESPACE}" \
  --replicas="${QDRANT_REPLICAS}"
kubectl rollout status "statefulset/${QDRANT_STS}" -n "${NAMESPACE}" --timeout=600s

echo "Resilience probes complete -> ${OUT}"
