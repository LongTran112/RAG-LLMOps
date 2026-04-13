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
│   └── ingestion/
└── README.md
```

## Runtime flow

1. `ingestion/ingest_data.py` loads and chunks text files from `ingestion/data`.
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
```

Optional scheduled ingestion:

```bash
kubectl apply -f k8s/ingestion/ingestion-cronjob.yaml
```

## API contract

- `GET /healthz` -> service health
- `POST /query` -> run RAG inference

Example request:

```bash
curl -X POST http://<backend-host>/query \
  -H "Content-Type: application/json" \
  -d '{"query":"What is this thesis PoC about?"}'
```

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
