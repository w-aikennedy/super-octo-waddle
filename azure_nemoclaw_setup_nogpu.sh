#!/usr/bin/env bash
# =============================================================================
# NemoClaw Setup Script — Azure VM (Ubuntu 22.04+, CPU-only, cloud inference)
# =============================================================================
# Strategy:
#   - nemotron-3-super:cloud → NVIDIA cloud API (free tier, no GPU needed)
#   - No local model — all inference routed to NVIDIA endpoints
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
echo "  NemoClaw Setup — Azure VM / Ubuntu / Cloud Inference"
echo "  ====================================================="
echo -e "${NC}"

# =============================================================================
# STEP 0 — Preflight checks
# =============================================================================
info "Running preflight checks..."

# NVIDIA API key
if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
  echo ""
  warn "NVIDIA_API_KEY is not set."
  echo "  Get a free key from: https://build.nvidia.com/nvidia/nemotron-3-super"
  echo ""
  read -rp "  Paste your key now (or press Enter to abort): " api_key
  if [[ -n "$api_key" ]]; then
    export NVIDIA_API_KEY="$api_key"
    log "API key set for this session"
  else
    fail "NVIDIA_API_KEY is required for cloud inference. Aborting."
  fi
fi

# RAM check
total_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ "$total_ram_mb" -lt 8192 ]]; then
  fail "Insufficient RAM: ${total_ram_mb}MB. NemoClaw needs 8GB minimum."
fi
log "RAM: ${total_ram_mb}MB ✓"

# Disk check
free_disk_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G ')
if [[ "$free_disk_gb" -lt 20 ]]; then
  warn "Free disk: ${free_disk_gb}GB. 20GB+ recommended."
else
  log "Disk: ${free_disk_gb}GB free ✓"
fi

# OS check
if ! grep -qE 'Ubuntu (22|24)\.' /etc/os-release 2>/dev/null; then
  warn "Not Ubuntu 22/24 — NemoClaw officially supports Ubuntu 22.04+. Proceeding anyway."
else
  log "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"') ✓"
fi

log "Kernel: $(uname -r) ✓"
echo ""

# =============================================================================
# STEP 1 — System dependencies
# =============================================================================
info "Installing system dependencies..."

sudo apt-get update -qq
sudo apt-get install -y -qq \
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
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  log "Docker installed"
  warn "Added to docker group — using 'sudo docker' for remainder of this session."
fi

sudo systemctl enable docker --quiet
sudo systemctl start docker

# Wait for Docker to be ready
info "Waiting for Docker daemon..."
for i in {1..15}; do
  if sudo docker info &>/dev/null; then
    log "Docker daemon running ✓"
    break
  fi
  sleep 2
  if [[ $i -eq 15 ]]; then
    fail "Docker failed to start. Run: sudo systemctl status docker"
  fi
done

# =============================================================================
# STEP 3 — Install NemoClaw
# =============================================================================
info "Installing NemoClaw..."
echo "  This installs Node.js (via nvm) and the NemoClaw CLI."
echo ""

export NVIDIA_API_KEY="${NVIDIA_API_KEY}"
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

log "NemoClaw installer complete"

# =============================================================================
# STEP 4 — Ensure nemoclaw is in PATH
# =============================================================================
info "Sourcing nvm to pick up nemoclaw..."

export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

if ! command -v nemoclaw &>/dev/null; then
  warn "nemoclaw not in PATH yet — run: source ~/.bashrc"
else
  log "nemoclaw CLI: $(nemoclaw --version) ✓"
fi

# =============================================================================
# STEP 5 — Run nemoclaw doctor
# =============================================================================
if command -v nemoclaw &>/dev/null; then
  info "Running nemoclaw doctor..."
  nemoclaw doctor || warn "Some checks failed — review output above"
fi

# =============================================================================
# STEP 6 — Summary
# =============================================================================
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete! Next steps:${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. If nemoclaw isn't found, reload your shell first:"
echo "     ${CYAN}source ~/.bashrc${NC}"
echo ""
echo "  2. Run the onboarding wizard:"
echo "     ${CYAN}nemoclaw onboard${NC}"
echo ""
echo "  3. When the wizard asks for inference provider:"
echo "     → Choose: NVIDIA Endpoints (option 1)"
echo "     → Your key starts with: ${NVIDIA_API_KEY:0:12}..."
echo "     → Model: nvidia/nemotron-3-super-120b-a12b (default)"
echo ""
echo "  4. When asked for a sandbox name, use something like: my-assistant"
echo ""
echo "  5. After onboarding:"
echo "     ${CYAN}nemoclaw my-assistant connect${NC}   # open a shell in the sandbox"
echo "     ${CYAN}openclaw tui${NC}                    # launch the interactive UI"
echo ""
echo "  Useful commands:"
echo "     nemoclaw my-assistant status     — sandbox status"
echo "     nemoclaw my-assistant logs -f    — follow logs"
echo "     nemoclaw doctor                  — diagnose issues"
echo ""
echo -e "${YELLOW}  Reminder:${NC} NemoClaw is alpha software. Expect rough edges."
echo "  GitHub issues: https://github.com/NVIDIA/NemoClaw/issues"
echo ""