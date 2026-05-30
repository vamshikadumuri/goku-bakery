#!/usr/bin/env bash
# Build and push the PyRIT datasets Docker image to GHCR.
#
# Usage:
#   bash build_datasets.sh [github_username]
#
# Requires: docker login ghcr.io -u <username> --password-stdin <<< "$GITHUB_TOKEN"

set -euo pipefail

GITHUB_USERNAME="${1:-vamshikadumuri}"
IMAGE_NAME="mlbakery"
TAG="pyrit-datasets"
FULL_IMAGE="ghcr.io/${GITHUB_USERNAME}/${IMAGE_NAME}:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Image: ${FULL_IMAGE}"

# ── Authenticate ────────────────────────────────────────────────────────────
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[WARN] GITHUB_TOKEN not set. Login manually before pushing:"
    echo "       echo \$GITHUB_TOKEN | docker login ghcr.io -u ${GITHUB_USERNAME} --password-stdin"
else
    echo "==> Logging into ghcr.io"
    echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_USERNAME}" --password-stdin
fi

# ── Build ───────────────────────────────────────────────────────────────────
echo "==> Building image (this will download all datasets — may take a while)"
DOCKER_BUILDKIT=1 docker build \
    --progress=plain \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "${FULL_IMAGE}" \
    "${SCRIPT_DIR}"

echo "==> Build complete: ${FULL_IMAGE}"

# ── Push ────────────────────────────────────────────────────────────────────
echo "==> Pushing to GHCR"
docker push "${FULL_IMAGE}"

echo ""
echo "Done!"
echo "  Image : ${FULL_IMAGE}"
echo "  Pull  : docker pull ${FULL_IMAGE}"
echo "  Run   : docker run --rm ${FULL_IMAGE}"
