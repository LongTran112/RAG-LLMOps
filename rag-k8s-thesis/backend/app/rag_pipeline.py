from __future__ import annotations

import json
from typing import Any, Iterator

import requests
from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient

from app.config import settings


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

    def _complete_ollama(self, prompt: str, *, max_tokens_override: int | None = None) -> str:
        payload: dict[str, Any] = {
            "model": settings.llm_model,
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

    def _complete_vllm(self, prompt: str, *, max_tokens_override: int | None = None) -> str:
        cap = max_tokens_override if max_tokens_override is not None else settings.ollama_max_output_tokens
        payload: dict[str, Any] = {
            "model": settings.llm_model,
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

    def _complete_llm(self, prompt: str, *, max_tokens_override: int | None = None) -> str:
        provider = settings.llm_provider.lower()
        if provider == "vllm":
            return self._complete_vllm(prompt, max_tokens_override=max_tokens_override)
        return self._complete_ollama(prompt, max_tokens_override=max_tokens_override)

    def _retrieve(self, user_query: str) -> tuple[list[Any], str]:
        query_vector = self.embeddings.embed_query(user_query)
        search_result = self.qdrant_client.query_points(
            collection_name=settings.qdrant_collection,
            query=query_vector,
            limit=self._retrieval_limit(),
            with_payload=True,
        )
        points = search_result.points
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
                    "score": point.score,
                },
            }
            for point in points
        ]

    def warmup_llm(self) -> None:
        """Prime LLM provider/model for lower first-user latency."""
        try:
            self._complete_llm(
                "System warmup. Reply with exactly: OK",
                max_tokens_override=8,
            )
        except Exception:
            # Do not block API startup if the cluster is still pulling models.
            pass

    def query(self, user_query: str) -> dict[str, Any]:
        points, context = self._retrieve(user_query)
        prompt = self._build_prompt(user_query, context)
        answer = self._complete_llm(prompt)
        return {"answer": answer, "sources": self._sources_from_points(points)}

    def stream_query_sse(self, user_query: str) -> Iterator[str]:
        """Server-Sent Events lines: data: {json}\\n\\n with types sources | token | done."""
        points, context = self._retrieve(user_query)
        sources = self._sources_from_points(points)
        yield f"data: {json.dumps({'type': 'sources', 'sources': sources})}\n\n"

        provider = settings.llm_provider.lower()
        if provider == "vllm":
            cap = settings.ollama_max_output_tokens
            payload: dict[str, Any] = {
                "model": settings.llm_model,
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
                "model": settings.llm_model,
                "prompt": self._build_prompt(user_query, context),
                "stream": True,
                "options": self._generation_options(),
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
        yield f"data: {json.dumps({'type': 'done'})}\n\n"
