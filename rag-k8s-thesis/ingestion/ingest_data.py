from __future__ import annotations

import hashlib
import os
from pathlib import Path
from time import perf_counter

from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.document_loaders import DirectoryLoader, TextLoader
from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.http.models import Distance, PointStruct, VectorParams

DATA_DIR = Path(os.getenv("DATA_DIR", "/data/sec_rag_dataset_50"))
GCS_DATA_URI = os.getenv("GCS_DATA_URI", "").strip()  # e.g. gs://my-bucket/sec_rag_dataset_50
COLLECTION_NAME = os.getenv("QDRANT_COLLECTION", "thesis_docs")
QDRANT_HOST = os.getenv("QDRANT_HOST", "qdrant")
QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "800"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "100"))
BATCH_SIZE = int(os.getenv("EMBEDDING_BATCH_SIZE", "64"))
MAX_DOCS = int(os.getenv("MAX_DOCS", "0"))


def stable_point_id(value: str) -> int:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return int(digest, 16)


def iter_batches(items: list, batch_size: int) -> list[list]:
    if batch_size <= 0:
        raise ValueError("EMBEDDING_BATCH_SIZE must be > 0")
    return [items[idx : idx + batch_size] for idx in range(0, len(items), batch_size)]


def download_gcs_prefix_to_dir(gs_uri: str, dest: Path) -> None:
    """Download objects under gs://bucket/prefix into dest (keeps relative paths)."""
    from google.cloud import storage

    if not gs_uri.startswith("gs://"):
        raise ValueError("GCS_DATA_URI must start with gs://")
    rest = gs_uri[5:]
    if "/" in rest:
        bucket_name, prefix = rest.split("/", 1)
        prefix = prefix.strip("/")
    else:
        bucket_name, prefix = rest, ""
    if prefix:
        prefix = f"{prefix}/"
    dest.mkdir(parents=True, exist_ok=True)
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    count = 0
    for blob in bucket.list_blobs(prefix=prefix if prefix else None):
        name = blob.name
        if name.endswith("/"):
            continue
        rel = name[len(prefix) :] if prefix else name
        if not rel:
            continue
        local_path = dest / rel
        local_path.parent.mkdir(parents=True, exist_ok=True)
        blob.download_to_filename(str(local_path))
        count += 1
    if count == 0:
        raise RuntimeError(f"No objects downloaded from {gs_uri!r} (check bucket IAM and prefix)")
    print(f"Downloaded {count} files from {gs_uri} -> {dest}")


def main() -> None:
    start = perf_counter()
    if GCS_DATA_URI:
        print(f"Syncing dataset from {GCS_DATA_URI} into {DATA_DIR}")
        download_gcs_prefix_to_dir(GCS_DATA_URI, DATA_DIR)
    print(f"Starting ingestion from DATA_DIR={DATA_DIR}")
    loader = DirectoryLoader(str(DATA_DIR), glob="**/*.txt", loader_cls=TextLoader)
    docs = loader.load()
    if not docs:
        raise RuntimeError(f"No .txt documents found in dataset directory: {DATA_DIR}")
    if MAX_DOCS > 0:
        docs = docs[:MAX_DOCS]
        print(f"MAX_DOCS is set, limiting loaded documents to {len(docs)}")
    else:
        print(f"Loaded {len(docs)} documents")

    splitter = RecursiveCharacterTextSplitter(chunk_size=CHUNK_SIZE, chunk_overlap=CHUNK_OVERLAP)
    chunks = splitter.split_documents(docs)
    if not chunks:
        raise RuntimeError("No chunks created from loaded documents")
    print(f"Created {len(chunks)} chunks (chunk_size={CHUNK_SIZE}, overlap={CHUNK_OVERLAP})")

    embeddings = HuggingFaceEmbeddings(model_name=EMBEDDING_MODEL)
    print(f"Embedding model ready: {EMBEDDING_MODEL}")

    first_vector = embeddings.embed_documents([chunks[0].page_content])[0]
    vector_size = len(first_vector)

    client = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)
    if not client.collection_exists(COLLECTION_NAME):
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        print(f"Created collection '{COLLECTION_NAME}' with vector_size={vector_size}")
    else:
        print(f"Using existing collection '{COLLECTION_NAME}'")

    total_points = 0
    chunk_batches = iter_batches(chunks, BATCH_SIZE)
    print(f"Embedding/upserting in {len(chunk_batches)} batches (batch_size={BATCH_SIZE})")
    for batch_index, chunk_batch in enumerate(chunk_batches, start=1):
        batch_vectors = embeddings.embed_documents([chunk.page_content for chunk in chunk_batch])
        points: list[PointStruct] = []
        for local_idx, (chunk, vector) in enumerate(zip(chunk_batch, batch_vectors)):
            global_idx = (batch_index - 1) * BATCH_SIZE + local_idx
            source = str(chunk.metadata.get("source", "unknown"))
            point_id = stable_point_id(f"{source}:{global_idx}:{chunk.page_content[:64]}")
            points.append(
                PointStruct(
                    id=point_id,
                    vector=vector,
                    payload={"text": chunk.page_content, "source": source, "chunk_index": global_idx},
                )
            )
        client.upsert(collection_name=COLLECTION_NAME, points=points, wait=True)
        total_points += len(points)
        print(
            f"Batch {batch_index}/{len(chunk_batches)} upserted "
            f"{len(points)} chunks (total={total_points})"
        )

    elapsed = perf_counter() - start
    print(f"Ingested {total_points} chunks into '{COLLECTION_NAME}' in {elapsed:.1f}s.")


if __name__ == "__main__":
    main()
