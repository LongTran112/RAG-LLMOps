#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-abstract-arc-480317-s4}"
# all = delete every GKE cluster in the project + Artifact Registry repos + common GKE orphans (LB, PVC disks)
# single = only CLUSTER in REGION
TEARDOWN_MODE="${TEARDOWN_MODE:-all}"
REGION="${REGION:-europe-west3}"
CLUSTER="${CLUSTER:-rag-thesis-gpu}"
REPO="${REPO:-rag-thesis}"
# Extra Artifact Registry locations to try (in addition to full repo scan below). Default is EU-only.
ARTIFACT_EXTRA_LOCATIONS="${ARTIFACT_EXTRA_LOCATIONS:-europe-west3}"

echo "==> Configure project ${PROJECT_ID} (TEARDOWN_MODE=${TEARDOWN_MODE}, REGION default=${REGION})"
gcloud config set project "${PROJECT_ID}"

# Wait until no RUNNING cluster operations in a regional control plane (best-effort).
wait_region_idle() {
  local reg="$1"
  local n=0
  while [[ "${n}" -lt 80 ]]; do
    local cnt
    cnt="$(gcloud container operations list --region="${reg}" --project="${PROJECT_ID}" \
      --filter="status=RUNNING" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${cnt}" == "0" ]] && return 0
    echo "    ... waiting on ${cnt} running operation(s) in ${reg}"
    sleep 20
    n=$((n + 1))
  done
  echo "WARN: timed out waiting for operations in ${reg}; delete may still fail" >&2
}

# GKE Ingress / Service type LoadBalancer often leaves global L7 resources named k8s2-*.
cleanup_k8s_global_load_balancers() {
  echo "==> Remove orphaned global load balancers (name~^k8s2-)"
  local name
  for name in $(gcloud compute forwarding-rules list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute forwarding-rules delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
  for name in $(gcloud compute target-http-proxies list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute target-http-proxies delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
  for name in $(gcloud compute target-https-proxies list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute target-https-proxies delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
  for name in $(gcloud compute url-maps list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute url-maps delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
  for name in $(gcloud compute backend-services list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute backend-services delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
  for name in $(gcloud compute health-checks list --global --project="${PROJECT_ID}" \
    --filter='name~^k8s2-' --format='value(name)' 2>/dev/null); do
    [[ -z "${name}" ]] && continue
    gcloud compute health-checks delete "${name}" --global --project="${PROJECT_ID}" --quiet || true
  done
}

# Kubernetes PVC disks often remain after cluster delete (name prefix pvc-).
cleanup_orphan_pvc_disks() {
  echo "==> Delete orphaned GKE PVC disks (name~^pvc-)"
  local name zone
  while read -r name zone; do
    [[ -z "${name}" ]] && continue
    zone="${zone##*/}"
    gcloud compute disks delete "${name}" --zone="${zone}" --project="${PROJECT_ID}" --quiet || true
  done < <(gcloud compute disks list --project="${PROJECT_ID}" --filter='name~^pvc-' \
    --format='value(name,zone)' 2>/dev/null || true)
}

delete_cluster_row() {
  local name="$1"
  local location="$2"
  [[ -z "${name}" ]] && return 0
  if gcloud container clusters describe "${name}" --region="${location}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "==> Delete cluster ${name} (region=${location})"
    wait_region_idle "${location}" || true
    gcloud container clusters delete "${name}" \
      --region="${location}" \
      --project="${PROJECT_ID}" \
      --quiet || true
  elif gcloud container clusters describe "${name}" --zone="${location}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "==> Delete cluster ${name} (zone=${location})"
    wait_region_idle "$(echo "${location}" | sed 's/-[^-]*$//')" || true
    gcloud container clusters delete "${name}" \
      --zone="${location}" \
      --project="${PROJECT_ID}" \
      --quiet || true
  else
    echo "WARN: could not describe ${name} at ${location}; skipping" >&2
  fi
}

if [[ "${TEARDOWN_MODE}" == "all" ]]; then
  echo "==> Delete all GKE clusters in project"
  _clist="$(gcloud container clusters list --project="${PROJECT_ID}" --format='csv[no-heading](name,location)' 2>&1)" || true
  if [[ -z "$(echo "${_clist}" | tr -d '[:space:]')" ]]; then
    echo "    No clusters in list output. If you still have VMs, enable billing and re-run, or check: gcloud container clusters list --project ${PROJECT_ID}"
  fi
  while IFS=, read -r cname cloc; do
    [[ -z "${cname}" ]] && continue
    delete_cluster_row "${cname}" "${cloc}"
  done < <(echo "${_clist}" | grep ',' || true)

  cleanup_k8s_global_load_balancers
  cleanup_orphan_pvc_disks

  echo "==> Delete Artifact Registry repos named ${REPO}"
  for loc in ${ARTIFACT_EXTRA_LOCATIONS}; do
    [[ -z "${loc}" ]] && continue
    gcloud artifacts repositories delete "${REPO}" --location="${loc}" --project="${PROJECT_ID}" --quiet || true
  done
  while IFS=, read -r rname rloc; do
    [[ -z "${rname}" ]] && continue
    [[ "${rname}" == "${REPO}" ]] || continue
    gcloud artifacts repositories delete "${rname}" --location="${rloc}" --project="${PROJECT_ID}" --quiet || true
  done < <(gcloud artifacts repositories list --project="${PROJECT_ID}" --format='csv[no-heading](name,location)' 2>/dev/null || true)
else
  echo "==> Delete single cluster ${CLUSTER} in ${REGION}"
  wait_region_idle "${REGION}" || true
  gcloud container clusters delete "${CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" \
    --quiet || true

  cleanup_k8s_global_load_balancers
  cleanup_orphan_pvc_disks

  gcloud artifacts repositories delete "${REPO}" \
    --location "${REGION}" \
    --project "${PROJECT_ID}" \
    --quiet || true
fi

echo "==> Post-check (leftovers — non-empty may still incur cost)"
gcloud compute instances list --project "${PROJECT_ID}" 2>/dev/null || true
gcloud compute disks list --project "${PROJECT_ID}" 2>/dev/null || true
gcloud compute forwarding-rules list --global --project "${PROJECT_ID}" 2>/dev/null || true
gcloud compute addresses list --project "${PROJECT_ID}" 2>/dev/null || true
gcloud container clusters list --project "${PROJECT_ID}" 2>/dev/null || true
gcloud artifacts repositories list --project "${PROJECT_ID}" 2>/dev/null || true

echo "==> Teardown finished (TEARDOWN_MODE=${TEARDOWN_MODE})"
