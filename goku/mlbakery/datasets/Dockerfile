FROM python:3.11-slim

LABEL org.opencontainers.image.title="mlbakery:pyrit-datasets" \
      org.opencontainers.image.description="PyRIT safety & red-teaming datasets baked in" \
      org.opencontainers.image.source="https://github.com/vamshikadumuri/goku-bakery"

# System deps: git for sparse-clone, curl for healthchecks
RUN apt-get update && \
    apt-get install -y --no-install-recommends git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Python deps for dataset download
RUN pip install --no-cache-dir \
    datasets==2.21.0 \
    huggingface_hub>=0.24.0 \
    requests>=2.32.0 \
    pandas>=2.2.0 \
    pyarrow>=16.0.0

COPY download_datasets.py /download_datasets.py

# Optional HuggingFace token for gated datasets
ARG HF_TOKEN=""
ENV HF_TOKEN=${HF_TOKEN}

# Run all downloads at build time; failures are logged but don't abort build
RUN python /download_datasets.py || true

# Convenience: print manifest on start if run interactively
CMD ["python", "-c", \
     "import json,pathlib; m=pathlib.Path('/datasets/manifest.json'); \
      print(json.dumps(json.loads(m.read_text()), indent=2)) if m.exists() else print('No manifest found')"]
