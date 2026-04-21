# `scripts/` — thesis automation

Every script is organized by *what it does to the cluster*, not *what it
measures*. Pick the folder that matches your step in the thesis runbook:

| Folder         | Purpose                                       | When to run |
| -------------- | --------------------------------------------- | ----------- |
| `deploy/`      | Provision GCP infrastructure (once per arch). | Before any benchmark. |
| `teardown/`    | Destroy everything `deploy/` created.         | After benchmarks, to stop the meter. |
| `ingestion/`   | Load the 100-PDF SEC corpus into Qdrant.      | Once per cluster, after `deploy/`. |
| `benchmark/`   | All performance measurements.                 | After ingestion completes. |
| `resilience/`  | Failure scenarios and update-strategy probes. | After benchmarks; orthogonal metrics. |
| `reports/`     | Post-hoc aggregation (IaC LoC, $/1k req).     | After the matrix completes. |

All scripts are safe to re-run. Output CSVs are timestamped into `benchmarks/`.

## `deploy/` — provision infrastructure

| Script | What it does |
| ------ | ------------ |
| `deploy_gcp_gpu.sh`      | GKE cluster + GPU node pool + Qdrant/Ollama/backend/frontend. Thesis "K8s architecture" target. |
| `deploy_gcp_cloudrun.sh` | Cloud Run services + Qdrant VM + VPC connector + GCS model cache. Thesis "Serverless architecture" target. |
| `install_argocd.sh`      | Installs ArgoCD into the GKE cluster and applies the Helm Application. Prereq for `resilience/measure_argocd_sync.sh`. |
| `enable_billing_export.sh` | Enables BigQuery billing export (one-off setup for `reports/cost_per_1k_requests.sql`). |

## `teardown/` — destroy infrastructure

| Script | What it does |
| ------ | ------------ |
| `teardown_gcp_gpu.sh`      | Removes everything `deploy_gcp_gpu.sh` created. |
| `teardown_gcp_cloudrun.sh` | Removes everything `deploy_gcp_cloudrun.sh` created. |

## `ingestion/` — load the corpus

| Script | What it does |
| ------ | ------------ |
| `download_pdf_dataset.py`   | Pulls ~100 SEC 10-K PDFs into `sec_rag_dataset_100_pdf/`. |
| `ingest_local_to_qdrant.sh` | Port-forwards Qdrant, runs `ingestion/ingest_data.py` against it. Use when you don't want an in-cluster ingestion Job. |

## `benchmark/` — performance measurements

The one script you usually run is `run_experiment_matrix.sh`; it invokes the
rest. The default thesis model set is:

- fast: `phi3:mini`
- fast: `granite3.3:8b`
- reasoning: `deepseek-r1:8b`

| Script | What it measures |
| ------ | ---------------- |
| `run_experiment_matrix.sh` | Orchestrator: one row per model × architecture. Calls every sibling below. |
| `benchmark_retrieval.py`   | Retrieval-only latency (`/retrieve`) + Qdrant RSS. |
| `benchmark_stream.py`      | TTFT + tokens/s (Python client; the high-fidelity version). |
| `benchmark_stream.sh`      | TTFT via `curl` (lighter, dependency-free). |
| `benchmark.sh`             | End-to-end `/query` sync latency. |
| `benchmark_profiles.sh`    | Runs `benchmark.sh` twice (FAST vs QUALITY profile). |
| `benchmark_coldstart.sh`   | Scale-from-zero latency, split into `image_pull_s` and `boot_s`. |
| `capture_gpu_util.sh`      | Pulls DCGM GPU util (GKE) or Cloud Monitoring GPU util (Cloud Run) alongside each k6 run. |

## `resilience/` — failure + update probes

| Script | What it exercises |
| ------ | ----------------- |
| `measure_resilience.sh`         | Bogus LLM model, Ollama down, Qdrant down → verifies fallback markers. |
| `measure_bluegreen_downtime.sh` | Runs traffic against `/retrieve` across a Qdrant alias swap; reports non-2xx and zero-hit windows. |
| `measure_argocd_sync.sh`        | Time-to-sync after a git commit (GitOps latency). |

## `reports/` — post-hoc aggregation

| File | What it produces |
| ---- | ---------------- |
| `loc_report.sh`           | Lines-of-infrastructure-code per bucket (raw K8s, Helm, Cloud Run bash, GKE bash). Output: `benchmarks/loc_report_*.csv`. |
| `cost_per_1k_requests.sql` | BigQuery query against the billing export. Joins with a known request count from the k6 summaries to get $ / 1 000 requests. |

## Running from anywhere

Shell scripts that need to resolve sibling files compute `SCRIPT_DIR` from
`BASH_SOURCE`, so they work whether invoked from the repo root, from inside
`scripts/`, or via an absolute path. Invocations in docs use the repo-root
form (e.g. `./scripts/benchmark/run_experiment_matrix.sh`) for consistency.
