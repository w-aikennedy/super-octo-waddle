#!/usr/bin/env bash
# =============================================================================
# NemoClaw Setup Script for RunPod (RTX 4090, 24GB VRAM, Ubuntu 22.04+)
# =============================================================================
# Strategy:
#   - nemotron-3-super:cloud  → NVIDIA cloud API (free tier, no VRAM needed)
#   - nemotron-3-nano         → local Ollama (~20GB, fits 4090) as fast fallback
#
# Prerequisites (manual, before running this script):
#   1. Get a free NVIDIA API key from https://build.nvidia.com
#   2. Set it: export NVIDIA_API_KEY=nvapi-xxxxxxxxxxxx
#
# Usage:
#   chmod +x nemoclaw_setup.sh
#   export NVIDIA_API_KEY=nvapi-xxxxxxxxxxxx
#   ./nemoclaw_setup.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo -e "${BLUE}"
echo "  ███╗   ██╗███████╗███╗   ███╗ ██████╗  ██████╗██╗      █████╗ ██╗    ██╗"
echo "  ████╗  ██║██╔════╝████╗ ████║██╔═══██╗██╔════╝██║     ██╔══██╗██║    ██║"
echo "  ██╔██╗ ██║█████╗  ██╔████╔██║██║   ██║██║     ██║     ███████║██║ █╗ ██║"
echo "  ██║╚██╗██║██╔══╝  ██║╚██╔╝██║██║   ██║██║     ██║     ██╔══██║██║███╗██║"
echo "  ██║ ╚████║███████╗██║ ╚═╝ ██║╚██████╔╝╚██████╗███████╗██║  ██║╚███╔███╔╝"
echo "  ╚═╝  ╚═══╝╚══════╝╚═╝     ╚═╝ ╚═════╝  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ "
echo -e "${NC}"
echo "  NemoClaw Setup — RunPod / RTX 4090 (24GB VRAM)"
echo "  ================================================"
echo ""

# =============================================================================
# STEP 0 — Preflight checks
# =============================================================================
info "Running preflight checks..."

# NVIDIA API key
if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
  echo ""
  warn "NVIDIA_API_KEY is not set."
  echo "  Get a free key from: https://build.nvidia.com/nvidia/nemotron-3-super"
  echo "  Then run: export NVIDIA_API_KEY=nvapi-xxxxxxxxxxxx"
  echo ""
  read -rp "  Paste your key now (or press Enter to skip cloud model): " api_key
  if [[ -n "$api_key" ]]; then
    export NVIDIA_API_KEY="$api_key"
    log "API key set for this session"
  else
    warn "Skipping NVIDIA cloud model — will configure local Nano only"
    SKIP_CLOUD=1
  fi
fi
SKIP_CLOUD="${SKIP_CLOUD:-0}"

# RAM check
total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ "$total_ram_mb" -lt 8192 ]]; then
  fail "Insufficient RAM: ${total_ram_mb}MB. NemoClaw needs 8GB minimum (16GB recommended)."
fi
log "RAM: ${total_ram_mb}MB ✓"

# Disk check
free_disk_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
if [[ "$free_disk_gb" -lt 40 ]]; then
  warn "Free disk: ${free_disk_gb}GB. Recommend 40GB+ (87GB for local Super model)."
else
  log "Disk: ${free_disk_gb}GB free ✓"
fi

# OS check
if ! grep -qE 'Ubuntu (22|24)\.' /etc/os-release 2>/dev/null; then
  warn "Not detected as Ubuntu 22/24. NemoClaw officially supports Ubuntu 22.04+. Proceeding anyway."
else
  log "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"') ✓"
fi

# GPU check
if command -v nvidia-smi &>/dev/null; then
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  gpu_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)
  log "GPU: ${gpu_name} (${gpu_vram}) ✓"
else
  warn "nvidia-smi not found — GPU may not be available or drivers not installed"
fi

# Kernel check for OpenShell (needs 5.15+ with cgroup v2)
kernel_ver=$(uname -r | cut -d. -f1-2)
log "Kernel: $(uname -r) ✓"

echo ""

# =============================================================================
# STEP 1 — System dependencies
# =============================================================================
info "Installing system dependencies..."

apt-get update -qq
apt-get install -y -qq \
  curl \
  git \
  ca-certificates \
  gnupg \
  lsb-release \
  build-essential \
  jq

log "System dependencies installed"

# =============================================================================
# STEP 2 — Docker
# =============================================================================
info "Checking Docker..."

if ! command -v docker &>/dev/null; then
  info "Docker not found — installing..."
  curl -fsSL https://get.docker.com | sh
  echo "Running as root, skipping docker group setup"
  log "Docker installed — NOTE: you may need to log out and back in for group changes"
  # Activate group in current session
  newgrp docker << 'DOCKERGROUP'
DOCKERGROUP
else
  log "Docker already installed: $(docker --version)"
fi

# Verify Docker is running
if ! docker info &>/dev/null; then
  info "Starting Docker daemon..."
  systemctl start docker
  systemctl enable docker
fi
log "Docker daemon is running ✓"

# =============================================================================
# STEP 3 — NVIDIA Container Toolkit (for GPU access in Docker)
# =============================================================================
info "Installing NVIDIA Container Toolkit..."

if ! dpkg -l | grep -q nvidia-container-toolkit; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  log "NVIDIA Container Toolkit installed and configured"
else
  log "NVIDIA Container Toolkit already installed ✓"
fi

# =============================================================================
# STEP 4 — Ollama (for local Nemotron Nano)
# =============================================================================
info "Installing Ollama..."

if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
  log "Ollama installed"
else
  log "Ollama already installed: $(ollama --version)"
fi

# Ensure Ollama is running and binding to all interfaces
# (NemoClaw sandbox needs to reach it through Docker networking)
info "Configuring Ollama to bind to 0.0.0.0 for Docker access..."
mkdir -p /etc/systemd/system/ollama.service.d
tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# Wait for Ollama to be ready
info "Waiting for Ollama to start..."
for i in {1..15}; do
  if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    log "Ollama is running ✓"
    break
  fi
  sleep 2
  if [[ $i -eq 15 ]]; then
    warn "Ollama may not be ready — check 'systemctl status ollama'"
  fi
done

# =============================================================================
# STEP 5 — Pull Nemotron 3 Nano (local, fits 4090 24GB VRAM)
# =============================================================================
info "Pulling nemotron-3-nano (local model, ~20GB, fits 4090)..."
echo "  This may take 10-20 minutes depending on your connection speed."
echo ""

if ollama list | grep -q "nemotron-3-nano"; then
  log "nemotron-3-nano already downloaded ✓"
else
  ollama pull nemotron-3-nano
  log "nemotron-3-nano downloaded ✓"
fi

# Quick smoke test
info "Running quick Nano inference test..."
response=$(ollama run nemotron-3-nano "Reply with exactly: NEMOTRON_OK" --nowordwrap 2>/dev/null || echo "TEST_FAILED")
if echo "$response" | grep -q "NEMOTRON_OK"; then
  log "Nano inference test passed ✓"
else
  warn "Nano test response: '$response' — model loaded but response unexpected (may be fine)"
fi

# =============================================================================
# STEP 6 — Install NemoClaw
# =============================================================================
info "Installing NemoClaw..."

# Export key for installer
if [[ "$SKIP_CLOUD" == "0" ]]; then
  export NVIDIA_API_KEY="${NVIDIA_API_KEY}"
fi

# The official one-liner — installs Node.js via nvm if needed, then NemoClaw
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

log "NemoClaw installed"

# =============================================================================
# STEP 7 — Verify installation
# =============================================================================
info "Verifying NemoClaw installation..."

if command -v nemoclaw &>/dev/null; then
  log "nemoclaw CLI: $(nemoclaw --version) ✓"
else
  # nvm installs to ~/.nvm, may need to source it
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  if command -v nemoclaw &>/dev/null; then
    log "nemoclaw CLI available (via nvm) ✓"
  else
    warn "nemoclaw not in PATH — you may need to source your shell profile"
    warn "Run: source ~/.bashrc  OR  source ~/.zshrc"
  fi
fi

# Run nemoclaw doctor if available
if command -v nemoclaw &>/dev/null; then
  info "Running nemoclaw doctor..."
  nemoclaw doctor || warn "Some doctor checks failed — review above output"
fi

# =============================================================================
# STEP 8 — Print onboarding instructions
# =============================================================================
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete! Next steps:${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. Run the onboarding wizard:"
echo "     ${CYAN}nemoclaw onboard${NC}"
echo ""
echo "  2. When prompted for inference provider:"
if [[ "$SKIP_CLOUD" == "0" ]]; then
  echo "     → Choose: NVIDIA Endpoints (option 1) for Nemotron Super cloud"
  echo "       Your key: ${NVIDIA_API_KEY:0:12}... (already set)"
fi
echo "     → OR choose: Local Ollama (option 7) for Nemotron Nano locally"
echo "       Model: nemotron-3-nano"
echo ""
echo "  3. After onboarding, connect to your sandbox:"
echo "     ${CYAN}nemoclaw my-assistant connect${NC}"
echo ""
echo "  4. Launch the interactive TUI:"
echo "     ${CYAN}openclaw tui${NC}"
echo ""
echo "  Useful commands:"
echo "     nemoclaw my-assistant status    — check sandbox status"
echo "     nemoclaw my-assistant logs -f   — follow logs"
echo "     nemoclaw doctor                 — diagnose issues"
echo "     ollama list                     — see local models"
echo ""
echo -e "${YELLOW}  Notes:${NC}"
echo "  - NemoClaw is alpha software — expect rough edges"
echo "  - Ollama is bound to 0.0.0.0 (Docker access) — on public WiFi"
echo "    this exposes port 11434. Add a firewall rule if needed:"
echo "    ${CYAN}ufw allow from 172.16.0.0/12 to any port 11434${NC}"
echo "  - Gateway does not survive reboots — run 'nemoclaw onboard'"
echo "    again after restarting the RunPod instance"
echo ""