#!/usr/bin/env python3
"""High-fidelity streaming benchmark for the RAG backend's /query/stream SSE.

Captures **per-event** timestamps so we can compute:
  * TTFT (time to first LLM token)
  * Time from request start to first `sources` event  (== retrieval latency
    as seen by the client)
  * Total stream duration
  * Token count and per-token intervals (for debugging / quality checks)

This Python client avoids curl's line-buffering limits that make a shell-only
implementation imprecise for TTFT. Results feed straight into the thesis
benchmark matrix.

Usage examples:

  # GKE via kubectl port-forward (start it yourself first):
  ./scripts/benchmark_stream.py \\
      --base-url http://127.0.0.1:8000 \\
      --models phi3:mini,qwen2.5:3b \\
      --prompts P1,P2 --repetitions 3

  # Cloud Run public backend:
  ./scripts/benchmark_stream.py \\
      --base-url https://rag-backend-xxxx.a.run.app

  # Cloud Run private backend (uses gcloud for an ID token):
  ./scripts/benchmark_stream.py \\
      --base-url https://rag-backend-xxxx.a.run.app \\
      --audience https://rag-backend-xxxx.a.run.app

Writes:
  benchmarks/stream_results_<timestamp>.csv
  benchmarks/stream_run_<timestamp>.log
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
from typing import Any

import requests

DEFAULT_PROMPTS = {
    "P1": "What is SEC filing?",
    "P2": "Summarize key risk factors discussed in these SEC filings.",
    "P3": "What recurring business risks are mentioned across multiple filings?",
    "P4": "List important compliance or regulatory themes in the dataset.",
    "P5": "Give a concise 5-bullet summary of major concerns from the filings.",
}


def get_id_token(audience: str) -> str | None:
    if not audience:
        return None
    if shutil.which("gcloud") is None:
        return None
    out = subprocess.run(
        ["gcloud", "auth", "print-identity-token", f"--audiences={audience}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None


def run_one_stream(
    base_url: str,
    prompt: str,
    *,
    audience: str,
    timeout: float,
) -> dict[str, Any]:
    """Send one /query/stream request and return timing + status."""
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    tok = get_id_token(audience)
    if tok:
        headers["Authorization"] = f"Bearer {tok}"

    start = time.perf_counter()
    first_sources_t: float | None = None
    first_token_t: float | None = None
    last_token_t: float | None = None
    token_count = 0
    error_stage: str | None = None
    error_message: str | None = None
    status_code = 0

    try:
        with requests.post(
            f"{base_url.rstrip('/')}/query/stream",
            json={"query": prompt},
            headers=headers,
            stream=True,
            timeout=timeout,
        ) as resp:
            status_code = resp.status_code
            resp.raise_for_status()
            for raw in resp.iter_lines(decode_unicode=True):
                if not raw or not raw.startswith("data: "):
                    continue
                now = time.perf_counter()
                try:
                    evt = json.loads(raw[6:].strip())
                except json.JSONDecodeError:
                    continue
                et = evt.get("type")
                if et == "sources" and first_sources_t is None:
                    first_sources_t = now
                elif et == "token":
                    if first_token_t is None:
                        first_token_t = now
                    last_token_t = now
                    token_count += 1
                elif et == "error":
                    error_stage = evt.get("stage", "unknown")
                    error_message = evt.get("message", "")
                elif et == "done":
                    break
    except requests.HTTPError as exc:
        error_stage = "http"
        error_message = str(exc)
    except requests.RequestException as exc:
        error_stage = "network"
        error_message = str(exc)

    end = time.perf_counter()
    return {
        "http_code": status_code,
        "ttft_s": round(first_token_t - start, 6) if first_token_t else -1.0,
        "sources_time_s": round(first_sources_t - start, 6) if first_sources_t else -1.0,
        "total_s": round(end - start, 6),
        "token_count": token_count,
        "gen_duration_s": (
            round(last_token_t - first_token_t, 6)
            if (first_token_t and last_token_t)
            else 0.0
        ),
        "error_stage": error_stage or "",
        "error_message": (error_message or "")[:200],
    }


def switch_gke_model(namespace: str, model: str) -> None:
    subprocess.run(
        ["kubectl", "exec", "-n", namespace, "deployment/ollama",
         "--", "ollama", "pull", model],
        check=True,
    )
    subprocess.run(
        [
            "kubectl", "set", "env", "deployment/rag-backend", "-n", namespace,
            f"LLM_MODEL={model}",
        ],
        check=True,
    )
    subprocess.run(
        [
            "kubectl", "rollout", "status", "deployment/rag-backend",
            "-n", namespace, "--timeout=1200s",
        ],
        check=True,
    )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default="http://127.0.0.1:8000",
                   help="Backend base URL (default: http://127.0.0.1:8000)")
    p.add_argument("--audience", default="",
                   help="If set, gcloud prints an ID token for this audience (Cloud Run private services)")
    p.add_argument("--models", default="phi3:mini",
                   help="Comma-separated list of models")
    p.add_argument("--prompts", default="P1,P2,P3",
                   help="Comma-separated prompt IDs from P1..P5")
    p.add_argument("--repetitions", type=int, default=3)
    p.add_argument("--timeout", type=float, default=1800.0)
    p.add_argument("--switch-gke-model", action="store_true",
                   help="If set, update the rag-backend Deployment's LLM_MODEL via kubectl before each model block")
    p.add_argument("--namespace", default="rag-thesis")
    p.add_argument("--result-dir", default="benchmarks")
    p.add_argument("--warmup/--no-warmup", dest="warmup", default=True, action=argparse.BooleanOptionalAction)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    result_dir = Path(args.result_dir)
    result_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    csv_path = result_dir / f"stream_results_{stamp}.csv"
    log_path = result_dir / f"stream_run_{stamp}.log"

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    prompt_ids = [p.strip() for p in args.prompts.split(",") if p.strip()]

    fieldnames = [
        "timestamp",
        "model",
        "prompt_id",
        "repetition",
        "http_code",
        "ttft_s",
        "sources_time_s",
        "gen_duration_s",
        "total_s",
        "token_count",
        "error_stage",
        "error_message",
    ]

    def log(msg: str) -> None:
        line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
        print(line)
        with log_path.open("a") as fh:
            fh.write(line + "\n")

    log(f"Streaming benchmark starting: base_url={args.base_url} -> {csv_path}")

    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()

        for model in models:
            if args.switch_gke_model:
                log(f"kubectl: switching rag-backend LLM_MODEL={model}")
                try:
                    switch_gke_model(args.namespace, model)
                except subprocess.CalledProcessError as exc:
                    log(f"WARN: model switch failed for {model}: {exc}")
                    continue

            if args.warmup:
                log(f"warmup query for model={model}")
                run_one_stream(
                    args.base_url,
                    DEFAULT_PROMPTS["P1"],
                    audience=args.audience,
                    timeout=args.timeout,
                )

            for pid in prompt_ids:
                prompt = DEFAULT_PROMPTS.get(pid, DEFAULT_PROMPTS["P1"])
                for rep in range(1, args.repetitions + 1):
                    r = run_one_stream(
                        args.base_url,
                        prompt,
                        audience=args.audience,
                        timeout=args.timeout,
                    )
                    row = {
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "model": model,
                        "prompt_id": pid,
                        "repetition": rep,
                        **r,
                    }
                    writer.writerow(row)
                    fh.flush()
                    log(
                        f"model={model} prompt={pid} rep={rep} "
                        f"code={r['http_code']} ttft={r['ttft_s']}s "
                        f"gen={r['gen_duration_s']}s total={r['total_s']}s tokens={r['token_count']} "
                        f"err={r['error_stage']}"
                    )

    log(f"Done -> {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
