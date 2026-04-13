from __future__ import annotations

import hashlib
import os
from pathlib import Path

from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.document_loaders import DirectoryLoader, TextLoader
from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, PointStruct, VectorParams

DATA_DIR = Path(__file__).parent / "data"
COLLECTION_NAME = os.getenv("QDRANT_COLLECTION", "thesis_docs")
QDRANT_HOST = os.getenv("QDRANT_HOST", "qdrant")
QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "800"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "100"))


def stable_point_id(value: str) -> int:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return int(digest, 16)


def main() -> None:
    loader = DirectoryLoader(str(DATA_DIR), glob="**/*.txt", loader_cls=TextLoader)
    docs = loader.load()
    if not docs:
        raise RuntimeError("No .txt documents found in ingestion/data")

    splitter = RecursiveCharacterTextSplitter(chunk_size=CHUNK_SIZE, chunk_overlap=CHUNK_OVERLAP)
    chunks = splitter.split_documents(docs)

    embeddings = HuggingFaceEmbeddings(model_name=EMBEDDING_MODEL)
    vectors = embeddings.embed_documents([chunk.page_content for chunk in chunks])
    vector_size = len(vectors[0])

    client = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)
    if not client.collection_exists(COLLECTION_NAME):
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )

    points = []
    for idx, (chunk, vector) in enumerate(zip(chunks, vectors)):
        source = str(chunk.metadata.get("source", "unknown"))
        point_id = stable_point_id(f"{source}:{idx}:{chunk.page_content[:64]}")
        points.append(
            PointStruct(
                id=point_id,
                vector=vector,
                payload={"text": chunk.page_content, "source": source, "chunk_index": idx},
            )
        )

    client.upsert(collection_name=COLLECTION_NAME, points=points, wait=True)
    print(f"Ingested {len(points)} chunks into '{COLLECTION_NAME}'.")


if __name__ == "__main__":
    main()
