#!/usr/bin/env bash
# =============================================================================
# setup-staging-server.sh — Ubuntu Staging / QA Server
# =============================================================================
# Targets: Ubuntu 22.04 LTS / 24.04 LTS / 25.10  (x86_64 | ARM64)
#
# Lighter than production:
#   - Docker + Compose  (same as prod)
#   - Tailscale         (same as prod — staging lives on tailnet)
#   - UFW               (SSH + Tailscale only)
#   - NO fail2ban, NO unattended-upgrades, NO swap by default
#   - GitHub sync timer (pull latest code automatically)
#   - Node exporter     (Prometheus scraping)
#   - Debug-friendly:   verbose logging, writable /opt/staging, relaxed limits
#
# Usage:
#   sudo ./setup-staging-server.sh [OPTIONS]
#
# Options:
#   -u, --user NAME         Admin user (default: current sudo user)
#   -p, --project NAME      Project name used for dirs/labels (default: staging)
#       --skip-docker       Skip Docker installation
#       --skip-tailscale    Skip Tailscale installation
#       --skip-firewall     Skip UFW configuration
#       --skip-sync         Skip GitHub sync timer
#       --no-confirm        Non-interactive / CI mode
#   -h, --help              Show this help
# =============================================================================
set -euo pipefail

# =============================================================================
# Source the Ubuntu base library
# =============================================================================
REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"
_LIB="$(dirname "${BASH_SOURCE[0]:-$0}")/setup-ubuntu.sh"

if [ -f "$_LIB" ]; then
    # shellcheck source=setup-ubuntu.sh
    . "$_LIB"
else
    _TMP=$(mktemp /tmp/setup-ubuntu.XXXXXX.sh)
    echo "  Fetching base library from GitHub..."
    curl -fsSL "${REPO_RAW}/setup-ubuntu.sh" -o "$_TMP"
    # shellcheck source=/dev/null
    . "$_TMP"
    rm -f "$_TMP"
fi

# =============================================================================
# Defaults (can be overridden before sourcing or via flags)
# =============================================================================
DEV_USER="${SUDO_USER:-${USER}}"
PROJECT_NAME="staging"
SKIP_DOCKER=false
SKIP_TAILSCALE=false
SKIP_FIREWALL=false
SKIP_SYNC=false
NO_CONFIRM=false

# Version pins
NVM_VERSION="v0.40.4"
GH_USER="nuniesmith"

# =============================================================================
# Help
# =============================================================================
show_help() {
    cat << 'EOF'
setup-staging-server.sh — Ubuntu Staging / QA Server
=====================================================

USAGE:
    sudo ./setup-staging-server.sh [OPTIONS]

OPTIONS:
    -u, --user NAME         Admin user (default: current sudo user)
    -p, --project NAME      Project name for dirs/labels (default: staging)
        --skip-docker       Skip Docker
        --skip-tailscale    Skip Tailscale
        --skip-firewall     Skip UFW
        --skip-sync         Skip GitHub sync timer
        --no-confirm        Non-interactive
    -h, --help              Show this help

WHAT THIS INSTALLS:
    Core tools · Docker Engine + Compose · Tailscale · UFW (SSH+TS only)
    GitHub sync timer · Node exporter · Staging project directory
EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)        DEV_USER="$2";      shift 2 ;;
        -p|--project)     PROJECT_NAME="$2";  shift 2 ;;
        --skip-docker)    SKIP_DOCKER=true;   shift ;;
        --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
        --skip-firewall)  SKIP_FIREWALL=true;  shift ;;
        --skip-sync)      SKIP_SYNC=true;      shift ;;
        --no-confirm)     NO_CONFIRM=true;     shift ;;
        -h|--help)        show_help ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Preflight
# =============================================================================
lib_require_root
lib_require_apt
lib_require_user

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Main
# =============================================================================
lib_show_banner "Staging Server Setup — ${PROJECT_NAME}"
lib_detect_system

USER_HOME=$(eval echo "~${DEV_USER}")

log_info "User:    $DEV_USER ($USER_HOME)"
log_info "Project: $PROJECT_NAME"
printf "\n  %-20s %s\n" "Docker:"    "$([ "$SKIP_DOCKER"    = true ] && echo SKIP || echo Install)"
printf "  %-20s %s\n"   "Tailscale:" "$([ "$SKIP_TAILSCALE" = true ] && echo SKIP || echo Install)"
printf "  %-20s %s\n"   "UFW:"       "$([ "$SKIP_FIREWALL"  = true ] && echo SKIP || echo Configure)"
printf "  %-20s %s\n"   "GH Sync:"   "$([ "$SKIP_SYNC"      = true ] && echo SKIP || echo Enable)"
printf "\n"

lib_confirm "Continue?" || { log_info "Cancelled"; exit 0; }

# ── Step 1: System update ────────────────────────────────────────────────────
log_header "Step 1: System Update"
lib_apt_update

# ── Step 2: Core tools ───────────────────────────────────────────────────────
log_header "Step 2: Core Tools"
lib_install_base_packages
lib_setup_git_config

# ── Step 3: Docker ───────────────────────────────────────────────────────────
log_header "Step 3: Docker Engine"
if [ "$SKIP_DOCKER" = true ]; then
    log_skip "Docker skipped"
else
    lib_install_docker
fi

# ── Step 4: Tailscale ────────────────────────────────────────────────────────
log_header "Step 4: Tailscale"
if [ "$SKIP_TAILSCALE" = true ]; then
    log_skip "Tailscale skipped"
elif command -v tailscale >/dev/null 2>&1; then
    log_info "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
else
    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    systemctl enable --now tailscaled
    log_success "Tailscale installed — run: sudo tailscale up"
fi

# ── Step 5: Firewall ─────────────────────────────────────────────────────────
log_header "Step 5: Firewall (UFW)"
if [ "$SKIP_FIREWALL" = true ]; then
    log_skip "UFW skipped"
else
    lib_apt_install ufw

    SSH_PORT="${SSH_PORT:-$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 22)}"
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"     comment "SSH"
    ufw allow in on tailscale0      comment "Tailscale"
    ufw allow 41641/udp             comment "Tailscale UDP"
    ufw --force enable

    log_success "UFW enabled — SSH(${SSH_PORT}) + Tailscale only"
fi

# ── Step 6: Staging project directory ────────────────────────────────────────
log_header "Step 6: Staging Directories"

STAGING_DIR="/opt/${PROJECT_NAME}"
mkdir -p "${STAGING_DIR}"/{app,config,logs,data,tmp}
chown -R "${DEV_USER}:${DEV_USER}" "${STAGING_DIR}"
chmod -R 775 "${STAGING_DIR}"

log_success "Staging root: ${STAGING_DIR}"
lib_setup_directories dev github projects workspace

# ── Step 7: SSH hardening ────────────────────────────────────────────────────
log_header "Step 7: SSH Hardening"
lib_setup_ssh_hardening

# ── Step 8: sysctl (debug-friendly — higher inotify, no strict limits) ───────
log_header "Step 8: System Tuning"
lib_setup_sysctl "staging" \
"# Staging server tuning
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 512
fs.file-max                   = 131072
net.core.somaxconn            = 4096
vm.overcommit_memory          = 1"

# ── Step 9: Node exporter (Prometheus) ───────────────────────────────────────
log_header "Step 9: Node Exporter"
if ! command -v node_exporter >/dev/null 2>&1; then
    log_info "Installing Prometheus node_exporter..."
    NE_VER="1.8.2"
    NE_TAR="node_exporter-${NE_VER}.linux-${ARCH_NORMALIZED}.tar.gz"
    curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/${NE_TAR}" \
        -o "/tmp/${NE_TAR}"
    tar -xzf "/tmp/${NE_TAR}" -C /tmp
    install -m 755 "/tmp/node_exporter-${NE_VER}.linux-${ARCH_NORMALIZED}/node_exporter" \
        /usr/local/bin/node_exporter
    rm -rf "/tmp/${NE_TAR}" "/tmp/node_exporter-${NE_VER}.linux-${ARCH_NORMALIZED}"

    useradd -r -s /bin/false node_exporter 2>/dev/null || true

    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now node_exporter
    log_success "Node exporter running on 127.0.0.1:9100"
else
    log_info "node_exporter already installed"
fi

# ── Step 10: GitHub sync ─────────────────────────────────────────────────────
log_header "Step 10: GitHub Sync"
if [ "$SKIP_SYNC" = true ]; then
    log_skip "GitHub sync skipped"
else
    lib_setup_github_sync
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log_header "Staging Server Ready!"

printf "${BOLD}${GREEN}%s${NC} — %s\n\n" "$PROJECT_NAME" "$HOSTNAME_VAL"
printf "  Staging root:  ${CYAN}%s${NC}\n"  "$STAGING_DIR"
printf "  Node exporter: ${CYAN}http://127.0.0.1:9100/metrics${NC}\n"
[ "$SKIP_TAILSCALE" = false ] && \
    printf "  Tailscale:     ${YELLOW}sudo tailscale up${NC}  (if not yet connected)\n"
printf "\n"

log_success "Staging server configured — happy testing!"
exit 0
