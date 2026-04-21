import json
import os
from collections.abc import Generator
from pathlib import Path
from typing import Any

import gradio as gr
import requests

BACKEND_URL = os.getenv("RAG_BACKEND_URL", "http://127.0.0.1:8000").rstrip("/")
QUERY_TIMEOUT = int(os.getenv("RAG_QUERY_TIMEOUT_SECONDS", "900"))
STREAM_TIMEOUT = int(os.getenv("RAG_STREAM_TIMEOUT_SECONDS", "900"))


def _source_filename(source_path: str | None) -> str:
    if not source_path:
        return "Unknown source"
    return Path(source_path).name


def _render_response(answer: str, thinking: str, sources: list[dict[str, Any]], *, done: bool) -> str:
    parts: list[str] = []

    if thinking:
        if done:
            parts.append(f"<details><summary>View full thinking</summary><pre>{thinking}</pre></details>")
        else:
            tail = thinking[-3500:]
            parts.append("<div style='opacity:0.65'><b>Thinking (live)</b></div>")
            parts.append(f"<pre>{tail}</pre>")

    if answer:
        parts.append(answer)
    elif not done:
        parts.append("...")

    if done and sources:
        source_blocks: list[str] = []
        for idx, source in enumerate(sources, start=1):
            meta = source.get("metadata", {}) or {}
            name = _source_filename(meta.get("source"))
            page = meta.get("page", "-")
            chunk = meta.get("chunk_index", "-")
            score = meta.get("score", "-")
            preview = source.get("content_preview", "") or ""
            preview_line = " ".join(preview.strip().split())
            if len(preview_line) > 220:
                preview_line = preview_line[:220].rstrip()
            if not preview_line.endswith("..."):
                preview_line = f"{preview_line}..."
            source_blocks.append(
                (
                    "<div style='margin:8px 0; padding:8px; border:1px solid #3a3a3a; border-radius:8px;'>"
                    f"<div><b>{idx}. {name}</b></div>"
                    f"<div style='opacity:0.75; font-size:0.9em;'>Page: {page} | Chunk: {chunk} | Score: {score}</div>"
                    f"<div style='margin-top:6px; white-space:normal; line-height:1.45;'>{preview_line}</div>"
                    "</div>"
                )
            )
        parts.append(
            (
                f"<details><summary><b>Sources ({len(sources)})</b></summary>"
                + "".join(source_blocks)
                + "</details>"
            )
        )

    return "\n\n".join(parts)


def _content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                value = item.get("text") or item.get("content") or ""
                if isinstance(value, str):
                    parts.append(value)
        return "\n".join(p for p in parts if p)
    return ""


def _add_user_message(
    message: str, history: list[dict[str, str]]
) -> tuple[str, list[dict[str, str]]]:
    message = message.strip()
    if not message:
        return "", history
    updated = history + [
        {"role": "user", "content": message},
        {"role": "assistant", "content": "..."},
    ]
    return "", updated


def _run_chat(
    history: list[dict[str, str]], mode_label: str, use_stream: bool
) -> Generator[list[dict[str, str]], None, None]:
    if not history:
        yield history
        return

    answer_mode = "complex" if mode_label == "Complex" else "fast"
    question = ""
    for msg in reversed(history):
        if msg.get("role") == "user":
            question = _content_to_text(msg.get("content")).strip()
            break
    if len(question) < 3:
        history[-1] = {
            "role": "assistant",
            "content": "Query must be at least 3 characters.",
        }
        yield history
        return

    answer = ""
    thinking = ""
    sources: list[dict[str, Any]] = []

    def push(done: bool = False) -> list[dict[str, str]]:
        rendered = _render_response(answer, thinking, sources, done=done)
        copied = list(history)
        copied[-1] = {"role": "assistant", "content": rendered}
        return copied

    if not use_stream:
        try:
            response = requests.post(
                f"{BACKEND_URL}/query",
                json={"query": question, "answer_mode": answer_mode},
                timeout=QUERY_TIMEOUT,
            )
            response.raise_for_status()
            payload = response.json()
            answer = payload.get("answer", "No answer returned.")
            sources = payload.get("sources", []) or []
            yield push(done=True)
            return
        except requests.HTTPError as exc:
            try:
                detail = exc.response.json()
            except Exception:
                detail = exc.response.text
            history[-1] = {
                "role": "assistant",
                "content": f"Backend HTTP error ({exc.response.status_code}): {detail}",
            }
            yield history
            return
        except Exception as exc:  # noqa: BLE001
            history[-1] = {"role": "assistant", "content": f"Query failed: {exc}"}
            yield history
            return

    try:
        with requests.post(
            f"{BACKEND_URL}/query/stream",
            json={"query": question, "answer_mode": answer_mode},
            stream=True,
            timeout=STREAM_TIMEOUT,
        ) as response:
            response.raise_for_status()
            for raw in response.iter_lines(decode_unicode=True):
                if not raw or not raw.startswith("data: "):
                    continue
                try:
                    evt = json.loads(raw[6:])
                except json.JSONDecodeError:
                    continue

                event_type = evt.get("type")
                if event_type == "sources":
                    sources = evt.get("sources", []) or []
                elif event_type == "thinking":
                    thinking += evt.get("t", "") or ""
                elif event_type == "token":
                    answer += evt.get("t", "") or ""
                elif event_type == "error":
                    history[-1] = {
                        "role": "assistant",
                        "content": f"Streaming error: {evt.get('message', 'unknown')}",
                    }
                    yield history
                    return
                elif event_type == "done":
                    yield push(done=True)
                    return

                yield push(done=False)
    except requests.HTTPError as exc:
        try:
            detail = exc.response.json()
        except Exception:
            detail = exc.response.text
        history[-1] = {
            "role": "assistant",
            "content": f"Backend HTTP error ({exc.response.status_code}): {detail}",
        }
        yield history
    except Exception as exc:  # noqa: BLE001
        history[-1] = {"role": "assistant", "content": f"Query failed: {exc}"}
        yield history


with gr.Blocks(title="RAG Thesis Chat (Gradio)") as demo:
    gr.Markdown("# RAG Thesis Chat (Gradio)")
    gr.Markdown(
        "Fast/Complex modes with streaming thinking, normal answer rendering, and source citations."
    )
    gr.Markdown(f"`Backend: {BACKEND_URL}`")

    with gr.Row():
        mode = gr.Radio(["Fast", "Complex"], value="Fast", label="Mode")
        stream = gr.Checkbox(value=True, label="Stream")

    chatbot = gr.Chatbot(height=560, label="Chat")
    msg = gr.Textbox(label="Ask a question", placeholder="Ask about the SEC filings dataset...")

    msg.submit(
        _add_user_message,
        inputs=[msg, chatbot],
        outputs=[msg, chatbot],
        queue=False,
    ).then(
        _run_chat,
        inputs=[chatbot, mode, stream],
        outputs=[chatbot],
    )


if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=7860)
