# Thesis-Scope Review

This document maps the current state of the repo against the six thesis
metric categories you defined (plus the MVP scope constraints). Only
**must-have** gaps are listed. Each finding uses the same compact format:

- **Metric** it maps to.
- **Current state** with a clickable file citation.
- **Why it matters for the thesis.**
- **Proposed change** (short snippet or env diff you can cherry-pick).

Nothing else in the repo was modified while writing this. This is a
review; treat every "Proposed change" as a recommendation, not an applied
edit.

---

## 0. Scope constraints (100 PDFs, 300-500 pages each, static)

### 0.1 Dataset drift — the repo still points at the 50-PDF corpus

- **Current state.** Three places still reference the old 50-PDF set:
  - [`ingestion/ingest_data.py`](ingestion/ingest_data.py) line 26:
    `DATA_DIR = Path(os.getenv("DATA_DIR", "/data/sec_rag_dataset_50"))`
  - [`helm/rag-k8s-thesis/values.yaml`](helm/rag-k8s-thesis/values.yaml) lines 121-123:
    `hostPath: /host/MasterThesis/sec_rag_dataset_50`, `mountPath: /data/sec_rag_dataset_50`, `dataDir: /data/sec_rag_dataset_50`.
  - [`README.md`](README.md) § "SEC dataset mount for ingestion" (lines 133-147) still documents `sec_rag_dataset_50`.
  - The 100-PDF corpus actually exists on disk at `/Users/longtran/Projects/MasterThesis/sec_rag_dataset_100_pdf/`.
- **Why it matters.** The thesis scope is explicit that the knowledge base is ~100 PDFs of 300-500 pages each (~30-50 k pages). Running the matrix with the 50-PDF corpus under-stresses the vector-DB path and invalidates the "realistically large vector space" claim.
- **Proposed change (one env default + one values override):**
  ```python
  # ingestion/ingest_data.py
  DATA_DIR = Path(os.getenv("DATA_DIR", "/data/sec_rag_dataset_100_pdf"))
  ```
  ```yaml
  # helm/rag-k8s-thesis/values.yaml (ingestion.dataset)
  hostPath: /host/MasterThesis/sec_rag_dataset_100_pdf
  mountPath: /data/sec_rag_dataset_100_pdf
  dataDir:   /data/sec_rag_dataset_100_pdf
  ```
  Also update the three README snippets and `k8s/ingestion/ingestion-job.yaml` / `ingestion-cronjob.yaml` hostPath mounts, which the README calls out.

### 0.2 Qdrant is sized for the 50-PDF set, not the 100-PDF set

- **Current state.** [`k8s/vector-db/qdrant.yaml`](k8s/vector-db/qdrant.yaml) lines 11-14 and 59-65 set a 10 GiB PVC, `requests.memory: 1Gi`, `limits.memory: 2Gi`.
- **Why it matters.** With `sentence-transformers/all-MiniLM-L6-v2` (384 dim × float32) and ~800-char chunks with 100-char overlap, ~50 k pages produce on the order of 150-200 k chunks. Raw vectors alone are ~300 MB; HNSW graph + payload typically 3-4× that. A 2 GiB limit is right on the edge of OOM for the 100-PDF run and will distort the "active RAM footprint" metric because Linux will page out instead of showing true working set.
- **Proposed change (k8s YAML + matching Helm values):**
  ```yaml
  # k8s/vector-db/qdrant.yaml
  spec:
    resources:
      requests: { storage: 25Gi }   # PVC
  # ...
  resources:
    requests: { cpu: "1",   memory: "4Gi" }
    limits:   { cpu: "2",   memory: "8Gi" }
  ```
  Same keys in [`helm/rag-k8s-thesis/values.yaml`](helm/rag-k8s-thesis/values.yaml) `qdrant:` block (`storageSize: 25Gi`, `resources.limits.memory: 8Gi`). Document the final value in `RESULTS.md` § 2 so the RAM-footprint number is reproducible.

---

## 1. Inference Performance — TTFT, max RPS, Cold Start

### 1.1 Cold-start does not separate image-pull time from boot time

- **Current state.** [`scripts/benchmark/benchmark_coldstart.sh`](scripts/benchmark/benchmark_coldstart.sh) captures `scale_up_s`, `pod_ready_s`, `health_200_s`, `query_200_s`, `total_s` (CSV header line 62). There is no column for container image pull vs container boot — pod-ready already folds both together.
- **Why it matters.** Your scope explicitly names "Cold Start Latency (container image pull and boot times)" as a measured sub-metric. Image pull dominates for a fresh node (often 60-120 s for the `ollama/ollama` image + model weights if `postStart` pulls them), and boot time dominates after the image is cached. A single `pod_ready` number hides the trade-off between the two architectures (Cloud Run's GCS-Fuse model cache in [`scripts/deploy/deploy_gcp_cloudrun.sh`](scripts/deploy/deploy_gcp_cloudrun.sh) lines 157-197 vs. GKE's PVC in [`k8s/llm-inference/ollama-gpu.yaml`](k8s/llm-inference/ollama-gpu.yaml)).
- **Proposed change.** Parse Kubernetes events between the scale-up and the ready condition and derive two new CSV columns (`image_pull_s`, `boot_s`). For Cloud Run, pull `run.googleapis.com/container/startup_latencies` — already referenced in [`k8s/observability/README.md`](k8s/observability/README.md) § 4 but not yet wired into the CSV.
  ```bash
  # GKE path, after the pod is ready, before writing the CSV row
  POD="$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=ollama -o jsonpath='{.items[0].metadata.name}')"
  PULL_START="$(kubectl get events -n "${NAMESPACE}" \
      --field-selector "involvedObject.name=${POD},reason=Pulling" \
      -o jsonpath='{.items[0].firstTimestamp}')"
  PULL_END="$(kubectl get events -n "${NAMESPACE}" \
      --field-selector "involvedObject.name=${POD},reason=Pulled" \
      -o jsonpath='{.items[0].firstTimestamp}')"
  image_pull_s=$(python3 -c "import sys,datetime as d; a,b=sys.argv[1:]; \
      print(round((d.datetime.fromisoformat(b.replace('Z','+00:00')) - \
                   d.datetime.fromisoformat(a.replace('Z','+00:00'))).total_seconds(),3))" \
      "${PULL_START}" "${PULL_END}")
  boot_s=$(awk -v p="${pod_ready_s}" -v i="${image_pull_s}" 'BEGIN{printf "%.3f", p-i}')
  ```
  ```bash
  # Cloud Run path (last successful startup)
  gcloud monitoring time-series list \
    --filter='metric.type="run.googleapis.com/container/startup_latencies" AND resource.labels.service_name="ollama-gpu"' \
    --interval-end-time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --interval-start-time="$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" \
    --format='value(points[0].value.distributionValue.mean)'
  ```
  Update the CSV header to `...,pod_ready_s,image_pull_s,boot_s,health_200_s,query_200_s,...`.

### 1.2 GKE vs Cloud Run RPS comparison is unfair at the web-server layer

- **Current state.**
  - Cloud Run pins backend concurrency to 8: [`scripts/deploy/deploy_gcp_cloudrun.sh`](scripts/deploy/deploy_gcp_cloudrun.sh) line 57 `BACKEND_CONCURRENCY="${BACKEND_CONCURRENCY:-8}"` and line 225.
  - On GKE, [`backend/Dockerfile`](backend/Dockerfile) launches a single uvicorn worker (no `--workers`, no `WEB_CONCURRENCY`), and the `/query` handler in [`backend/app/main.py`](backend/app/main.py) is a synchronous `def` that calls a blocking `requests.post(...)` inside [`backend/app/rag_pipeline.py`](backend/app/rag_pipeline.py) lines 60-66 and 84-91.
- **Why it matters.** FastAPI runs sync endpoints in a threadpool, but only one uvicorn worker means per-process Python concurrency is limited to the threadpool size (default 40) and single-core CPU. Against Cloud Run's 8-concurrency-per-instance × up-to-10-instances setup, the GKE backend will look artificially slow for RPS and p95 at high VU counts — even though the actual LLM/Qdrant bottleneck is identical. That contaminates the "max RPS" and "how the system queues" numbers.
- **Proposed change — pick one of three, document the choice in `RESULTS.md`:**
  1. Simplest: set `WEB_CONCURRENCY=8` via env and run uvicorn with gunicorn or `uvicorn --workers`:
     ```dockerfile
     # backend/Dockerfile
     ENV WEB_CONCURRENCY=8
     CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "8"]
     ```
     Also bump the Deployment CPU limit to match 8 workers (e.g. `limits.cpu: "2"` in [`k8s/backend/backend.yaml`](k8s/backend/backend.yaml) line 85).
  2. Cleaner: make the pipeline async (`httpx.AsyncClient`) and convert `query_rag` / `retrieve_only` to `async def`. Uvicorn's event loop will then handle 100+ in-flight requests on a single worker.
  3. Minimum diff: keep sync, but wrap blocking calls in `asyncio.to_thread` the way `warmup_llm` already does in [`backend/app/main.py`](backend/app/main.py) lines 15-17. This alone won't raise real concurrency much because `requests` still blocks a threadpool slot; option 1 or 2 is preferred.

### 1.3 Matrix hits GKE via `kubectl port-forward`, Cloud Run via public URL

- **Current state.** [`scripts/benchmark/run_experiment_matrix.sh`](scripts/benchmark/run_experiment_matrix.sh) lines 41-48 fall back to `kubectl port-forward -n rag-thesis svc/rag-backend 8000:80` when `BACKEND_URL` is empty. The Cloud Run path uses the real service URL (lines 58-62 and the `BACKEND_URL` override used in `RESULTS.md` runbook).
- **Why it matters.** `kubectl port-forward` bypasses the GKE Ingress / L7 load balancer entirely, so GKE numbers exclude the LB hop that Cloud Run numbers include. Ingress adds 5-30 ms p95 at high RPS on GCLB — small for huge models, non-trivial for `phi3:mini`.
- **Proposed change.** Expose the backend through the existing Ingress ([`k8s/backend/backend.yaml`](k8s/backend/backend.yaml) lines 100-119) or a LoadBalancer Service, and run the matrix against that URL:
  ```bash
  # once, after the ingress has a public IP
  BACKEND_URL="http://$(kubectl get ingress rag-backend -n rag-thesis -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  ARCH=gke BACKEND_URL="${BACKEND_URL}" ./scripts/benchmark/run_experiment_matrix.sh
  ```
  Document this in `RESULTS.md` § "Environment" so reviewers can see that both columns include the LB hop.

---

## 2. Cost Efficiency & Resource Utilization

### 2.1 GPU saturation during the 100-VU run is captured only as Grafana screenshots

- **Current state.** [`BENCHMARK_MATRIX.md`](BENCHMARK_MATRIX.md) and [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) § 3.3 both say "Attach Grafana screenshots". The DCGM exporter is installed ([`k8s/observability/dcgm-exporter.yaml`](k8s/observability/dcgm-exporter.yaml)) so the metric exists; it just is not pulled into the CSV schema.
- **Why it matters.** A defensible thesis number for "CPU/GPU saturation under high concurrent load" has to be a percentile over the k6 run window, not a screenshot. A reviewer will ask for the raw data.
- **Proposed change — small bash side-car next to each k6 invocation:**
  ```bash
  # Run in parallel with k6; stop when k6 exits.
  PROM_URL="http://127.0.0.1:9090"   # port-forward kps-prometheus
  kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID' EXIT

  START=$(date +%s)
  k6 run ... &
  K6_PID=$!
  while kill -0 "${K6_PID}" 2>/dev/null; do sleep 5; done
  END=$(date +%s)

  curl -sG "${PROM_URL}/api/v1/query_range" \
    --data-urlencode "query=max(DCGM_FI_DEV_GPU_UTIL) by (gpu)" \
    --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
    --data-urlencode "step=5s" \
    | jq -r '.data.result[0].values[] | @csv' > "${OUT_DIR}/gpu_util_${MODEL_SAFE}.csv"
  ```
  Cloud Run equivalent (same two-column CSV schema):
  ```bash
  gcloud monitoring time-series list \
    --project="${PROJECT_ID}" \
    --filter='metric.type="run.googleapis.com/container/gpu/utilizations" AND resource.labels.service_name="ollama-gpu"' \
    --interval-start-time="${ISO_START}" --interval-end-time="${ISO_END}" \
    --format=json | jq -r '.[0].points[] | [.interval.startTime, .value.doubleValue] | @csv' \
    > "${OUT_DIR}/gpu_util_${MODEL_SAFE}.csv"
  ```
  Then `RESULTS.md` § 3.3 can carry real p50/p95/peak GPU-util columns.

### 2.2 No metric captures "how the system queues" when 100 users hit at once

- **Current state.** Ollama serializes generation (default `OLLAMA_NUM_PARALLEL=1`, explicitly set in [`scripts/deploy/deploy_gcp_cloudrun.sh`](scripts/deploy/deploy_gcp_cloudrun.sh) line 197 and implicitly in [`k8s/llm-inference/ollama-gpu.yaml`](k8s/llm-inference/ollama-gpu.yaml)). Cloud Run pins Ollama to `--concurrency=1`. So with 100 concurrent users, ~99 are queued somewhere — but nothing measures the queue depth or wait time.
- **Why it matters.** Your scope explicitly calls out "evaluating how the system queues or scales when 100 users request an answer at the exact same time". Today the matrix only shows end-to-end p95 latency; you cannot tell whether time was spent in the LB queue, the uvicorn threadpool, or the Ollama serializer. That makes the GKE vs Cloud Run scaling story weaker in the thesis.
- **Proposed change — add a single in-flight gauge to the backend and export it at `/metrics`:**
  1. Add `prometheus-fastapi-instrumentator==6.*` to [`backend/requirements.txt`](backend/requirements.txt).
  2. In [`backend/app/main.py`](backend/app/main.py):
     ```python
     from prometheus_client import Gauge
     from prometheus_fastapi_instrumentator import Instrumentator

     IN_FLIGHT = Gauge("rag_inflight_requests", "Requests currently executing the RAG pipeline", ["endpoint"])

     @app.middleware("http")
     async def track_inflight(request, call_next):
         label = request.url.path
         IN_FLIGHT.labels(endpoint=label).inc()
         try:
             return await call_next(request)
         finally:
             IN_FLIGHT.labels(endpoint=label).dec()

     Instrumentator().instrument(app).expose(app, endpoint="/metrics")
     ```
  3. Add a PodMonitor or the standard `prometheus.io/scrape` annotations to the backend Deployment so kube-prometheus-stack already picks it up.
  4. Record `max(rag_inflight_requests)` alongside the k6 run (same PromQL side-car as 2.1).
     Together with the existing `http_req_duration` from k6, this lets you plot "time waiting in queue" vs "time executing" and that is exactly the story the thesis asks for.

---

## 3. Vector Database Performance

### 3.1 Ingestion / indexing time — already measured, just wire it into RESULTS

- **Current state.** [`ingestion/ingest_data.py`](ingestion/ingest_data.py) `write_metrics_row` (lines 155-165, 250-267) appends `embed_and_upsert_seconds`, `alias_swap_seconds`, `total_seconds`, and collection metadata to `INGESTION_METRICS_CSV`.
- **Status.** Satisfied. No code change needed.
- **Follow-up.** Set `INGESTION_METRICS_CSV=/data/metrics/ingestion.csv` (mounted to a PVC) in the Helm `ingestion.env.metricsCsv` value (currently `""` in [`helm/rag-k8s-thesis/values.yaml`](helm/rag-k8s-thesis/values.yaml) line 148) so the numbers persist across Jobs. Then copy the CSV row directly into `RESULTS.md` § 1.

### 3.2 Retrieval-only latency — already isolated

- **Current state.** [`backend/app/main.py`](backend/app/main.py) `POST /retrieve` (lines 42-55) and [`backend/app/rag_pipeline.py`](backend/app/rag_pipeline.py) `retrieve_only` return `timing_ms.embedding`, `timing_ms.qdrant_search`, `timing_ms.total_retrieval`. `scripts/benchmark/benchmark_retrieval.py` consumes it, and `run_experiment_matrix.sh` step [1/5] drives it.
- **Status.** Satisfied. No code change needed.

### 3.3 Active RAM footprint — tied to item 0.2 (Qdrant limits)

- **Current state.** `benchmark_retrieval.py` accepts `--sample-qdrant-rss` (see [`scripts/benchmark/run_experiment_matrix.sh`](scripts/benchmark/run_experiment_matrix.sh) line 71). But the Qdrant pod's `limits.memory: 2Gi` will artificially cap and distort the measured RSS for the 100-PDF corpus.
- **Why it matters.** The thesis names "active RAM footprint of the Vector DB (Qdrant) when hosting massive ~50,000-page dataset" as a specific metric. If Qdrant is OOM-killed or swapping, the number is meaningless.
- **Proposed change.** Fix 0.2 first, then sample RSS via `--sample-qdrant-rss` during the retrieval-latency pass. The headline RAM number goes into `RESULTS.md` § 2.

---

## 4. System Resilience (Fallbacks)

### 4.1 LLM and Qdrant failure paths — already implemented

- **Current state.** [`backend/app/rag_pipeline.py`](backend/app/rag_pipeline.py):
  - Lines 113-171: `_complete_llm_with_fallback` implements primary retry loop + one-shot fallback model + `LLM_UNAVAILABLE_MARKER` so the API still returns retrieved sources even if all LLM calls fail.
  - Lines 173-207: `_retrieve_raw` retries Qdrant once, then raises `QdrantUnavailableError`, which [`backend/app/main.py`](backend/app/main.py) line 37 converts to HTTP 503 (clean "dependency unavailable" signal, not a stack trace).
- **Status.** Satisfied from the code side.

### 4.2 Resilience scenarios in RESULTS.md are still placeholders

- **Current state.** [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) § 5 lists four scenarios with `TBD` downtime. Nothing in `scripts/` automates them.
- **Why it matters.** The thesis will be evaluated on whether the claims about resilience are reproducible. Manual `kubectl scale` during writing is fine, but leaving no script means next time you re-run the matrix the numbers have to be regenerated by hand.
- **Proposed change — a small, explicit script, e.g. `scripts/resilience/measure_resilience.sh`:**
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
  OUT="${OUT:-benchmarks/resilience_$(date +%Y%m%d_%H%M%S).csv}"
  mkdir -p "$(dirname "${OUT}")"
  echo "scenario,http_code,fallback,model_used,attempts,notes" > "${OUT}"

  probe() {
    local label="$1"
    local body
    body="$(curl -s -o /tmp/rag.json -w "%{http_code}" \
      -X POST "${BASE_URL}/query" -H "Content-Type: application/json" \
      -d '{"query":"What is SEC filing?"}' || echo 000)"
    local code="${body}"
    local fb model att
    fb="$(jq -r '.llm.fallback // false' /tmp/rag.json 2>/dev/null || echo n/a)"
    model="$(jq -r '.llm.model_used // "n/a"' /tmp/rag.json 2>/dev/null || echo n/a)"
    att="$(jq -r '.llm.attempts // "n/a"' /tmp/rag.json 2>/dev/null || echo n/a)"
    echo "${label},${code},${fb},${model},${att}," >> "${OUT}"
  }

  # A) baseline
  probe baseline
  # B) bogus primary model -> fallback must answer
  kubectl set env -n rag-thesis deployment/rag-backend LLM_MODEL=bogus:tag
  kubectl rollout status -n rag-thesis deployment/rag-backend --timeout=300s
  probe primary_bad
  kubectl set env -n rag-thesis deployment/rag-backend LLM_MODEL=granite3.3:8b
  kubectl rollout status -n rag-thesis deployment/rag-backend --timeout=300s
  # C) Ollama scaled to 0 -> LLM_UNAVAILABLE_MARKER, still sources
  kubectl scale -n rag-thesis deploy/ollama --replicas=0
  sleep 10; probe ollama_down
  kubectl scale -n rag-thesis deploy/ollama --replicas=1
  kubectl rollout status -n rag-thesis deploy/ollama --timeout=600s
  # D) Qdrant scaled to 0 -> HTTP 503
  kubectl scale -n rag-thesis statefulset/qdrant --replicas=0
  sleep 10; probe qdrant_down
  kubectl scale -n rag-thesis statefulset/qdrant --replicas=1
  kubectl rollout status -n rag-thesis statefulset/qdrant --timeout=600s

  echo "Done -> ${OUT}"
  ```
  The resulting CSV drops into `RESULTS.md` § 5 and can be regenerated on demand.

---

## 5. Update Strategy (Zero-Downtime / Blue-Green Vector Indexing)

### 5.1 Blue/green alias swap — already implemented

- **Current state.** [`ingestion/ingest_data.py`](ingestion/ingest_data.py):
  - Lines 126-134: `resolve_target_collection` writes to a dated physical collection `thesis_docs_YYYYMMDD_HHMMSS` unless `INGEST_INPLACE=true`.
  - Lines 137-152: `swap_alias` atomically repoints `thesis_docs_active` via `update_collection_aliases`.
  - The backend reads from the alias by default (`QDRANT_COLLECTION=thesis_docs_active` in [`backend/app/config.py`](backend/app/config.py) line 14).
- **Status.** Satisfied from the code side.

### 5.2 No automated under-load test for the alias swap

- **Current state.** [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) § 1 has a zero-downtime verification block as comments only; `non-2xx count` and `alias swap p95` are `TBD`.
- **Why it matters.** "Evaluating Zero-Downtime updates" is one of the six thesis metrics. A single scripted run that fires traffic while the alias swaps is the difference between a claim and evidence.
- **Proposed change — `scripts/resilience/measure_bluegreen_downtime.sh`:**
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
  NAMESPACE="${NAMESPACE:-rag-thesis}"
  CRONJOB="${CRONJOB:-rag-ingestion-nightly}"
  OUT="${OUT:-benchmarks/bluegreen_$(date +%Y%m%d_%H%M%S).csv}"
  mkdir -p "$(dirname "${OUT}")"

  # 1000 requests, 10 concurrent, 60s: plenty to overlap the alias swap.
  ab -n 1000 -c 10 -T 'application/json' \
     -p <(echo '{"query":"What is SEC filing?"}') \
     "${BASE_URL}/query" > /tmp/ab.log &
  AB_PID=$!
  sleep 5  # let the load start
  TS="$(date +%Y%m%d-%H%M%S)"
  kubectl -n "${NAMESPACE}" create job "ingest-${TS}" --from="cronjob/${CRONJOB}"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/ingest-${TS}" --timeout=1800s
  wait "${AB_PID}"

  non2xx=$(awk '/Non-2xx responses:/ {print $3}' /tmp/ab.log || echo 0)
  p95=$(awk '/95%/ {print $2}' /tmp/ab.log || echo 0)
  echo "ts,non_2xx,p95_ms,total_requests" > "${OUT}"
  echo "${TS},${non2xx:-0},${p95:-0},1000" >> "${OUT}"
  ```
  The thesis claim is then "alias swap produced N non-2xx responses out of 1000 while swapping collection X → Y," which is a falsifiable sentence.

---

## 6. Operational Complexity

### 6.1 LoC metric — already instrumented

- **Current state.** [`scripts/reports/loc_report.sh`](scripts/reports/loc_report.sh) exists and is referenced from [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) § 6.
- **Status.** Satisfied.

### 6.2 CI build-duration metric — already instrumented

- **Current state.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) lints Python, Helm, and shell. Duration is pulled via `gh run list -L 20 --workflow=CI --json durationMs` as documented in [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) § 6.
- **Status.** Satisfied. Worth running the matrix command once and committing `benchmarks/cicd_runs_<date>.json` so the thesis cites concrete numbers.

### 6.3 Bug: Deployment `replicas` competes with the HPA

- **Current state.** [`k8s/backend/backend.yaml`](k8s/backend/backend.yaml) line 26 pins `replicas: 1`, but [`k8s/backend/backend-hpa.yaml`](k8s/backend/backend-hpa.yaml) lines 14-15 set `minReplicas: 2, maxReplicas: 12`. Same pattern in the Helm chart: [`helm/rag-k8s-thesis/templates/backend.yaml`](helm/rag-k8s-thesis/templates/backend.yaml) line 27 uses `.Values.backend.replicaCount` (`2` in values.yaml).
- **Why it matters.**
  - Under ArgoCD with `selfHeal: true`, every HPA tick that pushes replicas above 1 will show as a drift against the `replicas: 1` in Git, and ArgoCD will fight the HPA. That either adds flap-noise to the "operational safety" evaluation or, worse, forces pods to restart mid-benchmark.
  - It also skews the "Raw Kubernetes YAML LoC" number because a broken manifest is not a fair baseline to compare Helm against.
- **Proposed change.** Drop `spec.replicas` from both Deployments when an HPA owns them:
  ```yaml
  # k8s/backend/backend.yaml
  kind: Deployment
  spec:
    # replicas: <removed — managed by rag-backend HPA>
    selector:
      matchLabels:
        app.kubernetes.io/name: rag-backend
  ```
  ```yaml
  # helm/rag-k8s-thesis/templates/backend.yaml
  spec:
    {{- if not .Values.backend.autoscaling.enabled }}
    replicas: {{ .Values.backend.replicaCount }}
    {{- end }}
  ```
  The same pattern should be applied to the Ollama Deployment ([`k8s/llm-inference/ollama-gpu.yaml`](k8s/llm-inference/ollama-gpu.yaml) vs [`k8s/llm-inference/ollama-gpu-hpa.yaml`](k8s/llm-inference/ollama-gpu-hpa.yaml)) for consistency.

---

## Summary checklist — the must-haves to close before the thesis matrix run

| # | Area | Change | File(s) |
|---|---|---|---|
| 0.1 | Scope | Point defaults at `sec_rag_dataset_100_pdf` | `ingestion/ingest_data.py`, `helm/rag-k8s-thesis/values.yaml`, `k8s/ingestion/*`, `README.md` |
| 0.2 | Scope | Raise Qdrant PVC to 25 GiB, memory limit to 8 GiB | `k8s/vector-db/qdrant.yaml`, `helm/rag-k8s-thesis/values.yaml` |
| 1.1 | Inference Perf | Split cold-start into `image_pull_s` + `boot_s` | `scripts/benchmark/benchmark_coldstart.sh` |
| 1.2 | Inference Perf | Match GKE backend concurrency to Cloud Run (workers/async) | `backend/Dockerfile`, `backend/app/main.py`, `backend/app/rag_pipeline.py` |
| 1.3 | Inference Perf | Route GKE matrix through Ingress, not `port-forward` | `scripts/benchmark/run_experiment_matrix.sh`, `k8s/backend/backend.yaml` |
| 2.1 | Cost / Util | Pull GPU-util time-series into CSV during k6 | `scripts/benchmark/run_experiment_matrix.sh` |
| 2.2 | Cost / Util | Expose `rag_inflight_requests` at `/metrics` | `backend/app/main.py`, `backend/requirements.txt` |
| 3.3 | Vector DB | Depends on 0.2; then sample RSS via existing flag | `scripts/benchmark/benchmark_retrieval.py` (no change) |
| 4.2 | Resilience | `scripts/resilience/measure_resilience.sh` automation | new script |
| 5.2 | Update | `scripts/resilience/measure_bluegreen_downtime.sh` automation | new script |
| 6.3 | Ops Complexity | Let the HPA own replicas | `k8s/backend/backend.yaml`, `k8s/llm-inference/ollama-gpu.yaml`, `helm/rag-k8s-thesis/templates/*.yaml` |

Items flagged as **already satisfied**: 3.1, 3.2, 4.1, 5.1, 6.1, 6.2.

---

## Out of scope for this review (nice-to-haves, not blockers)

These were identified but deliberately left out per the "must-haves only"
decision. Listed here so you can enable them explicitly in a later pass if
time permits.

- **Prometheus `/metrics` with per-model histograms** (beyond the single
  in-flight gauge in 2.2) for backend-side p50/p95 labelled by `LLM_MODEL`.
- **Qdrant `on_disk: true` + int8 scalar quantization** comparison
  experiment — directly lowers the RAM-footprint number and gives a clean
  thesis figure. Exposed via `VectorParams.on_disk=True` and
  `quantization_config=ScalarQuantization(...)` in
  `ingestion/ingest_data.py`.
- **Custom HPA on `rag_inflight_requests`** via prometheus-adapter,
  instead of CPU — CPU is near-zero while the backend is waiting on
  Ollama, so the current HPA under-reacts to load.
- **HA Qdrant** (replicas ≥ 3, `replication_factor=2`) so scenario "Vector
  DB offline" is absorbed rather than surfaced as HTTP 503.
- **vLLM-vs-Ollama benchmark** — the code path is already in
  `rag_pipeline.py` (`llm_provider="vllm"`), but the matrix only exercises
  Ollama.
- **Auth parity** — Cloud Run rag-backend is `--allow-unauthenticated`;
  GKE Ingress has no auth either. Fine for a thesis, worth documenting.
- **Minikube `metrics-server` reminder** in the README, so local HPA tests
  do not silently fall back to zero metrics.
