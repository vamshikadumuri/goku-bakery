---
name: mlbakery
description: >
  Bakes Hugging Face models (and datasets) into Docker images and pushes them to ghcr.io/vamshikadumuri/mlbakery.
  Use this skill whenever the user mentions baking a model, building a model image, sharding a model, pushing to GHCR,
  running bake.sh or build_image.sh, or says anything like "bake X model", "build image for Y", "shard and bake",
  "push model to registry", "mlbakery", or references a Hugging Face model ID in the context of Docker image creation.
  Always trigger proactively — don't wait for the user to say "use the mlbakery skill" explicitly.
---

# MLBakery Skill

Bakes Hugging Face models/datasets into Docker images and pushes them to GHCR.

## Key Config

| Setting | Value |
|---|---|
| Script location | `scripts/bake.sh` (relative to mlbakery project root) |
| Image registry | `ghcr.io/vamshikadumuri/mlbakery` |
| Default venv | `mymlbakeryenv` (in project root) |
| venv packages | `hf_transfer`, `huggingface-hub` |

**Important**: Tokens are stored in environment variables (`HF_TOKEN`) and Docker credential store. Never hardcode tokens in scripts.

## IMAGE_TAG Format

Given a HF model ID `family/modelname`:
- **Single safetensor** (small model): `family-modelname` — no shard suffix
- **Multiple safetensors** (large model): `family-modelname-shard1`, `family-modelname-shard2`, ... `family-modelname-shardN`

Examples:
- `garak-llm/pegasus_paraphrase` (1 safetensor) → `garak-llm-pegasus_paraphrase`
- `Qwen/Qwen3.5-27B` (11 safetensors) → `Qwen-Qwen3.5-27B-shard1` ... `Qwen-Qwen3.5-27B-shard11`

---

## bake.sh — Universal Bake Script

`scripts/bake.sh` handles the full workflow: download one safetensor at a time, build, verify, push, cleanup. Always disk-efficient — peak usage is ~2x one safetensor file.

### Usage

```bash
bash scripts/bake.sh -m MODEL_REPO [OPTIONS]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `-m MODEL_REPO` | HF model repo (required) | — |
| `-t TAG_PREFIX` | Image tag prefix | derived from repo |
| `-s START_SHARD` | Starting shard number | 1 |
| `-u GHCR_USER` | GHCR username | vamshikadumuri |
| `-e EXCLUDE` | Comma-separated exclude patterns | — |
| `-v VENV_NAME` | Venv directory name | mymlbakeryenv |
| `-h` | Show help | — |

### How It Works

1. Lists safetensor files from HF repo via Python API
2. Downloads metadata (non-safetensor files) once
3. For each safetensor (one at a time):
   - Downloads the file directly into a shard build dir
   - Shard 1 also gets all metadata files
   - Builds Docker image
   - Verifies image contents match staged files
   - Pushes to GHCR (3 retries)
   - Cleans up shard dir + Docker image

Single-file models get a clean tag (`family-modelname`), multi-file models get shard suffixes (`family-modelname-shardN`).

### Resuming from a Specific Shard

If some shards are already pushed (e.g., shards 1-4), use `-s` and `-e` to skip them:

```bash
bash scripts/bake.sh -m Qwen/Qwen3.5-27B -s 5 \
  -e "model.safetensors-00001-*,model.safetensors-00002-*,model.safetensors-00003-*,model.safetensors-00004-*"
```

### Pre-Push Content Verification

After each shard is built, bake.sh automatically verifies the Docker image contents before pushing:
- Runs `docker run --rm` to list all files under `/models/` inside the built image
- Compares the actual file list against the locally staged files
- If the lists don't match, the push is **blocked** and the shard is treated as a failure
- On success, prints a summary: file count and total size in `/models/`

This ensures each shard contains exactly `models/<modelname>/<shard data>` for sharded images, or `models/<modelname>/<entire HF data>` for single images.

### Recovery on Failure

- On build/verify/push failure, the shard dir is **kept intact** for manual retry
- The work directory is **kept** when there are any failures
- Pre-flight check verifies Docker is available before starting
- Push retries up to 3 times (handles WSL credential store flakiness)

---

## Step-by-Step Workflow for Claude

### 1. Determine model details

Check the HF model page to find:
- Number of safetensor files
- File sizes (to estimate shard count)
- Whether sharding is needed (multiple safetensors)

### 2. Choose the right command

- **Small model (1 safetensor)**: Single image, clean tag
- **Large model**: Sharded automatically (1 safetensor = 1 shard)
- **Resuming a partial bake**: Use `-s` and `-e` flags

### 3. Run bake.sh

```bash
cd /path/to/mlbakery
bash scripts/bake.sh -m family/modelname [-s N] [-e "patterns"]
```

### 4. Verify

Content verification happens automatically before each push. After completion, check GHCR for the pushed images.

---

## What Claude Should Always Provide

For every bake request:

1. The correct `bake.sh` command with appropriate flags
2. Estimated number of shards (based on HF model file listing)
3. Disk space check (`df -h /mnt/d`)
4. For resumed bakes: the correct `-s` and `-e` values

---

## Legacy Scripts

- `build_image.sh` — Original download-only script (docker build/cleanup commented out)
- `scripts/segregate_shards_template.sh` — Standalone shard segregation template

These are superseded by `bake.sh` which combines all functionality.
