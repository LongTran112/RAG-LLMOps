#!/usr/bin/env bash
# Operational-complexity metric: lines of infrastructure-as-code per target.
#
# Reports LoC for three buckets (running the comparison required by the
# thesis "Operational Complexity" section):
#
#   1. raw Kubernetes YAML    (k8s/)
#   2. Helm chart             (helm/rag-k8s-thesis/)
#   3. Cloud Run bash IaC     (scripts/deploy/deploy_gcp_cloudrun.sh +
#                              scripts/teardown/teardown_gcp_cloudrun.sh)
#
# Prefers `tokei` (much faster, better language detection) and falls back to
# `cloc` if tokei is missing. Output is both human-readable (stdout) and
# machine-readable (CSV under benchmarks/).
set -euo pipefail

# Script lives at scripts/reports/loc_report.sh -- repo root is two levels up.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

RESULT_DIR="benchmarks"
mkdir -p "${RESULT_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CSV_OUT="${RESULT_DIR}/loc_report_${TIMESTAMP}.csv"

pick_tool() {
  if command -v tokei >/dev/null 2>&1; then
    echo "tokei"
  elif command -v cloc >/dev/null 2>&1; then
    echo "cloc"
  else
    echo "none"
  fi
}

TOOL="$(pick_tool)"
if [[ "${TOOL}" == "none" ]]; then
  echo "ERROR: neither tokei nor cloc is installed." >&2
  echo "  brew install tokei      # macOS" >&2
  echo "  brew install cloc       # or" >&2
  exit 2
fi

# Count lines for a set of paths; returns total LoC as a single integer.
count_loc() {
  local label="$1"; shift
  if [[ "${TOOL}" == "tokei" ]]; then
    # --output=json gives a stable structure we can grep
    local total
    total="$(tokei --output=json "$@" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Total",{}).get("code",0))')"
    echo "${total:-0}"
  else
    local total
    total="$(cloc --quiet --csv --sum-one "$@" 2>/dev/null \
      | awk -F, '/^[0-9]+,/ { n+=$5 } END { print n+0 }')"
    echo "${total:-0}"
  fi
}

# Bucket 1: raw Kubernetes YAML (k8s/). Excludes argocd templates so we're
# only counting what we'd hand-maintain to stand up the stack without Helm.
RAW_K8S_LOC="$(count_loc "k8s" k8s/backend k8s/frontend k8s/llm-inference k8s/vector-db k8s/ingestion k8s/namespace.yaml)"

# Bucket 2: Helm chart (helm/rag-k8s-thesis/). Templates + values together
# represent the full managed IaC story.
HELM_LOC="$(count_loc "helm" helm/rag-k8s-thesis)"

# Bucket 3: Cloud Run bash IaC. Thesis-relevant scripts only.
CR_LOC="$(count_loc "cloudrun" scripts/deploy/deploy_gcp_cloudrun.sh scripts/teardown/teardown_gcp_cloudrun.sh)"

# Bonus: GKE bash IaC (for cross-checking with raw k8s + Helm numbers).
GKE_BASH_LOC="$(count_loc "gke-bash" scripts/deploy/deploy_gcp_gpu.sh scripts/teardown/teardown_gcp_gpu.sh)"

printf "%-24s %10s\n" "bucket" "code_loc"
printf "%-24s %10s\n" "------------------------" "----------"
printf "%-24s %10d\n" "raw_k8s_yaml"      "${RAW_K8S_LOC}"
printf "%-24s %10d\n" "helm_chart"        "${HELM_LOC}"
printf "%-24s %10d\n" "cloudrun_bash"     "${CR_LOC}"
printf "%-24s %10d\n" "gke_bash"          "${GKE_BASH_LOC}"

{
  echo "timestamp,bucket,code_loc,tool"
  echo "${TIMESTAMP},raw_k8s_yaml,${RAW_K8S_LOC},${TOOL}"
  echo "${TIMESTAMP},helm_chart,${HELM_LOC},${TOOL}"
  echo "${TIMESTAMP},cloudrun_bash,${CR_LOC},${TOOL}"
  echo "${TIMESTAMP},gke_bash,${GKE_BASH_LOC},${TOOL}"
} > "${CSV_OUT}"

echo
echo "Wrote ${CSV_OUT}"
