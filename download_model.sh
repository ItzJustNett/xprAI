#!/bin/bash

################################################################################
# Model Download Script for Qwen3-14B (Unsloth GGUF)
# Downloads the model from HuggingFace
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODEL_DIR="/opt/ai-cluster/models"
MODEL_NAME="qwen3-14b-q4_k_m.gguf"

# Unsloth Qwen3-14B GGUF
MODEL_URL="https://huggingface.co/unsloth/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf"

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log "========================================="
log "Model Download Script - Qwen3-14B (Unsloth)"
log "========================================="

mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

if [ -f "$MODEL_NAME" ]; then
    warn "Model already exists at: $MODEL_DIR/$MODEL_NAME"
    read -p "Re-download? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Skipping download"
        exit 0
    fi
    rm "$MODEL_NAME"
fi

log "Downloading Qwen3-14B from Unsloth (Q4_K_M quantization)..."
info "Size: ~8GB - This may take 10-30 minutes"
info ""

# Download with progress bar
wget --progress=bar:force:noscroll \
     --continue \
     --show-progress \
     "$MODEL_URL" \
     -O "$MODEL_NAME"

if [ $? -eq 0 ] && [ -f "$MODEL_NAME" ]; then
    log "Download complete!"
    info "Model saved to: $MODEL_DIR/$MODEL_NAME"
    info "Size: $(du -h "$MODEL_NAME" | cut -f1)"
    info ""
    info "You can now start the llama-server:"
    info "  sudo systemctl start llama-server"
else
    echo "Download failed! Please check your internet connection."
    exit 1
fi
