import asyncio
from contextlib import asynccontextmanager

from app.config import settings
from app.rag_pipeline import QdrantUnavailableError, RagPipeline
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from prometheus_client import Gauge
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, Field

pipeline = RagPipeline()

# Queue-depth gauge: answers the thesis question "how does the system queue
# when 100 users request an answer at the exact same time?". Ollama serializes
# generation, so under 100 concurrent VUs most requests sit in this counter
# waiting. Scraped by Prometheus (GKE) / Cloud Monitoring sidecar (Cloud Run)
# via the /metrics endpoint set up below.
IN_FLIGHT = Gauge(
    "rag_inflight_requests",
    "Requests currently executing the RAG pipeline.",
    ["endpoint"],
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.warmup_llm_on_startup:
        await asyncio.to_thread(pipeline.warmup_llm)
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)


@app.middleware("http")
async def track_inflight(request: Request, call_next):
    # Only count the RAG endpoints; /healthz and /metrics should not pollute
    # the queue-depth signal we report in the thesis.
    path = request.url.path
    if path in {"/query", "/query/stream", "/retrieve"}:
        IN_FLIGHT.labels(endpoint=path).inc()
        try:
            return await call_next(request)
        finally:
            IN_FLIGHT.labels(endpoint=path).dec()
    return await call_next(request)


# Standard HTTP histograms (http_request_duration_seconds,
# http_requests_total, ...) + our custom gauges exposed at /metrics.
Instrumentator(
    should_group_status_codes=False,
    excluded_handlers=["/metrics", "/healthz"],
).instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


class QueryRequest(BaseModel):
    query: str = Field(min_length=3, max_length=4000)
    # "fast" -> configured primary model (granite/phi3 depending on deploy).
    # "complex" -> reasoning model (deepseek-r1:8b by default).
    answer_mode: str = Field(default="fast", pattern="^(fast|complex)$")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/query")
def query_rag(payload: QueryRequest) -> dict:
    try:
        return pipeline.query(payload.query, answer_mode=payload.answer_mode)
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
        yield from pipeline.stream_query_sse(payload.query, answer_mode=payload.answer_mode)

    return StreamingResponse(
        event_iter(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
