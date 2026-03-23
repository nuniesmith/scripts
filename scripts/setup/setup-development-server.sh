#!/bin/sh
# =============================================================================
# Development Server Setup Script
# Targets: Ubuntu 25.10 (Questing Quetzal) — x86_64 / ARM64
# Includes: Rust, Python 3.13 + ruff/mypy/uv, Docker Engine,
#           NVIDIA Container Toolkit (CUDA), Zed IDE, full dev toolchain
# =============================================================================
#
# Usage:
#   chmod +x setup-development-server.sh
#   sudo ./setup-development-server.sh [OPTIONS]
#
# Options:
#   -u, --user NAME         Development user (default: current user)
#   -n, --name NAME         Machine name/identifier (default: hostname)
#   --skip-docker           Skip Docker installation
#   --skip-devtools         Skip development tools installation
#   --skip-languages        Skip programming language runtimes
#   --skip-gui              Skip GUI applications (only install CLI tools)
#   --skip-cuda             Skip NVIDIA/CUDA container toolkit
#   --minimal               Minimal install (Docker + essential tools only)
#   --full                  Full install (all tools and languages)
#   --no-confirm            Skip confirmation prompts
#   -h, --help              Show this help message
#
# =============================================================================

set -e

# =============================================================================
# Default Configuration
# =============================================================================
DEV_USER="${SUDO_USER:-${USER}}"
MACHINE_NAME=""
SKIP_DOCKER=false
SKIP_DEVTOOLS=false
SKIP_LANGUAGES=false
SKIP_GUI=false
SKIP_CUDA=false
MINIMAL_INSTALL=false
FULL_INSTALL=false
NO_CONFIRM=false
IS_WSL=false
IS_WSL2=false

# Pinned versions — update these as new releases ship
PYTHON_VERSION="3.13"
NVM_VERSION="v0.40.1"
GO_VERSION="1.24.1"

# =============================================================================
# Colors and Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC} %s\n"    "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n"  "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n"   "$*"; }
log_step()    { printf "${MAGENTA}[STEP]${NC} ${BOLD}%s${NC}\n" "$*"; }
log_skip()    { printf "${YELLOW}[SKIP]${NC} %s\n"  "$*"; }

log_header() {
    printf "\n"
    printf "${BOLD}${CYAN}================================================================================${NC}\n"
    printf "${BOLD}${CYAN}  %s${NC}\n" "$*"
    printf "${BOLD}${CYAN}================================================================================${NC}\n"
    printf "\n"
}

log_subheader() {
    printf "\n${BOLD}${YELLOW}--- %s ---${NC}\n\n" "$*"
}

# =============================================================================
# Help
# =============================================================================
show_help() {
    cat << 'EOF'
Development Server Setup Script  (Ubuntu 25.10 edition)
=======================================================

USAGE:
    sudo ./setup-development-server.sh [OPTIONS]

OPTIONS:
    -u, --user NAME         Development user (default: current user)
    -n, --name NAME         Machine name/identifier (default: hostname)
    --skip-docker           Skip Docker Engine installation
    --skip-devtools         Skip core CLI dev tools
    --skip-languages        Skip language runtimes
    --skip-gui              Skip Zed IDE and other GUI apps
    --skip-cuda             Skip NVIDIA Container Toolkit / CUDA setup
    --minimal               Docker + essential CLI only
    --full                  Everything (default)
    --no-confirm            Non-interactive / automation mode
    -h, --help              Show this help message

WHAT GETS INSTALLED:
    Core Tools:
      git, curl, wget, build-essential, tmux, zsh, fzf, ripgrep,
      fd-find, bat, jq, httpie, btop, ncdu, tree, tldr, etc.

    Languages:
      Python 3.13 + pip + venv + pipx + uv + ruff + mypy
      Rust (via rustup, stable toolchain)
      Node.js LTS (via nvm)
      Go (latest stable)

    Docker:
      Docker Engine (official repo)
      Docker Compose plugin
      BuildKit enabled by default

    NVIDIA / CUDA:
      nvidia-container-toolkit
      Docker configured with nvidia runtime
      (skipped if no NVIDIA GPU detected or --skip-cuda passed)

    GUI / IDE:
      Zed IDE (https://zed.dev)

    WSL2:
      wsl.conf with systemd=true, Windows interop aliases

EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)       DEV_USER="$2";   shift 2 ;;
        -n|--name)       MACHINE_NAME="$2"; shift 2 ;;
        --skip-docker)   SKIP_DOCKER=true;  shift ;;
        --skip-devtools) SKIP_DEVTOOLS=true; shift ;;
        --skip-languages) SKIP_LANGUAGES=true; shift ;;
        --skip-gui)      SKIP_GUI=true;    shift ;;
        --skip-cuda)     SKIP_CUDA=true;   shift ;;
        --minimal)
            MINIMAL_INSTALL=true
            SKIP_LANGUAGES=true
            SKIP_GUI=true
            shift
            ;;
        --full)    FULL_INSTALL=true; shift ;;
        --no-confirm) NO_CONFIRM=true; shift ;;
        -h|--help) show_help ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================
confirm() {
    [ "$NO_CONFIRM" = true ] && return 0
    printf "%s (Y/n) " "$1"
    read -r reply
    case "$reply" in n|N|no|No|NO) return 1 ;; *) return 0 ;; esac
}

confirm_no() {
    [ "$NO_CONFIRM" = true ] && return 1
    printf "%s (y/N) " "$1"
    read -r reply
    case "$reply" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}

run_as_user() {
    sudo -u "$DEV_USER" -H sh -c "$*"
}

# =============================================================================
# Pre-flight
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script with sudo"
    exit 1
fi

if ! id "$DEV_USER" >/dev/null 2>&1; then
    log_error "User '$DEV_USER' does not exist"
    exit 1
fi

# Only apt is supported — this script targets Ubuntu/Debian
if ! command -v apt-get >/dev/null 2>&1; then
    log_error "This script requires apt-get (Ubuntu/Debian only)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# System Detection
# =============================================================================
log_header "Development Environment Setup"
log_subheader "System Detection"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)    ARCH_NORMALIZED="amd64" ;;
    aarch64|arm64)   ARCH_NORMALIZED="arm64" ;;
    armv7l|armhf)    ARCH_NORMALIZED="armv7" ;;
    *)               ARCH_NORMALIZED="$ARCH" ;;
esac
log_info "Architecture: $ARCH ($ARCH_NORMALIZED)"

# WSL detection
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    if grep -qi wsl2 /proc/version 2>/dev/null || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
        IS_WSL2=true
        log_success "WSL2 environment detected"
    else
        log_warn "WSL1 detected — upgrade to WSL2 is strongly recommended"
    fi
fi

# OS info
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_VERSION="${VERSION_ID:-Unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    log_info "OS: $OS_NAME $OS_VERSION ${OS_CODENAME:+(${OS_CODENAME})}"
else
    log_warn "Cannot read /etc/os-release"
    OS_NAME="Ubuntu"
    OS_VERSION="25.10"
    OS_CODENAME=""
fi

# NVIDIA GPU detection
HAS_NVIDIA=false
if lspci 2>/dev/null | grep -qi nvidia || ls /dev/nvidia* >/dev/null 2>&1; then
    HAS_NVIDIA=true
    log_success "NVIDIA GPU detected"
else
    log_info "No NVIDIA GPU detected — CUDA setup will be skipped unless --full is passed explicitly"
    [ "$FULL_INSTALL" = false ] && SKIP_CUDA=true
fi

HOSTNAME_VAL=$(hostname 2>/dev/null || echo "devmachine")
[ -z "$MACHINE_NAME" ] && MACHINE_NAME="$HOSTNAME_VAL"
USER_HOME=$(eval echo "~$DEV_USER")

log_info "Machine: $MACHINE_NAME | User: $DEV_USER | Home: $USER_HOME"

# Summary
printf "\n${BOLD}Install Plan:${NC}\n"
printf "  Docker:            %s\n" "$([ "$SKIP_DOCKER"    = true ] && printf "${YELLOW}SKIP${NC}"    || printf "${GREEN}Install${NC}")"
printf "  Dev Tools:         %s\n" "$([ "$SKIP_DEVTOOLS"  = true ] && printf "${YELLOW}SKIP${NC}"    || printf "${GREEN}Install${NC}")"
printf "  Languages:         %s\n" "$([ "$SKIP_LANGUAGES" = true ] && printf "${YELLOW}SKIP${NC}"    || printf "${GREEN}Python 3.13, Rust, Node, Go${NC}")"
printf "  CUDA Toolkit:      %s\n" "$([ "$SKIP_CUDA"      = true ] && printf "${YELLOW}SKIP${NC}"    || printf "${GREEN}Install (nvidia-container-toolkit)${NC}")"
printf "  Zed IDE:           %s\n" "$([ "$SKIP_GUI"       = true ] && printf "${YELLOW}SKIP${NC}"    || printf "${GREEN}Install${NC}")"
printf "\n"

confirm "Continue with setup?" || { log_info "Setup cancelled"; exit 0; }

# =============================================================================
# Step 1: System Update
# =============================================================================
log_header "Step 1: System Update"

apt-get update
apt-get upgrade -y
apt-get install -y \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    curl \
    wget
log_success "System updated"

# =============================================================================
# Step 2: Core Development Tools
# =============================================================================
log_header "Step 2: Core Development Tools"

if [ "$SKIP_DEVTOOLS" = true ]; then
    log_skip "Dev tools skipped"
else
    log_info "Installing core CLI tools..."

    # bat is packaged as 'bat' on Ubuntu 23.10+ (not 'batcat')
    apt-get install -y \
        git \
        build-essential \
        pkg-config \
        libssl-dev \
        libffi-dev \
        vim \
        nano \
        tmux \
        zsh \
        htop \
        btop \
        jq \
        httpie \
        tree \
        unzip \
        zip \
        openssh-client \
        openssl \
        net-tools \
        dnsutils \
        iputils-ping \
        man-db \
        ncdu \
        fzf \
        ripgrep \
        fd-find \
        bat \
        tldr \
        pciutils \
        strace \
        lsof \
        2>/dev/null || apt-get install -y \
            git \
            build-essential \
            vim \
            tmux \
            zsh \
            htop \
            jq \
            tree \
            unzip \
            zip \
            curl \
            wget

    # On some Ubuntu releases bat is still 'batcat' — create alias if needed
    if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
        mkdir -p "$USER_HOME/.local/bin"
        ln -sf "$(command -v batcat)" "$USER_HOME/.local/bin/bat"
        chown -R "$DEV_USER:$DEV_USER" "$USER_HOME/.local"
        log_info "Created bat -> batcat symlink"
    fi

    log_success "Core tools installed"

    # --- Git configuration ---
    log_subheader "Git Configuration"

    CURRENT_GIT_NAME=$(run_as_user  "git config --global user.name"  2>/dev/null || echo "")
    CURRENT_GIT_EMAIL=$(run_as_user "git config --global user.email" 2>/dev/null || echo "")

    if [ -z "$CURRENT_GIT_NAME" ] && [ "$NO_CONFIRM" = false ]; then
        printf "Name for Git commits: "
        read -r GIT_NAME
        [ -n "$GIT_NAME" ] && run_as_user "git config --global user.name \"$GIT_NAME\""
    else
        log_info "Git user.name: ${CURRENT_GIT_NAME:-<not set>}"
    fi

    if [ -z "$CURRENT_GIT_EMAIL" ] && [ "$NO_CONFIRM" = false ]; then
        printf "Email for Git commits: "
        read -r GIT_EMAIL
        [ -n "$GIT_EMAIL" ] && run_as_user "git config --global user.email \"$GIT_EMAIL\""
    else
        log_info "Git user.email: ${CURRENT_GIT_EMAIL:-<not set>}"
    fi

    run_as_user "git config --global init.defaultBranch main"    2>/dev/null || true
    run_as_user "git config --global pull.rebase false"          2>/dev/null || true
    run_as_user "git config --global core.autocrlf input"        2>/dev/null || true
    run_as_user "git config --global core.editor vim"            2>/dev/null || true
    run_as_user "git config --global rerere.enabled true"        2>/dev/null || true
    log_success "Git configured"
fi

# =============================================================================
# Step 3: Docker Engine
# =============================================================================
log_header "Step 3: Docker Engine"

if [ "$SKIP_DOCKER" = true ]; then
    log_skip "Docker installation skipped"
else
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker already installed: $(docker --version)"
    else
        log_info "Installing Docker Engine (official repo)..."

        # Remove any legacy packages that conflict
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add repository — use the codename if available, otherwise use 'plucky'
        # Ubuntu 25.10 codename is 'questing'; adjust if Docker doesn't have it yet
        # and fall back to the nearest supported release.
        DOCKER_CODENAME="${OS_CODENAME:-questing}"
        echo \
            "deb [arch=${ARCH_NORMALIZED} signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update || {
            # If Docker repo doesn't carry 25.10 yet, fall back to 25.04 (plucky)
            log_warn "Docker repo may not carry ${DOCKER_CODENAME} yet — trying plucky fallback"
            sed -i "s/${DOCKER_CODENAME}/plucky/g" /etc/apt/sources.list.d/docker.list
            apt-get update
        }

        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        log_success "Docker installed: $(docker --version)"
    fi

    # Enable and start Docker (not needed inside WSL1; WSL2+systemd is fine)
    if [ "$IS_WSL" = false ] || [ "$IS_WSL2" = true ]; then
        systemctl enable docker 2>/dev/null || true
        systemctl start  docker 2>/dev/null || true
    fi

    # Add user to docker group
    if ! groups "$DEV_USER" | grep -q docker 2>/dev/null; then
        usermod -aG docker "$DEV_USER"
        log_success "User '$DEV_USER' added to docker group"
        log_warn "Log out and back in (or run: newgrp docker) for group change to take effect"
    else
        log_info "User '$DEV_USER' already in docker group"
    fi

    # Docker Compose sanity check
    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose: $(docker compose version)"
    else
        log_warn "Docker Compose plugin not available — check installation"
    fi

    # --- Docker daemon config ---
    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
    mkdir -p /etc/docker

    # Build the daemon config — will be updated again in CUDA step if needed
    if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
        log_info "Writing Docker daemon config..."
        cat > "$DOCKER_DAEMON_CONFIG" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
EOF
        log_success "Docker daemon config written"
    else
        log_info "Docker daemon config already exists — leaving untouched"
    fi

    systemctl restart docker 2>/dev/null || true
fi

# =============================================================================
# Step 4: NVIDIA Container Toolkit (CUDA)
# =============================================================================
log_header "Step 4: NVIDIA Container Toolkit (CUDA)"

if [ "$SKIP_CUDA" = true ]; then
    log_skip "CUDA / NVIDIA container toolkit skipped"
else
    log_info "Installing NVIDIA Container Toolkit..."

    # Add NVIDIA container toolkit GPG key and repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update
    apt-get install -y nvidia-container-toolkit

    log_success "nvidia-container-toolkit installed"

    # Configure Docker runtime for NVIDIA
    log_info "Configuring NVIDIA runtime for Docker..."
    nvidia-ctk runtime configure --runtime=docker

    # Merge nvidia runtime into daemon.json
    # nvidia-ctk writes to daemon.json; ensure our log and buildkit settings survive.
    # Re-write with full config if the file was just created by nvidia-ctk.
    if grep -q '"runtimes"' "$DOCKER_DAEMON_CONFIG" 2>/dev/null; then
        log_info "NVIDIA runtime block already present in daemon.json"
    else
        # nvidia-ctk should have added it; if not, add manually
        python3 - <<'PYEOF'
import json, sys

path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

cfg.setdefault("log-driver", "json-file")
cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})
cfg.setdefault("storage-driver", "overlay2")
cfg.setdefault("features", {"buildkit": True})
cfg.setdefault("default-runtime", "nvidia")
cfg.setdefault("runtimes", {
    "nvidia": {
        "path": "nvidia-container-runtime",
        "runtimeArgs": []
    }
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("daemon.json updated with nvidia runtime")
PYEOF
    fi

    systemctl restart docker 2>/dev/null || true
    log_success "Docker daemon restarted with NVIDIA runtime"

    # Quick smoke test
    log_info "Testing NVIDIA container runtime (nvidia-smi inside Docker)..."
    if docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi 2>/dev/null; then
        log_success "CUDA container test passed"
    else
        log_warn "CUDA container test failed — this is expected if NVIDIA drivers are not yet installed"
        log_warn "Install drivers with: sudo ubuntu-drivers install"
        log_warn "Then re-run the test: docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
    fi
fi

# =============================================================================
# Step 5: Programming Languages
# =============================================================================
log_header "Step 5: Programming Languages"

if [ "$SKIP_LANGUAGES" = true ]; then
    log_skip "Language runtimes skipped"
else

    # --- Python 3.13 ---
    log_subheader "Python ${PYTHON_VERSION}"

    # Ubuntu 25.10 ships Python 3.13 in main — use deadsnakes as a fallback
    if python3.13 --version >/dev/null 2>&1; then
        log_info "Python 3.13 already present: $(python3.13 --version)"
    else
        log_info "Adding deadsnakes PPA for Python 3.13..."
        add-apt-repository -y ppa:deadsnakes/ppa
        apt-get update
        apt-get install -y \
            python3.13 \
            python3.13-dev \
            python3.13-venv \
            python3.13-distutils 2>/dev/null || true
        log_success "Python 3.13 installed: $(python3.13 --version)"
    fi

    # pip for 3.13
    if ! python3.13 -m pip --version >/dev/null 2>&1; then
        log_info "Bootstrapping pip for Python 3.13..."
        python3.13 -m ensurepip --upgrade 2>/dev/null || \
            curl -sS https://bootstrap.pypa.io/get-pip.py | python3.13
    fi

    # pipx — isolated CLI tool installer
    if ! command -v pipx >/dev/null 2>&1; then
        apt-get install -y pipx 2>/dev/null || \
            python3.13 -m pip install --user pipx
        run_as_user "python3.13 -m pipx ensurepath"
        log_success "pipx installed"
    else
        log_info "pipx already installed"
    fi

    # Make ~/.local/bin visible for the rest of this script session.
    # The installers (uv, ruff, pipx) drop binaries there, and without this
    # the command -v checks below would all fail even though the tools are present.
    LOCAL_BIN="$USER_HOME/.local/bin"
    export PATH="$LOCAL_BIN:$PATH"

    # uv — fast Python package/project manager (replaces pip/venv in new projects)
    if ! [ -f "$LOCAL_BIN/uv" ]; then
        log_info "Installing uv..."
        run_as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
        log_success "uv installed"
    else
        log_info "uv already installed"
    fi

    # ruff — fast Python linter/formatter (replaces flake8/black)
    if ! [ -f "$LOCAL_BIN/ruff" ]; then
        log_info "Installing ruff..."
        run_as_user "curl -LsSf https://astral.sh/ruff/install.sh | sh"
        log_success "ruff installed"
    else
        log_info "ruff already installed: $("$LOCAL_BIN/ruff" --version 2>/dev/null || echo '')"
    fi

    # mypy — static type checker
    # Must use pipx, not pip --user: Ubuntu 25.10 enforces PEP 668
    # (externally-managed-environment) and will reject bare pip installs.
    if ! [ -f "$LOCAL_BIN/mypy" ]; then
        log_info "Installing mypy via pipx..."
        run_as_user "pipx install mypy"
        log_success "mypy installed: $("$LOCAL_BIN/mypy" --version 2>/dev/null || echo 'installed')"
    else
        log_info "mypy already installed: $("$LOCAL_BIN/mypy" --version 2>/dev/null || echo '')"
    fi

    # Make python3 point to 3.13 for this user if it doesn't already
    PYTHON3_VER=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
    if [ "$PYTHON3_VER" != "3.13" ] && command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --install /usr/bin/python3 python3 "$(command -v python3.13)" 10
        log_info "python3 -> python3.13 set via update-alternatives"
    fi

    log_success "Python stack ready"

    # --- Rust ---
    log_subheader "Rust (rustup)"

    if run_as_user "command -v rustc" >/dev/null 2>&1; then
        log_info "Rust already installed: $(run_as_user 'rustc --version')"
        run_as_user "$USER_HOME/.cargo/bin/rustup update stable" 2>/dev/null || true
    else
        log_info "Installing Rust via rustup..."
        run_as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --default-toolchain stable"

        CARGO_ENV="$USER_HOME/.cargo/env"
        if [ -f "$CARGO_ENV" ]; then
            . "$CARGO_ENV"
            log_success "Rust installed: $(rustc --version 2>/dev/null || echo 'stable')"
        fi
    fi

    # Useful cargo tools
    log_info "Installing cargo utilities (cargo-watch, cargo-edit, cargo-expand)..."
    run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-watch  2>/dev/null || true"
    run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-edit   2>/dev/null || true"
    run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-expand 2>/dev/null || true"
    log_success "Cargo utilities installed"

    # --- Node.js via nvm ---
    log_subheader "Node.js (nvm ${NVM_VERSION})"

    NVM_DIR="$USER_HOME/.nvm"
    if [ -d "$NVM_DIR" ]; then
        log_warn "nvm already installed"
    else
        log_info "Installing nvm ${NVM_VERSION}..."
        run_as_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
        log_success "nvm installed"
    fi

    log_info "Installing Node.js LTS..."
    run_as_user ". ${NVM_DIR}/nvm.sh && nvm install --lts && nvm use --lts && nvm alias default node"
    NODE_VER=$(run_as_user ". ${NVM_DIR}/nvm.sh && node --version" 2>/dev/null || echo "")
    [ -n "$NODE_VER" ] && log_success "Node.js installed: $NODE_VER"

    # --- Go ---
    log_subheader "Go ${GO_VERSION}"

    if command -v go >/dev/null 2>&1; then
        log_info "Go already installed: $(go version)"
    else
        log_info "Installing Go ${GO_VERSION}..."
        GO_TAR="go${GO_VERSION}.linux-${ARCH_NORMALIZED}.tar.gz"
        GO_URL="https://go.dev/dl/${GO_TAR}"
        wget -q "$GO_URL" -O "/tmp/${GO_TAR}"
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "/tmp/${GO_TAR}"
        rm "/tmp/${GO_TAR}"

        if ! grep -q '/usr/local/go/bin' "$USER_HOME/.profile" 2>/dev/null; then
            printf '\nexport PATH=$PATH:/usr/local/go/bin\nexport PATH=$PATH:$HOME/go/bin\n' \
                >> "$USER_HOME/.profile"
        fi
        export PATH=$PATH:/usr/local/go/bin
        log_success "Go installed: $(go version)"
    fi

fi  # SKIP_LANGUAGES

# =============================================================================
# Step 6: Shell Configuration
# =============================================================================
log_header "Step 6: Shell Configuration"

CURRENT_SHELL=$(getent passwd "$DEV_USER" | cut -d: -f7)
log_info "Current shell: $CURRENT_SHELL"

if command -v zsh >/dev/null 2>&1; then
    ZSH_PATH=$(command -v zsh)
    if [ "$CURRENT_SHELL" != "$ZSH_PATH" ] && [ "$NO_CONFIRM" = false ]; then
        if confirm_no "Switch default shell to zsh?"; then
            chsh -s "$ZSH_PATH" "$DEV_USER"
            log_success "Default shell -> zsh"

            if [ ! -d "$USER_HOME/.oh-my-zsh" ] && confirm_no "Install oh-my-zsh?"; then
                run_as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
                log_success "oh-my-zsh installed"
            fi
        fi
    else
        log_info "zsh is already the default shell"
    fi
fi

# Detect rc file
SHELL_RC=""
[ -f "$USER_HOME/.zshrc"  ] && SHELL_RC="$USER_HOME/.zshrc"
[ -z "$SHELL_RC" ] && [ -f "$USER_HOME/.bashrc" ] && SHELL_RC="$USER_HOME/.bashrc"

if [ -n "$SHELL_RC" ] && ! grep -q "# Dev environment aliases" "$SHELL_RC" 2>/dev/null; then
    log_info "Appending dev aliases to $SHELL_RC..."
    cat >> "$SHELL_RC" <<'RCEOF'

# Dev environment aliases
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# Git
alias gs='git status'
alias gp='git pull'
alias gc='git commit'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate'
alias gco='git checkout'
alias gb='git branch'

# Docker
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dimg='docker images'
alias dlog='docker logs -f'
alias dexec='docker exec -it'
alias dprune='docker system prune -af'

# Python
alias py='python3.13'
alias venv='python3.13 -m venv'
alias activate='source .venv/bin/activate'

# uv shortcuts
alias uvr='uv run'
alias uvs='uv sync'

# Navigation
alias dev='cd ~/dev'
alias proj='cd ~/projects'

# Add local bin and cargo to PATH
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
RCEOF

    chown "$DEV_USER:$DEV_USER" "$SHELL_RC"
    log_success "Shell aliases written to $SHELL_RC"
fi

# =============================================================================
# Step 7: Zed IDE
# =============================================================================
log_header "Step 7: Zed IDE"

if [ "$SKIP_GUI" = true ]; then
    log_skip "Zed IDE skipped (--skip-gui)"
else
    if run_as_user "command -v zed" >/dev/null 2>&1; then
        log_info "Zed already installed"
    else
        log_info "Installing Zed IDE..."

        # Zed requires a few system libraries
        apt-get install -y \
            libvulkan1 \
            libxkbcommon-x11-0 \
            libwayland-client0 \
            libwayland-cursor0 \
            libwayland-egl1 \
            libxcb-shape0 \
            libxcb-xfixes0 \
            libsm6 \
            libice6 \
            2>/dev/null || true

        # Official Zed installer (installs to ~/.local/bin/zed)
        run_as_user "curl -f https://zed.dev/install.sh | sh"

        if run_as_user "command -v zed" >/dev/null 2>&1; then
            ZED_VER=$(run_as_user "zed --version" 2>/dev/null || echo "installed")
            log_success "Zed installed: $ZED_VER"
        else
            log_warn "Zed installer ran but 'zed' not found in PATH yet"
            log_warn "Add ~/.local/bin to PATH and run: zed"
        fi
    fi

    # WSL note
    if [ "$IS_WSL" = true ]; then
        log_info "In WSL2, Zed launches via WSLg — ensure WSLg is enabled in your Windows setup"
    fi
fi

# =============================================================================
# Step 8: WSL2 Configuration
# =============================================================================
if [ "$IS_WSL" = true ]; then
    log_header "Step 8: WSL2 Configuration"

    apt-get install -y wslu 2>/dev/null || log_warn "wslu not available in this release"

    WSL_CONF="/etc/wsl.conf"
    if [ ! -f "$WSL_CONF" ]; then
        log_info "Writing /etc/wsl.conf..."
        cat > "$WSL_CONF" <<WSLEOF
[boot]
systemd=true

[network]
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false

[user]
default=${DEV_USER}
WSLEOF
        log_success "wsl.conf created"
        log_warn "Run 'wsl --shutdown' from PowerShell and reopen WSL for changes to apply"
    else
        log_info "/etc/wsl.conf already exists — leaving untouched"
    fi

    if [ -n "$SHELL_RC" ] && ! grep -q "# WSL aliases" "$SHELL_RC" 2>/dev/null; then
        cat >> "$SHELL_RC" <<'WSLRC'

# WSL aliases
alias open='wslview'
alias pbcopy='clip.exe'
alias pbpaste='powershell.exe -command "Get-Clipboard"'
WSLRC
        chown "$DEV_USER:$DEV_USER" "$SHELL_RC"
        log_success "WSL aliases added"
    fi
fi

# =============================================================================
# Step 9: Development Directories
# =============================================================================
log_header "Step 9: Development Directories"

for dir in dev projects github workspace tmp; do
    DIR_PATH="$USER_HOME/$dir"
    if [ ! -d "$DIR_PATH" ]; then
        run_as_user "mkdir -p $DIR_PATH"
        log_success "Created: ~/$dir"
    else
        log_info "Exists:  ~/$dir"
    fi
done

# =============================================================================
# Step 10: System Tuning
# =============================================================================
log_header "Step 10: System Tuning"

SYSCTL_CONF="/etc/sysctl.d/99-devtools.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    log_info "Writing sysctl tuning config..."
    cat > "$SYSCTL_CONF" <<'EOF'
# Development workstation tuning
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 256
fs.file-max                  = 65536
net.core.somaxconn           = 1024
EOF
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    log_success "sysctl tuning applied"
else
    log_info "sysctl tuning already configured"
fi

# =============================================================================
# Step 11: GitHub Sync Service (nuniesmith — all public repos)
# Clones every public repo under ~/github, keeps them current via hourly pull,
# and removes local dirs whose remote repo no longer exists.
# Also prunes Docker images/volumes older than 7 days on each run.
# =============================================================================
log_header "Step 11: GitHub Repo Sync Service"

GH_SYNC_SCRIPT="$USER_HOME/.local/bin/gh_sync.sh"
GH_SYNC_SERVICE="github-sync"

mkdir -p "$USER_HOME/.local/bin"
chown "$DEV_USER:$DEV_USER" "$USER_HOME/.local/bin"

# --- Write the sync script ---
log_info "Writing $GH_SYNC_SCRIPT..."
cat > "$GH_SYNC_SCRIPT" << 'SYNCEOF'
#!/bin/bash
# GitHub repo sync — nuniesmith (all public repos)
# Managed by setup-development-server.sh — edit carefully

set -euo pipefail

GH_USER="nuniesmith"
TARGET_DIR="$HOME/github"
LOG_TAG="gh_sync"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LOG_TAG] $*"; }

log "--- Sync starting ---"
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

# Fetch full repo list (handles >100 repos via pagination)
log "Fetching repo list for $GH_USER..."
REPO_DATA=""
PAGE=1
while true; do
    PAGE_DATA=$(curl -sf \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/users/$GH_USER/repos?per_page=100&page=$PAGE&type=public" \
        | jq -r '.[] | "\(.name)|\(.clone_url)"')
    [ -z "$PAGE_DATA" ] && break
    REPO_DATA="${REPO_DATA}${PAGE_DATA}"$'\n'
    PAGE=$((PAGE + 1))
done

if [ -z "$REPO_DATA" ]; then
    log "ERROR: Failed to fetch repo list — check network / GitHub API rate limit"
    exit 1
fi

ACTIVE_REPOS=$(echo "$REPO_DATA" | cut -d'|' -f1 | sort)
log "Found $(echo "$ACTIVE_REPOS" | grep -c .) repos"

# Remove local dirs that no longer exist on GitHub
for local_dir in */; do
    [ -d "$local_dir" ] || continue
    dir_name="${local_dir%/}"
    if ! echo "$ACTIVE_REPOS" | grep -qx "$dir_name"; then
        log "Removing stale repo: $dir_name"
        rm -rf "$dir_name"
    fi
done

# Clone missing / pull existing
CLONED=0
PULLED=0
FAILED=0
while IFS='|' read -r REPO_NAME REPO_URL; do
    [ -z "$REPO_NAME" ] && continue
    if [ -d "$REPO_NAME/.git" ]; then
        if git -C "$REPO_NAME" pull --ff-only --quiet 2>/dev/null; then
            PULLED=$((PULLED + 1))
        else
            log "WARN: ff-only pull failed for $REPO_NAME (diverged or dirty) — skipping"
            FAILED=$((FAILED + 1))
        fi
    else
        if git clone --quiet "$REPO_URL" 2>/dev/null; then
            log "Cloned: $REPO_NAME"
            CLONED=$((CLONED + 1))
        else
            log "ERROR: Failed to clone $REPO_NAME"
            FAILED=$((FAILED + 1))
        fi
    fi
done <<< "$REPO_DATA"

log "Sync complete — cloned=$CLONED pulled=$PULLED failed=$FAILED"

# Docker maintenance — prune images/containers older than 7 days and orphaned volumes
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    log "Running Docker prune (images/containers >7d, orphaned volumes)..."
    docker system prune -af --filter "until=168h" --quiet 2>/dev/null || true
    docker volume prune -f --quiet 2>/dev/null || true
    log "Docker prune complete"
fi

log "--- Done ---"
SYNCEOF

chmod +x "$GH_SYNC_SCRIPT"
chown "$DEV_USER:$DEV_USER" "$GH_SYNC_SCRIPT"
log_success "Sync script written: $GH_SYNC_SCRIPT"

# --- Systemd service unit ---
log_info "Writing systemd service unit..."
cat > "/etc/systemd/system/${GH_SYNC_SERVICE}.service" << SVCEOF
[Unit]
Description=Sync nuniesmith GitHub repos and prune Docker
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${GH_SYNC_SCRIPT}
User=${DEV_USER}
Environment="HOME=${USER_HOME}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${USER_HOME}/.local/bin:${USER_HOME}/.cargo/bin"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

# --- Systemd timer unit ---
log_info "Writing systemd timer unit..."
cat > "/etc/systemd/system/${GH_SYNC_SERVICE}.timer" << TMREOF
[Unit]
Description=Hourly GitHub sync and Docker maintenance

[Timer]
# Run 2 minutes after boot (gives network time to settle)
OnBootSec=2min
# Then every hour
OnUnitActiveSec=1h
# Re-fire a missed run on next boot if the machine was off
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

systemctl daemon-reload
systemctl enable --now "${GH_SYNC_SERVICE}.timer"

if systemctl is-active --quiet "${GH_SYNC_SERVICE}.timer"; then
    log_success "github-sync timer enabled and active"
    NEXT_RUN=$(systemctl show "${GH_SYNC_SERVICE}.timer" --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")
    log_info "Next run: $(systemctl list-timers ${GH_SYNC_SERVICE}.timer --no-legend 2>/dev/null | awk '{print $1, $2}' || echo 'check: systemctl list-timers')"
else
    log_warn "Timer may not be active yet — check: systemctl status ${GH_SYNC_SERVICE}.timer"
fi

log_info "Run manually anytime: ${CYAN}sudo -u ${DEV_USER} ${GH_SYNC_SCRIPT}${NC}"
log_info "View logs:            ${CYAN}journalctl -u ${GH_SYNC_SERVICE}.service -f${NC}"

# =============================================================================
# Done
# =============================================================================
log_header "Setup Complete!"

printf "${BOLD}${GREEN}Environment ready on %s${NC}\n\n" "$MACHINE_NAME"

printf "${BOLD}Installed:${NC}\n"
[ "$SKIP_DEVTOOLS"  = false ] && printf "  ${GREEN}✓${NC} Core CLI tools\n"
[ "$SKIP_DOCKER"    = false ] && command -v docker  >/dev/null 2>&1 && \
    printf "  ${GREEN}✓${NC} Docker %s + Compose\n" "$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[ "$SKIP_CUDA"      = false ] && \
    printf "  ${GREEN}✓${NC} NVIDIA Container Toolkit (nvidia-container-toolkit)\n"
if [ "$SKIP_LANGUAGES" = false ]; then
    python3.13 --version  >/dev/null 2>&1 && \
        printf "  ${GREEN}✓${NC} Python 3.13 + uv + ruff + mypy\n"
    run_as_user "command -v rustc" >/dev/null 2>&1 && \
        printf "  ${GREEN}✓${NC} Rust %s (stable)\n" "$(run_as_user 'rustc --version' 2>/dev/null | cut -d' ' -f2)"
    printf "  ${GREEN}✓${NC} Node.js LTS (nvm)\n"
    command -v go >/dev/null 2>&1 && \
        printf "  ${GREEN}✓${NC} Go %s\n" "$(go version | cut -d' ' -f3)"
fi
[ "$SKIP_GUI" = false ] && run_as_user "command -v zed" >/dev/null 2>&1 && \
    printf "  ${GREEN}✓${NC} Zed IDE\n"
systemctl is-active --quiet "${GH_SYNC_SERVICE}.timer" 2>/dev/null && \
    printf "  ${GREEN}✓${NC} GitHub sync timer (nuniesmith — hourly, ~/github)\n"

printf "\n${BOLD}${YELLOW}Next steps:${NC}\n"

N=1
[ "$SKIP_DOCKER" = false ] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}newgrp docker${NC}  (or log out/in for docker group)\n" "$N" && N=$((N+1))
printf "  ${GREEN}%d.${NC} ${CYAN}source %s${NC}\n" "$N" "${SHELL_RC:-~/.bashrc}" && N=$((N+1))
[ "$SKIP_DOCKER" = false ] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}docker run hello-world${NC}\n" "$N" && N=$((N+1))
[ "$SKIP_CUDA"   = false ] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi${NC}\n" "$N" && N=$((N+1))
printf "  ${GREEN}%d.${NC} Check sync logs: ${CYAN}journalctl -u github-sync.service -f${NC}\n" "$N" && N=$((N+1))
printf "  ${GREEN}%d.${NC} Trigger sync now: ${CYAN}sudo systemctl start github-sync.service${NC}\n" "$N" && N=$((N+1))
[ "$IS_WSL"      = true  ] && \
    printf "  ${GREEN}%d.${NC} Restart WSL: ${CYAN}wsl --shutdown${NC} (from PowerShell)\n" "$N"

printf "\n"
log_success "All done — happy hacking, Jordan!"
printf "\n"

exit 0
