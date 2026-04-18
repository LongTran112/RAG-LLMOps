# RAG Model Benchmark Matrix

## 1) Prerequisites

- Minikube is running and healthy.
- `rag-thesis` namespace is deployed.
- `qdrant`, `ollama`, and `rag-backend` are `1/1 Running`.
- SEC ingestion has completed (collection `thesis_docs` is populated).

Health checks:

```bash
kubectl get pods -n rag-thesis
kubectl exec -n rag-thesis deployment/rag-backend -- \
python -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://qdrant:6333/collections/thesis_docs')); print('points_count=', d['result']['points_count'])"
```

## 2) Fast model switching

Use this shell helper in terminal:

```bash
switch_model () {
  MODEL="$1"
  kubectl exec -n rag-thesis deployment/ollama -- ollama pull "$MODEL"
  kubectl set env deployment/rag-backend -n rag-thesis \
    LLM_PROVIDER="ollama" \
    LLM_BASE_URL="http://ollama:11434" \
    LLM_MODEL="$MODEL" \
    REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-1800}"
  kubectl rollout status deployment/rag-backend -n rag-thesis --timeout=1200s
  echo "Switched to model: $MODEL"
}
```

Examples:

```bash
switch_model phi3:mini
switch_model granite3.3:8b
```

## 3) Benchmark matrix (thesis models — 7B / 14B / 32B sweep)

Use the same query set and same cluster resources for all rows. The thesis
explicitly stress-tests the **infrastructure** across increasing parameter
sizes, not answer quality, so we lock in one model per size class and sweep.

| Model | Params | Quantization | VRAM needed | Recommended GPU | Concurrency set | Repetitions per prompt | Notes |
|---|---|---|---|---|---|---|---|
| `phi3:mini` | 3.8B | Q4 (default Ollama) | ~3 GB | nvidia-l4 (24 GB) | `1, 10, 50, 100` | 3 | Smoke/baseline |
| `qwen2.5:7b` | 7B | Q4_K_M | ~5 GB | nvidia-l4 (24 GB) | `1, 10, 50, 100` | 3 | Main 7B row |
| `qwen2.5:14b` | 14B | Q4_K_M | ~10 GB | nvidia-l4 (24 GB) | `1, 10, 50, 100` | 3 | Main 14B row — fits on L4 |
| `qwen2.5:32b` | 32B | Q4_K_M | ~20 GB | nvidia-l4 (tight); fallback nvidia-a100-40gb | `1, 10, 25, 50` | 3 | 32B Q4 is tight on 24 GB VRAM. If Ollama fails to load, redeploy GKE with `GPU_MACHINE_TYPE=a2-highgpu-1g` and rerun only the 32B row. Record which GPU SKU was actually used in the results CSV. |

Before each row, update Helm values to give Ollama enough headroom:

```bash
# example for the 14B row on GKE
helm upgrade --install rag-k8s-thesis ./helm/rag-k8s-thesis \
  --set ollama.modelName=qwen2.5:14b \
  --set ollama.contextLength=4096 \
  --set ollama.resources.limits.memory=20Gi \
  --set ollama.resources.requests.memory=12Gi
```

For Cloud Run the equivalent is:

```bash
gcloud run services update ollama-gpu \
  --region europe-west3 \
  --memory 32Gi --cpu 8 \
  --gpu 1 --gpu-type nvidia-l4
```

If the 32B model cannot fit L4 VRAM, document the fallback and rerun only
the 32B row on an A100 node pool (the existing `scripts/deploy_gcp_gpu.sh`
already exposes `GPU_MACHINE_TYPE` so this is a one-variable change).

## 4) Prompt set (fixed across all models)

Use these prompts for each row in the matrix:

1. `What is SEC filing?`
2. `Summarize key risk factors discussed in these SEC filings.`
3. `What recurring business risks are mentioned across multiple filings?`
4. `List important compliance or regulatory themes in the dataset.`
5. `Give a concise 5-bullet summary of major concerns from the filings.`

## 5) Single-request latency command

Run one prompt and print total time:

```bash
curl -s -o /tmp/rag_resp.json -w "http_code=%{http_code} total_time_s=%{time_total}\n" \
  -X POST http://127.0.0.1:8000/query \
  -H "Content-Type: application/json" \
  -d '{"query":"Summarize key risk factors discussed in these SEC filings."}'
```

## 6) Repeated-run benchmark loop (per model)

Port-forward backend first:

```bash
kubectl port-forward -n rag-thesis svc/rag-backend 8000:80
```

Then run:

```bash
for i in {1..5}; do
  curl -s -o /tmp/rag_resp_$i.json -w "run=$i http_code=%{http_code} total_time_s=%{time_total}\n" \
    -X POST http://127.0.0.1:8000/query \
    -H "Content-Type: application/json" \
    -d '{"query":"Summarize key risk factors discussed in these SEC filings."}'
done
```

## 7) Throughput/concurrency test with `hey`

Install `hey` (once), then run:

```bash
hey -n 30 -c 3 -m POST -H "Content-Type: application/json" \
  -d '{"query":"What recurring business risks are mentioned across multiple filings?"}' \
  http://127.0.0.1:8000/query
```

Change `-c` to match the matrix row.

## 8) Result capture template

Record one row per run:

| Date | Model | Concurrency | Prompt ID | Mean latency (s) | P95 latency (s) | Error rate | Notes |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD | `phi3:mini` | 3 | P2 |  |  |  |  |

## 9) Practical advice for fair comparisons

- Do a warm-up query after each model switch before timing.
- Keep ingestion and background heavy jobs stopped during benchmarking.
- Keep model-specific context and temperature unchanged across runs.
- If a model is too slow (for example `granite3.3:8b` on CPU), reduce concurrency to avoid queueing artifacts.
- Large models on CPU can take **10–20+ minutes** for the first response after a cold start; set `REQUEST_TIMEOUT_SECONDS` high (for example `1800`) and use a matching `curl --max-time`.
- If Ollama logs show the model barely fails to load, either give the `ollama` pod more memory or lower `OLLAMA_CONTEXT_LENGTH` (repo default is `2048` in `k8s/llm-inference/ollama.yaml`).

## 10) Automated script (CSV output)

Use the included script:

```bash
chmod +x scripts/benchmark.sh
./scripts/benchmark.sh
```

Useful overrides:

```bash
MODELS_CSV="phi3:mini,qwen2.5:3b" REPETITIONS=2 PROMPT_IDS_CSV="P1,P2" ./scripts/benchmark.sh
REQUEST_TIMEOUT_SECONDS=1800 CURL_MAX_TIME=1800 MODELS_CSV="granite3.3:8b" PROMPT_IDS_CSV="P1" ./scripts/benchmark.sh
```

The script defaults to **benchmark mode** (disables product latency caps) via:

- `BENCHMARK_PRODUCT_LATENCY_MODE=false`
- `BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS=0` (no `num_predict` cap)
- `BENCHMARK_QDRANT_TOP_K=4`

To measure the interactive/product configuration instead, run with `BENCHMARK_PRODUCT_LATENCY_MODE=true` and set `BENCHMARK_OLLAMA_MAX_OUTPUT_TOKENS=256`.

Outputs are written to:

- `benchmarks/results_<timestamp>.csv`
- `benchmarks/run_<timestamp>.log`

## 11) One-command profile comparison

Run fast-vs-quality comparison for the same model:

```bash
MODELS_CSV="phi3:mini" PROMPT_IDS_CSV="P1,P2,P3" REPETITIONS=2 ./scripts/benchmark_profiles.sh
```

Use vLLM endpoint instead of Ollama:

```bash
LLM_PROVIDER="vllm" LLM_BASE_URL="http://vllm:8000" MODELS_CSV="microsoft/Phi-3-mini-4k-instruct" ./scripts/benchmark_profiles.sh
```
