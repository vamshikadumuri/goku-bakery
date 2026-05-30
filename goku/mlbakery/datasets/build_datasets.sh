#!/usr/bin/env bash
# Build and push the PyRIT datasets Docker image to GHCR.
#
# Usage:
#   bash build_datasets.sh [github_username]
#
# Requires: echo $GITHUB_TOKEN | docker login ghcr.io -u <username> --password-stdin

set -euo pipefail

GITHUB_USERNAME="${1:-vamshikadumuri}"
IMAGE_NAME="mlbakery"
TAG="pyrit-datasets"
FULL_IMAGE="ghcr.io/${GITHUB_USERNAME}/${IMAGE_NAME}:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Image: ${FULL_IMAGE}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[WARN] GITHUB_TOKEN not set. Login manually before pushing:"
    echo "       echo \$GITHUB_TOKEN | docker login ghcr.io -u ${GITHUB_USERNAME} --password-stdin"
else
    echo "==> Logging into ghcr.io"
    echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${GITHUB_USERNAME}" --password-stdin
fi

echo "==> Building image"
DOCKER_BUILDKIT=1 docker build \
    --progress=plain \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "${FULL_IMAGE}" \
    "${SCRIPT_DIR}"

echo "==> Pushing to GHCR"
docker push "${FULL_IMAGE}"

echo ""
echo "Done: ${FULL_IMAGE}"
