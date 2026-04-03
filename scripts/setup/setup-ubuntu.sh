#!/usr/bin/env bash
# =============================================================================
# setup-ubuntu.sh — Ubuntu/Debian base library
# =============================================================================
# SOURCE this file; do NOT run it directly.
#
#   . "$(dirname "$0")/setup-ubuntu.sh"
#   # or fetch from GitHub:
#   _b=$(mktemp); curl -fsSL "${REPO_RAW}/setup-ubuntu.sh" -o "$_b"; . "$_b"; rm -f "$_b"
#
# Provides: colors, logging, system detection, and installer functions.
# Callers set their own globals (DEV_USER, NO_CONFIRM, etc.) before sourcing.
#
# All public functions are prefixed  lib_
# Internal helpers are prefixed      _lib_
# =============================================================================

# Guard against double-sourcing
[ -n "$_SETUP_UBUNTU_LOADED" ] && return 0
_SETUP_UBUNTU_LOADED=1

# =============================================================================
# Colors & Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { printf "${BLUE}[INFO]${NC}    %s\n"    "$*"; }
log_success() { printf "${GREEN}[OK]${NC}      %s\n"   "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}   %s\n"   "$*"; }
log_error()   { printf "${RED}[ERROR]${NC}   %s\n"    "$*"; }
log_step()    { printf "${MAGENTA}[STEP]${NC}  ${BOLD}%s${NC}\n" "$*"; }
log_skip()    { printf "${YELLOW}[SKIP]${NC}   %s\n"   "$*"; }
log_die()     { printf "${RED}[FATAL]${NC}  %s\n" "$*" >&2; exit 1; }

log_header() {
    printf "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════════${NC}\n"
    printf   "${BOLD}${CYAN}  %s${NC}\n" "$*"
    printf   "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════${NC}\n\n"
}

log_subheader() {
    printf "\n${BOLD}${YELLOW}── %s ──${NC}\n\n" "$*"
}

lib_sep() {
    printf "${DIM}──────────────────────────────────────────────────────────────────${NC}\n"
}

# =============================================================================
# Helpers
# =============================================================================

# lib_confirm "Question?"  → returns 0 (yes) or 1 (no)
# Respects global $NO_CONFIRM
lib_confirm() {
    [ "${NO_CONFIRM:-false}" = true ] && return 0
    printf "%s ${DIM}(Y/n)${NC} " "$1"
    read -r _reply
    case "$_reply" in n|N|no|No|NO) return 1 ;; *) return 0 ;; esac
}

# lib_confirm_no "Question?"  → default NO
lib_confirm_no() {
    [ "${NO_CONFIRM:-false}" = true ] && return 1
    printf "%s ${DIM}(y/N)${NC} " "$1"
    read -r _reply
    case "$_reply" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}

# lib_run_as_user "command string"
lib_run_as_user() {
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    sudo -u "$_u" -H bash -c "$*"
}

# =============================================================================
# System Detection
# Sets: ARCH ARCH_NORMALIZED OS_NAME OS_VERSION OS_CODENAME OS_ID
#       IS_WSL IS_WSL2 IS_PI HAS_NVIDIA HOSTNAME_VAL USER_HOME
# =============================================================================
lib_detect_system() {
    # Architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   ARCH_NORMALIZED="amd64" ;;
        aarch64|arm64)  ARCH_NORMALIZED="arm64" ;;
        armv7l|armhf)   ARCH_NORMALIZED="armhf" ;;
        *)              ARCH_NORMALIZED="$ARCH" ;;
    esac

    # OS info
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_NAME="${NAME:-Unknown}"
        OS_VERSION="${VERSION_ID:-Unknown}"
        OS_CODENAME="${VERSION_CODENAME:-}"
        OS_ID="${ID:-unknown}"
    else
        log_warn "Cannot read /etc/os-release — assuming Ubuntu"
        OS_NAME="Ubuntu"; OS_VERSION="unknown"; OS_CODENAME=""; OS_ID="ubuntu"
    fi

    # WSL detection
    IS_WSL=false; IS_WSL2=false
    if grep -qi microsoft /proc/version 2>/dev/null; then
        IS_WSL=true
        grep -qi wsl2 /proc/version 2>/dev/null \
            || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] && IS_WSL2=true
    fi

    # Raspberry Pi detection
    IS_PI=false
    grep -qi "raspberry pi" /proc/cpuinfo 2>/dev/null \
        || [ -f /sys/firmware/devicetree/base/model ] \
        && grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null \
        && IS_PI=true

    # NVIDIA
    HAS_NVIDIA=false
    lspci 2>/dev/null | grep -qi nvidia && HAS_NVIDIA=true
    ls /dev/nvidia* >/dev/null 2>&1 && HAS_NVIDIA=true

    # Hostname / user context
    HOSTNAME_VAL=$(hostname 2>/dev/null || echo "machine")
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    USER_HOME=$(eval echo "~${_u}")

    log_info "OS:    $OS_NAME $OS_VERSION ${OS_CODENAME:+(${OS_CODENAME})}"
    log_info "Arch:  $ARCH ($ARCH_NORMALIZED)"
    [ "$IS_WSL2" = true ]   && log_info "Env:   WSL2"
    [ "$IS_WSL"  = true ] && [ "$IS_WSL2" = false ] && log_warn "Env:   WSL1 — upgrade to WSL2 recommended"
    [ "$IS_PI"   = true ]   && log_info "Env:   Raspberry Pi"
    [ "$HAS_NVIDIA" = true ] && log_success "GPU:   NVIDIA detected"
}

# =============================================================================
# APT helpers
# =============================================================================
lib_apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    log_info "apt update + upgrade..."
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https \
        curl wget
    log_success "APT updated"
}

# Install a list of packages, with a fallback minimal set if any fail
lib_apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq "$@" 2>/dev/null || apt-get install -y "$@"
}

# Add an apt key + repo (idempotent)
# lib_apt_add_repo "keyring-path" "key-url" "repo-line" "list-file"
lib_apt_add_repo() {
    local keyring="$1" key_url="$2" repo_line="$3" list_file="$4"
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f "$keyring" ]; then
        curl -fsSL "$key_url" | gpg --dearmor -o "$keyring"
        chmod a+r "$keyring"
    fi
    echo "$repo_line" > "$list_file"
    apt-get update -qq
}

# =============================================================================
# Base packages
# =============================================================================
lib_install_base_packages() {
    log_subheader "Core CLI tools"
    lib_apt_install \
        git build-essential pkg-config libssl-dev libffi-dev \
        vim nano tmux zsh zsh-completions \
        htop btop jq tree \
        unzip zip \
        openssh-client openssl \
        net-tools dnsutils iputils-ping \
        man-db ncdu \
        fzf ripgrep fd-find bat \
        tldr pciutils strace lsof \
        httpie 2>/dev/null || true

    # bat alias (Ubuntu calls it batcat)
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
        mkdir -p "$USER_HOME/.local/bin"
        ln -sf "$(command -v batcat)" "$USER_HOME/.local/bin/bat"
        chown -R "${_u}:${_u}" "$USER_HOME/.local"
        log_info "Created bat → batcat symlink"
    fi

    log_success "Core CLI tools installed"
}

# =============================================================================
# Docker Engine
# Sets: DOCKER_INSTALLED (true|false)
# =============================================================================
lib_install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker already installed: $(docker --version 2>/dev/null)"
        DOCKER_INSTALLED=true
        return 0
    fi

    log_info "Installing Docker Engine (official repo)..."
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    local _codename="${OS_CODENAME:-jammy}"
    lib_apt_add_repo \
        "/etc/apt/keyrings/docker.gpg" \
        "https://download.docker.com/linux/ubuntu/gpg" \
        "deb [arch=${ARCH_NORMALIZED} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${_codename} stable" \
        "/etc/apt/sources.list.d/docker.list"

    # Fallback: if the current codename isn't in Docker's repo yet
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || {
        log_warn "Docker repo may not carry '${_codename}' yet — trying 'noble' fallback"
        sed -i "s/${_codename}/noble/g" /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    }

    log_success "Docker installed: $(docker --version)"
    DOCKER_INSTALLED=true

    # Enable service (skip in WSL1)
    if [ "${IS_WSL:-false}" = false ] || [ "${IS_WSL2:-false}" = true ]; then
        systemctl enable docker 2>/dev/null || true
        systemctl start  docker 2>/dev/null || true
    fi

    # Add user to docker group
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    if ! groups "$_u" 2>/dev/null | grep -q docker; then
        usermod -aG docker "$_u"
        log_success "User '$_u' added to docker group (re-login required)"
    fi

    # Daemon config
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "features": { "buildkit": true }
}
EOF
        systemctl restart docker 2>/dev/null || true
        log_success "Docker daemon config written (BuildKit enabled)"
    fi
}

# =============================================================================
# NVIDIA Container Toolkit
# =============================================================================
lib_install_nvidia_toolkit() {
    if [ "${HAS_NVIDIA:-false}" = false ]; then
        log_skip "No NVIDIA GPU — skipping container toolkit"
        return 0
    fi

    log_info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true
    log_success "NVIDIA Container Toolkit installed"
}

# =============================================================================
# Language runtimes
# =============================================================================

lib_install_rust() {
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    if lib_run_as_user "command -v rustc" >/dev/null 2>&1; then
        log_info "Rust already installed: $(lib_run_as_user 'rustc --version' 2>/dev/null)"
        return 0
    fi
    log_info "Installing Rust via rustup..."
    lib_run_as_user "curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable"
    lib_run_as_user "source \$HOME/.cargo/env && rustup component add rust-analyzer clippy rustfmt"
    log_success "Rust installed: $(lib_run_as_user 'source $HOME/.cargo/env && rustc --version' 2>/dev/null)"
}

# lib_install_node [nvm_version]
lib_install_node() {
    local _nvm_ver="${1:-v0.40.4}"
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    log_info "Installing Node.js LTS via nvm ${_nvm_ver}..."
    lib_run_as_user "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${_nvm_ver}/install.sh | bash"
    lib_run_as_user "source \$HOME/.nvm/nvm.sh && nvm install --lts && nvm use --lts && nvm alias default 'lts/*'"
    log_success "Node.js installed: $(lib_run_as_user 'source $HOME/.nvm/nvm.sh && node --version' 2>/dev/null)"
}

# lib_install_python [version]  e.g. lib_install_python 3.13
lib_install_python() {
    local _ver="${1:-3.13}"
    log_info "Installing Python ${_ver} + uv + ruff + mypy..."

    # deadsnakes PPA for non-LTS versions
    add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
    apt-get update -qq

    lib_apt_install \
        "python${_ver}" "python${_ver}-dev" "python${_ver}-venv" \
        python3-pip python3-venv pipx

    lib_run_as_user "pipx install uv ruff mypy 2>/dev/null || pip3 install --user uv ruff mypy"

    # Make python3.X the default python3 if needed
    update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${_ver}" 100 2>/dev/null || true

    log_success "Python ${_ver} installed + uv + ruff + mypy"
}

# lib_install_go [version]  e.g. lib_install_go 1.24.0
lib_install_go() {
    local _ver="${1:-}"
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"

    if command -v go >/dev/null 2>&1; then
        log_info "Go already installed: $(go version 2>/dev/null)"
        return 0
    fi

    # Fetch latest stable version if not pinned
    if [ -z "$_ver" ]; then
        _ver=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1 | tr -d 'go\n' || echo "1.24.0")
    fi

    log_info "Installing Go ${_ver}..."
    local _tarball="go${_ver}.linux-${ARCH_NORMALIZED}.tar.gz"
    curl -fsSL "https://go.dev/dl/${_tarball}" -o "/tmp/${_tarball}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${_tarball}"
    rm -f "/tmp/${_tarball}"

    # Add to PATH for the user
    local _profile="$USER_HOME/.profile"
    grep -q '/usr/local/go/bin' "$_profile" 2>/dev/null || \
        echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' >> "$_profile"

    export PATH="$PATH:/usr/local/go/bin"
    log_success "Go installed: $(go version 2>/dev/null)"
}

# =============================================================================
# Shell config (zsh + shell profile additions)
# lib_setup_shell_profile "line to append if not present"
# =============================================================================
lib_setup_shell_profile() {
    local _line="$1"
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    local _zshrc="$USER_HOME/.zshrc"
    local _bashrc="$USER_HOME/.bashrc"
    local _profile="$USER_HOME/.profile"

    for _f in "$_zshrc" "$_bashrc" "$_profile"; do
        grep -qF "$_line" "$_f" 2>/dev/null || echo "$_line" >> "$_f"
    done
    chown "${_u}:${_u}" "$_zshrc" "$_bashrc" "$_profile" 2>/dev/null || true
}

# =============================================================================
# GitHub Sync Service
# Creates ~/.local/bin/gh_sync.sh + systemd service + timer
# Globals used: GH_USER (default: nuniesmith), DEV_USER, USER_HOME
# =============================================================================
lib_setup_github_sync() {
    local _gh_user="${GH_USER:-nuniesmith}"
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    local _sync_script="$USER_HOME/.local/bin/gh_sync.sh"
    local _svc="github-sync"

    mkdir -p "$USER_HOME/.local/bin"
    chown "${_u}:${_u}" "$USER_HOME/.local/bin"

    log_info "Writing $(_sync_script)..."
    cat > "$_sync_script" << SYNCEOF
#!/usr/bin/env bash
# GitHub repo sync — ${_gh_user} (all public repos)
set -euo pipefail
GH_USER="${_gh_user}"
TARGET_DIR="\$HOME/github"
LOG_TAG="gh_sync"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [\$LOG_TAG] \$*"; }

log "--- Sync starting ---"
mkdir -p "\$TARGET_DIR"
cd "\$TARGET_DIR"

log "Fetching repo list for \$GH_USER..."
REPO_DATA=""; PAGE=1
while true; do
    PAGE_DATA=\$(curl -sf \\
        -H "Accept: application/vnd.github.v3+json" \\
        "https://api.github.com/users/\$GH_USER/repos?per_page=100&page=\$PAGE&type=public" \\
        | jq -r '.[] | "\(.name)|\(.clone_url)"')
    [ -z "\$PAGE_DATA" ] && break
    REPO_DATA="\${REPO_DATA}\${PAGE_DATA}"$'\n'
    PAGE=\$((PAGE + 1))
done

[ -z "\$REPO_DATA" ] && { log "ERROR: Could not fetch repo list"; exit 1; }

ACTIVE=\$(echo "\$REPO_DATA" | cut -d'|' -f1 | sort)
log "Found \$(echo "\$ACTIVE" | grep -c .) repos"

for d in */; do
    [ -d "\$d" ] || continue
    n="\${d%/}"
    echo "\$ACTIVE" | grep -qx "\$n" || { log "Removing stale: \$n"; rm -rf "\$n"; }
done

CLONED=0; PULLED=0; FAILED=0
while IFS='|' read -r NAME URL; do
    [ -z "\$NAME" ] && continue
    if [ -d "\$NAME/.git" ]; then
        git -C "\$NAME" pull --ff-only --quiet 2>/dev/null && PULLED=\$((PULLED+1)) \\
            || { log "WARN: ff-only failed for \$NAME"; FAILED=\$((FAILED+1)); }
    else
        git clone --quiet "\$URL" 2>/dev/null && { log "Cloned: \$NAME"; CLONED=\$((CLONED+1)); } \\
            || { log "ERROR: clone failed for \$NAME"; FAILED=\$((FAILED+1)); }
    fi
done <<< "\$REPO_DATA"

log "Sync complete — cloned=\$CLONED pulled=\$PULLED failed=\$FAILED"

command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && {
    log "Docker prune (>7d)..."
    docker system prune -af --filter "until=168h" --quiet 2>/dev/null || true
    docker volume prune -f --quiet 2>/dev/null || true
}

log "--- Done ---"
SYNCEOF

    chmod +x "$_sync_script"
    chown "${_u}:${_u}" "$_sync_script"

    cat > "/etc/systemd/system/${_svc}.service" << SVCEOF
[Unit]
Description=Sync ${_gh_user} GitHub repos + Docker prune
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_sync_script}
User=${_u}
Environment=HOME=${USER_HOME}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${USER_HOME}/.local/bin:${USER_HOME}/.cargo/bin:/usr/local/go/bin
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    cat > "/etc/systemd/system/${_svc}.timer" << TMREOF
[Unit]
Description=Hourly GitHub sync + Docker maintenance

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

    systemctl daemon-reload
    systemctl enable --now "${_svc}.timer"
    log_success "GitHub sync timer enabled (hourly, ~/github)"
    log_info "Logs: journalctl -u ${_svc}.service -f"
    log_info "Run now: sudo systemctl start ${_svc}.service"
}

# =============================================================================
# SSH hardening
# =============================================================================
lib_setup_ssh_hardening() {
    local _cfg="/etc/ssh/sshd_config"
    local _port="${SSH_PORT:-22}"

    log_info "Hardening SSH config..."

    # Only touch settings that are still at default/commented
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/'           "$_cfg"
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$_cfg"
    sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/'  "$_cfg"
    sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/'               "$_cfg"
    sed -i "s/^#\?Port .*/Port ${_port}/"                            "$_cfg"

    grep -q "^MaxAuthTries"  "$_cfg" || echo "MaxAuthTries 3"   >> "$_cfg"
    grep -q "^ClientAliveInterval" "$_cfg" || \
        printf "\nClientAliveInterval 300\nClientAliveCountMax 2\n" >> "$_cfg"

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    log_success "SSH hardened (root login disabled, port ${_port})"
}

# =============================================================================
# sysctl tuning
# lib_setup_sysctl "label" "conf-content"
# =============================================================================
lib_setup_sysctl() {
    local _label="${1:-devtools}"
    local _conf="/etc/sysctl.d/99-${_label}.conf"
    shift
    if [ ! -f "$_conf" ]; then
        printf "%s\n" "$*" > "$_conf"
        sysctl -p "$_conf" >/dev/null 2>&1 || true
        log_success "sysctl tuning applied (${_conf})"
    else
        log_info "sysctl config already present: ${_conf}"
    fi
}

# =============================================================================
# Standard dev directories
# lib_setup_directories dir1 dir2 ...
# =============================================================================
lib_setup_directories() {
    local _u="${DEV_USER:-${SUDO_USER:-${USER}}}"
    for _d in "$@"; do
        local _path="$USER_HOME/$_d"
        if [ ! -d "$_path" ]; then
            lib_run_as_user "mkdir -p '$_path'"
            log_success "Created: ~/$_d"
        else
            log_info "Exists:  ~/$_d"
        fi
    done
}

# =============================================================================
# Git global config (interactive unless NO_CONFIRM=true)
# =============================================================================
lib_setup_git_config() {
    local _current_name  _current_email
    _current_name=$(lib_run_as_user  "git config --global user.name"  2>/dev/null || true)
    _current_email=$(lib_run_as_user "git config --global user.email" 2>/dev/null || true)

    if [ -z "$_current_name" ] && [ "${NO_CONFIRM:-false}" = false ]; then
        printf "Name for Git commits: "; read -r _name
        [ -n "$_name" ] && lib_run_as_user "git config --global user.name '$_name'"
    else
        log_info "Git user.name: ${_current_name:-<not set>}"
    fi

    if [ -z "$_current_email" ] && [ "${NO_CONFIRM:-false}" = false ]; then
        printf "Email for Git commits: "; read -r _email
        [ -n "$_email" ] && lib_run_as_user "git config --global user.email '$_email'"
    else
        log_info "Git user.email: ${_current_email:-<not set>}"
    fi

    lib_run_as_user "git config --global init.defaultBranch main"  2>/dev/null || true
    lib_run_as_user "git config --global pull.rebase false"        2>/dev/null || true
    lib_run_as_user "git config --global core.autocrlf input"      2>/dev/null || true
    lib_run_as_user "git config --global core.editor vim"          2>/dev/null || true
    lib_run_as_user "git config --global rerere.enabled true"      2>/dev/null || true
    log_success "Git configured"
}

# =============================================================================
# Preflight checks
# =============================================================================
lib_require_root() {
    [ "$(id -u)" -eq 0 ] || log_die "Run this script with sudo"
}

lib_require_apt() {
    command -v apt-get >/dev/null 2>&1 || log_die "apt-get not found — Ubuntu/Debian only"
}

lib_require_user() {
    local _u="${DEV_USER:-${SUDO_USER:-}}"
    [ -n "$_u" ] && id "$_u" >/dev/null 2>&1 && return 0
    log_die "No valid DEV_USER set (got: '${_u}'). Pass --user NAME"
}

# =============================================================================
# Banner
# =============================================================================
lib_show_banner() {
    local _title="${1:-Ubuntu Setup}"
    clear 2>/dev/null || true
    printf "\n${CYAN}${BOLD}"
    printf "  ╔══════════════════════════════════════════════════════╗\n"
    printf "  ║  %-52s║\n" "$_title"
    printf "  ╚══════════════════════════════════════════════════════╝\n"
    printf "${NC}\n"
}

# =============================================================================
# If executed directly (not sourced) — show usage
# =============================================================================
_lib_is_sourced() {
    # BASH_SOURCE[0] == $0 means we were executed, not sourced
    [ "${BASH_SOURCE[0]}" = "$0" ] && return 1 || return 0
}

if ! _lib_is_sourced 2>/dev/null; then
    printf "\n%s is a library — source it, don't run it directly.\n\n" "$(basename "$0")"
    printf "  Usage:  . %s\n\n" "$(basename "$0")"
    printf "  Provides: colors, logging, lib_detect_system(), lib_install_docker(),\n"
    printf "            lib_install_rust(), lib_install_node(), lib_install_python(),\n"
    printf "            lib_install_go(), lib_setup_github_sync(), and more.\n\n"
    exit 0
fi
