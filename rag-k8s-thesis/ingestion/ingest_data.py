from __future__ import annotations

import csv
import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter

from langchain_community.document_loaders import (
    DirectoryLoader,
    PyMuPDFLoader,
    TextLoader,
)
from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_text_splitters import RecursiveCharacterTextSplitter
from qdrant_client import QdrantClient
from qdrant_client.http.models import (
    CreateAlias,
    CreateAliasOperation,
    Distance,
    PointStruct,
    VectorParams,
)

DATA_DIR = Path(os.getenv("DATA_DIR", "/data/sec_rag_dataset_50"))
GCS_DATA_URI = os.getenv("GCS_DATA_URI", "").strip()  # e.g. gs://my-bucket/sec_rag_dataset_50
# Logical collection/alias that the API always reads from. The ingestion job writes
# to a dated physical collection, then atomically swaps this alias so queries never
# see a partially-indexed corpus (blue/green vector indexing).
COLLECTION_ALIAS = os.getenv("QDRANT_COLLECTION", "thesis_docs_active")
# Base name for the dated physical collection (e.g. thesis_docs_20260420_094210).
COLLECTION_BASE_NAME = os.getenv("QDRANT_COLLECTION_BASE", "thesis_docs")
# If "true", write directly into COLLECTION_ALIAS (legacy behaviour). Defaults to
# blue/green mode so the API is never blocked by re-ingestion.
INGEST_INPLACE = os.getenv("INGEST_INPLACE", "false").lower() in {"1", "true", "yes"}
QDRANT_HOST = os.getenv("QDRANT_HOST", "qdrant")
QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "800"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "100"))
BATCH_SIZE = int(os.getenv("EMBEDDING_BATCH_SIZE", "64"))
MAX_DOCS = int(os.getenv("MAX_DOCS", "0"))
METRICS_CSV_PATH = os.getenv("INGESTION_METRICS_CSV", "").strip()


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


def load_documents(data_dir: Path) -> list:
    """Load .pdf and .txt documents from data_dir.

    PDFs are parsed with PyMuPDF (fast, robust for large filings); .txt files go
    through the plain TextLoader so the existing SEC .txt corpus keeps working.
    """
    all_docs: list = []
    pdf_loader = DirectoryLoader(
        str(data_dir),
        glob="**/*.pdf",
        loader_cls=PyMuPDFLoader,
        use_multithreading=True,
        show_progress=False,
    )
    pdf_docs = pdf_loader.load()
    if pdf_docs:
        print(f"Loaded {len(pdf_docs)} PDF pages from {data_dir}")
        all_docs.extend(pdf_docs)

    txt_loader = DirectoryLoader(
        str(data_dir),
        glob="**/*.txt",
        loader_cls=TextLoader,
        use_multithreading=True,
        show_progress=False,
    )
    txt_docs = txt_loader.load()
    if txt_docs:
        print(f"Loaded {len(txt_docs)} .txt documents from {data_dir}")
        all_docs.extend(txt_docs)

    return all_docs


def resolve_target_collection(client: QdrantClient) -> tuple[str, bool]:
    """Decide which physical Qdrant collection to write into.

    Returns (collection_name, should_swap_alias_after_ingest).
    """
    if INGEST_INPLACE:
        return COLLECTION_ALIAS, False
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return f"{COLLECTION_BASE_NAME}_{stamp}", True


def swap_alias(client: QdrantClient, alias: str, new_collection: str) -> None:
    """Atomically point `alias` at `new_collection`.

    Qdrant's update_collection_aliases applies a list of ops atomically; deleting
    the old alias target (if any) and creating the new one in the same call makes
    the switchover zero-downtime for readers.
    """
    ops: list = [
        CreateAliasOperation(
            create_alias=CreateAlias(collection_name=new_collection, alias_name=alias)
        )
    ]
    # `update_collection_aliases` will replace an existing alias that points
    # elsewhere, so we do not need a separate delete_alias op here.
    client.update_collection_aliases(change_aliases_operations=ops)
    print(f"Alias '{alias}' now points to collection '{new_collection}'")


def write_metrics_row(row: dict) -> None:
    if not METRICS_CSV_PATH:
        return
    path = Path(METRICS_CSV_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not path.exists()
    with path.open("a", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(row.keys()))
        if write_header:
            writer.writeheader()
        writer.writerow(row)


def main() -> None:
    start = perf_counter()
    if GCS_DATA_URI:
        print(f"Syncing dataset from {GCS_DATA_URI} into {DATA_DIR}")
        download_gcs_prefix_to_dir(GCS_DATA_URI, DATA_DIR)
    print(f"Starting ingestion from DATA_DIR={DATA_DIR}")

    docs = load_documents(DATA_DIR)
    if not docs:
        raise RuntimeError(f"No .pdf/.txt documents found in dataset directory: {DATA_DIR}")
    if MAX_DOCS > 0:
        docs = docs[:MAX_DOCS]
        print(f"MAX_DOCS is set, limiting loaded documents to {len(docs)}")
    else:
        print(f"Loaded {len(docs)} total documents/pages")

    splitter = RecursiveCharacterTextSplitter(chunk_size=CHUNK_SIZE, chunk_overlap=CHUNK_OVERLAP)
    chunks = splitter.split_documents(docs)
    if not chunks:
        raise RuntimeError("No chunks created from loaded documents")
    print(f"Created {len(chunks)} chunks (chunk_size={CHUNK_SIZE}, overlap={CHUNK_OVERLAP})")

    embed_start = perf_counter()
    embeddings = HuggingFaceEmbeddings(model_name=EMBEDDING_MODEL)
    print(f"Embedding model ready: {EMBEDDING_MODEL}")

    first_vector = embeddings.embed_documents([chunks[0].page_content])[0]
    vector_size = len(first_vector)

    client = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)
    target_collection, swap_after = resolve_target_collection(client)

    if not client.collection_exists(target_collection):
        client.create_collection(
            collection_name=target_collection,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        print(f"Created collection '{target_collection}' with vector_size={vector_size}")
    else:
        print(f"Using existing collection '{target_collection}'")

    total_points = 0
    chunk_batches = iter_batches(chunks, BATCH_SIZE)
    print(f"Embedding/upserting in {len(chunk_batches)} batches (batch_size={BATCH_SIZE})")
    for batch_index, chunk_batch in enumerate(chunk_batches, start=1):
        batch_vectors = embeddings.embed_documents([chunk.page_content for chunk in chunk_batch])
        points: list[PointStruct] = []
        for local_idx, (chunk, vector) in enumerate(zip(chunk_batch, batch_vectors, strict=True)):
            global_idx = (batch_index - 1) * BATCH_SIZE + local_idx
            source = str(chunk.metadata.get("source", "unknown"))
            page = chunk.metadata.get("page")
            point_id = stable_point_id(f"{source}:{global_idx}:{chunk.page_content[:64]}")
            payload = {
                "text": chunk.page_content,
                "source": source,
                "chunk_index": global_idx,
            }
            if page is not None:
                payload["page"] = page
            points.append(PointStruct(id=point_id, vector=vector, payload=payload))
        client.upsert(collection_name=target_collection, points=points, wait=True)
        total_points += len(points)
        print(
            f"Batch {batch_index}/{len(chunk_batches)} upserted "
            f"{len(points)} chunks (total={total_points})"
        )

    embed_seconds = perf_counter() - embed_start

    swap_seconds = 0.0
    if swap_after:
        swap_start = perf_counter()
        swap_alias(client, COLLECTION_ALIAS, target_collection)
        swap_seconds = perf_counter() - swap_start

    elapsed = perf_counter() - start
    print(
        f"Ingested {total_points} chunks into '{target_collection}' "
        f"(alias='{COLLECTION_ALIAS}' swap_after={swap_after}, swap_s={swap_seconds:.3f}) "
        f"in {elapsed:.1f}s."
    )

    write_metrics_row(
        {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "data_dir": str(DATA_DIR),
            "documents_or_pages": len(docs),
            "chunks": len(chunks),
            "points_upserted": total_points,
            "chunk_size": CHUNK_SIZE,
            "chunk_overlap": CHUNK_OVERLAP,
            "batch_size": BATCH_SIZE,
            "embedding_model": EMBEDDING_MODEL,
            "target_collection": target_collection,
            "alias_swapped": swap_after,
            "embed_and_upsert_seconds": round(embed_seconds, 3),
            "alias_swap_seconds": round(swap_seconds, 3),
            "total_seconds": round(elapsed, 3),
        }
    )


if __name__ == "__main__":
    main()
