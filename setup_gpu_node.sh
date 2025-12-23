#!/bin/bash

################################################################################
# GPU Node Setup Script for Distributed AI Cluster
# Machine 1: Primary inference server with GPU acceleration
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/ai-cluster"
CONFIG_DIR="/etc/ai-cluster"
MODEL_DIR="${INSTALL_DIR}/models"
LOG_FILE="/var/log/ai-cluster-setup.log"

# Helper functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
}

################################################################################
# Main Setup
################################################################################

log "========================================="
log "GPU Node Setup - Starting Installation"
log "========================================="

check_root

# Create directories
log "Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$MODEL_DIR"
mkdir -p /var/log/ai-cluster

################################################################################
# 1. System Update
################################################################################

log "Updating system packages..."
apt update && apt upgrade -y

log "Installing essential tools..."
apt install -y \
    build-essential \
    git \
    curl \
    wget \
    htop \
    net-tools \
    ufw \
    software-properties-common

################################################################################
# 2. Install Yggdrasil
################################################################################

log "Installing Yggdrasil network daemon..."

if ! command -v yggdrasil &> /dev/null; then
    # Add Yggdrasil repository
    gpg --fetch-keys https://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/key.txt
    gpg --export 569130E8CA20FBC4CB3FDE555898470A764B32C9 | sudo tee /usr/share/keyrings/yggdrasil-keyring.gpg > /dev/null
    
    echo "deb [signed-by=/usr/share/keyrings/yggdrasil-keyring.gpg] http://neilalexander.s3.dualstack.eu-west-2.amazonaws.com/deb/ debian yggdrasil" | \
        sudo tee /etc/apt/sources.list.d/yggdrasil.list
    
    apt update
    apt install -y yggdrasil
    
    log "Generating Yggdrasil configuration..."
    yggdrasil -genconf > /etc/yggdrasil/yggdrasil.conf
    
    systemctl enable yggdrasil
    systemctl start yggdrasil
    
    sleep 3  # Wait for Yggdrasil to initialize
else
    log "Yggdrasil already installed"
fi

# Get Yggdrasil IPv6 address
YGGDRASIL_IP=$(yggdrasilctl getSelf | grep 'IPv6 address' | awk '{print $3}')
info "Yggdrasil IPv6: $YGGDRASIL_IP"

# Save to config
cat > "$CONFIG_DIR/gpu-node.conf" <<EOF
# GPU Node Configuration
YGGDRASIL_IP=$YGGDRASIL_IP
HOSTNAME=$(hostname)
INSTALL_DIR=$INSTALL_DIR
MODEL_DIR=$MODEL_DIR
SETUP_DATE=$(date)
EOF

################################################################################
# 3. Install Nvidia Drivers & CUDA
################################################################################

log "Checking for Nvidia GPU..."
if lspci | grep -i nvidia > /dev/null; then
    log "Nvidia GPU detected!"
    
    if ! command -v nvidia-smi &> /dev/null; then
        log "Installing Nvidia drivers..."
        
        # Add Nvidia repository
        add-apt-repository -y ppa:graphics-drivers/ppa
        apt update
        
        # Install driver
        apt install -y nvidia-driver-535 nvidia-dkms-535
        
        log "Installing CUDA Toolkit..."
        wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i cuda-keyring_1.1-1_all.deb
        apt update
        apt install -y cuda-toolkit-12-3
        
        # Add CUDA to PATH
        cat >> /etc/environment <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
        
        # Load new environment
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
        
        warn "Nvidia drivers installed. REBOOT REQUIRED before continuing!"
        info "After reboot, run this script again to continue setup."
        
        echo ""
        read -p "Reboot now? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            reboot
        else
            warn "Please reboot manually and re-run this script"
            exit 0
        fi
    else
        log "Nvidia drivers already installed"
        nvidia-smi || error "Nvidia driver not working properly"
    fi
else
    error "No Nvidia GPU detected! This script is for GPU nodes only."
fi

################################################################################
# 4. Compile llama.cpp with CUDA Support
################################################################################

log "Setting up llama.cpp..."

cd "$INSTALL_DIR"

if [ ! -d "llama.cpp" ]; then
    log "Cloning llama.cpp repository..."
    git clone https://github.com/ggerganov/llama.cpp.git
else
    log "llama.cpp already cloned, pulling latest..."
    cd llama.cpp
    git pull
    cd ..
fi

cd llama.cpp

log "Compiling llama.cpp with CUDA support..."
make clean
make LLAMA_CUDA=1 -j$(nproc)

# Verify compilation
if [ ! -f "llama-server" ]; then
    error "llama-server binary not found! Compilation failed."
fi

if [ ! -f "llama-rpc-server" ]; then
    error "llama-rpc-server binary not found! RPC support missing."
fi

log "llama.cpp compiled successfully!"

################################################################################
# 5. Create Systemd Service for llama-server
################################################################################

log "Creating systemd service..."

cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp Inference Server (GPU Node)
After=network.target yggdrasil.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/llama.cpp
Environment="CUDA_VISIBLE_DEVICES=0"
ExecStart=$INSTALL_DIR/llama.cpp/llama-server \\
    --model $MODEL_DIR/qwen3-14b-q4_k_m.gguf \\
    --host $YGGDRASIL_IP \\
    --port 8080 \\
    --ctx-size 4096 \\
    --n-gpu-layers 30 \\
    --threads $(nproc) \\
    --rpc 50052 \\
    --flash-attn \\
    --cont-batching

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llama-server

log "Systemd service created (will start after model is downloaded)"

################################################################################
# 6. Configure Firewall
################################################################################

log "Configuring firewall..."

# Enable UFW
ufw --force enable

# Allow SSH
ufw allow 22/tcp

# Allow Yggdrasil
ufw allow from any to any port 8080 proto tcp
ufw allow from any to any port 50052 proto tcp

# Set default policies
ufw default deny incoming
ufw default allow outgoing

log "Firewall configured"

################################################################################
# 7. Final Summary
################################################################################

log "========================================="
log "GPU Node Setup Complete!"
log "========================================="

info "Configuration saved to: $CONFIG_DIR/gpu-node.conf"
info ""
info "Yggdrasil IPv6 Address: $YGGDRASIL_IP"
info "  ⚠️  IMPORTANT: Save this address! You'll need it for other machines."
info ""
info "Next Steps:"
info "  1. Download the model with: ./download_model.sh"
info "  2. Start the server: sudo systemctl start llama-server"
info "  3. Check status: sudo systemctl status llama-server"
info "  4. View logs: sudo journalctl -u llama-server -f"
info ""
info "Test API:"
info "  curl http://localhost:8080/health"
info ""

# Save Yggdrasil IP to easy-to-find file
echo "$YGGDRASIL_IP" > "$INSTALL_DIR/YGGDRASIL_IP.txt"

log "Setup script completed successfully!"
