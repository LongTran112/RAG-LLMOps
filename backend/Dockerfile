ARG BASE_IMAGE=rag-base:latest
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
# Match Cloud Run's --concurrency=8 default so the GKE vs Cloud Run RPS
# comparison is fair at the web-server layer. Overridable per deployment.
ENV WEB_CONCURRENCY=8

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app /app/app

EXPOSE 8000

# --workers honors $WEB_CONCURRENCY via uvicorn's default argparse; we pass
# the flag explicitly so the intent is obvious in `docker inspect`.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${WEB_CONCURRENCY:-8}"]
