# Distributed AI Inference Cluster Setup

Automated installation scripts for running Qwen2.5:14B across multiple machines using llama.cpp and Yggdrasil networking.

## Architecture
```
Machine 1 (GPU Node)          Machine 2 (CPU Worker)       Machine 3 (WebUI Host)
├─ Nvidia RTX 2050           ├─ CPU only                  ├─ Docker
├─ llama.cpp server          ├─ llama.cpp rpc-server      ├─ OpenWebUI
├─ GPU acceleration          └─ Handles offloaded layers  └─ Web interface
└─ Primary inference
         ↓                            ↓                            ↓
         └────────────── Yggdrasil Network ──────────────────────┘
```

## Prerequisites

- Ubuntu Server 22.04 LTS (fresh install on all machines)
- Internet connection during setup
- Sudo privileges
- At least 20GB free disk space per machine

## Installation Order

### Step 1: Setup GPU Node (Machine 1)
```bash
# On Machine 1:
chmod +x setup_gpu_node.sh
sudo ./setup_gpu_node.sh
```

**This will:**
- Install Yggdrasil
- Install Nvidia drivers + CUDA
- Compile llama.cpp with GPU support
- Configure llama.cpp server with RPC support
- Create systemd service

**After completion:**
- Note the Yggdrasil IPv6 address displayed
- Reboot when prompted (for Nvidia drivers)

### Step 2: Download Model (Machine 1)
```bash
# After reboot, on Machine 1:
chmod +x download_model.sh
./download_model.sh
```

**This will:**
- Download Qwen2.5-14B-Instruct-Q4_K_M.gguf (~8GB)
- Place it in `/opt/ai-cluster/models/`
- May take 10-30 minutes depending on connection

### Step 3: Setup CPU Worker (Machine 2)
```bash
# On Machine 2:
chmod +x setup_cpu_worker.sh
sudo ./setup_cpu_worker.sh
```

**When prompted:**
- Enter Machine 1's Yggdrasil IPv6 address

**This will:**
- Install Yggdrasil
- Compile llama.cpp
- Configure RPC server to connect to Machine 1
- Create systemd service

### Step 4: Setup WebUI Host (Machine 3)
```bash
# On Machine 3:
chmod +x setup_webui_host.sh
sudo ./setup_webui_host.sh
```

**When prompted:**
- Enter Machine 1's Yggdrasil IPv6 address

**This will:**
- Install Yggdrasil + Docker
- Pull and configure OpenWebUI
- Set up systemd service
- Configure firewall

### Step 5: Start Services
```bash
# On Machine 1:
sudo systemctl start llama-server

# On Machine 2:
sudo systemctl start llama-rpc-worker

# On Machine 3:
sudo systemctl start openwebui
```

## Verification

### Check Yggdrasil Connectivity
```bash
# From any machine, ping others:
ping6 -c 3 [other-machine-yggdrasil-ipv6]
```

### Check Services Status
```bash
# Machine 1:
sudo systemctl status llama-server
curl http://localhost:8080/health

# Machine 2:
sudo systemctl status llama-rpc-worker

# Machine 3:
sudo systemctl status openwebui
# Access UI: http://[machine-3-lan-ip]:3000
```

### Test Inference
```bash
# From Machine 1:
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-14b",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Accessing OpenWebUI

1. Open browser on your laptop/desktop
2. Go to: `http://[machine-3-lan-ip]:3000`
3. Create an account (first user is admin)
4. Start chatting!

## Configuration Files

- **Machine 1:** `/etc/ai-cluster/gpu-node.conf`
- **Machine 2:** `/etc/ai-cluster/cpu-worker.conf`
- **Machine 3:** `/etc/ai-cluster/webui.conf`
- **Yggdrasil:** `/etc/yggdrasil/yggdrasil.conf`

## Logs
```bash
# View service logs:
sudo journalctl -u llama-server -f      # Machine 1
sudo journalctl -u llama-rpc-worker -f  # Machine 2
sudo journalctl -u openwebui -f         # Machine 3
```

## Troubleshooting

### Nvidia Driver Issues (Machine 1)
```bash
# Check driver:
nvidia-smi

# If not working:
sudo apt install --reinstall nvidia-driver-535
sudo reboot
```

### Yggdrasil Connection Issues
```bash
# Check Yggdrasil status:
sudo systemctl status yggdrasil

# View Yggdrasil info:
yggdrasilctl getSelf

# Restart Yggdrasil:
sudo systemctl restart yggdrasil
```

### llama.cpp Server Not Starting
```bash
# Check if model exists:
ls -lh /opt/ai-cluster/models/

# Check GPU availability:
nvidia-smi

# Test manual start:
cd /opt/ai-cluster/llama.cpp
./llama-server -m /opt/ai-cluster/models/qwen2.5-14b-instruct-q4_k_m.gguf -c 4096 --port 8080
```

### RPC Worker Can't Connect
```bash
# Verify Machine 1's Yggdrasil IP:
# On Machine 1:
yggdrasilctl getSelf | grep IPv6

# Test connectivity from Machine 2:
ping6 [machine-1-yggdrasil-ipv6]

# Check if port 50052 is open on Machine 1:
# On Machine 1:
sudo ss -tulpn | grep 50052
```

### OpenWebUI Can't Connect to API
```bash
# Check Machine 1 API is accessible:
# From Machine 3:
curl -v http://[machine-1-yggdrasil-ipv6]:8080/health

# Check OpenWebUI logs:
sudo docker logs -f openwebui

# Restart OpenWebUI:
sudo systemctl restart openwebui
```

## Performance Tuning

### Adjust GPU Layers (Machine 1)

Edit `/etc/systemd/system/llama-server.service`:
```ini
# Increase for more GPU usage (faster but needs more VRAM):
--n-gpu-layers 35

# Decrease if getting CUDA OOM errors:
--n-gpu-layers 25
```

Then: `sudo systemctl daemon-reload && sudo systemctl restart llama-server`

### Adjust CPU Threads (Machine 2)

Edit `/etc/systemd/system/llama-rpc-worker.service`:
```ini
# Set threads manually:
--threads 8
```

## Security Notes

- All inter-node traffic encrypted via Yggdrasil
- No services exposed to internet
- OpenWebUI only accessible from LAN
- Firewall (ufw) enabled on all machines

## Maintenance

### Update llama.cpp
```bash
# On each machine:
cd /opt/ai-cluster/llama.cpp
git pull
make clean
make LLAMA_CUDA=1  # GPU node only
make               # CPU nodes
sudo systemctl restart llama-*
```

### Update OpenWebUI
```bash
# On Machine 3:
sudo docker pull ghcr.io/open-webui/open-webui:main
sudo systemctl restart openwebui
```

## Uninstallation
```bash
# On each machine:
sudo systemctl stop llama-* openwebui yggdrasil
sudo systemctl disable llama-* openwebui yggdrasil
sudo rm -rf /opt/ai-cluster
sudo rm /etc/systemd/system/llama-* /etc/systemd/system/openwebui.service
```

## Support

For issues:
1. Check logs with `journalctl`
2. Verify network connectivity with `ping6`
3. Ensure all services are running with `systemctl status`

## License

MIT License - Feel free to modify and distribute
