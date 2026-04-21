# Thesis Benchmark Results

This file is the single document that holds the outcome of the full
experiment matrix defined in the thesis. The raw CSVs live alongside this
file under `benchmarks/`.

The experiment runner is `scripts/benchmark/run_experiment_matrix.sh`; see the
[Runbook](#runbook) section at the bottom for the exact commands used.

> **Status placeholder**: rows marked `TBD` are filled in by running the
> experiment matrix. Do **not** hand-edit numbers -- re-run the matrix so
> the CSV evidence matches the narrative.

---

## Environment

| Setting | GKE value | Cloud Run value |
|---|---|---|
| Region | `europe-west3` | `europe-west3` |
| GPU SKU (Ollama) | `nvidia-l4` (1 per Ollama pod) | `nvidia-l4` (1 per instance) |
| Machine type (GPU node / CR instance) | `g2-standard-8` | 8 vCPU / 32 GiB / 1 L4 |
| Backend compute | 2 pods, 1 vCPU / 3 GiB each | CPU=2, memory=2 GiB, concurrency=8 |
| Qdrant | StatefulSet on standard pool, 2 vCPU / 2 GiB, 10 GiB PVC | `qdrant-shared` VM, e2-standard-4, 100 GiB SSD |
| Vector DB | same code path (`qdrant_client`) against the **same shared Qdrant** for both architectures (see plan §1) | same |
| Dataset | ~100 SEC 10-K PDFs (~50 k pages), alias `thesis_docs_active` | same |
| Image tag | `gcp-gpu-v2` (Artifact Registry) | reuses GKE images |

Commit SHA used for the reported numbers: `TBD`.

---

## 1. Ingestion (blue/green write phase)

Source: `ingest_data.py` emits one row per run into `ingestion_metrics.csv`
(env `INGESTION_METRICS_CSV`).

| Run date | Docs/pages | Chunks | Embed + upsert (s) | Alias swap (s) | Total (s) | Notes |
|---|---|---|---|---|---|---|
| `TBD` | TBD | TBD | TBD | TBD | TBD | granite3.3:8b default baseline |

Zero-downtime verification (blue/green swap under load):

```bash
# Run `ab -n 1000 -c 10` against /query while retriggering ingestion.
# Record non-2xx count: should be 0 because readers are redirected via the
# alias only after the new collection is fully upserted.
```

| Run | 2xx | non-2xx | alias swap p95 (ms) |
|---|---|---|---|
| `TBD` | TBD | TBD | TBD |

---

## 2. Retrieval-only latency (Qdrant)

Endpoint: `/retrieve`. Prompts P1..P5, 10 repetitions.

| Architecture | p50 embed (ms) | p50 search (ms) | p95 embed (ms) | p95 search (ms) | Qdrant RSS peak (MiB) |
|---|---|---|---|---|---|
| GKE       | TBD | TBD | TBD | TBD | TBD |
| Cloud Run | TBD | TBD | TBD | TBD | TBD |

Raw CSVs: `benchmarks/<arch>_<ts>/retrieval_results_*.csv`.

---

## 3. Inference performance

All numbers measured at model-warmed steady state with 3 reps per prompt
(P1..P3). TTFT measured via `benchmark_stream.py`.

### 3.1 Time To First Token (s)

| Model | GKE p50 | GKE p95 | Cloud Run p50 | Cloud Run p95 |
|---|---|---|---|---|
| `phi3:mini`    | TBD | TBD | TBD | TBD |
| `granite3.3:8b` | TBD | TBD | TBD | TBD |
| `deepseek-r1:8b` | TBD | TBD | TBD | TBD |

### 3.2 End-to-end `/query` latency (s)

| Model | GKE p50 | GKE p95 | Cloud Run p50 | Cloud Run p95 |
|---|---|---|---|---|
| `phi3:mini`    | TBD | TBD | TBD | TBD |
| `granite3.3:8b` | TBD | TBD | TBD | TBD |
| `deepseek-r1:8b` | TBD | TBD | TBD | TBD |

### 3.3 Max sustained RPS at 100 concurrent users (k6)

| Model | GKE RPS | GKE p95 query (ms) | GKE error % | Cloud Run RPS | Cloud Run p95 | Cloud Run error % |
|---|---|---|---|---|---|---|
| `phi3:mini`    | TBD | TBD | TBD | TBD | TBD | TBD |
| `granite3.3:8b` | TBD | TBD | TBD | TBD | TBD | TBD |
| `deepseek-r1:8b` | TBD | TBD | TBD | TBD | TBD | TBD |

Attach Grafana screenshots (`k8s/observability/grafana_dashboard_rag.json`)
for GPU utilization + backend RPS/p95 during each row.

### 3.4 Cold start (s from scale-zero to first /query 200)

| Model | GKE pod_ready | GKE first /query | Cloud Run healthz | Cloud Run first /query |
|---|---|---|---|---|
| `phi3:mini`    | TBD | TBD | TBD | TBD |
| `granite3.3:8b` | TBD | TBD | TBD | TBD |
| `deepseek-r1:8b` | TBD | TBD | TBD | TBD |

Raw CSV: `benchmarks/<arch>_<ts>/coldstart_results_*.csv`.

---

## 4. Cost efficiency

Query: `scripts/reports/cost_per_1k_requests.sql` against the BigQuery billing
export, over the exact benchmark window per model.

| Architecture | Model | Idle $/hr | Active $/hr | Active $ / 1k requests |
|---|---|---|---|---|
| GKE       | phi3:mini    | TBD | TBD | TBD |
| GKE       | granite3.3:8b | TBD | TBD | TBD |
| GKE       | deepseek-r1:8b | TBD | TBD | TBD |
| Cloud Run | phi3:mini    | TBD | TBD | TBD |
| Cloud Run | granite3.3:8b | TBD | TBD | TBD |
| Cloud Run | deepseek-r1:8b | TBD | TBD | TBD |

Observation hypothesis (to confirm/refute with data):

- Cloud Run's idle cost should approach zero (min-instances=0), but its
  active per-request cost is expected to be higher because GPU billing is
  second-grained and serialized by concurrency=1.
- GKE has constant idle cost (GPU node always on) but wins at high sustained
  RPS because a single L4 handles more concurrent decodes per second.

---

## 5. Resilience

`rag_pipeline.py` now supports:

- LLM retries + fallback model -> verified by `LLM_MODEL=bogus:tag` run
  returning the configured fallback's answer (attempts field in the
  response body).
- Qdrant outage -> `kubectl scale deploy/qdrant --replicas=0` while hitting
  `/query` returns **HTTP 503** (`Qdrant unavailable: ...`) instead of a
  stack trace.

| Scenario | Observed behaviour | Downtime (s) |
|---|---|---|
| Primary LLM returns HTTP 500 N times | Fallback `phi3:mini` answered; `llm.fallback=true` in body | TBD |
| Ollama scaled to 0 | `[LLM unavailable, returning retrieved context only]` with sources | TBD |
| Qdrant scaled to 0 | HTTP 503 with detail "Qdrant unavailable: ..." | TBD |
| Blue/green alias swap during 1000-request load | 0 non-2xx (expected) | 0 |

---

## 6. Operational complexity

| Metric | Value |
|---|---|
| Raw Kubernetes YAML LoC (`k8s/`) | TBD |
| Helm chart LoC (`helm/rag-k8s-thesis/`) | TBD |
| Cloud Run bash IaC LoC (`scripts/deploy/deploy_gcp_cloudrun.sh` + teardown) | TBD |
| GKE bash IaC LoC (`scripts/deploy/deploy_gcp_gpu.sh` + teardown) | TBD |
| CI pipeline duration median (5 runs) | TBD |
| ArgoCD time-to-sync median (5 config commits) | TBD |

Generate the LoC row with:

```bash
./scripts/reports/loc_report.sh
```

Capture CI durations:

```bash
gh run list -L 20 --workflow=CI --json databaseId,conclusion,durationMs \
  > benchmarks/cicd_runs_$(date +%Y%m%d).json
```

---

## Runbook

Numbers in this document must be regenerated end-to-end, not hand-edited.

```bash
# 1. Deploy
PROJECT_ID=... REGION=europe-west3 ./scripts/deploy/deploy_gcp_gpu.sh
PROJECT_ID=... REGION=europe-west3 ./scripts/deploy/deploy_gcp_cloudrun.sh

# 2. Populate Qdrant (blue/green)
# -- produces a dated collection, then flips alias `thesis_docs_active`
kubectl -n rag-thesis create job --from=cronjob/rag-ingestion-nightly ingest-${TS}

# 3. Run the matrix on GKE
ARCH=gke ./scripts/benchmark/run_experiment_matrix.sh

# 4. Run the matrix on Cloud Run
BACKEND_URL=$(gcloud run services describe rag-backend --region europe-west3 --format='value(status.url)')
ARCH=cloudrun BACKEND_URL="${BACKEND_URL}" AUDIENCE="${BACKEND_URL}" \
  ./scripts/benchmark/run_experiment_matrix.sh

# 5. Cost + LoC + CI/CD
./scripts/reports/loc_report.sh
# Run cost query in BigQuery console, paste results into section 4.

# 6. Grafana + Cloud Monitoring screenshots
#   - import k8s/observability/grafana_dashboard_rag.json
#   - gcloud monitoring dashboards create --config-from-file=k8s/observability/cloud_run_dashboard.json
#   - attach PNGs next to sections 3 / 4 of this document.
```
