from __future__ import annotations

import json
import time
from collections.abc import Iterator
from typing import Any

import requests
from app.config import settings
from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.http import exceptions as qdrant_exceptions

# Sentinel value used on the returned answer string when every LLM attempt has
# failed (including the configured fallback model). The sources list is still
# populated so the API stays useful for downstream graders.
LLM_UNAVAILABLE_MARKER = "[LLM unavailable, returning retrieved context only]"


class QdrantUnavailableError(RuntimeError):
    """Raised when Qdrant is unreachable after retries.

    Translated into HTTP 503 in the FastAPI layer so the client sees a clean
    'dependency unavailable' signal instead of a 500 / stack trace.
    """


class RagPipeline:
    def __init__(self) -> None:
        self.embeddings = HuggingFaceEmbeddings(model_name=settings.embedding_model_name)
        self.qdrant_client = QdrantClient(host=settings.qdrant_host, port=settings.qdrant_port)

    def _retrieval_limit(self) -> int:
        return settings.qdrant_top_k_product if settings.product_latency_mode else settings.qdrant_top_k

    def _generation_options(self, *, max_tokens_override: int | None = None) -> dict[str, Any]:
        opts: dict[str, Any] = {"temperature": settings.ollama_temperature}
        cap = max_tokens_override if max_tokens_override is not None else settings.ollama_max_output_tokens
        if cap and cap > 0:
            opts["num_predict"] = cap
        return opts

    def _provider_url(self, path: str) -> str:
        base = settings.llm_base_url.rstrip("/")
        return f"{base}{path}"

    def _resolve_primary_model(self, answer_mode: str | None) -> str:
        if (answer_mode or "").lower() == "complex":
            return settings.llm_reasoning_model
        return settings.llm_model

    def _max_tokens_for_mode(self, answer_mode: str | None) -> int | None:
        # Reasoning models (e.g., deepseek-r1) may emit long "thinking" traces
        # before final answer tokens. If we keep a tight num_predict cap,
        # streaming can terminate after thinking with no user-visible answer.
        # Disable token cap for complex mode so response tokens can arrive.
        if (answer_mode or "").lower() == "complex":
            return 0
        return None

    def _complete_ollama(
        self,
        prompt: str,
        *,
        max_tokens_override: int | None = None,
        model_override: str | None = None,
    ) -> str:
        payload: dict[str, Any] = {
            "model": model_override or settings.llm_model,
            "prompt": prompt,
            "stream": False,
            "options": self._generation_options(max_tokens_override=max_tokens_override),
        }
        resp = requests.post(
            self._provider_url("/api/generate"),
            json=payload,
            timeout=settings.request_timeout_seconds,
        )
        resp.raise_for_status()
        body = resp.json()
        return str(body.get("response", ""))

    def _complete_vllm(
        self,
        prompt: str,
        *,
        max_tokens_override: int | None = None,
        model_override: str | None = None,
    ) -> str:
        cap = max_tokens_override if max_tokens_override is not None else settings.ollama_max_output_tokens
        payload: dict[str, Any] = {
            "model": model_override or settings.llm_model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": settings.ollama_temperature,
        }
        if cap and cap > 0:
            payload["max_tokens"] = cap
        resp = requests.post(
            self._provider_url("/v1/chat/completions"),
            json=payload,
            timeout=settings.request_timeout_seconds,
        )
        resp.raise_for_status()
        body = resp.json()
        return str(body["choices"][0]["message"]["content"])

    def _call_llm_once(
        self,
        prompt: str,
        *,
        max_tokens_override: int | None = None,
        model_override: str | None = None,
    ) -> str:
        provider = settings.llm_provider.lower()
        if provider == "vllm":
            return self._complete_vllm(
                prompt,
                max_tokens_override=max_tokens_override,
                model_override=model_override,
            )
        return self._complete_ollama(
            prompt,
            max_tokens_override=max_tokens_override,
            model_override=model_override,
        )

    def _complete_llm_with_fallback(
        self,
        prompt: str,
        *,
        max_tokens_override: int | None = None,
        answer_mode: str | None = None,
    ) -> tuple[str, dict[str, Any]]:
        """Call the LLM with retries + fallback model.

        Returns (answer_text, meta) where meta includes which model answered
        and how many attempts were used. This is the resilience mechanism the
        thesis evaluates: if the primary model fails N times, we try the
        configured fallback; only after that returns do we surface the "LLM
        unavailable" marker to the caller.
        """
        attempts = 0
        retries = max(0, settings.llm_max_retries)
        backoff = max(0.0, settings.llm_retry_backoff_seconds)

        primary = self._resolve_primary_model(answer_mode)
        fallback = (settings.llm_fallback_model or "").strip()

        last_exc: Exception | None = None
        for attempt in range(1, retries + 2):  # retries + initial attempt
            attempts += 1
            try:
                answer = self._call_llm_once(
                    prompt,
                    max_tokens_override=max_tokens_override,
                    model_override=primary,
                )
                return answer, {"model_used": primary, "attempts": attempts, "fallback": False}
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                if attempt <= retries:
                    time.sleep(backoff * attempt)  # linear-ish backoff

        # Primary exhausted; try fallback if configured and different.
        if fallback and fallback != primary:
            attempts += 1
            try:
                answer = self._call_llm_once(
                    prompt,
                    max_tokens_override=max_tokens_override,
                    model_override=fallback,
                )
                return answer, {
                    "model_used": fallback,
                    "attempts": attempts,
                    "fallback": True,
                    "primary_error": str(last_exc) if last_exc else None,
                }
            except Exception as exc:  # noqa: BLE001
                last_exc = exc

        # Everything failed. Return the context-only marker so the API still
        # serves *something* useful (retrieved sources) and callers can decide
        # what to do with the degraded response.
        return LLM_UNAVAILABLE_MARKER, {
            "model_used": None,
            "attempts": attempts,
            "fallback": bool(fallback and fallback != primary),
            "error": str(last_exc) if last_exc else "unknown",
        }

    def _retrieve_raw(self, user_query: str) -> tuple[list[Any], float, float]:
        """Run retrieval and return (points, embed_seconds, search_seconds).

        Splits timings so benchmarks can attribute latency to the embedding
        step vs. the Qdrant search step. Retries Qdrant once on connection
        errors; if the second attempt still fails, raises QdrantUnavailableError.
        """
        embed_start = time.perf_counter()
        query_vector = self.embeddings.embed_query(user_query)
        embed_seconds = time.perf_counter() - embed_start

        last_exc: Exception | None = None
        for attempt in range(1, settings.qdrant_max_retries + 2):
            try:
                search_start = time.perf_counter()
                search_result = self.qdrant_client.query_points(
                    collection_name=settings.qdrant_collection,
                    query=query_vector,
                    limit=self._retrieval_limit(),
                    with_payload=True,
                )
                search_seconds = time.perf_counter() - search_start
                return search_result.points, embed_seconds, search_seconds
            except (
                qdrant_exceptions.ResponseHandlingException,
                qdrant_exceptions.UnexpectedResponse,
                ConnectionError,
                requests.ConnectionError,
                requests.Timeout,
            ) as exc:
                last_exc = exc
                if attempt <= settings.qdrant_max_retries:
                    time.sleep(settings.qdrant_retry_backoff_seconds * attempt)

        raise QdrantUnavailableError(f"Qdrant unreachable after retries: {last_exc}")

    def _retrieve(self, user_query: str) -> tuple[list[Any], str]:
        points, _, _ = self._retrieve_raw(user_query)
        context = "\n\n".join(str((point.payload or {}).get("text", "")) for point in points)
        return points, context

    def _build_prompt(self, user_query: str, context: str) -> str:
        return (
            "You are a helpful assistant for a master's thesis RAG PoC.\n"
            "Use the context to answer the question. If context is insufficient, say so.\n"
            "Be concise when the question allows it.\n\n"
            f"Context:\n{context}\n\n"
            f"Question:\n{user_query}\n\n"
            "Answer:"
        )

    def _sources_from_points(self, points: list[Any]) -> list[dict[str, Any]]:
        return [
            {
                "content_preview": str((point.payload or {}).get("text", ""))[:220],
                "metadata": {
                    "source": (point.payload or {}).get("source"),
                    "chunk_index": (point.payload or {}).get("chunk_index"),
                    "page": (point.payload or {}).get("page"),
                    "score": point.score,
                },
            }
            for point in points
        ]

    def warmup_llm(self) -> None:
        """Prime LLM provider/model for lower first-user latency."""
        try:
            self._call_llm_once(
                "System warmup. Reply with exactly: OK",
                max_tokens_override=8,
            )
        except Exception:
            # Do not block API startup if the cluster is still pulling models.
            pass

    def retrieve_only(self, user_query: str) -> dict[str, Any]:
        """Vector-DB path without the LLM.

        Used by the /retrieve endpoint so thesis benchmarks can isolate Qdrant
        latency (embedding time + search time) from generation latency.
        """
        points, embed_seconds, search_seconds = self._retrieve_raw(user_query)
        return {
            "sources": self._sources_from_points(points),
            "timing_ms": {
                "embedding": round(embed_seconds * 1000.0, 3),
                "qdrant_search": round(search_seconds * 1000.0, 3),
                "total_retrieval": round((embed_seconds + search_seconds) * 1000.0, 3),
            },
            "collection": settings.qdrant_collection,
            "top_k": self._retrieval_limit(),
        }

    def query(self, user_query: str, *, answer_mode: str | None = None) -> dict[str, Any]:
        retrieve_start = time.perf_counter()
        points, embed_seconds, search_seconds = self._retrieve_raw(user_query)
        retrieve_seconds = time.perf_counter() - retrieve_start
        context = "\n\n".join(str((point.payload or {}).get("text", "")) for point in points)

        prompt = self._build_prompt(user_query, context)
        gen_start = time.perf_counter()
        answer, llm_meta = self._complete_llm_with_fallback(
            prompt,
            max_tokens_override=self._max_tokens_for_mode(answer_mode),
            answer_mode=answer_mode,
        )
        gen_seconds = time.perf_counter() - gen_start

        return {
            "answer": answer,
            "sources": self._sources_from_points(points),
            "llm": llm_meta,
            "timing_ms": {
                "embedding": round(embed_seconds * 1000.0, 3),
                "qdrant_search": round(search_seconds * 1000.0, 3),
                "retrieval_total": round(retrieve_seconds * 1000.0, 3),
                "generation": round(gen_seconds * 1000.0, 3),
            },
        }

    def stream_query_sse(self, user_query: str, *, answer_mode: str | None = None) -> Iterator[str]:
        """Server-Sent Events lines: data: {json}\\n\\n with types sources | token | done.

        Emits a final event of type `done` (or `error`) so clients can
        distinguish a clean end-of-stream from a truncated connection.
        """
        try:
            points, embed_seconds, search_seconds = self._retrieve_raw(user_query)
        except QdrantUnavailableError as exc:
            yield f"data: {json.dumps({'type': 'error', 'stage': 'retrieve', 'message': str(exc)})}\n\n"
            return

        context = "\n\n".join(str((point.payload or {}).get("text", "")) for point in points)
        sources = self._sources_from_points(points)
        yield (
            "data: "
            + json.dumps(
                {
                    "type": "sources",
                    "sources": sources,
                    "timing_ms": {
                        "embedding": round(embed_seconds * 1000.0, 3),
                        "qdrant_search": round(search_seconds * 1000.0, 3),
                    },
                }
            )
            + "\n\n"
        )

        provider = settings.llm_provider.lower()
        selected_model = self._resolve_primary_model(answer_mode)
        try:
            if provider == "vllm":
                cap_override = self._max_tokens_for_mode(answer_mode)
                cap = cap_override if cap_override is not None else settings.ollama_max_output_tokens
                payload: dict[str, Any] = {
                    "model": selected_model,
                    "messages": [{"role": "user", "content": self._build_prompt(user_query, context)}],
                    "temperature": settings.ollama_temperature,
                    "stream": True,
                }
                if cap and cap > 0:
                    payload["max_tokens"] = cap
                with requests.post(
                    self._provider_url("/v1/chat/completions"),
                    json=payload,
                    stream=True,
                    timeout=settings.request_timeout_seconds,
                ) as resp:
                    resp.raise_for_status()
                    for raw in resp.iter_lines(decode_unicode=True):
                        if not raw or not raw.startswith("data: "):
                            continue
                        data_part = raw[6:].strip()
                        if data_part == "[DONE]":
                            break
                        evt = json.loads(data_part)
                        delta = evt.get("choices", [{}])[0].get("delta", {})
                        piece = delta.get("content") or ""
                        if piece:
                            yield f"data: {json.dumps({'type': 'token', 't': piece})}\n\n"
            else:
                payload = {
                    "model": selected_model,
                    "prompt": self._build_prompt(user_query, context),
                    "stream": True,
                    "options": self._generation_options(
                        max_tokens_override=self._max_tokens_for_mode(answer_mode)
                    ),
                }
                with requests.post(
                    self._provider_url("/api/generate"),
                    json=payload,
                    stream=True,
                    timeout=settings.request_timeout_seconds,
                ) as resp:
                    resp.raise_for_status()
                    for raw in resp.iter_lines(decode_unicode=True):
                        if not raw:
                            continue
                        data = json.loads(raw)
                        piece = data.get("response") or ""
                        if piece:
                            yield f"data: {json.dumps({'type': 'token', 't': piece})}\n\n"
                        if data.get("done"):
                            break
        except Exception as exc:  # noqa: BLE001
            yield f"data: {json.dumps({'type': 'error', 'stage': 'generate', 'message': str(exc)})}\n\n"
            return

        yield f"data: {json.dumps({'type': 'done'})}\n\n"
