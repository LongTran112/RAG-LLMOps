// k6 load-test script: ramp virtual users from 1 -> 100 and measure the
// RPS vs p95 latency vs error-rate curve. This is the "100 users asking
// at the exact same time" stress test in the thesis metrics list.
//
// Run (GKE, via kubectl port-forward on 127.0.0.1:8000):
//   kubectl port-forward -n rag-thesis svc/rag-backend 8000:80 &
//   k6 run \
//     -e BASE_URL=http://127.0.0.1:8000 \
//     -e MODEL_TAG=phi3:mini \
//     -e ARCH=gke \
//     --summary-export=benchmarks/k6/gke_phi3_mini_summary.json \
//     --out csv=benchmarks/k6/gke_phi3_mini_raw.csv \
//     benchmarks/k6/rps_sweep.js
//
// Run (Cloud Run; service is public, else pass -e AUTH_TOKEN=$(gcloud auth
// print-identity-token --audiences=<backend-url>)):
//   k6 run \
//     -e BASE_URL=https://rag-backend-xxx.a.run.app \
//     -e ARCH=cloudrun \
//     -e MODEL_TAG=phi3:mini \
//     --summary-export=benchmarks/k6/cr_phi3_mini_summary.json \
//     --out csv=benchmarks/k6/cr_phi3_mini_raw.csv \
//     benchmarks/k6/rps_sweep.js
//
// Why ramping VUs instead of a constant-RPS arrival rate: the thesis explicitly
// evaluates "how the system queues or scales when 100 users request an answer
// at the exact same time". Ramping VUs up to 100 is a closed-loop model that
// matches that framing (an open-loop arrival-rate profile would overwhelm
// CPU-only backends and make the RPS numbers incomparable). Swap to
// `scenarios: { ramping_arrival_rate: {...} }` if you want the open-loop view.

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://127.0.0.1:8000";
const AUTH_TOKEN = __ENV.AUTH_TOKEN || "";
const ARCH = __ENV.ARCH || "unknown";
const MODEL_TAG = __ENV.MODEL_TAG || "unknown";
const PROMPT = __ENV.PROMPT ||
  "Summarize key risk factors discussed in these SEC filings.";

// Scenario:
//   - warm-up 1 VU for 30s
//   - ramp 1 -> 25 over 60s   (find healthy baseline)
//   - ramp 25 -> 50 over 60s  (mid-load)
//   - ramp 50 -> 100 over 60s (the "100 users" stress point in the thesis)
//   - hold 100 VUs for 120s   (sustained overload / queue behaviour)
//   - cool down 100 -> 0 over 30s
// Tune VU ceiling via MAX_VUS (e.g. MAX_VUS=150) if your budget allows.
const MAX_VUS = Number(__ENV.MAX_VUS || 100);

export const options = {
  scenarios: {
    ramp_users: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "30s", target: 1 },
        { duration: "60s", target: Math.max(1, Math.round(MAX_VUS * 0.25)) },
        { duration: "60s", target: Math.max(1, Math.round(MAX_VUS * 0.5)) },
        { duration: "60s", target: MAX_VUS },
        { duration: "120s", target: MAX_VUS },
        { duration: "30s", target: 0 },
      ],
      gracefulRampDown: "30s",
      gracefulStop: "30s",
    },
  },
  // Thresholds let k6 exit non-zero if SLOs are violated (handy for CI).
  thresholds: {
    http_req_failed: ["rate<0.10"],
    http_req_duration: ["p(95)<180000"], // 180s p95 upper bound for huge models
  },
  discardResponseBodies: false,
  summaryTrendStats: ["avg", "min", "med", "p(50)", "p(90)", "p(95)", "p(99)", "max"],
};

const ttftTrend = new Trend("rag_ttft_s", true);
const queryDuration = new Trend("rag_query_duration_ms", true);
const queryOk = new Counter("rag_query_ok");
const queryErr = new Counter("rag_query_err");

function headers() {
  const h = {
    "Content-Type": "application/json",
    "X-RAG-Arch": ARCH,
    "X-RAG-Model": MODEL_TAG,
  };
  if (AUTH_TOKEN) {
    h["Authorization"] = `Bearer ${AUTH_TOKEN}`;
  }
  return h;
}

export default function () {
  const body = JSON.stringify({ query: PROMPT });
  const t0 = Date.now();
  const res = http.post(`${BASE_URL}/query`, body, {
    headers: headers(),
    timeout: "1800s",
    tags: { arch: ARCH, model: MODEL_TAG, endpoint: "/query" },
  });
  const dt = Date.now() - t0;
  queryDuration.add(dt);

  const ok = check(res, {
    "status is 200": (r) => r.status === 200,
    "has answer": (r) => r.status === 200 && r.json("answer") !== undefined,
  });
  if (ok) {
    queryOk.add(1);
  } else {
    queryErr.add(1);
  }

  // Small think time so we're not immediately firing the next call on the
  // same VU the instant the response lands.
  sleep(0.1);
}

export function handleSummary(data) {
  // Write one extra machine-readable JSON with the headline numbers.
  const out = {
    arch: ARCH,
    model: MODEL_TAG,
    base_url: BASE_URL,
    max_vus: MAX_VUS,
    duration_s: data.state && data.state.testRunDurationMs
      ? data.state.testRunDurationMs / 1000
      : null,
    rps: data.metrics.http_reqs && data.metrics.http_reqs.values
      ? data.metrics.http_reqs.values.rate
      : null,
    p95_query_ms: data.metrics.rag_query_duration_ms &&
      data.metrics.rag_query_duration_ms.values["p(95)"],
    p99_query_ms: data.metrics.rag_query_duration_ms &&
      data.metrics.rag_query_duration_ms.values["p(99)"],
    avg_query_ms: data.metrics.rag_query_duration_ms &&
      data.metrics.rag_query_duration_ms.values.avg,
    error_rate: data.metrics.http_req_failed &&
      data.metrics.http_req_failed.values.rate,
    ok_count: data.metrics.rag_query_ok &&
      data.metrics.rag_query_ok.values.count,
    err_count: data.metrics.rag_query_err &&
      data.metrics.rag_query_err.values.count,
  };
  return {
    "stdout": JSON.stringify(out, null, 2),
    // The --summary-export CLI flag overrides the default summary.json path
    // if set; this key is only used when running without that flag.
    "benchmarks/k6/last_summary.json": JSON.stringify(data, null, 2),
  };
}
