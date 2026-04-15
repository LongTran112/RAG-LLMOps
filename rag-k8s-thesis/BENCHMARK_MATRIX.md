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
  kubectl set env deployment/rag-backend -n rag-thesis OLLAMA_MODEL="$MODEL"
  kubectl rollout status deployment/rag-backend -n rag-thesis --timeout=600s
  echo "Switched to model: $MODEL"
}
```

Examples:

```bash
switch_model phi3:mini
switch_model granite3.3:8b
```

## 3) Benchmark matrix (recommended)

Use the same query set and same cluster resources for all rows.

| Model | Expected quality | Expected latency (CPU) | Concurrency set | Repetitions per prompt | Notes |
|---|---|---|---|---|---|
| `phi3:mini` | Baseline | Fastest | `1, 3, 5` | 5 | Good for sanity checks |
| `qwen2.5:3b` | Medium | Medium | `1, 3, 5` | 5 | Good speed/quality balance |
| `granite3.3:8b` | Higher | Slowest | `1, 2, 3` | 3 | Needs more memory/CPU |

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

## 10) Automated script (CSV output)

Use the included script:

```bash
chmod +x scripts/benchmark.sh
./scripts/benchmark.sh
```

Useful overrides:

```bash
MODELS_CSV="phi3:mini,qwen2.5:3b" REPETITIONS=2 PROMPT_IDS_CSV="P1,P2" ./scripts/benchmark.sh
```

Outputs are written to:

- `benchmarks/results_<timestamp>.csv`
- `benchmarks/run_<timestamp>.log`
