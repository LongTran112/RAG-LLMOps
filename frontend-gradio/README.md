# frontend-gradio

Gradio chat frontend for the thesis RAG backend.

## Features

- Fast / Complex mode toggle
- Streaming from backend `/query/stream`
- Live thinking display (grayscale style)
- Normal answer rendering
- Source citations (file name only)

## Run locally

```bash
cd frontend-gradio
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export RAG_BACKEND_URL="http://127.0.0.1:8000"
python app.py
```

Open `http://127.0.0.1:7860`.
