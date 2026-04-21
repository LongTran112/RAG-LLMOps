FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/base-requirements.txt
# CPU-only torch wheel first (keeps image small; GPU inference is served by Ollama, not Python).
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch \
    && pip install -r /tmp/base-requirements.txt
