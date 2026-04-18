#!/usr/bin/env bash
# Measure the time ArgoCD takes to converge after a git commit.
#
# Records: git commit time -> first `Application.status.reconciledAt` >= commit ->
#          sync status == Synced && health == Healthy.
#
# The "time-to-sync" metric is used in the thesis operational-complexity
# section to compare GitOps-managed GKE vs. imperative `gcloud run deploy`
# for Cloud Run (where the equivalent is the gcloud command's wall-clock time).
#
# Usage (from a clean tree):
#   git commit -am "bump ollama.contextLength"
#   git push
#   ./scripts/measure_argocd_sync.sh
#
# Optional env:
#   APP_NAME=rag-k8s-thesis
#   NAMESPACE=argocd
#   TIMEOUT_S=900

set -euo pipefail

APP_NAME="${APP_NAME:-rag-k8s-thesis}"
NAMESPACE="${NAMESPACE:-argocd}"
TIMEOUT_S="${TIMEOUT_S:-900}"

COMMIT_TIME_EPOCH="$(git log -1 --format=%ct)"
COMMIT_SHA="$(git log -1 --format=%H)"
echo "Measuring time-to-sync for commit ${COMMIT_SHA} (pushed at $(date -r "${COMMIT_TIME_EPOCH}"))"

start_mono=$(python3 -c 'import time; print(time.monotonic())')
deadline=$((SECONDS + TIMEOUT_S))

prev_status=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  sync_status="$(kubectl -n "${NAMESPACE}" get application "${APP_NAME}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
  health_status="$(kubectl -n "${NAMESPACE}" get application "${APP_NAME}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
  revision="$(kubectl -n "${NAMESPACE}" get application "${APP_NAME}" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo '')"
  current="sync=${sync_status} health=${health_status} rev=${revision:0:7}"
  if [ "${current}" != "${prev_status}" ]; then
    echo "[$(date +%H:%M:%S)] ${current}"
    prev_status="${current}"
  fi
  if [ "${sync_status}" = "Synced" ] && [ "${health_status}" = "Healthy" ] \
     && [ "${revision}" = "${COMMIT_SHA}" ]; then
    elapsed=$(python3 -c "import time; print(round(time.monotonic() - ${start_mono}, 2))")
    echo "Converged in ${elapsed}s."
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p benchmarks
    echo "${ts},${COMMIT_SHA},${elapsed}" >> benchmarks/argocd_sync_times.csv
    exit 0
  fi
  sleep 5
done

echo "ERROR: timed out after ${TIMEOUT_S}s waiting for ${APP_NAME} to sync commit ${COMMIT_SHA}" >&2
exit 1
