from __future__ import annotations

from typing import Any

from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.llms import Ollama
from langchain_community.vectorstores import Qdrant
from qdrant_client import QdrantClient

from app.config import settings


class RagPipeline:
    def __init__(self) -> None:
        self.embeddings = HuggingFaceEmbeddings(model_name=settings.embedding_model_name)
        self.qdrant_client = QdrantClient(host=settings.qdrant_host, port=settings.qdrant_port)
        self.vector_store = Qdrant(
            client=self.qdrant_client,
            collection_name=settings.qdrant_collection,
            embeddings=self.embeddings,
            content_payload_key="text",
        )
        self.llm = Ollama(
            base_url=settings.ollama_base_url,
            model=settings.ollama_model,
            temperature=0.1,
        )

    def query(self, user_query: str) -> dict[str, Any]:
        docs = self.vector_store.similarity_search(user_query, k=settings.qdrant_top_k)
        context = "\n\n".join(doc.page_content for doc in docs)
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
                "content_preview": doc.page_content[:220],
                "metadata": doc.metadata,
            }
            for doc in docs
        ]
        return {"answer": answer, "sources": sources}
