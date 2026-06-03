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
IMAGE_TAG="ghcr.io/${OWNER}/mlbakery:${MODEL_NAME}"

echo "=== Bake Configuration ==="
echo "Model repo:    $MODEL_REPO"
echo "Start shard:   $START_SHARD"
echo "Exclude:       $EXCLUDE_PATTERNS"
echo "Image tag:     $IMAGE_TAG"
echo "=========================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLBAKERY_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOWNLOAD_DIR="$(pwd)/model_download"
mkdir -p "$DOWNLOAD_DIR"

python3 << PYEOF
import os
import sys
import fnmatch
from huggingface_hub import list_repo_files, hf_hub_download

repo_id = "${MODEL_REPO}"
download_dir = "${DOWNLOAD_DIR}"
start_shard = ${START_SHARD}
token = os.environ.get("HF_TOKEN")

exclude_patterns = []
if "${EXCLUDE_PATTERNS}":
    exclude_patterns = [p.strip() for p in "${EXCLUDE_PATTERNS}".split(",") if p.strip()]

print(f"Listing files in {repo_id}...")
all_files = list(list_repo_files(repo_id, token=token))
print(f"Total files: {len(all_files)}")

def is_excluded(filename):
    for pattern in exclude_patterns:
        if fnmatch.fnmatch(filename, pattern):
            return True
    return False

files_to_download = [f for f in all_files if not is_excluded(f)]
print(f"Files to download (after exclusions): {len(files_to_download)}")

safetensors_files = sorted([f for f in files_to_download if f.endswith(".safetensors")])
other_files = [f for f in files_to_download if not f.endswith(".safetensors")]

print(f"Safetensors shards: {len(safetensors_files)}")
print(f"Other files: {len(other_files)}")

for filename in other_files:
    print(f"Downloading: {filename}")
    try:
        hf_hub_download(repo_id=repo_id, filename=filename, local_dir=download_dir, token=token)
    except Exception as e:
        print(f"  WARNING: Failed to download {filename}: {e}")

for i, filename in enumerate(safetensors_files, start=1):
    if i < start_shard:
        print(f"Skipping shard {i}/{len(safetensors_files)}: {filename}")
        continue
    print(f"Downloading shard {i}/{len(safetensors_files)}: {filename}")
    try:
        hf_hub_download(repo_id=repo_id, filename=filename, local_dir=download_dir, token=token)
        print(f"  Shard {i} complete")
    except Exception as e:
        print(f"  ERROR: Failed shard {i}: {e}", file=sys.stderr)
        sys.exit(1)

print("All downloads complete!")
PYEOF

echo "Building Docker image: $IMAGE_TAG"
TEMP_DIR=$(mktemp -d "$(pwd)/bake_ctx.XXXXXXXX")
cp -r "$DOWNLOAD_DIR/." "$TEMP_DIR/"

docker build -f "$MLBAKERY_DIR/Dockerfile" -t "$IMAGE_TAG" "$TEMP_DIR"

echo "Pushing to GHCR: $IMAGE_TAG"
docker push "$IMAGE_TAG"

rm -rf "$TEMP_DIR" "$DOWNLOAD_DIR"

echo "=== SUCCESS ==="
echo "Baked and pushed: $IMAGE_TAG"
