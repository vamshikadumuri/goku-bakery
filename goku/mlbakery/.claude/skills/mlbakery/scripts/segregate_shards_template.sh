#!/bin/bash
# segregate_shards.sh
# Segregates downloaded HF model files into per-shard directories,
# builds, pushes, and cleans up each shard one at a time to conserve disk space.
# Uses 'mv' instead of 'cp' for safetensor files to avoid doubling disk usage.
# Uses permanent deletion to avoid NTFS Recycle Bin on /mnt/ drives.

# Don't use set -e; handle errors per-shard with retries instead

# Permanent delete function: bypasses Windows Recycle Bin on NTFS mounts
perm_rm() {
  for target in "$@"; do
    if [[ -e "$target" ]]; then
      # Overwrite files before deleting to prevent recycle bin recovery on NTFS
      if [[ -d "$target" ]]; then
        find "$target" -type f -exec rm -f {} +
        rm -rf "$target"
      else
        rm -f "$target"
      fi
    fi
  done
}

MODEL_DIR=""
OUTPUT_BASE=""
TAG_PREFIX=""
MAX_SHARD_GB=4.0
GHCR_USER="vamshikadumuri"
IMAGE_NAME="ghcr.io/${GHCR_USER}/mlbakery"

while [[ $# -gt 0 ]]; do
  case $1 in
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --output-base) OUTPUT_BASE="$2"; shift 2 ;;
    --tag-prefix) TAG_PREFIX="$2"; shift 2 ;;
    --max-shard-gb) MAX_SHARD_GB="$2"; shift 2 ;;
    --ghcr-user) GHCR_USER="$2"; IMAGE_NAME="ghcr.io/${GHCR_USER}/mlbakery"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$MODEL_DIR" || -z "$OUTPUT_BASE" || -z "$TAG_PREFIX" ]]; then
  echo "Error: --model-dir, --output-base, and --tag-prefix are required."
  exit 1
fi

MODEL_NAME=$(basename "$MODEL_DIR")
MAX_SHARD_BYTES=$(echo "$MAX_SHARD_GB * 1024 * 1024 * 1024" | bc | cut -d. -f1)

DOCKERFILE='FROM ubuntu:latest

RUN apt-get update && \
    apt-get install -y g++

RUN apt-get install -y python3 python3-pip git htop

WORKDIR /models
COPY models/ /models/

WORKDIR /datasets
COPY datasets/ /datasets/
'

echo "📦 Scanning model directory: $MODEL_DIR"

SAFETENSORS=()
METADATA=()

for f in "$MODEL_DIR"/*; do
  fname=$(basename "$f")
  if [[ "$fname" == *.safetensors ]]; then
    SAFETENSORS+=("$fname")
  else
    METADATA+=("$fname")
  fi
done

IFS=$'\n' SAFETENSORS=($(sort <<<"${SAFETENSORS[*]}")); unset IFS

echo "   Found ${#SAFETENSORS[@]} safetensors files"
echo "   Found ${#METADATA[@]} metadata files (will go into shard1)"

declare -a SHARD_FILES
CURRENT_SHARD=0
CURRENT_SIZE=0
SHARD_FILES[0]=""

for fname in "${SAFETENSORS[@]}"; do
  fpath="$MODEL_DIR/$fname"
  fsize=$(stat -c%s "$fpath")

  if [[ $CURRENT_SIZE -gt 0 && $((CURRENT_SIZE + fsize)) -gt $MAX_SHARD_BYTES ]]; then
    CURRENT_SHARD=$((CURRENT_SHARD + 1))
    CURRENT_SIZE=0
    SHARD_FILES[$CURRENT_SHARD]=""
  fi

  SHARD_FILES[$CURRENT_SHARD]="${SHARD_FILES[$CURRENT_SHARD]} $fname"
  CURRENT_SIZE=$((CURRENT_SIZE + fsize))
done

TOTAL_SHARDS=${#SHARD_FILES[@]}
echo "📊 Will create $TOTAL_SHARDS shard(s)"
echo ""

FAILED_SHARDS=()

# --- Process each shard: move -> build -> push -> cleanup ---
for i in $(seq 0 $((TOTAL_SHARDS - 1))); do
  SHARD_NUM=$((i + 1))
  SHARD_DIR="$OUTPUT_BASE/shard${SHARD_NUM}"
  SHARD_MODEL_DIR="$SHARD_DIR/models/$MODEL_NAME"
  SHARD_DATASETS_DIR="$SHARD_DIR/datasets"
  TAG="${TAG_PREFIX}-shard${SHARD_NUM}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 Processing shard ${SHARD_NUM}/${TOTAL_SHARDS}: ${IMAGE_NAME}:${TAG}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  mkdir -p "$SHARD_MODEL_DIR"
  mkdir -p "$SHARD_DATASETS_DIR"
  echo "$DOCKERFILE" > "$SHARD_DIR/Dockerfile"

  # Copy metadata into shard1 only (small files, copy is fine)
  if [[ $SHARD_NUM -eq 1 ]]; then
    echo "   📁 shard1: copying metadata files..."
    for mf in "${METADATA[@]}"; do
      cp -r "$MODEL_DIR/$mf" "$SHARD_MODEL_DIR/"
    done
  fi

  # MOVE safetensor files (not copy) to save disk space
  for fname in ${SHARD_FILES[$i]}; do
    echo "   📁 shard${SHARD_NUM}: moving $fname"
    mv "$MODEL_DIR/$fname" "$SHARD_MODEL_DIR/"
  done

  # Build Docker image
  echo "   🔨 Building ${IMAGE_NAME}:${TAG}..."
  if ! docker build -t "${IMAGE_NAME}:${TAG}" "$SHARD_DIR"; then
    echo "   ❌ Build FAILED for shard${SHARD_NUM}. Skipping."
    FAILED_SHARDS+=("shard${SHARD_NUM}")
    perm_rm "$SHARD_DIR"
    continue
  fi

  # Push Docker image with retries (handles WSL credential store flakiness)
  echo "   🚀 Pushing ${IMAGE_NAME}:${TAG}..."
  PUSH_OK=false
  for attempt in 1 2 3; do
    if docker push "${IMAGE_NAME}:${TAG}" 2>&1; then
      PUSH_OK=true
      break
    fi
    echo "   ⚠️  Push attempt $attempt failed. Retrying in 5s..."
    sleep 5
  done

  if [[ "$PUSH_OK" != "true" ]]; then
    echo "   ❌ Push FAILED for shard${SHARD_NUM} after 3 attempts."
    FAILED_SHARDS+=("shard${SHARD_NUM}")
    perm_rm "$SHARD_DIR"
    docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
    continue
  fi

  # Cleanup: permanently delete shard directory and docker image to free space
  echo "   🗑️  Cleaning up shard${SHARD_NUM} (freeing disk space)..."
  perm_rm "$SHARD_DIR"
  docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true

  echo "   ✅ shard${SHARD_NUM} done!"
  echo ""
done

# --- Final cleanup (permanent delete to bypass NTFS Recycle Bin) ---
echo "🗑️  Permanently deleting remaining source files..."
perm_rm "$MODEL_DIR"
perm_rm "$OUTPUT_BASE"

echo ""
if [[ ${#FAILED_SHARDS[@]} -gt 0 ]]; then
  echo "⚠️  Completed with ${#FAILED_SHARDS[@]} failure(s): ${FAILED_SHARDS[*]}"
  echo ""
  echo "Successfully pushed:"
  for i in $(seq 1 $TOTAL_SHARDS); do
    sname="shard${i}"
    if [[ ! " ${FAILED_SHARDS[*]} " =~ " ${sname} " ]]; then
      echo "  ✅ ${IMAGE_NAME}:${TAG_PREFIX}-shard${i}"
    else
      echo "  ❌ ${IMAGE_NAME}:${TAG_PREFIX}-shard${i} (FAILED)"
    fi
  done
  exit 1
else
  echo "🎉 All $TOTAL_SHARDS shards built and pushed successfully!"
  echo ""
  echo "Pushed images:"
  for i in $(seq 1 $TOTAL_SHARDS); do
    echo "  ${IMAGE_NAME}:${TAG_PREFIX}-shard${i}"
  done
fi
