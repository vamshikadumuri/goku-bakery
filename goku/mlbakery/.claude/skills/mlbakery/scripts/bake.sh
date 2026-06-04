#!/bin/bash
set -e

MODEL_REPO=""
START_SHARD=1
EXCLUDE_PATTERNS=""

while getopts "m:s:e:" opt; do
    case $opt in
        m) MODEL_REPO="$OPTARG" ;;
        s) START_SHARD="$OPTARG" ;;
        e) EXCLUDE_PATTERNS="$OPTARG" ;;
        *) echo "Usage: $0 -m model_repo [-s start_shard] [-e exclude_patterns]"; exit 1 ;;
    esac
done

if [ -z "$MODEL_REPO" ]; then
    echo "Error: -m model_repo is required"
    exit 1
fi

MODEL_NAME=$(echo "$MODEL_REPO" | cut -d'/' -f2 | tr '[:upper:]' '[:lower:]')
OWNER="${GITHUB_REPOSITORY_OWNER:-$(whoami)}"
OWNER=$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')
BASE_TAG="ghcr.io/${OWNER}/mlbakery:${MODEL_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLBAKERY_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

echo "=== Bake Configuration ==="
echo "Model repo:    $MODEL_REPO"
echo "Start shard:   $START_SHARD"
echo "Exclude:       $EXCLUDE_PATTERNS"
echo "Base tag:      $BASE_TAG"
echo "Dockerfile:    $MLBAKERY_DIR/Dockerfile"
echo "=========================="

# Fetch full file list from HuggingFace into /tmp/file_list.json
MODEL_REPO="$MODEL_REPO" EXCLUDE_PATTERNS="$EXCLUDE_PATTERNS" python3 << 'PYEOF'
import os, json, fnmatch, sys
from huggingface_hub import list_repo_files

repo_id      = os.environ['MODEL_REPO']
exclude_str  = os.environ.get('EXCLUDE_PATTERNS', '')
token        = os.environ.get('HF_TOKEN')

all_files       = list(list_repo_files(repo_id, token=token))
exclude_pats    = [p.strip() for p in exclude_str.split(',') if p.strip()] if exclude_str else []
excluded        = lambda f: any(fnmatch.fnmatch(f, p) for p in exclude_pats)

safetensors = sorted([f for f in all_files if f.endswith('.safetensors') and not excluded(f)])
others      = [f for f in all_files if not f.endswith('.safetensors') and not excluded(f)]

print(f"Total files: {len(all_files)}  |  safetensors shards: {len(safetensors)}  |  other: {len(others)}")
json.dump({'safetensors': safetensors, 'others': others}, open('/tmp/file_list.json', 'w'))
PYEOF

TOTAL_SHARDS=$(python3 -c "import json; print(len(json.load(open('/tmp/file_list.json'))['safetensors']))")
echo "Total shards: $TOTAL_SHARDS  |  Starting from: $START_SHARD"

# Download config/tokenizer files once into a reusable staging dir
CONFIG_DIR=$(mktemp -d "$(pwd)/config.XXXXXXXX")
echo "--- Downloading config/tokenizer files ---"
MODEL_REPO="$MODEL_REPO" CONFIG_DIR="$CONFIG_DIR" python3 << 'PYEOF'
import os, json
from huggingface_hub import hf_hub_download

data    = json.load(open('/tmp/file_list.json'))
token   = os.environ.get('HF_TOKEN')
repo_id = os.environ['MODEL_REPO']
dst     = os.environ['CONFIG_DIR']

for f in data['others']:
    print(f"  {f}")
    try:
        hf_hub_download(repo_id=repo_id, filename=f, local_dir=dst, token=token)
    except Exception as e:
        print(f"  WARNING: {f}: {e}")
print("Config files done")
PYEOF

# Bake each shard individually
for SHARD_IDX in $(seq 1 "$TOTAL_SHARDS"); do
    SHARD_FILE=$(python3 -c "import json; print(json.load(open('/tmp/file_list.json'))['safetensors'][${SHARD_IDX}-1])")
    SHARD_TAG="${BASE_TAG}-shard-$(printf '%03d' "$SHARD_IDX")"

    if [ "$SHARD_IDX" -lt "$START_SHARD" ]; then
        echo "Skipping shard $SHARD_IDX/$TOTAL_SHARDS: $SHARD_FILE"
        continue
    fi

    echo ""
    echo "=== Shard $SHARD_IDX/$TOTAL_SHARDS: $SHARD_FILE ==="
    echo "    Tag: $SHARD_TAG"

    SHARD_DIR=$(mktemp -d "$(pwd)/shard.XXXXXXXX")

    # Copy config files into shard context
    cp -r "$CONFIG_DIR/." "$SHARD_DIR/"

    # Download this shard
    echo "  Downloading..."
    SHARD_FILE="$SHARD_FILE" MODEL_REPO="$MODEL_REPO" SHARD_DIR="$SHARD_DIR" python3 << 'PYEOF'
import os
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id   = os.environ['MODEL_REPO'],
    filename  = os.environ['SHARD_FILE'],
    local_dir = os.environ['SHARD_DIR'],
    token     = os.environ.get('HF_TOKEN'),
)
print("  Download complete")
PYEOF

    # Build
    echo "  Building image..."
    docker build -f "$MLBAKERY_DIR/Dockerfile" -t "$SHARD_TAG" "$SHARD_DIR"

    # Push
    echo "  Pushing $SHARD_TAG..."
    docker push "$SHARD_TAG"

    # Free disk space before next shard
    docker rmi "$SHARD_TAG" || true
    rm -rf "$SHARD_DIR"

    echo "  Done: $SHARD_TAG"
done

rm -rf "$CONFIG_DIR"

echo ""
echo "=== ALL SHARDS BAKED AND PUSHED ==="
echo "Images: ${BASE_TAG}-shard-001  through  ${BASE_TAG}-shard-$(printf '%03d' "$TOTAL_SHARDS")"
