# backend-go

Go implementation of the thesis RAG API using **Chi**, **Weaviate**, and **Ollama** (embeddings + generation).

## Prerequisites

- Go 1.24+ (matches `go.mod`)
- Running **Weaviate** (see repo root `docker-compose.yml`)
- Running **Ollama** with embedding + chat models pulled

Example models (adjust via env):

```bash
ollama pull all-minilm
ollama pull llama3
```

## Configuration (environment)

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_LISTEN_ADDR` | `:8000` | Bind address |
| `WEAVIATE_HOST` | `localhost:8080` | Weaviate host:port (**use `localhost:8090` with repo root `docker-compose.yml`**) |
| `WEAVIATE_SCHEME` | `http` | `http` or `https` |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama base URL |
| `EMBEDDING_MODEL` | `all-minilm` | Model name for `/api/embeddings` |
| `PRIMARY_MODEL` | `llama3` | Fast mode chat model |
| `REASONING_MODEL` | `deepseek-r1` | Complex mode model |
| `RETRIEVE_TOP_K` | `4` | Weaviate vector search limit |

On startup the server creates the Weaviate class **`DocumentChunk`** (vectorizer `none`) if missing.

Use **`cmd/ingest`** (below) to load `.pdf` / `.txt` from `DATA_DIR`, chunk them, embed via Ollama, and batch-write **`DocumentChunk`** objects with vectors.

## Run locally

```bash
cd backend-go
go mod tidy
go run ./cmd/server
```

### Ingest into Weaviate

Requirements: **Weaviate** up (same host/scheme as the server), **Ollama** running with **`EMBEDDING_MODEL`** pulled — must match what the API uses at query time (same vector dimension).

```bash
# From repo root (example): compose maps Weaviate to host port 8090
docker compose up -d weaviate

cd backend-go
export WEAVIATE_HOST=localhost:8090
export WEAVIATE_SCHEME=http
export OLLAMA_BASE_URL=http://localhost:11434
export EMBEDDING_MODEL=all-minilm
export DATA_DIR=/absolute/path/to/your/documents   # folder with .pdf and/or .txt

# Optional tuning
# export CHUNK_SIZE=800
# export CHUNK_OVERLAP=100
# export BATCH_WEAVIATE=32
# export MAX_FILES=50          # limit file count (0 = all)
# export EMBED_MAX_RUNES=512   # default; caps split size for Ollama (avoids "context length" errors). Use 0 to disable.

go run ./cmd/ingest
```

Ollama’s embedding endpoint uses the model’s **context window** (often much smaller in tokens than a large `CHUNK_SIZE` in characters). Ingest uses **`splitSize = min(CHUNK_SIZE, EMBED_MAX_RUNES)`** with **`EMBED_MAX_RUNES` default `512`**. If you still see context errors, lower **`EMBED_MAX_RUNES`** (e.g. `256`). To retry a failed run from scratch, delete the **`DocumentChunk`** objects or drop the class in Weaviate before re-running ingest.

PDF text extraction uses **`github.com/ledongthuc/pdf`** (simple extraction; some SEC PDFs may be noisy). After ingest, **`POST /retrieve`** should return non-empty **`sources`** for matching queries.

**Common mistakes**

- **`WEAVIATE_HOST`** must be `hostname:port` only (example: `localhost:8090`). Do **not** include `http://` — use `WEAVIATE_SCHEME=http` separately.
- **Repo `docker-compose.yml` maps Weaviate to host port `8090`** (`8090:8080`) so it does not fight with whatever already listens on **`8080`** on your machine. After compose is up, point the backend at it:
  ```bash
  export WEAVIATE_HOST=localhost:8090
  go run ./cmd/server
  ```
  Quick check: `curl -s http://localhost:8090/v1/meta | head` — expect JSON (not `404 page not found`).
- If compose prints **`Bind for 0.0.0.0:8090 failed`**, pick another free host port in `docker-compose.yml` and set `WEAVIATE_HOST` to match.
- **Weaviate must be running** before the server starts. From repo root:  
  `docker compose up -d weaviate`
- **Go**: build all packages with three dots — `go build ./...` (not `./..`).
- **Docker**: pass the build context — `docker build -t rag-backend-go .` (run inside `backend-go`, or pass the folder path).

## Endpoints

- `GET /healthz`
- `POST /query` — JSON `{ "query": "...", "answer_mode": "fast"|"complex" }`
- `POST /retrieve` — retrieval only (no LLM)
- `POST /query/stream` — SSE (`event:` + `data:`), emits `sources`, `token`, optional `timing`, then handler sends `done`

## Docker

```bash
docker build -t rag-backend-go:latest ./backend-go
```
