# GCP GPU Deployment Guide + Cost Estimate

This document captures:

1. What failed in the current terminal run.
2. The exact fix sequence.
3. A realistic cost estimate for thesis benchmarking on GKE GPU nodes.

## 1) What failed and why

From the latest run, all major failures trace to:

- `FAILED_PRECONDITION: Billing account ... is not open`
- `UREQ_PROJECT_BILLING_NOT_OPEN`

Because billing is not enabled for project `abstract-arc-480317-s4`, GCP cannot enable required services:

- `artifactregistry.googleapis.com`
- `container.googleapis.com`
- `compute.googleapis.com`
- `containerregistry.googleapis.com`
- `dns.googleapis.com`

That is why the following steps fail:

- Artifact Registry repo create
- Docker push to Artifact Registry
- GKE cluster creation
- GKE GPU node-pool creation
- `gcloud container clusters get-credentials`

## 2) Fix steps (in order)

### 0. Authentication + project sanity checks

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project abstract-arc-480317-s4
gcloud auth list
gcloud config list project
```

### A. Enable billing in Console (required)

Open:

- <https://console.cloud.google.com/billing/linkedaccount?project=abstract-arc-480317-s4>

Link the project to an active billing account.

Wait 2-5 minutes for propagation.

Optional CLI check (after linking billing):

```bash
gcloud beta billing projects describe abstract-arc-480317-s4
```

### B. Re-run setup commands

`./scripts/deploy/deploy_gcp_gpu.sh` defaults to **`europe-west3` (Frankfurt)** so the GKE cluster, Artifact Registry, and GPU node pool stay in one region (a US cluster cannot use a EU GPU pool).

```bash
PROJECT_ID="abstract-arc-480317-s4"
REGION="europe-west3"
CLUSTER="rag-thesis-gpu"
REPO="rag-thesis"
IMAGE_TAG="gcp-gpu-v1"

gcloud config set project "$PROJECT_ID"

gcloud services enable \
  artifactregistry.googleapis.com \
  container.googleapis.com \
  compute.googleapis.com \
  containerregistry.googleapis.com \
  dns.googleapis.com

gcloud artifacts repositories create "$REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="RAG thesis images" || true

gcloud auth configure-docker "$REGION-docker.pkg.dev"

cd /Users/longtran/Projects/MasterThesis/rag-k8s-thesis
BACKEND_IMG="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/backend:$IMAGE_TAG"
FRONTEND_IMG="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/frontend:$IMAGE_TAG"

docker build -t "$BACKEND_IMG" ./backend && docker push "$BACKEND_IMG"
docker build -t "$FRONTEND_IMG" ./frontend && docker push "$FRONTEND_IMG"

gcloud container clusters create "$CLUSTER" \
  --region "$REGION" \
  --num-nodes 2 \
  --machine-type e2-standard-4

gcloud container node-pools create gpu-pool \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --machine-type g2-standard-8 \
  --accelerator type=nvidia-l4,count=1 \
  --num-nodes 1 \
  --node-labels=accelerator=nvidia \
  --node-taints=nvidia.com/gpu=present:NoSchedule

gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"

# Strongly recommended for bursty benchmark traffic:
gcloud container node-pools update gpu-pool \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --enable-autoscaling \
  --min-nodes 1 \
  --max-nodes 6
```

### C. Deploy app on GKE (Helm, GPU Ollama)

```bash
kubectl apply -f k8s/llm-inference/nvidia-device-plugin.yaml

helm upgrade --install rag-poc ./helm/rag-k8s-thesis \
  --namespace rag-thesis --create-namespace \
  --set backend.image="$BACKEND_IMG" \
  --set frontend.image="$FRONTEND_IMG" \
  --set ollama.gpu.enabled=true \
  --set ollama.gpu.count=1 \
  --set ollama.gpu.nodeSelector.accelerator=nvidia \
  --set ollama.gpu.tolerations[0].key=nvidia.com/gpu \
  --set ollama.gpu.tolerations[0].operator=Exists \
  --set ollama.gpu.tolerations[0].effect=NoSchedule \
  --set backend.autoscaling.enabled=true \
  --set backend.autoscaling.minReplicas=2 \
  --set backend.autoscaling.maxReplicas=12 \
  --set backend.autoscaling.targetCPUUtilizationPercentage=65 \
  --set ollama.autoscaling.enabled=true \
  --set ollama.autoscaling.minReplicas=1 \
  --set ollama.autoscaling.maxReplicas=6 \
  --set ollama.autoscaling.targetCPUUtilizationPercentage=70 \
  --set backend.env.llmProvider=ollama \
  --set backend.env.llmBaseUrl=http://ollama:11434 \
  --set ollama.modelName=granite3.3:8b \
  --set backend.env.llmModel=granite3.3:8b \
  --set backend.env.llmFallbackModel=phi3:mini
```

### D. Apply raw HPA manifests (if you deploy with `kubectl apply` instead of Helm)

```bash
kubectl apply -f k8s/backend/backend-hpa.yaml
kubectl apply -f k8s/llm-inference/ollama-gpu-hpa.yaml
```

### E. Verify GPU scheduling

```bash
kubectl get nodes -o wide
kubectl get pods -n rag-thesis -o wide
kubectl get hpa -n rag-thesis
kubectl describe pod -n rag-thesis -l app.kubernetes.io/name=ollama | rg "Node:|nvidia.com/gpu"
kubectl exec -n rag-thesis deployment/ollama -- ollama ps
```

If `kubectl get hpa` shows `unknown` metrics, install metrics-server:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

## 3) Cost estimate (GCP)

> Prices vary by region, sustained use, discounts, and future pricing updates.  
> Treat these as planning estimates for thesis budgeting.

### Likely resources in this setup

- CPU pool: `2 x e2-standard-4` nodes
- GPU pool: `1 x g2-standard-8` node with `1 x NVIDIA L4`
- Persistent disks for Qdrant + Ollama models
- Minimal network egress (if mostly in-cluster traffic)

### Rough hourly estimate (europe-west3 or similar EU region, on-demand style)

- CPU pool total: ~`$0.25 - $0.35 / hour`
- GPU node (g2-standard-8 + L4): ~`$0.90 - $1.20 / hour`
- GKE control plane (standard cluster): ~`$0.10 / hour`
- PD storage (prorated): ~`$0.01 - $0.05 / hour`

Estimated total:

- **~`$1.25 - $1.70 / hour`**

### Daily and monthly equivalents

- 4-hour benchmark session: **~`$5 - $7`**
- 8-hour test day: **~`$10 - $14`**
- 30 days continuous (24/7): **~`$900 - $1,224`** (not recommended for thesis budget)

### Cost-saving tips for thesis work

- Delete cluster after each benchmark day:
  - `gcloud container clusters delete "$CLUSTER" --region "$REGION"`
- Keep images in Artifact Registry; recreate cluster only when needed.
- Use shorter benchmark windows and stop idle GPU nodes.
- Start with `phi3:mini` and low repetition counts for smoke tests, then run the
  full thesis trio: `phi3:mini`, `granite3.3:8b`, `deepseek-r1:8b`.

## 4) Recommended benchmark budget plan

- Dry run (1-2 hours): validate deployment + health checks.
- Main benchmark session (3-4 hours): collect thesis data.
- Optional rerun (2-3 hours): confirm reproducibility.

Expected spend range for meaningful results:

- **~`$8 - $20`** total, if you tear down promptly after each run.



gcloud container clusters describe rag-thesis-gpu \
  --region europe-west3 \
  --format="value(status)"