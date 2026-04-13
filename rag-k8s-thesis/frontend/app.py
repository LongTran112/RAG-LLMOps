import os
from typing import Any

import requests
import streamlit as st
from langchain_core.runnables import RunnableLambda

BACKEND_URL = os.getenv("RAG_BACKEND_URL", "http://127.0.0.1:8000")


def call_rag_backend(question: str) -> dict[str, Any]:
    response = requests.post(
        f"{BACKEND_URL}/query",
        json={"query": question},
        timeout=600,
    )
    response.raise_for_status()
    return response.json()


rag_chain = RunnableLambda(call_rag_backend)

st.set_page_config(page_title="RAG Thesis Tester", page_icon=":robot_face:", layout="wide")
st.title("RAG Thesis Frontend Tester")
st.caption("LangChain-powered UI for querying your FastAPI RAG backend.")
st.code(f"Backend: {BACKEND_URL}", language="text")

query = st.text_area(
    "Ask a question",
    value="What is this thesis PoC about?",
    height=120,
)

if st.button("Run Query", type="primary"):
    if not query.strip():
        st.warning("Please enter a question.")
    else:
        with st.spinner("Querying RAG backend..."):
            try:
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
