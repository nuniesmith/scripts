#!/usr/bin/env bash
# =============================================================================
# setup-arch.sh — Arch Linux base library
# =============================================================================
# SOURCE this file; do NOT run it directly.
#
#   . "$(dirname "$0")/setup-arch.sh"
#   # or fetch from GitHub:
#   _b=$(mktemp); curl -fsSL "${REPO_RAW}/setup-arch.sh" -o "$_b"; . "$_b"; rm -f "$_b"
#
# Designed for: Arch live ISO (Phase 1) and installed Arch systems (Phase 2).
# All public functions prefixed lib_  — internal helpers prefixed _lib_
# =============================================================================

[ -n "$_SETUP_ARCH_LOADED" ] && return 0
_SETUP_ARCH_LOADED=1

# =============================================================================
# Colors & Logging  (same API as setup-ubuntu.sh so callers are portable)
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
lib_confirm() {
    [ "${NO_CONFIRM:-false}" = true ] && return 0
    printf "%s ${DIM}(Y/n)${NC} " "$1"
    read -r _reply
    case "$_reply" in n|N|no|No|NO) return 1 ;; *) return 0 ;; esac
}

lib_confirm_no() {
    [ "${NO_CONFIRM:-false}" = true ] && return 1
    printf "%s ${DIM}(y/N)${NC} " "$1"
    read -r _reply
    case "$_reply" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}

lib_run_as_user() {
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    sudo -u "$_u" -H bash -c "$*"
}

# =============================================================================
# System Detection
# Sets: ARCH ARCH_NORMALIZED IS_LIVE_ISO IS_UEFI HAS_NVIDIA HOSTNAME_VAL
# =============================================================================
lib_detect_system() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   ARCH_NORMALIZED="x86_64" ;;
        aarch64|arm64)  ARCH_NORMALIZED="aarch64" ;;
        *)              ARCH_NORMALIZED="$ARCH" ;;
    esac

    # Live ISO detection
    IS_LIVE_ISO=false
    grep -q "archiso" /proc/cmdline 2>/dev/null && IS_LIVE_ISO=true
    [ "$(uname -n)" = "archiso" ] && IS_LIVE_ISO=true

    # UEFI detection
    IS_UEFI=false
    [ -d /sys/firmware/efi ] && IS_UEFI=true

    # NVIDIA
    HAS_NVIDIA=false
    lspci 2>/dev/null | grep -qi nvidia && HAS_NVIDIA=true

    HOSTNAME_VAL=$(hostname 2>/dev/null || echo "archbox")
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    USER_HOME="/home/${_u}"

    log_info "Arch:     $ARCH ($ARCH_NORMALIZED)"
    log_info "UEFI:     $IS_UEFI"
    log_info "Live ISO: $IS_LIVE_ISO"
    [ "$HAS_NVIDIA" = true ] && log_success "GPU: NVIDIA detected"
}

# =============================================================================
# Preflight
# =============================================================================
lib_require_root()    { [ "$(id -u)" -eq 0 ] || log_die "Run as root"; }
lib_require_pacman()  { command -v pacman >/dev/null 2>&1 || log_die "pacman not found — Arch only"; }
lib_require_network() {
    log_info "Checking network..."
    for _h in archlinux.org 8.8.8.8 1.1.1.1; do
        ping -c1 -W3 "$_h" >/dev/null 2>&1 && { log_success "Network OK"; return 0; }
    done
    log_die "No network — connect via USB ethernet or phone tethering, then re-run"
}

# =============================================================================
# pacman wrappers
# =============================================================================

# lib_pacman_install pkg1 pkg2 ...  (idempotent, quiet)
lib_pacman_install() {
    pacman -S --needed --noconfirm "$@"
}

# lib_pacman_update  — refresh db + upgrade
lib_pacman_update() {
    log_info "pacman -Syu..."
    pacman -Syu --noconfirm
    log_success "System updated"
}

# =============================================================================
# Mirrors (reflector)
# =============================================================================
lib_setup_mirrors() {
    local _country="${1:-CA,US}"
    if command -v reflector >/dev/null 2>&1; then
        log_info "Optimising mirrorlist (reflector)..."
        reflector --country "$_country" --latest 10 --sort rate \
                  --save /etc/pacman.d/mirrorlist 2>/dev/null || true
        log_success "Mirrorlist updated"
    else
        log_skip "reflector not installed — using default mirrors"
    fi
}

# =============================================================================
# AUR helper — yay
# =============================================================================
lib_install_yay() {
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    if lib_run_as_user "command -v yay" >/dev/null 2>&1; then
        log_info "yay already installed"
        return 0
    fi

    log_info "Installing yay (AUR helper)..."
    lib_pacman_install git base-devel

    lib_run_as_user "
        rm -rf /tmp/yay-bin
        git clone --depth=1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
        cd /tmp/yay-bin && makepkg -si --noconfirm
        rm -rf /tmp/yay-bin
    "
    log_success "yay installed"
}

# lib_yay_install pkg1 pkg2 ...  (run as non-root user)
lib_yay_install() {
    lib_run_as_user "yay -S --needed --noconfirm $*"
}

# =============================================================================
# Rust  (via rustup)
# =============================================================================
lib_install_rust() {
    lib_run_as_user "command -v rustc" >/dev/null 2>&1 && {
        log_info "Rust already installed: $(lib_run_as_user 'rustc --version' 2>/dev/null)"
        return 0
    }
    log_info "Installing Rust via rustup..."
    lib_run_as_user "curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable"
    lib_run_as_user "source \$HOME/.cargo/env && rustup component add rust-analyzer clippy rustfmt"
    log_success "Rust installed"
}

# =============================================================================
# Node.js  (via fnm — fast node manager, preferred on Arch)
# =============================================================================
lib_install_node() {
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    lib_run_as_user "command -v node" >/dev/null 2>&1 && {
        log_info "Node already installed: $(lib_run_as_user 'node --version' 2>/dev/null)"
        return 0
    }
    log_info "Installing Node.js LTS via fnm..."
    lib_run_as_user "curl -fsSL https://fnm.vercel.app/install | bash"
    lib_run_as_user "source \$HOME/.bashrc && fnm install --lts && fnm use lts-latest && fnm default lts-latest"
    log_success "Node.js installed: $(lib_run_as_user 'source $HOME/.bashrc && node --version' 2>/dev/null)"
}

# =============================================================================
# Python  (pacman + pipx tools)
# =============================================================================
lib_install_python() {
    log_info "Installing Python + uv + ruff + mypy..."
    lib_pacman_install python python-pip python-pipx
    lib_run_as_user "pipx install uv ruff mypy"
    log_success "Python installed + uv, ruff, mypy"
}

# =============================================================================
# Docker (Docker Engine via pacman)
# =============================================================================
lib_install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker already installed: $(docker --version 2>/dev/null)"
        return 0
    fi
    log_info "Installing Docker..."
    lib_pacman_install docker docker-compose

    systemctl enable --now docker
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    usermod -aG docker "$_u"

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "features": { "buildkit": true }
}
EOF
    systemctl restart docker
    log_success "Docker installed: $(docker --version)"
}

# =============================================================================
# GitHub Sync Service  (identical logic to ubuntu base, but Arch paths)
# =============================================================================
lib_setup_github_sync() {
    local _gh_user="${GH_USER:-nuniesmith}"
    local _u="${USERNAME:-${SUDO_USER:-${USER}}}"
    local _home="/home/${_u}"
    local _sync_script="${_home}/.local/bin/gh_sync.sh"
    local _svc="github-sync"

    mkdir -p "${_home}/.local/bin"
    chown "${_u}:${_u}" "${_home}/.local/bin"

    cat > "$_sync_script" << SYNCEOF
#!/usr/bin/env bash
set -euo pipefail
GH_USER="${_gh_user}"
TARGET_DIR="\$HOME/github"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [gh_sync] \$*"; }

log "--- Sync starting ---"
mkdir -p "\$TARGET_DIR"; cd "\$TARGET_DIR"

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
[ -z "\$REPO_DATA" ] && { log "ERROR: repo list fetch failed"; exit 1; }

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
        git -C "\$NAME" pull --ff-only --quiet 2>/dev/null \\
            && PULLED=\$((PULLED+1)) \\
            || { log "WARN: ff-only failed for \$NAME"; FAILED=\$((FAILED+1)); }
    else
        git clone --quiet "\$URL" 2>/dev/null \\
            && { log "Cloned: \$NAME"; CLONED=\$((CLONED+1)); } \\
            || { log "ERROR: clone failed for \$NAME"; FAILED=\$((FAILED+1)); }
    fi
done <<< "\$REPO_DATA"

log "Done — cloned=\$CLONED pulled=\$PULLED failed=\$FAILED"
command -v docker &>/dev/null && docker info &>/dev/null && {
    docker system prune -af --filter "until=168h" --quiet 2>/dev/null || true
    docker volume prune -f --quiet 2>/dev/null || true
}
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
Environment=HOME=${_home}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${_home}/.local/bin:${_home}/.cargo/bin
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    cat > "/etc/systemd/system/${_svc}.timer" << TMREOF
[Unit]
Description=Hourly GitHub sync + Docker maintenance

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

    systemctl daemon-reload
    systemctl enable github-sync.timer
    log_success "GitHub sync timer installed (runs hourly after boot)"
}

# =============================================================================
# Btrfs subvolume layout helpers
# =============================================================================

# lib_btrfs_create_subvolumes /dev/sdX2 "@" "@home" "@var" ...
lib_btrfs_create_subvolumes() {
    local _part="$1"; shift
    local _mnt
    _mnt=$(mktemp -d)
    mount "$_part" "$_mnt"
    for sv in "$@"; do
        btrfs subvolume create "${_mnt}/${sv}"
        log_success "Btrfs subvol: ${sv}"
    done
    umount "$_mnt"
    rmdir "$_mnt"
}

# =============================================================================
# Banner
# =============================================================================
lib_show_banner() {
    local _title="${1:-Arch Setup}"
    clear 2>/dev/null || true
    printf "\n${CYAN}${BOLD}"
    printf "  ╔══════════════════════════════════════════════════════╗\n"
    printf "  ║  %-52s║\n" "$_title"
    printf "  ╚══════════════════════════════════════════════════════╝\n"
    printf "${NC}\n"
}

# =============================================================================
# If executed directly — show usage
# =============================================================================
_lib_is_sourced() { [ "${BASH_SOURCE[0]}" = "$0" ] && return 1 || return 0; }

if ! _lib_is_sourced 2>/dev/null; then
    printf "\n%s is a library — source it, don't run it directly.\n\n" "$(basename "$0")"
    printf "  Usage:  . %s\n\n" "$(basename "$0")"
    exit 0
fi
