---
name: mlbakery
description: >
  Bakes Hugging Face models (and datasets) into Docker images and pushes them to ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery.
  Use this skill whenever the user mentions baking a model, building a model image, sharding a model, pushing to GHCR,
  running build_image.sh, or says anything like "bake X model", "build image for Y", "shard and bake", 
  "push model to registry", "mlbakery", or references a Hugging Face model ID in the context of Docker image creation.
  Always trigger proactively — don't wait for the user to say "use the mlbakery skill" explicitly.
---

# MLBakery Skill

Bakes Hugging Face models/datasets into Docker images and pushes them to GHCR.

## Key Config

| Setting | Value |
|---|---|
| Script location (WSL) | `/path/to/your/mlbakery/` |
| Image registry | `ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery` |
| GHCR token | `<YOUR_GHCR_TOKEN>` |
| HF token | `<YOUR_HF_TOKEN>` |
| venv packages | `hf_transfer==0.1.9`, `huggingface-hub==0.34.3` |

## IMAGE_TAG Format

Given a HF model ID `family/modelname`:
- **Single image**: `family-modelname`  ← replace `/` with `-`
- **Sharded**: `Family-ModelName-shard1`, `Family-ModelName-shard2`, ... `Family-ModelName-shardN`

Examples:
- `garak-llm/pegasus_paraphrase` → `garak-llm-pegasus_paraphrase`
- `Qwen/Qwen3-32B` (sharded, 17 shards) → `Qwen-Qwen3-32B-shard1` ... `Qwen-Qwen3-32B-shard17`

---

## Step-by-Step Workflow

### 1. Determine if the model needs sharding

Ask the user (or check HF) whether the model has multiple `.safetensors` files. 

- **Single safetensors or small model** → single image workflow
- **Multiple safetensors** → sharded workflow

Rule of thumb: each shard image must stay under 4 GB. Metadata files (`.json`, `.txt`, `tokenizer*`, `config*`, `*.model`, etc.) go into **shard1** alongside the first safetensors file.

---

### 2. Update IMAGE_TAG in build_image.sh

Before running anything, edit `build_image.sh` and replace the `IMAGE_TAG=...` line at the top:

```bash
# In build_image.sh, find this line:
IMAGE_TAG=<whatever_was_there>

# Replace with (single image example):
IMAGE_TAG=garak-llm-pegasus_paraphrase

# Or for sharded (you'll run this multiple times, updating each time):
IMAGE_TAG=Qwen-Qwen3-32B-shard1
```

---

### 3A. Single Image — Run & Push

```bash
# Navigate to the script directory
cd "/path/to/your/mlbakery"

# Activate venv
source <your-venv>/bin/activate

# Run the build
bash build_image.sh -m family/modelname

# Push to GHCR
echo <YOUR_GHCR_TOKEN> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin
docker push ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery:family-modelname
```

---

### 3B. Sharded Model — Full Workflow

When a model has multiple `.safetensors` files, follow this extended workflow:

#### Step 1: Download only (skip cleanup)

Comment out the `rm -rf "$TEMP_DIR"` line in `build_image.sh` temporarily, then download:

```bash
bash build_image.sh -m Qwen/Qwen3-32B
```

This downloads everything into `temp_YYYYMMDD/models/Qwen3-32B/`.

#### Step 2: Run the shard segregation script

Claude will generate a `segregate_shards.sh` script for you (see below). Run it:

```bash
bash segregate_shards.sh \
  --model-dir "temp_YYYYMMDD/models/Qwen3-32B" \
  --output-base "temp_YYYYMMDD" \
  --tag-prefix "Qwen-Qwen3-32B" \
  --max-shard-gb 4.0
```

This creates:
```
temp_YYYYMMDD/
  shard1/
    models/Qwen3-32B/   ← metadata files + model-00001-of-XXXXX.safetensors
    datasets/
    Dockerfile
  shard2/
    models/Qwen3-32B/   ← model-00002-of-XXXXX.safetensors
    datasets/
    Dockerfile
  ...
```

#### Step 3: Build each shard image

For each shard directory:

```bash
# Update IMAGE_TAG in build_image.sh for each shard, then:
docker build -t ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery:Qwen-Qwen3-32B-shard1 temp_YYYYMMDD/shard1
docker build -t ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery:Qwen-Qwen3-32B-shard2 temp_YYYYMMDD/shard2
# ... repeat for all shards
```

Or use the loop commands Claude generates for you.

#### Step 4: Push all shards

```bash
echo <YOUR_GHCR_TOKEN> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin

for i in $(seq 1 <N>); do
  docker push ghcr.io/<YOUR_GITHUB_USERNAME>/mlbakery:Qwen-Qwen3-32B-shard${i}
done
```

#### Step 5: Clean up

```bash
rm -rf temp_YYYYMMDD
```

---

## Shard Segregation Script Generation

When the user needs to shard a model, generate a `segregate_shards.sh` script. See `scripts/segregate_shards_template.sh` for the full template to use — read it and adapt it to the specific model.

---

## What Claude Should Always Output

For every bake request, Claude should provide:

1. ✅ The correct `IMAGE_TAG` value(s) to put in `build_image.sh`
2. ✅ The exact `bash build_image.sh ...` command(s) to run
3. ✅ For sharded models: the generated `segregate_shards.sh` script
4. ✅ The `docker build` loop (for shards) or single build command
5. ✅ The `docker push` command(s)
6. ✅ Cleanup command

Always confirm with the user: is this a model or a dataset (`-m` vs `-d` flag)?
