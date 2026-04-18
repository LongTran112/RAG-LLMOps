import asyncio
from contextlib import asynccontextmanager

from app.config import settings
from app.rag_pipeline import QdrantUnavailableError, RagPipeline
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

pipeline = RagPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.warmup_llm_on_startup:
        await asyncio.to_thread(pipeline.warmup_llm)
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)


class QueryRequest(BaseModel):
    query: str = Field(min_length=3, max_length=4000)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/query")
def query_rag(payload: QueryRequest) -> dict:
    try:
        return pipeline.query(payload.query)
    except QdrantUnavailableError as exc:
        raise HTTPException(status_code=503, detail=f"Qdrant unavailable: {exc}") from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Query failed: {exc}") from exc


@app.post("/retrieve")
def retrieve_only(payload: QueryRequest) -> dict:
    """Run only the embedding + Qdrant search steps (no LLM call).

    Thesis benchmarks use this to isolate vector-DB latency from generation
    latency. Response shape matches /query's `sources` + `timing_ms` keys so
    downstream tooling can share parsers.
    """
    try:
        return pipeline.retrieve_only(payload.query)
    except QdrantUnavailableError as exc:
        raise HTTPException(status_code=503, detail=f"Qdrant unavailable: {exc}") from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Retrieve failed: {exc}") from exc


@app.post("/query/stream")
def query_rag_stream(payload: QueryRequest) -> StreamingResponse:
    def event_iter():
        yield from pipeline.stream_query_sse(payload.query)

    return StreamingResponse(
        event_iter(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
