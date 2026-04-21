import json
import os
from collections.abc import Iterator
from typing import Any

import requests
import streamlit as st

BACKEND_URL = os.getenv("RAG_BACKEND_URL", "http://127.0.0.1:8000").rstrip("/")
QUERY_TIMEOUT = int(os.getenv("RAG_QUERY_TIMEOUT_SECONDS", "900"))
STREAM_TIMEOUT = int(os.getenv("RAG_STREAM_TIMEOUT_SECONDS", "900"))


def call_rag_backend(question: str, answer_mode: str) -> dict[str, Any]:
    response = requests.post(
        f"{BACKEND_URL}/query",
        json={"query": question, "answer_mode": answer_mode},
        timeout=QUERY_TIMEOUT,
    )
    response.raise_for_status()
    return response.json()


def _parse_sse_line(line: str) -> dict[str, Any] | None:
    if not line.startswith("data: "):
        return None
    return json.loads(line[6:])


def stream_rag_tokens(question: str, answer_mode: str) -> Iterator[str]:
    with requests.post(
        f"{BACKEND_URL}/query/stream",
        json={"query": question, "answer_mode": answer_mode},
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
            if evt.get("type") == "thinking":
                t = evt.get("t") or ""
                if t:
                    st.session_state["rag_last_thinking"] = (
                        st.session_state.get("rag_last_thinking", "") + t
                    )
                continue
            if evt.get("type") == "token":
                t = evt.get("t") or ""
                if t:
                    yield t
            if evt.get("type") == "done":
                break


def render_sources(sources: list[dict[str, Any]]) -> None:
    if not sources:
        st.caption("No sources returned.")
        return
    with st.expander(f"Sources ({len(sources)})", expanded=False):
        for idx, source in enumerate(sources, start=1):
            metadata = source.get("metadata", {}) or {}
            preview = source.get("content_preview", "") or ""
            preview_line = " ".join(preview.strip().split())
            if len(preview_line) > 220:
                preview_line = preview_line[:220].rstrip()
            if not preview_line.endswith("..."):
                preview_line = f"{preview_line}..."
            source_path = str(metadata.get("source", "") or "")
            source_name = os.path.basename(source_path) if source_path else "Unknown source"
            st.markdown(f"**{idx}. {source_name}**")
            cols = st.columns(3)
            cols[0].caption(f"Page: {metadata.get('page', '-')}")
            cols[1].caption(f"Chunk: {metadata.get('chunk_index', '-')}")
            cols[2].caption(f"Score: {metadata.get('score', '-')}")
            st.markdown(f"> {preview_line}")
            st.divider()


def summarize_thinking(thinking: str, max_chars: int = 220) -> str:
    text = " ".join(thinking.strip().split())
    if not text:
        return ""
    if len(text) <= max_chars:
        return text
    return f"{text[:max_chars].rstrip()}..."


def render_thinking_collapsed(thinking: str) -> None:
    if not thinking.strip():
        return
    with st.expander("View full thinking", expanded=False):
        st.text(thinking)


def run_query(
    question: str, answer_mode: str, use_stream: bool
) -> tuple[str, list[dict[str, Any]], dict[str, Any] | None, str]:
    if use_stream:
        st.session_state.pop("rag_last_sources", None)
        st.session_state.pop("rag_last_thinking", None)
        chunks: list[str] = []
        for piece in stream_rag_tokens(question, answer_mode):
            chunks.append(piece)
            yield (
                "".join(chunks),
                st.session_state.get("rag_last_sources") or [],
                None,
                st.session_state.get("rag_last_thinking", ""),
            )
        return
    result = call_rag_backend(question, answer_mode)
    answer = result.get("answer", "No answer returned.")
    sources = result.get("sources", []) or []
    llm_meta = result.get("llm")
    yield (answer, sources, llm_meta, "")


st.set_page_config(page_title="RAG Thesis Tester", page_icon=":robot_face:", layout="wide")
st.title("RAG Thesis Chat")
st.caption("Chat-style interface for your FastAPI RAG backend.")
st.code(f"Backend: {BACKEND_URL}", language="text")

if "messages" not in st.session_state:
    st.session_state["messages"] = []

control_col1, control_col2 = st.columns([2, 1])
with control_col1:
    answer_profile = st.radio(
        "Mode",
        options=["Fast", "Complex"],
        horizontal=True,
        help=(
            "Fast uses deployed fast model (phi3/granite). "
            "Complex uses reasoning model (deepseek-r1:8b)."
        ),
    )
with control_col2:
    use_stream = st.toggle("Stream", value=True, help="Stream answer tokens like ChatGPT/Gemini.")

answer_mode = "complex" if answer_profile == "Complex" else "fast"

for message in st.session_state["messages"]:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])
        if message["role"] == "assistant":
            mode_label = "Complex" if message.get("answer_mode") == "complex" else "Fast"
            st.caption(f"Mode: {mode_label}")
            thinking = message.get("thinking", "")
            if thinking:
                render_thinking_collapsed(thinking)
            render_sources(message.get("sources", []))
            llm_meta = message.get("llm")
            if llm_meta:
                st.caption(
                    f"Model used: {llm_meta.get('model_used', '-')} | "
                    f"Fallback: {llm_meta.get('fallback', False)} | "
                    f"Attempts: {llm_meta.get('attempts', '-')}"
                )

if prompt := st.chat_input("Ask about the SEC filings dataset..."):
    st.session_state["messages"].append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        thinking_header = st.empty()
        thinking_placeholder = st.empty()
        answer_placeholder = st.empty()
        final_answer = ""
        final_sources: list[dict[str, Any]] = []
        final_llm_meta: dict[str, Any] | None = None
        final_thinking = ""
        try:
            with st.spinner("Thinking..."):
                for answer, sources, llm_meta, thinking in run_query(prompt, answer_mode, use_stream):
                    final_answer = answer
                    final_sources = sources
                    final_llm_meta = llm_meta
                    final_thinking = thinking
                    if answer_mode == "complex":
                        if final_answer:
                            # As soon as answer starts, collapse and gray out thinking.
                            thinking_header.empty()
                            with thinking_placeholder.container():
                                render_thinking_collapsed(final_thinking)
                        else:
                            thinking_header.caption("Thinking process (live)")
                            if final_thinking:
                                # Keep this readable during generation; show the most recent window.
                                thinking_placeholder.code(final_thinking[-3000:])
                            else:
                                thinking_placeholder.code("...")
                    if final_answer:
                        answer_placeholder.markdown(final_answer)
                    elif answer_mode != "complex":
                        answer_placeholder.markdown("...")
            render_sources(final_sources)
            mode_label = "Complex" if answer_mode == "complex" else "Fast"
            st.caption(f"Mode: {mode_label}")
            if final_llm_meta:
                st.caption(
                    f"Model used: {final_llm_meta.get('model_used', '-')} | "
                    f"Fallback: {final_llm_meta.get('fallback', False)} | "
                    f"Attempts: {final_llm_meta.get('attempts', '-')}"
                )
            st.session_state["messages"].append(
                {
                    "role": "assistant",
                    "content": final_answer or "No answer returned.",
                    "sources": final_sources,
                    "answer_mode": answer_mode,
                    "llm": final_llm_meta,
                    "thinking": final_thinking,
                }
            )
        except requests.HTTPError as exc:
            st.error(f"Backend HTTP error: {exc}")
            try:
                st.json(exc.response.json())
            except Exception:
                st.text(exc.response.text)
            st.session_state["messages"].append(
                {"role": "assistant", "content": f"Backend HTTP error: {exc}", "sources": [], "answer_mode": answer_mode}
            )
        except Exception as exc:  # noqa: BLE001
            st.error(f"Query failed: {exc}")
            st.session_state["messages"].append(
                {"role": "assistant", "content": f"Query failed: {exc}", "sources": [], "answer_mode": answer_mode}
            )
