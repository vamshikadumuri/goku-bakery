#!/bin/bash
# bake.sh — Universal MLBakery script
# Downloads a HF model one safetensor at a time, builds Docker images,
# verifies contents, pushes to GHCR, and cleans up — maximally disk-efficient.
#
# Examples:
#   # Bake a model (all shards)
#   bash scripts/bake.sh -m Qwen/Qwen3.5-35B-A3B
#
#   # Resume from shard 5 (skip safetensors 1-4)
#   bash scripts/bake.sh -m Qwen/Qwen3.5-27B -s 5 \
#     -e "model.safetensors-00001-*,model.safetensors-00002-*,model.safetensors-00003-*,model.safetensors-00004-*"
#
# Prerequisites:
#   - pip install huggingface_hub[hf_transfer]
#   - huggingface-cli login (or HF_TOKEN env var)
#   - docker login ghcr.io

set +e  # Handle errors per-shard

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

# ── Usage ─────────────────────────────────────────────────
print_usage() {
  echo "Usage: $0 -m MODEL_REPO [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -m MODEL_REPO       HF model repo (e.g. Qwen/Qwen3.5-27B) [required]"
  echo "  -t TAG_PREFIX       Image tag prefix (default: derived from model repo)"
  echo "  -s START_SHARD      Starting shard number (default: 1)"
  echo "  -u GHCR_USER        GHCR username (default: vamshikadumuri)"
  echo "  -e EXCLUDE          Comma-separated HF download exclude patterns"
  echo "  -v VENV_NAME        Venv directory name inside project dir (default: mymlbakeryenv)"
  echo "  -h                  Show this help"
  echo ""
  echo "Examples:"
  echo "  # Bake a model"
  echo "  $0 -m Qwen/Qwen3.5-35B-A3B"
  echo ""
  echo "  # Bake a small single-file model (tagged without -shard suffix)"
  echo "  $0 -m garak-llm/pegasus_paraphrase"
  echo ""
  echo "  # Resume from shard 5 (4 shards already pushed)"
  echo "  $0 -m Qwen/Qwen3.5-27B -s 5 \\"
  echo "    -e 'model.safetensors-00001-*,model.safetensors-00002-*,model.safetensors-00003-*,model.safetensors-00004-*'"
}

# ── Parse args ────────────────────────────────────────────
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

# Derive tag prefix from model repo if not provided (Qwen/Qwen3.5-27B → Qwen-Qwen3.5-27B)
if [[ -z "$TAG_PREFIX" ]]; then
  TAG_PREFIX=$(echo "$MODEL_REPO" | tr '/' '-')
fi

MODEL_NAME=$(basename "$MODEL_REPO")
WORK_DIR="$(pwd)/temp_$(date +%Y%m%d)_${MODEL_NAME}"
MODEL_DIR="$WORK_DIR/models/$MODEL_NAME"

export HF_HUB_ENABLE_HF_TRANSFER=1

# Resolve huggingface-cli: use venv python -m if provided, else bare command
if [[ -z "$VENV_PYTHON" ]]; then
  VENV_PYTHON="$PROJECT_DIR/mymlbakeryenv/bin/python3"
fi

if [[ -x "$VENV_PYTHON" ]]; then
  HF_CLI="$VENV_PYTHON -m huggingface_hub.commands.huggingface_cli"
  echo "🐍 Using venv Python: $VENV_PYTHON"
else
  HF_CLI="huggingface-cli"
  echo "🐍 Using system huggingface-cli: $(which huggingface-cli 2>/dev/null)"
fi

# ── Helpers ───────────────────────────────────────────────

# Permanent delete: bypasses NTFS Recycle Bin on WSL /mnt/ drives
perm_rm() {
  for target in "$@"; do
    if [[ -e "$target" ]]; then
      if [[ -d "$target" ]]; then
        find "$target" -type f -exec rm -f {} +
        rm -rf "$target"
      else
        rm -f "$target"
      fi
    fi
  done
}

# Verify Docker image contents match local staged files before pushing
verify_image_contents() {
  local IMAGE_TAG=$1
  local SHARD_DIR=$2

  echo "   🔍 Verifying image contents..."

  # Get list of files staged locally (what we expect in the image)
  EXPECTED=$(cd "$SHARD_DIR" && find models/ -type f | sort)

  # Single docker run: get file list + size in one container
  VERIFY_OUTPUT=$(docker run --rm "$IMAGE_TAG" sh -c 'find /models/ -type f | sort; echo "===VERIFY_SEP==="; du -sh /models/' 2>/dev/null)

  if [[ -z "$VERIFY_OUTPUT" ]]; then
    echo "   ❌ Verification FAILED: could not read image contents"
    return 1
  fi

  # Split output on separator
  ACTUAL=$(echo "$VERIFY_OUTPUT" | sed '/===VERIFY_SEP===/,$d' | sed 's|^/||')
  IMAGE_SIZE=$(echo "$VERIFY_OUTPUT" | sed -n '/===VERIFY_SEP===/,$ p' | tail -1 | cut -f1)

  if [[ -z "$ACTUAL" ]]; then
    echo "   ❌ Verification FAILED: no files found in image"
    return 1
  fi

  # Compare expected vs actual
  DIFF=$(diff <(echo "$EXPECTED") <(echo "$ACTUAL"))
  if [[ -n "$DIFF" ]]; then
    echo "   ❌ Verification FAILED: image contents don't match expected files"
    echo "   Diff (< expected, > actual):"
    echo "$DIFF" | head -20
    return 1
  fi

  # Show summary
  FILE_COUNT=$(echo "$ACTUAL" | wc -l)
  echo "   ✅ Verified: ${FILE_COUNT} files, ${IMAGE_SIZE} in /models/"
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

# Pre-flight: check docker is available
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker is not available. Start Docker Desktop and enable WSL integration."
  exit 1
fi
echo "🐳 Docker: OK"

# ── Build & push a single shard ──────────────────────────
# Args: SHARD_NUM TAG SHARD_DIR
# Returns 0 on success, 1 on failure
# On failure, keeps shard dir intact for manual retry
build_and_push_shard() {
  local SHARD_NUM=$1
  local TAG=$2
  local SHARD_DIR=$3

  # Build
  echo "   🔨 Building ${IMAGE_NAME}:${TAG}..."
  if ! docker build -t "${IMAGE_NAME}:${TAG}" "$SHARD_DIR"; then
    echo "   ❌ Build FAILED for shard${SHARD_NUM}."
    echo "   Keeping shard dir intact for retry: $SHARD_DIR"
    return 1
  fi

  # Verify image contents before pushing
  if ! verify_image_contents "${IMAGE_NAME}:${TAG}" "$SHARD_DIR"; then
    echo "   ❌ Content verification FAILED for shard${SHARD_NUM}. NOT pushing."
    echo "   Keeping shard dir intact for retry: $SHARD_DIR"
    docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
    return 1
  fi

  # Push with retries
  echo "   🚀 Pushing ${IMAGE_NAME}:${TAG}..."
  local PUSH_OK=false
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
    echo "   Keeping shard dir intact for retry: $SHARD_DIR"
    docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
    return 1
  fi

  # Success: cleanup
  echo "   🗑️  Cleaning up shard${SHARD_NUM}..."
  perm_rm "$SHARD_DIR"
  docker rmi "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
  echo "   ✅ shard${SHARD_NUM} done!"
  echo ""
  return 0
}

# ══════════════════════════════════════════════════════════
#  Main flow: download one safetensor at a time
# ══════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MLBakery — Baking ${MODEL_REPO}"
echo "  Tag prefix: ${TAG_PREFIX}"
echo "  Start shard: ${START_SHARD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "$MODEL_DIR"

# List safetensor files from HF repo via Python API
echo "📋 Listing safetensor files from ${MODEL_REPO}..."
EXCLUDE_PY_LIST=""
if [[ -n "$EXCLUDE_PATTERNS" ]]; then
  IFS=',' read -ra EXCL_LIST <<< "$EXCLUDE_PATTERNS"
  EXCLUDE_PY_LIST=$(printf "'%s'," "${EXCL_LIST[@]}")
  EXCLUDE_PY_LIST="[${EXCLUDE_PY_LIST%,}]"
else
  EXCLUDE_PY_LIST="[]"
fi

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

if [[ -z "$SAFETENSOR_LIST" ]]; then
  echo "❌ Could not list safetensor files. Check model repo and network."
  exit 1
fi

IFS=$'\n' read -rd '' -a SAFETENSORS <<< "$SAFETENSOR_LIST" || true
TOTAL_FILES=${#SAFETENSORS[@]}
END_SHARD=$((TOTAL_FILES))

# Single-file models get a clean tag (no -shard suffix)
if [[ $TOTAL_FILES -eq 1 ]]; then
  IS_SINGLE=true
  echo "   Found 1 safetensor file → single image: ${TAG_PREFIX}"
else
  IS_SINGLE=false
  echo "   Found ${TOTAL_FILES} safetensor files → sharded: ${TAG_PREFIX}-shard1 through ${TAG_PREFIX}-shard${TOTAL_FILES}"
fi
if [[ $START_SHARD -gt 1 ]]; then
  echo "   Skipping shards 1-$((START_SHARD - 1)) (already on GHCR)"
fi
echo ""

# Download metadata (everything except safetensors) to MODEL_DIR
echo "📁 Downloading metadata files..."
METADATA_CMD="$HF_CLI download \"$MODEL_REPO\" --local-dir \"$MODEL_DIR\" --exclude \"*.safetensors\""
if ! eval $METADATA_CMD; then
  echo "❌ Metadata download failed. Aborting."
  exit 1
fi
rm -rf "$MODEL_DIR/.huggingface" "$MODEL_DIR/.cache"

# Collect metadata file names
METADATA=()
for f in "$MODEL_DIR"/*; do
  [[ -f "$f" || -d "$f" ]] && METADATA+=("$(basename "$f")")
done
echo "   Downloaded ${#METADATA[@]} metadata entries"
echo ""

# Process each shard
FAILED_SHARDS=()

for i in $(seq 0 $((TOTAL_FILES - 1))); do
  SHARD_NUM=$((i + 1))

  # Skip shards before START_SHARD
  if [[ $SHARD_NUM -lt $START_SHARD ]]; then
    continue
  fi

  FNAME="${SAFETENSORS[$i]}"

  # Tag: no -shard suffix for single-file models
  if [[ "$IS_SINGLE" == "true" ]]; then
    TAG="${TAG_PREFIX}"
  else
    TAG="${TAG_PREFIX}-shard${SHARD_NUM}"
  fi

  SHARD_DIR="$WORK_DIR/shard${SHARD_NUM}"
  SHARD_MODEL_DIR="$SHARD_DIR/models/$MODEL_NAME"
  SHARD_DATASETS_DIR="$SHARD_DIR/datasets"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$IS_SINGLE" == "true" ]]; then
    echo "📦 ${IMAGE_NAME}:${TAG}"
  else
    echo "📦 Shard ${SHARD_NUM}/${END_SHARD}: ${IMAGE_NAME}:${TAG}"
  fi
  echo "   File: ${FNAME}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  mkdir -p "$SHARD_MODEL_DIR"
  mkdir -p "$SHARD_DATASETS_DIR"
  echo "$DOCKERFILE" > "$SHARD_DIR/Dockerfile"

  # Shard 1 (or single-file model): copy metadata
  if [[ $SHARD_NUM -eq 1 ]]; then
    echo "   📁 Copying metadata files..."
    for mf in "${METADATA[@]}"; do
      cp -r "$MODEL_DIR/$mf" "$SHARD_MODEL_DIR/"
    done
  fi

  # Download this single safetensor file directly to shard dir
  echo "   ⬇️  Downloading ${FNAME}..."
  DL_CMD="$HF_CLI download \"$MODEL_REPO\" \"$FNAME\" --local-dir \"$SHARD_MODEL_DIR\""
  if ! eval $DL_CMD; then
    echo "   ❌ Download FAILED for ${FNAME}. Skipping shard${SHARD_NUM}."
    FAILED_SHARDS+=("shard${SHARD_NUM}")
    perm_rm "$SHARD_DIR"
    continue
  fi
  rm -rf "$SHARD_MODEL_DIR/.huggingface" "$SHARD_MODEL_DIR/.cache"

  # Build, verify & push (keeps shard dir on failure for retry)
  if ! build_and_push_shard "$SHARD_NUM" "$TAG" "$SHARD_DIR"; then
    FAILED_SHARDS+=("shard${SHARD_NUM}")
  fi
done

# ── Final summary ─────────────────────────────────────────
# Only cleanup work dir if all shards succeeded
if [[ ${#FAILED_SHARDS[@]} -eq 0 ]]; then
  echo "🗑️  Cleaning up working directory..."
  perm_rm "$WORK_DIR"
else
  echo "⚠️  Keeping working directory for retry: $WORK_DIR"
fi

echo ""
if [[ ${#FAILED_SHARDS[@]} -gt 0 ]]; then
  echo "⚠️  Completed with ${#FAILED_SHARDS[@]} failure(s): ${FAILED_SHARDS[*]}"
  echo ""
  echo "Image status:"
  for i in $(seq 1 $END_SHARD); do
    sname="shard${i}"
    if [[ "$IS_SINGLE" == "true" ]]; then
      DISPLAY_TAG="${TAG_PREFIX}"
    else
      DISPLAY_TAG="${TAG_PREFIX}-shard${i}"
    fi
    if [[ $i -lt $START_SHARD ]]; then
      echo "  ✅ ${IMAGE_NAME}:${DISPLAY_TAG} (previously pushed)"
    elif [[ " ${FAILED_SHARDS[*]} " =~ " ${sname} " ]]; then
      echo "  ❌ ${IMAGE_NAME}:${DISPLAY_TAG} (FAILED)"
    else
      echo "  ✅ ${IMAGE_NAME}:${DISPLAY_TAG}"
    fi
  done
  exit 1
else
  echo "🎉 All done!"
  echo ""
  echo "Pushed images:"
  for i in $(seq $START_SHARD $END_SHARD); do
    if [[ "$IS_SINGLE" == "true" ]]; then
      echo "  ${IMAGE_NAME}:${TAG_PREFIX}"
    else
      echo "  ${IMAGE_NAME}:${TAG_PREFIX}-shard${i}"
    fi
  done
  if [[ $START_SHARD -gt 1 ]]; then
    echo ""
    echo "Previously pushed (shards 1-$((START_SHARD - 1))):"
    for i in $(seq 1 $((START_SHARD - 1))); do
      echo "  ${IMAGE_NAME}:${TAG_PREFIX}-shard${i}"
    done
  fi
fi
