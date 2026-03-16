#!/bin/bash

# Set default values for image name and tag
IMAGE_NAME=ghcr.io/vamshikadumuri/mlbakery
IMAGE_TAG=Qwen-Qwen3.5-27B-shard1
REMOVE_PATTERNS=""
MODELS=""
DATASETS=""

# Dockerfile contents
DOCKERFILE="
FROM ubuntu:latest

# Install necessary packages
RUN apt-get update && \\
    apt-get install -y g++

RUN apt-get install -y python3 python3-pip git htop

# Copy the model and dataset files into the container
WORKDIR /models
COPY models/ /models/

WORKDIR /datasets
COPY datasets/ /datasets/
"

# Function to print usage
print_usage() {
    echo "Usage: $0 [-n IMAGE_NAME] [-t IMAGE_TAG] [-m MODELS] [-d DATASETS] [-r REMOVE_PATTERNS]"
    echo "  -n IMAGE_NAME          Set the name of the Docker image (default: $IMAGE_NAME)"
    echo "  -t IMAGE_TAG           Set the tag for the Docker image (default: $IMAGE_TAG)"
    echo "  -m MODELS              Comma-separated list of Hugging Face models to download"
    echo "  -d DATASETS            Comma-separated list of Hugging Face datasets to download"
    echo "  -r REMOVE_PATTERNS     Comma-separated list of files/directories to remove from each model/dataset directory"
    echo "  -h                     Display this help message"
    echo ""x
    echo "Note: This script requires HF_HUB_ENABLE_HF_TRANSFER to be successfully enabled."
    echo "  # Exclude 'original' folder during download:"
    echo "  $0 -m openai/gpt-oss-120b -e 'original/*'"
    echo ""
    echo "  # Exclude multiple patterns:"
    echo "  $0 -m openai/gpt-oss-120b -e 'original/*,metal/*,*.bin'"
}

# Parse command-line arguments
while getopts "n:t:m:d:r:e:i:h" opt; do
    case $opt in
        n)
            IMAGE_NAME=$OPTARG
            ;;
        t)
            IMAGE_TAG=$OPTARG
            ;;
        m)
            MODELS=$OPTARG
            ;;
        d)
            DATASETS=$OPTARG
            ;;
        r)
            REMOVE_PATTERNS=$OPTARG
            ;;
        e)
            EXCLUDE_PATTERNS=$OPTARG
            ;;
        i)
            INCLUDE_PATTERN=$OPTARG
            ;;
        h)
            print_usage
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Check if at least one model or dataset is provided
if [ -z "$MODELS" ] && [ -z "$DATASETS" ]; then
    echo "Error: No models or datasets provided." >&2
    print_usage
    exit 1
fi

# Enable hf_transfer (already verified to work)
export HF_HUB_ENABLE_HF_TRANSFER=1
echo "🔧 HF_HUB_ENABLE_HF_TRANSFER=1 (fast downloads confirmed working)"

# Create a temporary directory
# TEMP_DIR=$(mkdir -d)
TEMP_DIR="temp_$(date +%Y%m%d)"
mkdir "$TEMP_DIR"
chmod 777 "$TEMP_DIR"


# Create directories for models and datasets
mkdir -p "$TEMP_DIR/models"
mkdir -p "$TEMP_DIR/datasets"

# Write Dockerfile to temporary directory
echo "$DOCKERFILE" > "$TEMP_DIR/Dockerfile"

# Build exclude arguments for huggingface-cli
EXCLUDE_ARGS=""
if [ -n "$EXCLUDE_PATTERNS" ]; then
    echo "📋 Exclude patterns specified: $EXCLUDE_PATTERNS"
    IFS=',' read -ra EXCLUDE_LIST <<< "$EXCLUDE_PATTERNS"
    for PATTERN in "${EXCLUDE_LIST[@]}"; do
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude \"$PATTERN\""
    done
fi

# Download models using Hugging Face CLI with hf_transfer enabled
if [ -n "$MODELS" ]; then
    echo "Downloading models with hf_transfer (fast mode)..."
    IFS=',' read -ra MODEL_LIST <<< "$MODELS"
    for MODEL in "${MODEL_LIST[@]}"; do
        MODEL_DIR="$TEMP_DIR/models/$(basename "$MODEL")"
        mkdir -p "$MODEL_DIR"

        FILES_TO_DOWNLOAD=$(echo $INCLUDE_PATTERN | tr ',' ' ')

        # Build the command with exclude patterns
        DOWNLOAD_CMD="HF_HUB_ENABLE_HF_TRANSFER=1 HF_TOKEN=\"HF_TOKEN\" huggingface-cli download \"$MODEL\" $FILES_TO_DOWNLOAD --local-dir \"$MODEL_DIR\" --repo-type model"

        if [ -n "$EXCLUDE_PATTERNS" ]; then
            IFS=',' read -ra EXCLUDE_LIST <<< "$EXCLUDE_PATTERNS"
            for PATTERN in "${EXCLUDE_LIST[@]}"; do
                DOWNLOAD_CMD="$DOWNLOAD_CMD --exclude \"$PATTERN\""
            done
            echo "   🚫 Excluding: $EXCLUDE_PATTERNS"
        fi
        
        # Execute the download command
        eval $DOWNLOAD_CMD
        
        if [ $? -eq 0 ]; then
            echo "   ✅ Successfully downloaded $MODEL"
        else
            echo "   ❌ Failed to download $MODEL"
        fi
    done
fi

# Download datasets using Hugging Face CLI with hf_transfer enabled
if [ -n "$DATASETS" ]; then
    echo "Downloading datasets with hf_transfer (fast mode)..."
    IFS=',' read -ra DATASET_LIST <<< "$DATASETS"
    for DATASET in "${DATASET_LIST[@]}"; do
        DATASET_DIR="$TEMP_DIR/datasets/$(basename "$DATASET")"
        mkdir -p "$DATASET_DIR"
        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download "$DATASET" --local-dir "$DATASET_DIR" --repo-type dataset
    done
fi

# Remove specified files/directories from models and datasets
if [ -n "$REMOVE_PATTERNS" ]; then
    echo "Removing specified files/directories..."
    IFS=',' read -ra PATTERNS <<< "$REMOVE_PATTERNS"
    for PATTERN in "${PATTERNS[@]}"; do
        if [ -n "$MODELS" ]; then
            for MODEL_DIR in "$TEMP_DIR/models/"*; do
                echo "Removing $PATTERN from $MODEL_DIR"
                rm -rf "$MODEL_DIR/$PATTERN"
            done
        fi
        if [ -n "$DATASETS" ]; then
            for DATASET_DIR in "$TEMP_DIR/datasets/"*; do
                echo "Removing $PATTERN from $DATASET_DIR"
                rm -rf "$DATASET_DIR/$PATTERN"
            done
        fi
    done
fi

# Build Docker image
echo "Building Docker image $IMAGE_NAME:$IMAGE_TAG..."
# docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$TEMP_DIR"


# Clean up temporary directory
# rm -rf "$TEMP_DIR"

# echo "Docker image $IMAGE_NAME:$IMAGE_TAG built successfully."