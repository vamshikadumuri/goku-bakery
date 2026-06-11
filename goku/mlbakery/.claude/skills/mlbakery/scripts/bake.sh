#!/bin/bash
# bake.sh — Universal MLBakery script
# Uses huggingface_hub Python API directly (no huggingface-cli dependency).
# For safetensors models: one shard = one image.
# For ONNX models (no .safetensors): full repo download into a single image.

set +e

# ── Defaults ──────────────────────────────────────────────
MODEL_REPO=""
TAG_PREFIX=""
START_SHARD=1
GHCR_USER="vamshikadumuri"
IMAGE_NAME="ghcr.io/${GHCR_USER}/mlbakery"
EXCLUDE_PATTERNS=""
VENV_PYTHON=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

print_usage() {
  echo "Usage: $0 -m MODEL_REPO [OPTIONS]"
  echo "  -m MODEL_REPO   HF model repo [required]"
  echo "  -t TAG_PREFIX   Image tag prefix (default: derived from repo name)"
  echo "  -s START_SHARD  Resume from shard N (default: 1)"
  echo "  -u GHCR_USER    GHCR username (default: vamshikadumuri)"
  echo "  -e EXCLUDE      Comma-separated exclude patterns"
  echo "  -v VENV_NAME    Venv dir name inside project dir"
  echo "  -h              Help"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -m) MODEL_REPO="$2"; shift 2 ;;
    -t) TAG_PREFIX="$2"; shift 2 ;;
    -s) START_SHARD="$2"; shift 2 ;;
    -u) GHCR_USER="$2"; IMAGE_NAME="ghcr.io/${GHCR_USER}/mlbakery"; shift 2 ;;
    -e) EXCLUDE_PATTERNS="$2"; shift 2 ;;
    -v) VENV_PYTHON="$PROJECT_DIR/$2/bin/python3"; shift 2 ;;
    -h) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done

if [[ -z "$MODEL_REPO" ]]; then
  echo "Error: -m MODEL_REPO is required."
  print_usage
  exit 1
fi

if [[ -z "$TAG_PREFIX" ]]; then
  TAG_PREFIX=$(echo "$MODEL_REPO" | tr '/' '-')
fi

MODEL_NAME=$(basename "$MODEL_REPO")
WORK_DIR="$(pwd)/temp_$(date +%Y%m%d)_${MODEL_NAME}"
MODEL_DIR="$WORK_DIR/models/$MODEL_NAME"

# Resolve python interpreter (venv wrapper created by workflow, or system python3)
if [[ -z "$VENV_PYTHON" ]]; then
  VENV_PYTHON="$PROJECT_DIR/mymlbakeryenv/bin/python3"
fi
if [[ ! -x "$VENV_PYTHON" ]]; then
  VENV_PYTHON="python3"
fi
echo "🐍 Python: $VENV_PYTHON ($($VENV_PYTHON --version 2>&1))"

# ── Helpers ───────────────────────────────────────────────

perm_rm() {
  for target in "$@"; do
    [[ -d "$target" ]] && { find "$target" -type f -exec rm -f {} +; rm -rf "$target"; } || rm -f "$target"
  done
}

hf_download_repo() {
  # Download entire repo (or with ignore patterns) using Python API
  local REPO="$1" LOCAL_DIR="$2" IGNORE="$3"
  REPO="$REPO" LOCAL_DIR="$LOCAL_DIR" IGNORE="$IGNORE" \
  $VENV_PYTHON - <<'PYEOF'
import os, sys
from huggingface_hub import snapshot_download
repo      = os.environ['REPO']
local_dir = os.environ['LOCAL_DIR']
ignore    = [p.strip() for p in os.environ['IGNORE'].split(',') if p.strip()] or None
print(f'  Downloading repo {repo} -> {local_dir}' + (f'  (ignoring {ignore})' if ignore else ''))
snapshot_download(repo, local_dir=local_dir, ignore_patterns=ignore)
print('  Download complete')
PYEOF
}

hf_download_file() {
  # Download a single file from a repo using Python API
  local REPO="$1" FILENAME="$2" LOCAL_DIR="$3"
  REPO="$REPO" FILENAME="$FILENAME" LOCAL_DIR="$LOCAL_DIR" \
  $VENV_PYTHON - <<'PYEOF'
import os
from huggingface_hub import hf_hub_download
repo      = os.environ['REPO']
filename  = os.environ['FILENAME']
local_dir = os.environ['LOCAL_DIR']
print(f'  Downloading {filename}')
hf_hub_download(repo, filename=filename, local_dir=local_dir)
print('  Download complete')
PYEOF
}

verify_image_contents() {
  local IMAGE_TAG=$1 SHARD_DIR=$2
  echo "   🔍 Verifying image contents..."
  EXPECTED=$(cd "$SHARD_DIR" && find models/ -type f | sort)
  VERIFY_OUTPUT=$(docker run --rm "$IMAGE_TAG" sh -c 'find /models/ -type f | sort; echo "===SEP==="; du -sh /models/' 2>/dev/null)
  [[ -z "$VERIFY_OUTPUT" ]] && { echo "   ❌ Verification FAILED: could not read image"; return 1; }
  ACTUAL=$(echo "$VERIFY_OUTPUT" | sed '/===SEP===/,$d' | sed 's|^/||')
  IMAGE_SIZE=$(echo "$VERIFY_OUTPUT" | sed -n '/===SEP===/,$ p' | tail -1 | cut -f1)
  [[ -z "$ACTUAL" ]] && { echo "   ❌ Verification FAILED: no files in image"; return 1; }
  DIFF=$(diff <(echo "$EXPECTED") <(echo "$ACTUAL"))
  if [[ -n "$DIFF" ]]; then
    echo "   ❌ Verification FAILED: contents mismatch"
    echo "$DIFF" | head -20
    return 1
  fi
  echo "   ✅ Verified: $(echo "$ACTUAL" | wc -l) files, ${IMAGE_SIZE} in /models/"
  return 0
}

DOCKERFILE='FROM ubuntu:latest
RUN apt-get update && apt-get install -y g++
RUN apt-get install -y python3 python3-pip git htop
WORKDIR /models
COPY models/ /models/
WORKDIR /datasets
COPY datasets/ /datasets/
'

if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker not available"; exit 1
fi
echo "🐳 Docker: OK"

build_and_push_shard() {
  local SHARD_NUM=$1 TAG=$2 SHARD_DIR=$3
  echo "   🔨 Building ${IMAGE_NAME}:${TAG}..."
  if ! docker build -t "${IMAGE_NAME}:${TAG}" "$SHARD_DIR"; then
    echo "   ❌ Build FAILED"; return 1
  fi
  if ! verify_image_contents "${IMAGE_NAME}:${TAG}" "$SHARD_DIR"; then
    echo "   ❌ Verification FAILED, not pushing"
    docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true; return 1
  fi
  echo "   🚀 Pushing ${IMAGE_NAME}:${TAG}..."
  local PUSH_OK=false
  for attempt in 1 2 3; do
    docker push "${IMAGE_NAME}:${TAG}" 2>&1 && { PUSH_OK=true; break; }
    echo "   ⚠️ Push attempt $attempt failed. Retrying in 5s..."; sleep 5
  done
  if [[ "$PUSH_OK" != "true" ]]; then
    echo "   ❌ Push FAILED after 3 attempts"
    docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true; return 1
  fi
  perm_rm "$SHARD_DIR"
  docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
  echo "   ✅ Done!"; echo ""
  return 0
}

# ══ Main ══════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MLBakery — Baking ${MODEL_REPO}"
echo "  Tag prefix: ${TAG_PREFIX}  |  Start shard: ${START_SHARD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "$MODEL_DIR"

# Build exclude list for Python
EXCLUDE_PY_LIST=""
if [[ -n "$EXCLUDE_PATTERNS" ]]; then
  IFS=',' read -ra EXCL_LIST <<< "$EXCLUDE_PATTERNS"
  EXCLUDE_PY_LIST=$(printf "'%s'," "${EXCL_LIST[@]}")
  EXCLUDE_PY_LIST="[${EXCLUDE_PY_LIST%,}]"
else
  EXCLUDE_PY_LIST="[]"
fi

echo "📋 Listing model files from ${MODEL_REPO}..."
SAFETENSOR_LIST=$($VENV_PYTHON -c "
from huggingface_hub import list_repo_files
import fnmatch
files = list_repo_files('$MODEL_REPO')
safetensors = sorted([f for f in files if f.endswith('.safetensors')])
excludes = $EXCLUDE_PY_LIST
for f in safetensors:
    if not any(fnmatch.fnmatch(f, p) for p in excludes):
        print(f)
" 2>/dev/null)

# ── ONNX path: no safetensors → full-repo single image ───────────────────────
if [[ -z "$SAFETENSOR_LIST" ]]; then
  echo "   No .safetensors found — checking for ONNX..."
  ONNX_COUNT=$($VENV_PYTHON -c "
from huggingface_hub import list_repo_files
files = list_repo_files('$MODEL_REPO')
print(len([f for f in files if f.endswith('.onnx')]))
" 2>/dev/null)
  if [[ -z "$ONNX_COUNT" || "$ONNX_COUNT" -eq 0 ]]; then
    echo "❌ No .safetensors or .onnx files found. Check repo name / network."
    exit 1
  fi
  echo "   Found ${ONNX_COUNT} .onnx file(s) → single image: ${TAG_PREFIX}"
  echo ""

  TAG="${TAG_PREFIX}"
  SHARD_DIR="$WORK_DIR/shard1"
  SHARD_MODEL_DIR="$SHARD_DIR/models/$MODEL_NAME"
  mkdir -p "$SHARD_MODEL_DIR" "$SHARD_DIR/datasets"
  echo "$DOCKERFILE" > "$SHARD_DIR/Dockerfile"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 ${IMAGE_NAME}:${TAG} (ONNX — full repo)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if ! hf_download_repo "$MODEL_REPO" "$SHARD_MODEL_DIR" ""; then
    echo "❌ Download failed"; perm_rm "$WORK_DIR"; exit 1
  fi
  rm -rf "$SHARD_MODEL_DIR/.huggingface" "$SHARD_MODEL_DIR/.cache"

  if ! build_and_push_shard "1" "$TAG" "$SHARD_DIR"; then
    perm_rm "$WORK_DIR"; exit 1
  fi

  perm_rm "$WORK_DIR"
  echo "🎉 Done!"
  echo "Pushed: ${IMAGE_NAME}:${TAG}"
  exit 0
fi

# ── Safetensors path ─────────────────────────────────────────────
IFS=$'\n' read -rd '' -a SAFETENSORS <<< "$SAFETENSOR_LIST" || true
TOTAL_FILES=${#SAFETENSORS[@]}

if [[ $TOTAL_FILES -eq 1 ]]; then
  IS_SINGLE=true
  echo "   Found 1 safetensor → single image: ${TAG_PREFIX}"
else
  IS_SINGLE=false
  echo "   Found ${TOTAL_FILES} safetensors → sharded: ${TAG_PREFIX}-shard1..${TOTAL_FILES}"
fi
[[ $START_SHARD -gt 1 ]] && echo "   Resuming from shard ${START_SHARD}"
echo ""

# Download metadata (all non-safetensors files)
echo "📁 Downloading metadata files..."
if ! hf_download_repo "$MODEL_REPO" "$MODEL_DIR" "*.safetensors"; then
  echo "❌ Metadata download failed"; exit 1
fi
rm -rf "$MODEL_DIR/.huggingface" "$MODEL_DIR/.cache"

METADATA=()
for f in "$MODEL_DIR"/*; do
  [[ -f "$f" || -d "$f" ]] && METADATA+=("$(basename "$f")")
done
echo "   Downloaded ${#METADATA[@]} metadata entries"
echo ""

FAILED_SHARDS=()

for i in $(seq 0 $((TOTAL_FILES - 1))); do
  SHARD_NUM=$((i + 1))
  [[ $SHARD_NUM -lt $START_SHARD ]] && continue

  FNAME="${SAFETENSORS[$i]}"
  TAG=$([[ "$IS_SINGLE" == "true" ]] && echo "${TAG_PREFIX}" || echo "${TAG_PREFIX}-shard${SHARD_NUM}")

  SHARD_DIR="$WORK_DIR/shard${SHARD_NUM}"
  SHARD_MODEL_DIR="$SHARD_DIR/models/$MODEL_NAME"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ "$IS_SINGLE" == "true" ]] && echo "📦 ${IMAGE_NAME}:${TAG}" || echo "📦 Shard ${SHARD_NUM}/${TOTAL_FILES}: ${IMAGE_NAME}:${TAG}"
  echo "   File: ${FNAME}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  mkdir -p "$SHARD_MODEL_DIR" "$SHARD_DIR/datasets"
  echo "$DOCKERFILE" > "$SHARD_DIR/Dockerfile"

  if [[ $SHARD_NUM -eq 1 ]]; then
    echo "   📁 Copying metadata..."
    for mf in "${METADATA[@]}"; do cp -r "$MODEL_DIR/$mf" "$SHARD_MODEL_DIR/"; done
  fi

  echo "   ⬇️  Downloading ${FNAME}..."
  if ! hf_download_file "$MODEL_REPO" "$FNAME" "$SHARD_MODEL_DIR"; then
    echo "   ❌ Download FAILED for ${FNAME}"
    FAILED_SHARDS+=("shard${SHARD_NUM}")
    perm_rm "$SHARD_DIR"
    continue
  fi
  rm -rf "$SHARD_MODEL_DIR/.huggingface" "$SHARD_MODEL_DIR/.cache"

  if ! build_and_push_shard "$SHARD_NUM" "$TAG" "$SHARD_DIR"; then
    FAILED_SHARDS+=("shard${SHARD_NUM}")
  fi
done

# ── Summary ───────────────────────────────────────────────
if [[ ${#FAILED_SHARDS[@]} -eq 0 ]]; then
  perm_rm "$WORK_DIR"
  echo "🎉 All done!"
  echo "Pushed images:"
  for i in $(seq $START_SHARD $TOTAL_FILES); do
    [[ "$IS_SINGLE" == "true" ]] && echo "  ${IMAGE_NAME}:${TAG_PREFIX}" || echo "  ${IMAGE_NAME}:${TAG_PREFIX}-shard${i}"
  done
else
  echo "⚠️  Keeping work dir for retry: $WORK_DIR"
  echo "⚠️  Failed: ${FAILED_SHARDS[*]}"
  exit 1
fi
