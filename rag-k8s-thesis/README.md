# RAG on Kubernetes Thesis PoC

This repository contains a proof-of-concept (PoC) for a Retrieval-Augmented Generation (RAG) application deployed on Kubernetes, designed for evaluating:

- performance (latency and throughput),
- scalability (horizontal scaling behavior),
- CI/CD maintainability (GitOps-friendly deployment changes).

## Tech stack

- Backend/API: FastAPI + Uvicorn (Python 3.11)
- RAG orchestration: LangChain
- Vector database: Qdrant
- LLM inference: Ollama (in-cluster)
- Embeddings: `sentence-transformers/all-MiniLM-L6-v2`
- Containerization: Docker
- Orchestration: Kubernetes (raw YAML baseline)
- GitOps target: ArgoCD-compatible directory layout

## Repository layout

```text
rag-k8s-thesis/
├── frontend/
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── backend/
│   ├── app/
│   │   ├── main.py
│   │   ├── rag_pipeline.py
│   │   └── config.py
│   ├── requirements.txt
│   └── Dockerfile
├── ingestion/
│   ├── ingest_data.py
│   ├── data/
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/
│   ├── namespace.yaml
│   ├── vector-db/
│   ├── llm-inference/
│   ├── backend/
│   ├── frontend/
│   └── ingestion/
└── README.md
```

## Runtime flow

1. `ingestion/ingest_data.py` loads and chunks text files from `DATA_DIR` (default: `/data/sec_rag_dataset_100_pdf`).
2. Chunks are embedded using `all-MiniLM-L6-v2`.
3. Vectors and metadata are upserted into Qdrant collection `thesis_docs`.
4. API `/query` retrieves top-k chunks from Qdrant.
5. Retrieved context is sent to Ollama model for answer generation.
6. API returns answer and source snippets.

## Local image build

From `rag-k8s-thesis/`:

```bash
docker build -t rag-k8s-thesis/backend:latest ./backend
docker build -t rag-k8s-thesis/ingestion:latest ./ingestion
```

## Kubernetes deployment

Apply manifests in this order:

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/vector-db/qdrant.yaml
kubectl apply -f k8s/llm-inference/ollama.yaml
kubectl apply -f k8s/backend/backend.yaml
kubectl apply -f k8s/ingestion/ingestion-job.yaml
kubectl apply -f k8s/frontend/frontend.yaml
```

## GPU nodes for faster inference (cloud)

If you deploy on a cloud Kubernetes cluster with NVIDIA GPU nodes, inference latency can drop significantly versus CPU-only Minikube.

1) Install the NVIDIA device plugin:

```bash
kubectl apply -f k8s/llm-inference/nvidia-device-plugin.yaml
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu"
```

2) Deploy Ollama on GPU nodes:

```bash
kubectl apply -f k8s/llm-inference/ollama-gpu.yaml
kubectl rollout status deployment/ollama -n rag-thesis
```

3) (Optional) Deploy vLLM on GPU nodes:

```bash
kubectl apply -f k8s/llm-inference/vllm-gpu.yaml
kubectl rollout status deployment/vllm -n rag-thesis
```

4) Verify GPU allocation:

```bash
kubectl describe pod -n rag-thesis -l app.kubernetes.io/name=ollama | rg "nvidia.com/gpu|Node:"
kubectl exec -n rag-thesis deployment/ollama -- ollama ps
```

### Helm GPU toggle for Ollama

Set in `helm/rag-k8s-thesis/values.yaml`:

- `ollama.gpu.enabled: true`
- `ollama.gpu.count: 1`
- `ollama.gpu.nodeSelector` and `ollama.gpu.tolerations` to match your GPU node pool labels/taints.

Install/upgrade:

```bash
helm upgrade --install rag-poc ./helm/rag-k8s-thesis --namespace rag-thesis --create-namespace
```

Optional scheduled ingestion:

```bash
kubectl apply -f k8s/ingestion/ingestion-cronjob.yaml
```

### SEC dataset mount for ingestion

The ingestion Job/CronJob is configured to mount this host dataset path:

- `/Users/longtran/Projects/MasterThesis/sec_rag_dataset_100_pdf`

inside the container at:

- `/data/sec_rag_dataset_100_pdf`

and sets:

- `DATA_DIR=/data/sec_rag_dataset_100_pdf`

If your dataset path is different, update:

- `k8s/ingestion/ingestion-job.yaml`
- `k8s/ingestion/ingestion-cronjob.yaml`
- `helm/rag-k8s-thesis/values.yaml` (`ingestion.dataset.hostPath`)

Rerun ingestion after dataset or config changes:

```bash
kubectl delete job -n rag-thesis rag-ingestion-once --ignore-not-found
kubectl apply -f k8s/ingestion/ingestion-job.yaml
kubectl logs -n rag-thesis job/rag-ingestion-once --follow
```

Expected success log contains:

- `Ingested <N> chunks into 'thesis_docs'.`

## API contract

- `GET /healthz` -> service health
- `POST /query` -> run RAG inference

Example request:

```bash
curl -X POST http://<backend-host>/query \
  -H "Content-Type: application/json" \
  -d '{"query":"What is this thesis PoC about?"}'
```

## Frontend tester (LangChain + Streamlit)

Run from `rag-k8s-thesis/frontend`:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If backend is port-forwarded to `127.0.0.1:8000`, start UI directly:

```bash
streamlit run app.py
```

If backend is elsewhere:

```bash
RAG_BACKEND_URL=http://<backend-host>:<port> streamlit run app.py
```

Docker option:

```bash
docker build -t rag-k8s-thesis/frontend:latest ./frontend
docker run --rm -p 8501:8501 -e RAG_BACKEND_URL=http://host.docker.internal:8000 rag-k8s-thesis/frontend:latest
```

Kubernetes option:

```bash
eval $(minikube docker-env)
docker build -t rag-k8s-thesis/frontend:latest ./frontend
eval $(minikube docker-env -u)

kubectl apply -f k8s/frontend/frontend.yaml
kubectl port-forward -n rag-thesis svc/rag-frontend 8501:80
```

Open `http://127.0.0.1:8501`.

## Experiment plan for thesis evaluation

### 1) Performance tests

- Measure P50/P95/P99 latency for `/query`.
- Sweep concurrent users (e.g., 1, 5, 10, 20).
- Record CPU/memory of backend, Ollama, and Qdrant pods.

Suggested tool: `k6` or `hey`.

### 2) Scalability tests

- Increase backend replicas (`Deployment` replicas: 1 -> 2 -> 4).
- Compare throughput and latency under fixed concurrency.
- Validate Qdrant and Ollama bottlenecks as backend scales.

### 3) Data consistency tests

- Re-run ingestion job after corpus changes.
- Validate retrieval sources before/after updates.
- Track collection size and duplicate/overwrite behavior.

### 4) CI/CD maintainability criteria (GitOps-oriented)

- Change granularity: isolated component manifests per directory.
- Rollback simplicity: revert manifest commit and ArgoCD sync.
- Reviewability: clear diffs per component (backend/vector-db/llm/ingestion).
- Operational safety: probes, resource bounds, and explicit namespace.

## ArgoCD alignment (conceptual)

Current `k8s/` structure is intentionally directory-based for straightforward ArgoCD app definitions (single app-of-apps or per-component apps). No imperative steps are required in manifests.

## ArgoCD Application (Helm)

A starter ArgoCD `Application` is available at:

- `k8s/argocd/application-helm.yaml`

Before applying, update these fields:

- `spec.source.repoURL` -> your Git repository URL
- `spec.source.targetRevision` -> your branch/tag/commit
- `spec.source.path` -> chart path in your repo (default is `rag-k8s-thesis/helm/rag-k8s-thesis`)

Apply:

```bash
kubectl apply -f k8s/argocd/application-helm.yaml
```

This config enables automated sync with prune + self-heal and creates the destination namespace (`rag-thesis`) when missing.

## Helm transition path (next phase)

After validating raw YAML behavior:

1. Create `helm/rag-k8s-thesis/` chart skeleton.
2. Convert component manifests to templates (`qdrant`, `ollama`, `backend`, `ingestion`).
3. Move tunables to `values.yaml`:
   - model name,
   - resource limits/requests,
   - replicas,
   - host/ingress config,
   - storage sizes.
4. Keep raw YAML as baseline for maintainability comparison in thesis results.

## Helm chart (implemented)

A chart skeleton is available at `helm/rag-k8s-thesis/` and templates all core components:

- Qdrant (PVC, Service, StatefulSet)
- Ollama (PVC, Service, Deployment)
- Backend (Service, Deployment, optional Ingress)
- Ingestion (one-off Job and optional CronJob)

Render and validate:

```bash
helm template rag-poc ./helm/rag-k8s-thesis --namespace rag-thesis
```

Install/upgrade:

```bash
helm upgrade --install rag-poc ./helm/rag-k8s-thesis --namespace rag-thesis --create-namespace
```

Tune runtime parameters via `helm/rag-k8s-thesis/values.yaml` (images, replicas, model name, resource limits, storage sizes, ingress settings, ingestion schedule).
