# Observability (GKE)

Deploys:

1. `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, node-exporter,
   kube-state-metrics) — cluster-wide CPU / memory / pod metrics.
2. NVIDIA DCGM exporter DaemonSet on the GPU node pool — GPU utilization, VRAM
   used, SM occupancy, temperature, power.
3. Grafana dashboards tuned for the thesis figures.

Cloud Run's observability relies on Cloud Monitoring instead (see
[cloud_run_dashboard.json](cloud_run_dashboard.json)).

## 1. Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f k8s/observability/kube-prometheus-stack-values.yaml
```

Port-forward Grafana:

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# default creds: admin / prom-operator  (override in values file)
```

## 2. Install the NVIDIA DCGM exporter

Tolerates the GPU node taint and reports nvidia_smi_* metrics that Prometheus
scrapes via a ServiceMonitor (included in kube-prometheus-stack).

```bash
kubectl apply -f k8s/observability/dcgm-exporter.yaml
```

Smoke test the metrics target in Prometheus:

```promql
# Should show the g2-standard-8 node's L4
DCGM_FI_DEV_GPU_UTIL
DCGM_FI_DEV_FB_USED   # VRAM in bytes
```

## 3. Import Grafana dashboards

Two dashboards are included:

- [grafana_dashboard_rag.json](grafana_dashboard_rag.json): backend RPS/p95,
  Qdrant memory, Ollama GPU %, HPA replicas.
- Import manually in Grafana: **Dashboards → New → Import → Upload JSON**.

For the cost side, the `cost_per_1k_requests.sql` lives in `scripts/`.

## 4. Cloud Run side

For the serverless architecture, use Cloud Monitoring. The equivalent
dashboard lives at [cloud_run_dashboard.json](cloud_run_dashboard.json) and
can be imported via:

```bash
gcloud monitoring dashboards create \
  --config-from-file=k8s/observability/cloud_run_dashboard.json
```

Key Cloud Monitoring metrics used in the thesis:

- `run.googleapis.com/request_latencies`
- `run.googleapis.com/request_count`
- `run.googleapis.com/container/cpu/utilizations`
- `run.googleapis.com/container/instance_count`
- `run.googleapis.com/container/startup_latencies` (cold-start breakdown)
