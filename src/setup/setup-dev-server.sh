#!/usr/bin/env bash
# =============================================================================
# setup-dev-server.sh — Ubuntu Development Server
# Targets: Ubuntu 25.10 (Questing Quetzal) — x86_64 / ARM64
# Includes: Rust, Python 3.13 + uv/ruff/mypy, Docker Engine,
#           NVIDIA Container Toolkit (CUDA), Zed IDE, full dev toolchain,
#           protoc (GitHub releases), buf CLI, protoc-gen-prost/tonic
# =============================================================================
#
# Usage:
#   sudo ./setup-dev-server.sh [OPTIONS]
#
# Options:
#   -u, --user NAME         Development user (default: current user)
#   -n, --name NAME         Machine name/identifier (default: hostname)
#       --skip-docker       Skip Docker installation
#       --skip-devtools     Skip development tools installation
#       --skip-languages    Skip programming language runtimes
#       --skip-gui          Skip GUI applications (only install CLI tools)
#       --skip-cuda         Skip NVIDIA/CUDA container toolkit
#       --skip-proto        Skip protoc, buf CLI, and Rust protobuf plugins
#       --minimal           Minimal install (Docker + essential tools only)
#       --full              Full install (all tools and languages)
#       --no-confirm        Skip confirmation prompts
#   -h, --help              Show this help message
# =============================================================================
set -euo pipefail

# =============================================================================
# Source Ubuntu base library
# =============================================================================
REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"
_LIB="$(dirname "${BASH_SOURCE[0]}")/setup-ubuntu.sh"

if [[ -f "$_LIB" ]]; then
    # shellcheck source=setup-ubuntu.sh
    . "$_LIB"
else
    _TMP=$(mktemp /tmp/setup-ubuntu.XXXXXX.sh)
    printf "  Fetching base library from GitHub...\n"
    curl -fsSL "${REPO_RAW}/setup-ubuntu.sh" -o "$_TMP"
    # shellcheck source=/dev/null
    . "$_TMP"
    rm -f "$_TMP"
fi

# =============================================================================
# Defaults
# =============================================================================
DEV_USER="${SUDO_USER:-${USER}}"
MACHINE_NAME=""
SKIP_DOCKER=false
SKIP_DEVTOOLS=false
SKIP_LANGUAGES=false
SKIP_GUI=false
SKIP_CUDA=false
SKIP_PROTO=false
MINIMAL_INSTALL=false
FULL_INSTALL=false
NO_CONFIRM=false

# Pinned versions — update as new releases ship
PYTHON_VERSION="3.13"
NVM_VERSION="v0.40.4"
GO_VERSION="1.24.2"
PROTOC_VERSION="27.3"   # https://github.com/protocolbuffers/protobuf/releases
BUF_VERSION="1.34.0"    # https://github.com/bufbuild/buf/releases
GH_USER="nuniesmith"

# =============================================================================
# Help
# =============================================================================
show_help() {
    cat << 'EOF'
setup-dev-server.sh — Ubuntu Development Server (25.10)
=======================================================

USAGE:
    sudo ./setup-dev-server.sh [OPTIONS]

OPTIONS:
    -u, --user NAME         Development user (default: current user)
    -n, --name NAME         Machine name/identifier (default: hostname)
        --skip-docker       Skip Docker Engine installation
        --skip-devtools     Skip core CLI dev tools
        --skip-languages    Skip language runtimes
        --skip-gui          Skip Zed IDE and other GUI apps
        --skip-cuda         Skip NVIDIA Container Toolkit / CUDA setup
        --skip-proto        Skip protoc, buf CLI, and Rust protobuf plugins
        --minimal           Docker + essential CLI only
        --full              Everything (default)
        --no-confirm        Non-interactive / automation mode
    -h, --help              Show this help message

WHAT GETS INSTALLED:
    Core tools, Python 3.13 + uv/ruff/mypy, Rust (rustup),
    Node.js LTS (nvm), Go, protoc + buf + protoc-gen-prost/tonic,
    Docker Engine + Compose + BuildKit, NVIDIA Container Toolkit (if GPU),
    Zed IDE, WSL2 config (if applicable), GitHub sync timer.
EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)        DEV_USER="$2";       shift 2 ;;
        -n|--name)        MACHINE_NAME="$2";   shift 2 ;;
        --skip-docker)    SKIP_DOCKER=true;    shift ;;
        --skip-devtools)  SKIP_DEVTOOLS=true;  shift ;;
        --skip-languages) SKIP_LANGUAGES=true; shift ;;
        --skip-gui)       SKIP_GUI=true;       shift ;;
        --skip-cuda)      SKIP_CUDA=true;      shift ;;
        --skip-proto)     SKIP_PROTO=true;     shift ;;
        --minimal)
            MINIMAL_INSTALL=true
            SKIP_LANGUAGES=true
            SKIP_GUI=true
            SKIP_PROTO=true
            shift
            ;;
        --full)       FULL_INSTALL=true; shift ;;
        --no-confirm) NO_CONFIRM=true;   shift ;;
        -h|--help)    show_help ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Pre-flight
# =============================================================================
lib_require_root
lib_require_apt
lib_require_user

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# System Detection
# =============================================================================
lib_show_banner "Dev Server Setup"
log_header "System Detection"

lib_detect_system

[[ -z "$MACHINE_NAME" ]] && MACHINE_NAME="$HOSTNAME_VAL"
USER_HOME=$(eval echo "~$DEV_USER")

# Auto-skip CUDA if no GPU and not forcing full install
if [[ "$HAS_NVIDIA" = false && "$FULL_INSTALL" = false ]]; then
    SKIP_CUDA=true
fi

log_info "Machine: $MACHINE_NAME | User: $DEV_USER | Home: $USER_HOME"
printf "\n${BOLD}Install Plan:${NC}\n"
printf "  Docker:       %s\n" "$( [[ $SKIP_DOCKER    = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "  Dev Tools:    %s\n" "$( [[ $SKIP_DEVTOOLS  = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "  Languages:    %s\n" "$( [[ $SKIP_LANGUAGES = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Python ${PYTHON_VERSION}, Rust, Node, Go${NC}")"
printf "  Proto/gRPC:   %s\n" "$( [[ $SKIP_PROTO     = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}protoc ${PROTOC_VERSION}, buf ${BUF_VERSION}, prost+tonic${NC}")"
printf "  CUDA Toolkit: %s\n" "$( [[ $SKIP_CUDA      = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}nvidia-container-toolkit${NC}")"
printf "  Zed IDE:      %s\n" "$( [[ $SKIP_GUI       = true ]] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "\n"

lib_confirm "Continue with setup?" || { log_info "Setup cancelled"; exit 0; }

# =============================================================================
# Step 1: System Update
# =============================================================================
log_header "Step 1: System Update"
lib_apt_update

# =============================================================================
# Step 2: Core Development Tools
# =============================================================================
log_header "Step 2: Core Development Tools"

if [[ "$SKIP_DEVTOOLS" = true ]]; then
    log_skip "Dev tools skipped"
else
    lib_install_base_packages
    log_subheader "Git Configuration"
    lib_setup_git_config
fi

# =============================================================================
# Step 3: Docker Engine
# =============================================================================
log_header "Step 3: Docker Engine"

if [[ "$SKIP_DOCKER" = true ]]; then
    log_skip "Docker installation skipped"
else
    lib_install_docker

    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"   # referenced by Step 4
fi

# =============================================================================
# Step 4: NVIDIA Container Toolkit (CUDA)
# =============================================================================
log_header "Step 4: NVIDIA Container Toolkit"

if [[ "$SKIP_CUDA" = true ]]; then
    log_skip "CUDA / NVIDIA toolkit skipped"
else
    lib_install_nvidia_toolkit

    # Patch daemon.json to add nvidia as default-runtime
    # (lib_install_nvidia_toolkit runs nvidia-ctk configure but doesn't set
    #  default-runtime — we need that for `docker run --gpus all` without flags)
    DOCKER_DAEMON_CONFIG="${DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}"
    if ! grep -q '"default-runtime"' "$DOCKER_DAEMON_CONFIG" 2>/dev/null; then
        log_info "Setting nvidia as Docker default runtime..."
        python3 - <<'PYEOF'
import json
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.setdefault("features", {})["buildkit"] = True
cfg["default-runtime"] = "nvidia"
cfg.setdefault("runtimes", {})["nvidia"] = {
    "path": "nvidia-container-runtime",
    "runtimeArgs": []
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("daemon.json updated with nvidia default-runtime")
PYEOF
        systemctl restart docker 2>/dev/null || true
    fi

    log_info "Testing NVIDIA container runtime..."
    if docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi 2>/dev/null; then
        log_success "CUDA container test passed"
    else
        log_warn "CUDA test failed — expected if drivers not yet installed"
        log_warn "Install drivers: sudo ubuntu-drivers install"
    fi
fi

# =============================================================================
# Step 5: Programming Languages
# =============================================================================
log_header "Step 5: Programming Languages"

if [[ "$SKIP_LANGUAGES" = true ]]; then
    log_skip "Language runtimes skipped"
else

    # ── Python ────────────────────────────────────────────────────────────────
    log_subheader "Python ${PYTHON_VERSION}"

    if python3.13 --version >/dev/null 2>&1; then
        log_info "Python 3.13 already present: $(python3.13 --version)"
    else
        log_info "Adding deadsnakes PPA for Python ${PYTHON_VERSION}..."
        add-apt-repository -y ppa:deadsnakes/ppa
        apt-get update -qq
        apt-get install -y \
            "python${PYTHON_VERSION}" \
            "python${PYTHON_VERSION}-dev" \
            "python${PYTHON_VERSION}-venv" \
            "python${PYTHON_VERSION}-distutils" 2>/dev/null || true
        log_success "Python ${PYTHON_VERSION} installed: $(python3.13 --version)"
    fi

    # pip bootstrap
    python3.13 -m pip --version >/dev/null 2>&1 || \
        python3.13 -m ensurepip --upgrade 2>/dev/null || \
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3.13

    # pipx
    if ! command -v pipx >/dev/null 2>&1; then
        apt-get install -y pipx 2>/dev/null || python3.13 -m pip install --user pipx
        lib_run_as_user "python3.13 -m pipx ensurepath"
        log_success "pipx installed"
    else
        log_info "pipx already installed"
    fi

    LOCAL_BIN="$USER_HOME/.local/bin"
    export PATH="$LOCAL_BIN:$PATH"

    # uv (astral.sh installer — faster than pipx for uv)
    if [[ ! -f "$LOCAL_BIN/uv" ]]; then
        log_info "Installing uv..."
        lib_run_as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
        log_success "uv installed"
    else
        log_info "uv already installed"
    fi

    # ruff
    if [[ ! -f "$LOCAL_BIN/ruff" ]]; then
        log_info "Installing ruff..."
        lib_run_as_user "curl -LsSf https://astral.sh/ruff/install.sh | sh"
        log_success "ruff installed"
    else
        log_info "ruff already installed: $("$LOCAL_BIN/ruff" --version 2>/dev/null || true)"
    fi

    # mypy
    if [[ ! -f "$LOCAL_BIN/mypy" ]]; then
        log_info "Installing mypy via pipx..."
        lib_run_as_user "pipx install mypy"
        log_success "mypy installed"
    else
        log_info "mypy already installed: $("$LOCAL_BIN/mypy" --version 2>/dev/null || true)"
    fi

    # update-alternatives
    PYTHON3_VER=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$PYTHON3_VER" != "3.13" ]] && command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --install /usr/bin/python3 python3 "$(command -v python3.13)" 10
        log_info "python3 → python3.13 via update-alternatives"
    fi
    log_success "Python stack ready"

    # ── Rust ──────────────────────────────────────────────────────────────────
    log_subheader "Rust (rustup)"

    if lib_run_as_user "command -v rustc" >/dev/null 2>&1; then
        log_info "Rust already installed: $(lib_run_as_user 'rustc --version')"
        lib_run_as_user "$USER_HOME/.cargo/bin/rustup update stable" 2>/dev/null || true
    else
        lib_install_rust
    fi

    log_info "Installing cargo utilities (cargo-watch, cargo-edit, cargo-expand)..."
    lib_run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-watch  2>/dev/null || true"
    lib_run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-edit   2>/dev/null || true"
    lib_run_as_user "$USER_HOME/.cargo/bin/cargo install cargo-expand 2>/dev/null || true"
    log_success "Cargo utilities installed"

    # ── Node.js ───────────────────────────────────────────────────────────────
    log_subheader "Node.js (nvm ${NVM_VERSION})"

    NVM_DIR="$USER_HOME/.nvm"
    if [[ -d "$NVM_DIR" ]]; then
        log_info "nvm already installed"
    else
        log_info "Installing nvm ${NVM_VERSION}..."
        lib_run_as_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
        log_success "nvm installed"
    fi

    log_info "Installing Node.js LTS..."
    lib_run_as_user ". ${NVM_DIR}/nvm.sh && nvm install --lts && nvm use --lts && nvm alias default node"
    NODE_VER=$(lib_run_as_user ". ${NVM_DIR}/nvm.sh && node --version" 2>/dev/null || true)
    [[ -n "$NODE_VER" ]] && log_success "Node.js installed: $NODE_VER"

    # ── Go ────────────────────────────────────────────────────────────────────
    log_subheader "Go ${GO_VERSION}"
    lib_install_go "$GO_VERSION"

fi  # SKIP_LANGUAGES

# =============================================================================
# Step 6: Protobuf / gRPC Toolchain
# =============================================================================
log_header "Step 6: Protobuf / gRPC Toolchain"

if [[ "$SKIP_PROTO" = true ]]; then
    log_skip "Proto toolchain skipped (--skip-proto)"
else
    CARGO_BIN="$USER_HOME/.cargo/bin"
    PROTOC_INSTALL_DIR="$USER_HOME/.local"
    PROTOC_BIN="$PROTOC_INSTALL_DIR/bin/protoc"

    # ── protoc ────────────────────────────────────────────────────────────────
    log_subheader "protoc ${PROTOC_VERSION}"

    if [[ -f "$PROTOC_BIN" ]]; then
        log_info "protoc already installed: $($PROTOC_BIN --version 2>/dev/null || echo 'installed')"
    else
        log_info "Installing protoc ${PROTOC_VERSION} from GitHub releases..."

        case "$ARCH_NORMALIZED" in
            amd64) PB_ARCH="linux-x86_64"  ;;
            arm64) PB_ARCH="linux-aarch_64" ;;
            armv7) PB_ARCH="linux-x86_32"  ;;
            *)     PB_ARCH="linux-x86_64"  ;;
        esac

        PB_ZIP="protoc-${PROTOC_VERSION}-${PB_ARCH}.zip"
        PB_URL="https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/${PB_ZIP}"

        log_info "Downloading ${PB_URL}..."
        wget -q "$PB_URL" -O "/tmp/${PB_ZIP}"
        lib_run_as_user "mkdir -p ${PROTOC_INSTALL_DIR}"
        lib_run_as_user "unzip -o /tmp/${PB_ZIP} -d ${PROTOC_INSTALL_DIR} 'bin/protoc' 'include/*'"
        chmod +x "$PROTOC_BIN"
        chown "$DEV_USER:$DEV_USER" "$PROTOC_BIN"
        rm "/tmp/${PB_ZIP}"

        log_success "protoc installed: $($PROTOC_BIN --version 2>/dev/null || echo "${PROTOC_VERSION}")"
    fi

    # Write PROTOC + PROTOC_INCLUDE env vars so prost-build / tonic-build pick
    # them up automatically in build.rs without per-project configuration
    PROTO_INCLUDE_DIR="$PROTOC_INSTALL_DIR/include"
    SHELL_RC_CHECK=""
    [[ -f "$USER_HOME/.zshrc"  ]] && SHELL_RC_CHECK="$USER_HOME/.zshrc"
    [[ -z "$SHELL_RC_CHECK" && -f "$USER_HOME/.bashrc" ]] && SHELL_RC_CHECK="$USER_HOME/.bashrc"

    if [[ -n "$SHELL_RC_CHECK" ]] && ! grep -q "PROTOC=" "$SHELL_RC_CHECK" 2>/dev/null; then
        printf '\n# protoc — prost-build / tonic-build in build.rs\nexport PROTOC="%s"\nexport PROTOC_INCLUDE="%s"\n' \
            "$PROTOC_BIN" "$PROTO_INCLUDE_DIR" >> "$SHELL_RC_CHECK"
        chown "$DEV_USER:$DEV_USER" "$SHELL_RC_CHECK"
        log_info "PROTOC env vars written to $SHELL_RC_CHECK"
    fi

    # ── buf ───────────────────────────────────────────────────────────────────
    log_subheader "buf CLI ${BUF_VERSION}"

    BUF_BIN="/usr/local/bin/buf"
    if [[ -f "$BUF_BIN" ]]; then
        log_info "buf already installed: $($BUF_BIN --version 2>/dev/null || echo 'installed')"
    else
        log_info "Installing buf ${BUF_VERSION}..."
        case "$ARCH_NORMALIZED" in
            amd64) BUF_ARCH="Linux-x86_64" ;;
            arm64) BUF_ARCH="Linux-arm64"  ;;
            *)     BUF_ARCH="Linux-x86_64" ;;
        esac
        curl -sSL \
            "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-${BUF_ARCH}" \
            -o "$BUF_BIN"
        chmod +x "$BUF_BIN"
        log_success "buf installed: $($BUF_BIN --version 2>/dev/null || echo "${BUF_VERSION}")"
    fi

    # ── Rust protoc plugins ───────────────────────────────────────────────────
    log_subheader "Rust codegen plugins (protoc-gen-prost, protoc-gen-tonic)"

    if [[ ! -f "${CARGO_BIN}/cargo" ]]; then
        log_warn "cargo not found — install Rust first, then:"
        log_warn "  cargo install protoc-gen-prost protoc-gen-tonic"
    else
        for plugin in protoc-gen-prost protoc-gen-tonic; do
            if [[ -f "${CARGO_BIN}/${plugin}" ]]; then
                log_info "${plugin} already installed"
            else
                log_info "Installing ${plugin}..."
                lib_run_as_user "${CARGO_BIN}/cargo install ${plugin}" \
                    && log_success "${plugin} installed" \
                    || log_warn "${plugin} failed — retry: cargo install ${plugin}"
            fi
        done
    fi

fi  # SKIP_PROTO

# =============================================================================
# Step 7: Shell Configuration
# =============================================================================
log_header "Step 7: Shell Configuration"

CURRENT_SHELL=$(getent passwd "$DEV_USER" | cut -d: -f7)
log_info "Current shell: $CURRENT_SHELL"

if command -v zsh >/dev/null 2>&1; then
    ZSH_PATH=$(command -v zsh)
    if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
        if lib_confirm_no "Switch default shell to zsh?"; then
            chsh -s "$ZSH_PATH" "$DEV_USER"
            log_success "Default shell → zsh"

            if [[ ! -d "$USER_HOME/.oh-my-zsh" ]] && lib_confirm_no "Install oh-my-zsh?"; then
                lib_run_as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
                log_success "oh-my-zsh installed"
            fi
        fi
    else
        log_info "zsh is already the default shell"
    fi
fi

SHELL_RC=""
[[ -f "$USER_HOME/.zshrc"  ]] && SHELL_RC="$USER_HOME/.zshrc"
[[ -z "$SHELL_RC" && -f "$USER_HOME/.bashrc" ]] && SHELL_RC="$USER_HOME/.bashrc"

if [[ -n "$SHELL_RC" ]] && ! grep -q "# Dev environment aliases" "$SHELL_RC" 2>/dev/null; then
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

# PATH
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"
RCEOF

    chown "$DEV_USER:$DEV_USER" "$SHELL_RC"
    log_success "Shell aliases written to $SHELL_RC"
fi

# =============================================================================
# Step 8: Zed IDE
# =============================================================================
log_header "Step 8: Zed IDE"

if [[ "$SKIP_GUI" = true ]]; then
    log_skip "Zed IDE skipped (--skip-gui)"
else
    if lib_run_as_user "command -v zed" >/dev/null 2>&1; then
        log_info "Zed already installed"
    else
        log_info "Installing Zed IDE..."
        apt-get install -y \
            libvulkan1 libxkbcommon-x11-0 \
            libwayland-client0 libwayland-cursor0 libwayland-egl1 \
            libxcb-shape0 libxcb-xfixes0 libsm6 libice6 \
            2>/dev/null || true

        lib_run_as_user "curl -f https://zed.dev/install.sh | sh"

        if lib_run_as_user "command -v zed" >/dev/null 2>&1; then
            log_success "Zed installed: $(lib_run_as_user 'zed --version' 2>/dev/null || echo 'installed')"
        else
            log_warn "Zed installer ran but 'zed' not found in PATH yet — add ~/.local/bin to PATH"
        fi
    fi

    [[ "$IS_WSL" = true ]] && \
        log_info "WSL2: Zed launches via WSLg — ensure WSLg is enabled in your Windows build"
fi

# =============================================================================
# Step 9: WSL2 Configuration
# =============================================================================
if [[ "$IS_WSL" = true ]]; then
    log_header "Step 9: WSL2 Configuration"

    apt-get install -y wslu 2>/dev/null || log_warn "wslu not available in this release"

    WSL_CONF="/etc/wsl.conf"
    if [[ ! -f "$WSL_CONF" ]]; then
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

    if [[ -n "$SHELL_RC" ]] && ! grep -q "# WSL aliases" "$SHELL_RC" 2>/dev/null; then
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
# Step 10: Development Directories
# =============================================================================
log_header "Step 10: Development Directories"
lib_setup_directories dev projects github workspace tmp

# =============================================================================
# Step 11: System Tuning
# =============================================================================
log_header "Step 11: System Tuning"
lib_setup_sysctl "devtools" \
"# Development workstation tuning
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 256
fs.file-max                   = 65536
net.core.somaxconn            = 1024"

# =============================================================================
# Step 12: GitHub Sync Service
# =============================================================================
log_header "Step 12: GitHub Repo Sync"
lib_setup_github_sync

# =============================================================================
# Done
# =============================================================================
log_header "Setup Complete!"

printf "${BOLD}${GREEN}Environment ready on %s${NC}\n\n" "$MACHINE_NAME"

printf "${BOLD}Installed:${NC}\n"
[[ "$SKIP_DEVTOOLS"  = false ]] && printf "  ${GREEN}✓${NC} Core CLI tools\n"
[[ "$SKIP_DOCKER"    = false ]] && command -v docker >/dev/null 2>&1 && \
    printf "  ${GREEN}✓${NC} Docker %s + Compose\n" "$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[[ "$SKIP_CUDA"      = false ]] && printf "  ${GREEN}✓${NC} NVIDIA Container Toolkit\n"
if [[ "$SKIP_LANGUAGES" = false ]]; then
    python3.13 --version >/dev/null 2>&1 && printf "  ${GREEN}✓${NC} Python 3.13 + uv + ruff + mypy\n"
    lib_run_as_user "command -v rustc" >/dev/null 2>&1 && \
        printf "  ${GREEN}✓${NC} Rust %s (stable)\n" "$(lib_run_as_user 'rustc --version' 2>/dev/null | cut -d' ' -f2)"
    printf "  ${GREEN}✓${NC} Node.js LTS (nvm)\n"
    command -v go >/dev/null 2>&1 && \
        printf "  ${GREEN}✓${NC} Go %s\n" "$(go version | cut -d' ' -f3)"
fi
if [[ "$SKIP_PROTO" = false ]]; then
    [[ -f "$USER_HOME/.local/bin/protoc" ]] && printf "  ${GREEN}✓${NC} protoc %s\n" "$PROTOC_VERSION"
    command -v buf >/dev/null 2>&1         && printf "  ${GREEN}✓${NC} buf %s\n" "$BUF_VERSION"
    [[ -f "$USER_HOME/.cargo/bin/protoc-gen-prost" ]] && \
        printf "  ${GREEN}✓${NC} protoc-gen-prost + protoc-gen-tonic\n"
fi
[[ "$SKIP_GUI" = false ]] && lib_run_as_user "command -v zed" >/dev/null 2>&1 && \
    printf "  ${GREEN}✓${NC} Zed IDE\n"
systemctl is-active --quiet github-sync.timer 2>/dev/null && \
    printf "  ${GREEN}✓${NC} GitHub sync timer (hourly, ~/github)\n"

printf "\n${BOLD}${YELLOW}Next steps:${NC}\n"
N=1
[[ "$SKIP_DOCKER" = false ]] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}newgrp docker${NC}  (or log out/in)\n" "$N" && N=$((N+1))
[[ -n "${SHELL_RC:-}" ]] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}source %s${NC}\n" "$N" "$SHELL_RC" && N=$((N+1))
[[ "$SKIP_DOCKER" = false ]] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}docker run hello-world${NC}\n" "$N" && N=$((N+1))
[[ "$SKIP_CUDA"   = false ]] && \
    printf "  ${GREEN}%d.${NC} ${CYAN}docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi${NC}\n" "$N" && N=$((N+1))
[[ "$SKIP_PROTO"  = false ]] && \
    printf "  ${GREEN}%d.${NC} Verify: ${CYAN}protoc --version && buf --version${NC}\n" "$N" && N=$((N+1))
printf "  ${GREEN}%d.${NC} Sync logs: ${CYAN}journalctl -u github-sync.service -f${NC}\n" "$N" && N=$((N+1))
printf "  ${GREEN}%d.${NC} Trigger:   ${CYAN}sudo systemctl start github-sync.service${NC}\n" "$N" && N=$((N+1))
[[ "$IS_WSL" = true ]] && \
    printf "  ${GREEN}%d.${NC} Restart WSL: ${CYAN}wsl --shutdown${NC} (from PowerShell)\n" "$N"

printf "\n"
log_success "All done — happy hacking, Jordan!"
printf "\n"

exit 0
