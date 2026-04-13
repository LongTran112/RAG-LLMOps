from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.config import settings
from app.rag_pipeline import RagPipeline

app = FastAPI(title=settings.app_name)
pipeline = RagPipeline()


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
