from __future__ import annotations

from typing import Any

from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.llms import Ollama
from qdrant_client import QdrantClient

from app.config import settings


class RagPipeline:
    def __init__(self) -> None:
        self.embeddings = HuggingFaceEmbeddings(model_name=settings.embedding_model_name)
        self.qdrant_client = QdrantClient(host=settings.qdrant_host, port=settings.qdrant_port)
        self.llm = Ollama(
            base_url=settings.ollama_base_url,
            model=settings.ollama_model,
            temperature=0.1,
        )

    def query(self, user_query: str) -> dict[str, Any]:
        query_vector = self.embeddings.embed_query(user_query)
        search_result = self.qdrant_client.query_points(
            collection_name=settings.qdrant_collection,
            query=query_vector,
            limit=settings.qdrant_top_k,
            with_payload=True,
        )
        points = search_result.points
        context = "\n\n".join(str((point.payload or {}).get("text", "")) for point in points)
        prompt = (
            "You are a helpful assistant for a master's thesis RAG PoC.\n"
            "Use the context to answer the question. If context is insufficient, say so.\n\n"
            f"Context:\n{context}\n\n"
            f"Question:\n{user_query}\n\n"
            "Answer:"
        )
        answer = self.llm.invoke(prompt)
        sources = [
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
        return {"answer": answer, "sources": sources}
