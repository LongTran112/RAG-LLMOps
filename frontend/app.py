import json
import os
from collections.abc import Iterator
from typing import Any

import requests
import streamlit as st
from langchain_core.runnables import RunnableLambda

BACKEND_URL = os.getenv("RAG_BACKEND_URL", "http://127.0.0.1:8000").rstrip("/")
QUERY_TIMEOUT = int(os.getenv("RAG_QUERY_TIMEOUT_SECONDS", "900"))
STREAM_TIMEOUT = int(os.getenv("RAG_STREAM_TIMEOUT_SECONDS", "900"))


def call_rag_backend(question: str) -> dict[str, Any]:
    response = requests.post(
        f"{BACKEND_URL}/query",
        json={"query": question},
        timeout=QUERY_TIMEOUT,
    )
    response.raise_for_status()
    return response.json()


def _parse_sse_line(line: str) -> dict[str, Any] | None:
    if not line.startswith("data: "):
        return None
    return json.loads(line[6:])


def stream_rag_tokens(question: str) -> Iterator[str]:
    with requests.post(
        f"{BACKEND_URL}/query/stream",
        json={"query": question},
        stream=True,
        timeout=STREAM_TIMEOUT,
    ) as response:
        response.raise_for_status()
        for raw in response.iter_lines(decode_unicode=True):
            if not raw:
                continue
            evt = _parse_sse_line(raw)
            if not evt:
                continue
            if evt.get("type") == "sources":
                st.session_state["rag_last_sources"] = evt.get("sources", [])
                continue
            if evt.get("type") == "token":
                t = evt.get("t") or ""
                if t:
                    yield t
            if evt.get("type") == "done":
                break


rag_chain = RunnableLambda(call_rag_backend)

st.set_page_config(page_title="RAG Thesis Tester", page_icon=":robot_face:", layout="wide")
st.title("RAG Thesis Frontend Tester")
st.caption("LangChain-powered UI for querying your FastAPI RAG backend.")
st.code(f"Backend: {BACKEND_URL}", language="text")

use_stream = st.checkbox(
    "Stream answer (recommended for interactive use)",
    value=True,
    help="Shows tokens as they arrive from Ollama for lower perceived latency.",
)

query = st.text_area(
    "Ask a question",
    value="What is this thesis PoC about?",
    height=120,
)

if st.button("Run Query", type="primary"):
    if not query.strip():
        st.warning("Please enter a question.")
    else:
        try:
            if use_stream:
                st.session_state.pop("rag_last_sources", None)
                st.caption("Streaming answer from the backend (first tokens may take a moment on CPU).")
                st.subheader("Answer")
                if hasattr(st, "write_stream"):
                    st.write_stream(stream_rag_tokens(query))
                else:
                    buf: list[str] = []
                    for piece in stream_rag_tokens(query):
                        buf.append(piece)
                    st.write("".join(buf))
                sources = st.session_state.get("rag_last_sources") or []
                st.subheader("Sources")
                if not sources:
                    st.info("No sources were returned.")
                else:
                    for idx, source in enumerate(sources, start=1):
                        st.markdown(f"**Source {idx}**")
                        st.write(source.get("content_preview", ""))
                        st.json(source.get("metadata", {}))
            else:
                with st.spinner("Querying RAG backend..."):
                    result = rag_chain.invoke(query)
                st.subheader("Answer")
                st.write(result.get("answer", "No answer returned."))
                st.subheader("Sources")
                sources = result.get("sources", [])
                if not sources:
                    st.info("No sources were returned.")
                else:
                    for idx, source in enumerate(sources, start=1):
                        st.markdown(f"**Source {idx}**")
                        st.write(source.get("content_preview", ""))
                        st.json(source.get("metadata", {}))
        except requests.HTTPError as exc:
            st.error(f"Backend returned HTTP error: {exc}")
            try:
                st.json(exc.response.json())
            except Exception:
                st.text(exc.response.text)
        except Exception as exc:  # noqa: BLE001
            st.error(f"Query failed: {exc}")
