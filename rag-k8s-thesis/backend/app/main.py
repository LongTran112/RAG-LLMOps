from contextlib import asynccontextmanager

import asyncio

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from app.config import settings
from app.rag_pipeline import RagPipeline


pipeline = RagPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.warmup_ollama_on_startup:
        await asyncio.to_thread(pipeline.warmup_ollama)
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
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"Query failed: {exc}") from exc


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
