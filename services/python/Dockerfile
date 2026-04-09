ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim

ARG DEBIAN_FRONTEND=noninteractive

# ── Common tools ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# ── Common Python packages ──
RUN pip install --no-cache-dir gunicorn uvicorn

WORKDIR /var/www/html

EXPOSE 8000

# PYTHON_COMMAND can be overridden at runtime via environment variable
CMD ["sh", "-c", "exec ${PYTHON_COMMAND:-python -m http.server 8000}"]
