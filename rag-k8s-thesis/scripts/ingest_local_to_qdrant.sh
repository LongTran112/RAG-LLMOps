#!/usr/bin/env bash
# Load sec_rag_dataset_50 (or any folder of .txt files) into Qdrant in the cluster via port-forward.
# Usage:
#   kubectl config use-context gke_<project>_<region>_rag-thesis-gpu
#   DATA_DIR=/path/to/sec_rag_dataset_50 ./scripts/ingest_local_to_qdrant.sh
set -euo pipefail

NS="${NS:-rag-thesis}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${DATA_DIR:-${REPO_ROOT}/../sec_rag_dataset_50}"

if [[ ! -d "${DATA_DIR}" ]]; then
  echo "ERROR: DATA_DIR is not a directory: ${DATA_DIR}" >&2
  exit 1
fi

cleanup() { kill "${PF_PID:-0}" 2>/dev/null || true; }
trap cleanup EXIT

kubectl port-forward -n "${NS}" svc/qdrant 6333:6333 &
PF_PID=$!
sleep 2

export QDRANT_HOST="${QDRANT_HOST:-127.0.0.1}"
export QDRANT_PORT="${QDRANT_PORT:-6333}"
export DATA_DIR

cd "${REPO_ROOT}/ingestion"
if [[ -d .venv ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
elif [[ -n "${VIRTUAL_ENV:-}" ]]; then
  true
else
  python3 -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
fi
pip install -q -r requirements.txt
python ingest_data.py

echo "==> Done. Re-try: curl -sS http://127.0.0.1:8080/query ..."
