#!/usr/bin/env bash
# =============================================================================
# Capture GPU utilization time-series during a load test and write it to CSV.
#
# Called in parallel with k6 so the thesis can report real p50 / p95 / peak
# GPU-util numbers instead of the current "attach Grafana screenshot" story.
# The two architectures are queried from different sources but written into
# the same schema (timestamp,gpu_util_pct,fb_used_bytes) so Cloud Run vs GKE
# rows are directly comparable.
#
#   GKE:        Prometheus (kube-prometheus-stack) scraping DCGM exporter
#   Cloud Run:  Cloud Monitoring metric run.googleapis.com/container/gpu/utilizations
#
# Usage:
#   TARGET=gke  OUT_DIR=benchmarks/gke_20260420   MODEL_TAG=granite3.3:8b \
#     DURATION_SECONDS=330 ./scripts/benchmark/capture_gpu_util.sh
#
#   TARGET=cloudrun PROJECT_ID=... REGION=europe-west3 \
#     CR_OLLAMA_SERVICE=ollama-gpu OUT_DIR=... MODEL_TAG=deepseek-r1:8b \
#     DURATION_SECONDS=330 ./scripts/benchmark/capture_gpu_util.sh
#
# Honors an explicit START_EPOCH + END_EPOCH pair if you already captured
# the window; otherwise samples for DURATION_SECONDS starting now.
# =============================================================================

set -euo pipefail

TARGET="${TARGET:-gke}"
OUT_DIR="${OUT_DIR:-benchmarks}"
MODEL_TAG="${MODEL_TAG:-unknown}"
DURATION_SECONDS="${DURATION_SECONDS:-300}"
STEP_SECONDS="${STEP_SECONDS:-5}"

# GKE / Prometheus
PROM_NS="${PROM_NS:-monitoring}"
PROM_SVC="${PROM_SVC:-kps-kube-prometheus-stack-prometheus}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_LOCAL_PORT="${PROM_LOCAL_PORT:-9091}"

# Cloud Run / Cloud Monitoring
PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
REGION="${REGION:-europe-west3}"
CR_OLLAMA_SERVICE="${CR_OLLAMA_SERVICE:-ollama-gpu}"

mkdir -p "${OUT_DIR}"
MODEL_SAFE="$(echo "${MODEL_TAG}" | tr ':/' '_')"
CSV_PATH="${OUT_DIR}/gpu_util_${TARGET}_${MODEL_SAFE}_$(date +%Y%m%d_%H%M%S).csv"

START_EPOCH="${START_EPOCH:-$(date +%s)}"
END_EPOCH="${END_EPOCH:-$((START_EPOCH + DURATION_SECONDS))}"

echo "timestamp,gpu_util_pct,fb_used_bytes" > "${CSV_PATH}"

if [[ "${TARGET}" == "gke" ]]; then
  # kube-prometheus-stack exposes Prometheus as svc/<release>-prometheus.
  # We port-forward for the sampling window so this script is self-contained.
  kubectl port-forward -n "${PROM_NS}" "svc/${PROM_SVC}" \
    "${PROM_LOCAL_PORT}:${PROM_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT
  sleep 2

  # Wait until k6 window has finished before querying, so we get the whole
  # range in a single HTTP round-trip.
  SLEEP_LEFT=$(( END_EPOCH - $(date +%s) ))
  if [ "${SLEEP_LEFT}" -gt 0 ]; then
    sleep "${SLEEP_LEFT}"
  fi

  fetch_series() {
    local query="$1"
    curl -sG "http://127.0.0.1:${PROM_LOCAL_PORT}/api/v1/query_range" \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${START_EPOCH}" \
      --data-urlencode "end=${END_EPOCH}" \
      --data-urlencode "step=${STEP_SECONDS}s"
  }

  util_json="$(fetch_series 'max(DCGM_FI_DEV_GPU_UTIL)')"
  fb_json="$(fetch_series 'max(DCGM_FI_DEV_FB_USED)')"

  python3 - <<PY >> "${CSV_PATH}"
import json, sys
util = json.loads('''${util_json}''')
fb   = json.loads('''${fb_json}''')
u_series = {float(t): float(v) for t, v in (util.get("data", {}).get("result", [{}])[0].get("values") or [])}
f_series = {float(t): float(v) for t, v in (fb.get("data", {}).get("result",   [{}])[0].get("values") or [])}
for ts in sorted(set(u_series) | set(f_series)):
    u = u_series.get(ts, "")
    f = f_series.get(ts, "")
    print(f"{int(ts)},{u},{f}")
PY

elif [[ "${TARGET}" == "cloudrun" ]]; then
  ISO_START="$(date -u -r "${START_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || python3 -c "import datetime as d,sys; print(d.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${START_EPOCH}")"
  ISO_END="$(date -u -r "${END_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || python3 -c "import datetime as d,sys; print(d.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${END_EPOCH}")"

  # Let the window finish before querying.
  SLEEP_LEFT=$(( END_EPOCH - $(date +%s) ))
  if [ "${SLEEP_LEFT}" -gt 0 ]; then
    sleep "${SLEEP_LEFT}"
  fi

  gcloud monitoring time-series list \
    --project="${PROJECT_ID}" \
    --filter="metric.type=\"run.googleapis.com/container/gpu/utilizations\" AND resource.labels.service_name=\"${CR_OLLAMA_SERVICE}\"" \
    --interval-start-time="${ISO_START}" --interval-end-time="${ISO_END}" \
    --format=json > "${OUT_DIR}/_raw_cr_gpu.json" || true

  gcloud monitoring time-series list \
    --project="${PROJECT_ID}" \
    --filter="metric.type=\"run.googleapis.com/container/memory/utilizations\" AND resource.labels.service_name=\"${CR_OLLAMA_SERVICE}\"" \
    --interval-start-time="${ISO_START}" --interval-end-time="${ISO_END}" \
    --format=json > "${OUT_DIR}/_raw_cr_mem.json" || true

  python3 - <<'PY' >> "${CSV_PATH}"
import json, os, datetime as d
out_dir = os.environ["OUT_DIR"]
def load(p):
    try:
        with open(os.path.join(out_dir, p)) as fh:
            return json.load(fh)
    except Exception:
        return []
util = load("_raw_cr_gpu.json")
mem  = load("_raw_cr_mem.json")
def flatten(series):
    out = {}
    for s in series or []:
        for p in s.get("points", []) or []:
            ts = p.get("interval", {}).get("startTime")
            val = (p.get("value", {}) or {}).get("doubleValue")
            if ts is None or val is None:
                continue
            epoch = int(d.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
            out[epoch] = val
    return out
u_series = flatten(util)
m_series = flatten(mem)
for ts in sorted(set(u_series) | set(m_series)):
    print(f"{ts},{u_series.get(ts,'')},{m_series.get(ts,'')}")
PY
  rm -f "${OUT_DIR}/_raw_cr_gpu.json" "${OUT_DIR}/_raw_cr_mem.json"

else
  echo "ERROR: unknown TARGET=${TARGET} (use gke or cloudrun)" >&2
  exit 2
fi

echo "GPU-util series -> ${CSV_PATH}"
