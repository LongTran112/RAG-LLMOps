#!/usr/bin/env python3
"""Retrieval-only benchmark against the /retrieve endpoint.

Reports embedding time, Qdrant search time, and total client-observed latency,
and -- when run against a GKE deployment via kubectl -- also samples Qdrant
pod RSS via `kubectl top pod` so we can answer:
  "What is the Qdrant RAM footprint when hosting the ~50k-page dataset?"

The endpoint returns server-side timings in ms; we additionally measure
end-to-end client latency so Helm/Cloud Run network overhead can be compared.

Example:
  ./scripts/benchmark_retrieval.py --base-url http://127.0.0.1:8000 \\
      --prompts P1,P2,P3,P4,P5 --repetitions 20 \\
      --sample-qdrant-rss --namespace rag-thesis
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import requests

DEFAULT_PROMPTS = {
    "P1": "What is SEC filing?",
    "P2": "Summarize key risk factors discussed in these SEC filings.",
    "P3": "What recurring business risks are mentioned across multiple filings?",
    "P4": "List important compliance or regulatory themes in the dataset.",
    "P5": "Give a concise 5-bullet summary of major concerns from the filings.",
}


def sample_qdrant_rss_mib(namespace: str) -> float:
    """Best-effort: parse `kubectl top pod` for any Qdrant pod in namespace.

    Returns peak RSS in MiB across matching pods, or 0.0 if we can't sample
    (e.g. metrics-server not installed, not GKE, etc.).
    """
    if shutil.which("kubectl") is None:
        return 0.0
    proc = subprocess.run(
        [
            "kubectl", "top", "pod", "-n", namespace,
            "-l", "app.kubernetes.io/name=qdrant",
            "--no-headers",
        ],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return 0.0
    peak = 0.0
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        mem = parts[-1]  # e.g. "512Mi" / "1Gi"
        try:
            if mem.endswith("Mi"):
                val = float(mem[:-2])
            elif mem.endswith("Gi"):
                val = float(mem[:-2]) * 1024.0
            else:
                val = float(mem)
        except ValueError:
            continue
        peak = max(peak, val)
    return peak


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", default="http://127.0.0.1:8000")
    p.add_argument("--audience", default="")
    p.add_argument("--prompts", default="P1,P2,P3,P4,P5")
    p.add_argument("--repetitions", type=int, default=10)
    p.add_argument("--timeout", type=float, default=60.0)
    p.add_argument("--sample-qdrant-rss", action="store_true",
                   help="Call `kubectl top pod` after each request to record Qdrant RSS")
    p.add_argument("--namespace", default="rag-thesis")
    p.add_argument("--result-dir", default="benchmarks")
    return p.parse_args()


def get_id_token(audience: str) -> str | None:
    if not audience or shutil.which("gcloud") is None:
        return None
    r = subprocess.run(
        ["gcloud", "auth", "print-identity-token", f"--audiences={audience}"],
        capture_output=True, text=True, check=False,
    )
    return r.stdout.strip() or None if r.returncode == 0 else None


def main() -> int:
    args = parse_args()
    result_dir = Path(args.result_dir)
    result_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    csv_path = result_dir / f"retrieval_results_{stamp}.csv"

    prompt_ids = [p.strip() for p in args.prompts.split(",") if p.strip()]

    headers = {"Content-Type": "application/json"}
    tok = get_id_token(args.audience)
    if tok:
        headers["Authorization"] = f"Bearer {tok}"

    fieldnames = [
        "timestamp",
        "prompt_id",
        "repetition",
        "http_code",
        "client_total_ms",
        "server_embedding_ms",
        "server_search_ms",
        "server_total_retrieval_ms",
        "qdrant_rss_mib",
        "top_k",
        "collection",
    ]

    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for pid in prompt_ids:
            prompt = DEFAULT_PROMPTS.get(pid, DEFAULT_PROMPTS["P1"])
            for rep in range(1, args.repetitions + 1):
                t0 = time.perf_counter()
                try:
                    resp = requests.post(
                        f"{args.base_url.rstrip('/')}/retrieve",
                        json={"query": prompt},
                        headers=headers,
                        timeout=args.timeout,
                    )
                    code = resp.status_code
                    body = resp.json() if resp.ok else {}
                except requests.RequestException as exc:
                    code = 0
                    body = {"error": str(exc)}
                t1 = time.perf_counter()

                timing = body.get("timing_ms", {}) if isinstance(body, dict) else {}
                rss = (
                    sample_qdrant_rss_mib(args.namespace)
                    if args.sample_qdrant_rss and code == 200
                    else 0.0
                )
                row = {
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "prompt_id": pid,
                    "repetition": rep,
                    "http_code": code,
                    "client_total_ms": round((t1 - t0) * 1000.0, 3),
                    "server_embedding_ms": timing.get("embedding", -1),
                    "server_search_ms": timing.get("qdrant_search", -1),
                    "server_total_retrieval_ms": timing.get("total_retrieval", -1),
                    "qdrant_rss_mib": round(rss, 1),
                    "top_k": body.get("top_k") if isinstance(body, dict) else None,
                    "collection": body.get("collection") if isinstance(body, dict) else None,
                }
                writer.writerow(row)
                fh.flush()
                print(json.dumps(row))

    print(f"Wrote {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
