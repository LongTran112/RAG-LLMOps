#!/usr/bin/env bash
# =============================================================================
# Measures observable downtime of the blue/green vector-index swap.
#
# Drives steady HTTP traffic against /retrieve (cheap, no LLM call) from the
# moment the background load generator starts until it is stopped, then kicks
# off a fresh ingestion Job that writes into a new physical Qdrant collection
# and atomically re-points the alias. Because the alias swap is the only
# operation that can cause a query to see an empty collection, counting non-2xx
# / zero-hit responses during the swap window is the thesis definition of
# "zero-downtime".
#
# Outputs:
#   benchmarks/bluegreen_<ts>/requests.csv    -- per-request log
#     columns: t_epoch_ms, http_code, latency_ms, hits
#   benchmarks/bluegreen_<ts>/summary.txt     -- counters + window boundaries
#
# Assumes:
#   - The ingestion Job template lives at k8s/ingestion/ingestion-job.yaml
#     (or the Helm chart with ingestion.job.enabled=true).
#   - INGEST_INPLACE=false (the default) so the ingestion actually creates a
#     new physical collection and swaps the alias. In-place ingestion skips
#     the swap and this test is meaningless.
#
# Usage:
#   kubectl port-forward -n rag-thesis svc/rag-backend 8000:80 &
#   BASE_URL=http://127.0.0.1:8000 ./scripts/resilience/measure_bluegreen_downtime.sh
# =============================================================================

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
NAMESPACE="${NAMESPACE:-rag-thesis}"
JOB_MANIFEST="${JOB_MANIFEST:-k8s/ingestion/ingestion-job.yaml}"
JOB_BASE_NAME="${JOB_BASE_NAME:-rag-ingestion-once}"
PROMPT="${PROMPT:-What is SEC filing?}"
RATE_RPS="${RATE_RPS:-5}"        # queries/sec; keep modest so we don't skew timings
TIMEOUT_S="${TIMEOUT_S:-10}"
JOB_TIMEOUT_S="${JOB_TIMEOUT_S:-1800}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-benchmarks/bluegreen_${TS}}"
mkdir -p "${OUT_DIR}"
REQ_CSV="${OUT_DIR}/requests.csv"
SUMMARY="${OUT_DIR}/summary.txt"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1' on PATH" >&2; exit 2; }
}
require kubectl
require curl
require python3

echo "t_epoch_ms,http_code,latency_ms,hits" > "${REQ_CSV}"

# --- background load --------------------------------------------------------
# One-shot python generator in the background: paces at RATE_RPS, logs every
# request's epoch ms, HTTP code, wall-clock latency, and hit count from the
# /retrieve JSON. Stops on SIGTERM.
GEN_PY="$(mktemp /tmp/bluegreen_gen_XXXX.py)"
cat > "${GEN_PY}" <<'PY'
import json, os, signal, sys, time, urllib.request, urllib.error

base = os.environ["BASE_URL"]
rate = float(os.environ.get("RATE_RPS", "5"))
timeout = float(os.environ.get("TIMEOUT_S", "10"))
prompt = os.environ.get("PROMPT", "What is SEC filing?")
period = 1.0 / max(rate, 0.1)

stop = False
def _stop(*_):
    global stop
    stop = True
signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

body = json.dumps({"query": prompt, "top_k": 5}).encode()
while not stop:
    t0 = time.time()
    t0_ms = int(t0 * 1000)
    code = 0
    hits = 0
    try:
        req = urllib.request.Request(
            base.rstrip("/") + "/retrieve",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.status
            try:
                doc = json.loads(resp.read().decode())
                hits = len(doc.get("sources") or doc.get("documents") or [])
            except Exception:
                hits = -1
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        code = 0
    latency_ms = int((time.time() - t0) * 1000)
    print(f"{t0_ms},{code},{latency_ms},{hits}", flush=True)
    sleep_left = period - (time.time() - t0)
    if sleep_left > 0 and not stop:
        time.sleep(sleep_left)
PY

BASE_URL="${BASE_URL}" RATE_RPS="${RATE_RPS}" TIMEOUT_S="${TIMEOUT_S}" PROMPT="${PROMPT}" \
  python3 "${GEN_PY}" >> "${REQ_CSV}" &
GEN_PID=$!

cleanup() {
  kill -TERM "${GEN_PID}" 2>/dev/null || true
  wait "${GEN_PID}" 2>/dev/null || true
  rm -f "${GEN_PY}" 2>/dev/null || true
}
trap cleanup EXIT

# Let the generator warm up before we start the swap so the CSV has a clean
# "before" baseline.
sleep 10
SWAP_START_MS="$(date +%s)000"

# --- trigger ingestion with a unique name so we do not collide with any
# previous Job. We deep-copy the manifest through sed so the user's source
# file is untouched.
JOB_NAME="${JOB_BASE_NAME}-bg-${TS}"
TMP_MANIFEST="$(mktemp)"
cp "${JOB_MANIFEST}" "${TMP_MANIFEST}"
# Rename the Job in-place. Using Python keeps it YAML-safe.
python3 - "${TMP_MANIFEST}" "${JOB_NAME}" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text()
# Replace only the first `name:` line inside the metadata block.
src = re.sub(r"(^metadata:\n(?:[^\n]*\n)*?\s*name:\s*)\S+", r"\g<1>" + sys.argv[2], src, count=1, flags=re.M)
p.write_text(src)
PY

echo "[info] applying ingestion job ${JOB_NAME}"
kubectl apply -f "${TMP_MANIFEST}"
rm -f "${TMP_MANIFEST}"

echo "[info] waiting for job ${JOB_NAME} to complete (timeout=${JOB_TIMEOUT_S}s)"
if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" \
    -n "${NAMESPACE}" --timeout="${JOB_TIMEOUT_S}s"; then
  echo "WARN: job did not complete within timeout; capturing current state anyway" >&2
fi
SWAP_END_MS="$(date +%s)000"

# Give the generator 10s after the swap so we capture the post-swap steady
# state in the CSV too.
sleep 10

cleanup
trap - EXIT

# --- summary ---------------------------------------------------------------
python3 - <<PY | tee "${SUMMARY}"
import csv, pathlib
req = pathlib.Path("${REQ_CSV}")
swap_start = ${SWAP_START_MS}
swap_end   = ${SWAP_END_MS}

total = in_window = bad_in_window = zero_hits_in_window = 0
max_gap_ms = 0
prev_ok_ts = None
with req.open() as fh:
    rdr = csv.DictReader(fh)
    for row in rdr:
        try:
            t  = int(row["t_epoch_ms"])
            c  = int(row["http_code"])
            h  = int(row["hits"])
        except Exception:
            continue
        total += 1
        if swap_start <= t <= swap_end:
            in_window += 1
            if c < 200 or c >= 300:
                bad_in_window += 1
            elif h == 0:
                zero_hits_in_window += 1
        if 200 <= c < 300 and h > 0:
            if prev_ok_ts is not None:
                max_gap_ms = max(max_gap_ms, t - prev_ok_ts)
            prev_ok_ts = t

print(f"swap_window_ms_start={swap_start}")
print(f"swap_window_ms_end={swap_end}")
print(f"swap_window_duration_s={(swap_end - swap_start)/1000:.3f}")
print(f"requests_total={total}")
print(f"requests_in_window={in_window}")
print(f"non2xx_in_window={bad_in_window}")
print(f"zero_hits_in_window={zero_hits_in_window}")
print(f"max_gap_between_good_responses_ms={max_gap_ms}")
PY

echo "Per-request log: ${REQ_CSV}"
echo "Summary:         ${SUMMARY}"
