#!/usr/bin/env bash
# Install ArgoCD on the GKE cluster and apply the rag-k8s-thesis Application
# (see k8s/argocd/application-helm.yaml).
#
# Prereqs:
#   - kubectl is pointed at your GKE cluster
#   - The repo is public (or ArgoCD has credentials for a private repo)
#
# Usage:
#   REPO_URL=https://github.com/<you>/<repo>.git REPO_REF=main \
#     ./scripts/install_argocd.sh
#
# To measure "time-to-sync" for the thesis operational-complexity metric:
#   1. Bump a value in helm/rag-k8s-thesis/values.yaml
#   2. git commit && git push
#   3. ./scripts/measure_argocd_sync.sh
set -euo pipefail

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.12.4}"
APP_NAMESPACE="${APP_NAMESPACE:-rag-thesis}"
REPO_URL="${REPO_URL:-https://github.com/your-org/your-repo.git}"
REPO_REF="${REPO_REF:-main}"
APP_PATH="${APP_PATH:-rag-k8s-thesis/helm/rag-k8s-thesis}"

echo "==> Creating argocd namespace + installing ArgoCD ${ARGOCD_VERSION}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Waiting for argocd-server Deployment to roll out"
kubectl -n "${NAMESPACE}" rollout status deploy/argocd-server --timeout=600s
kubectl -n "${NAMESPACE}" rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n "${NAMESPACE}" rollout status deploy/argocd-applicationset-controller --timeout=600s || true

echo "==> Rendering Application manifest with your repo URL/ref/path"
APP_MANIFEST="$(mktemp)"
sed \
  -e "s|https://github.com/your-org/your-repo.git|${REPO_URL}|" \
  -e "s|targetRevision: main|targetRevision: ${REPO_REF}|" \
  -e "s|rag-k8s-thesis/helm/rag-k8s-thesis|${APP_PATH}|" \
  rag-k8s-thesis/k8s/argocd/application-helm.yaml > "${APP_MANIFEST}" || \
  sed \
    -e "s|https://github.com/your-org/your-repo.git|${REPO_URL}|" \
    -e "s|targetRevision: main|targetRevision: ${REPO_REF}|" \
    -e "s|rag-k8s-thesis/helm/rag-k8s-thesis|${APP_PATH}|" \
    k8s/argocd/application-helm.yaml > "${APP_MANIFEST}"

kubectl apply -f "${APP_MANIFEST}"
rm -f "${APP_MANIFEST}"

echo "==> Admin password:"
kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

cat <<EOF

==> ArgoCD installed.

Port-forward the UI:
  kubectl -n ${NAMESPACE} port-forward svc/argocd-server 8080:443
  open https://localhost:8080   (user: admin)

The Application object is now tracking ${REPO_URL}#${REPO_REF} (path: ${APP_PATH}).
Pushing a commit that changes values.yaml should trigger an auto-sync within
~3 minutes (default ArgoCD poll). Use scripts/measure_argocd_sync.sh to record
the exact time-to-sync.
EOF
