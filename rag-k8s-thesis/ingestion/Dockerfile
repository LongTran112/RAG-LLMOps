ARG BASE_IMAGE=rag-base:latest
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY ingest_data.py /app/ingest_data.py
# Dataset is NOT baked into the image; it is mounted at runtime from GCS
# or a PVC (see helm/rag-k8s-thesis/templates/ingestion.yaml).

CMD ["python", "ingest_data.py"]
