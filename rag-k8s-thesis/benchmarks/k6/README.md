# k6 load tests

Install k6 locally once:

```bash
brew install k6
# or: docker run -i --rm grafana/k6 run - <benchmarks/k6/rps_sweep.js
```

## rps_sweep.js

Ramps virtual users from 1 up to MAX_VUS (default 100) and holds the peak for
two minutes. Captures:

- overall RPS achieved (throughput knee-point)
- p50 / p95 / p99 of `POST /query` latency
- error rate
- count of OK vs errored responses

This is the primary script used for the thesis "100 concurrent users" metric.

### GKE (port-forward first)

```bash
kubectl port-forward -n rag-thesis svc/rag-backend 8000:80 >/dev/null &
PF_PID=$!

k6 run \
  -e BASE_URL=http://127.0.0.1:8000 \
  -e ARCH=gke \
  -e MODEL_TAG=phi3:mini \
  -e MAX_VUS=100 \
  --summary-export=benchmarks/k6/gke_phi3_mini_summary.json \
  --out csv=benchmarks/k6/gke_phi3_mini_raw.csv \
  benchmarks/k6/rps_sweep.js

kill "${PF_PID}"
```

### Cloud Run

If the backend is public (`--allow-unauthenticated` in the deploy script):

```bash
k6 run \
  -e BASE_URL=https://rag-backend-xxxx.a.run.app \
  -e ARCH=cloudrun \
  -e MODEL_TAG=phi3:mini \
  -e MAX_VUS=100 \
  --summary-export=benchmarks/k6/cr_phi3_mini_summary.json \
  --out csv=benchmarks/k6/cr_phi3_mini_raw.csv \
  benchmarks/k6/rps_sweep.js
```

If the backend is private, mint an identity token first:

```bash
AUTH_TOKEN="$(gcloud auth print-identity-token --audiences=https://rag-backend-xxxx.a.run.app)"
k6 run -e BASE_URL=https://rag-backend-xxxx.a.run.app -e AUTH_TOKEN=$AUTH_TOKEN ...
```

### What to record for the thesis

For each (architecture, model, MAX_VUS) triple, copy from the summary JSON:

- `rps` (requests / second achieved during the test)
- `p95_query_ms`, `p99_query_ms`
- `error_rate`
- `ok_count`, `err_count`

and attach Grafana screenshots (backend pod CPU, Ollama GPU %, Qdrant pod
memory) for the same time window.
