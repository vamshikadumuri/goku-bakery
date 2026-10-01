# Minimal vLLM image for A100 (sm_80) | driver 580.x / CUDA 13.0 | OCP 4.18
# Expected size: ~4.2 GB compressed (registry), ~8.5 GB uncompressed
#   (measured from the resolved vllm==0.30.0 wheel set: 3.89 GB / 7.98 GB)
#
# Why it's small: slim CUDA *base* image + pip wheels (torch bundles
# cuBLAS/cuDNN/NCCL), all installed and cleaned in ONE layer.
# Dropped vs upstream vllm-openai: system nvcc/-dev pkgs, FlashInfer JIT cache,
# DeepEP, DeepGEMM, gdrcopy, CRIU - none are used on Ampere.
#
# Defaults pull from public Docker Hub / PyPI. Behind a corporate proxy,
# override BASE_IMAGE / PIP_INDEX / PIP_TRUSTED_HOST and drop any extra CA
# certs (*.crt) into ./certs before building.

# CUDA 13.0 matches the node's driver 580.126.20 exactly.
ARG BASE_IMAGE=nvidia/cuda:13.0.3-base-ubuntu24.04
FROM ${BASE_IMAGE}

ARG VLLM_VERSION=0.30.0
ARG PIP_INDEX=https://pypi.org/simple
ARG PIP_TRUSTED_HOST=pypi.org

LABEL maintainer="ADA AMLP Team" \
      description="Minimal hardened vLLM OpenAI server for red-team attacker LLM inference" \
      vllm-version="${VLLM_VERSION}" \
      cuda-version="13.0" \
      target-gpu="A100 sm_80" \
      org.opencontainers.image.source="https://github.com/vamshikadumuri/goku-bakery"

# VLLM_USE_FLASHINFER_SAMPLER=0: FlashInfer's sampler JIT-compiles CUDA on the
# first request (needs nvcc); off -> vLLM's PyTorch/Triton sampler. Attention on
# sm_80 already defaults to FLASH_ATTN (precompiled, bundled in the vllm wheel).
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Singapore \
    PIP_INDEX_URL=${PIP_INDEX} \
    PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST} \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:${PATH} \
    HOME=/home/vllm \
    HF_HOME=/models/.cache/huggingface \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    VLLM_USE_FLASHINFER_SAMPLER=0 \
    VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1

# Optional extra CAs: ADD them to the trust store (don't overwrite ca-certificates.crt)
COPY certs/ /usr/local/share/ca-certificates/extra/

# ONE layer: CVE patching + runtime deps + vLLM + cleanup.
# gcc/libc6-dev/python3-dev are REQUIRED: Triton compiles a small C launcher
# at runtime (triton/runtime/build.py) and fails without a C compiler + Python.h.
RUN set -eux; \
    rm -f /usr/local/share/ca-certificates/extra/.gitkeep; \
    update-ca-certificates; \
    # nothing is installed from NVIDIA's apt repo; drop it so apt never
    # needs developer.download.nvidia.com and upgrade won't touch CUDA pkgs
    rm -f /etc/apt/sources.list.d/cuda*.list; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        ca-certificates tzdata libnuma1 \
        python3 python3-venv python3-dev gcc libc6-dev; \
    update-ca-certificates; \
    python3 -m venv "${VIRTUAL_ENV}"; \
    pip install --no-compile --upgrade pip; \
    pip install --no-compile "vllm==${VLLM_VERSION}"; \
    find "${VIRTUAL_ENV}" -name "*.a" -delete; \
    find "${VIRTUAL_ENV}" -type d -name "__pycache__" -prune -exec rm -rf {} +; \
    mkdir -p /home/vllm /models; \
    python -c "import torch, vllm; print('torch', torch.__version__, 'cuda', torch.version.cuda, 'vllm', vllm.__version__)"; \
    # OpenShift arbitrary UID: group 0 owns every writable dir
    chgrp -R 0 /home/vllm /models; \
    chmod -R g=u /home/vllm /models; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

USER 1001
WORKDIR /home/vllm
EXPOSE 8000
ENTRYPOINT ["vllm", "serve"]
