#!/bin/sh
# =============================================================================
# Production Server Setup Script
# Reusable base for CI/CD deployment servers
# Supports x86_64 and ARM64 (including Raspberry Pi)
#
# Access model: Tailscale-only. Services bind to loopback.
# tailscale serve proxies HTTPS → nginx on 127.0.0.1:80.
# Port 80/443 are intentionally NOT opened in UFW.
# =============================================================================
#
# Usage:
#   chmod +x setup-production-server.sh
#   sudo ./setup-production-server.sh [OPTIONS]
#
# Options:
#   -p, --project NAME          Project name (default: myproject)
#   -u, --user NAME             Admin user to add to docker group
#   -a, --actions-user NAME     CI/CD user name (default: actions)
#   -s, --ssh-port PORT         SSH port (default: auto-detect or 22)
#       --serve-port PORT       Port tailscale serve proxies to (default: 80)
#       --skip-docker           Skip Docker installation
#       --skip-tailscale        Skip Tailscale installation
#       --skip-tailscale-serve  Skip tailscale serve setup (keep manual)
#       --skip-nvidia           Skip NVIDIA container toolkit setup
#       --skip-firewall         Skip firewall configuration
#       --skip-secrets          Skip secrets generation
#       --no-confirm            Skip confirmation prompts
#   -h, --help                  Show this help message
#
# =============================================================================

set -e

# =============================================================================
# Default Configuration
# =============================================================================
PROJECT_NAME="myproject"
ADMIN_USER=""
ACTIONS_USER="actions"
SSH_PORT_OVERRIDE=""
TAILSCALE_SERVE_PORT=80     # port tailscale serve will proxy to (nginx)
SKIP_DOCKER=false
SKIP_TAILSCALE=false
SKIP_TAILSCALE_SERVE=false
SKIP_NVIDIA=false
SKIP_FIREWALL=false
SKIP_SECRETS=false
NO_CONFIRM=false
NEEDS_REBOOT=false

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
Production Server Setup Script
==============================

Reusable script for CI/CD deployment servers.
Access model: Tailscale-only. No public ports 80/443.
tailscale serve proxies HTTPS to nginx on loopback.

USAGE:
    sudo ./setup-production-server.sh [OPTIONS]

OPTIONS:
    -p, --project NAME          Project name for directories and credentials
    -u, --user NAME             Admin user to add to docker group
    -a, --actions-user NAME     CI/CD deployment user (default: actions)
    -s, --ssh-port PORT         SSH port (default: auto-detect or 22)
        --serve-port PORT       Port tailscale serve proxies to (default: 80)
        --skip-docker           Skip Docker installation
        --skip-tailscale        Skip Tailscale installation
        --skip-tailscale-serve  Skip tailscale serve setup
        --skip-nvidia           Skip NVIDIA container toolkit
        --skip-firewall         Skip firewall (UFW) configuration
        --skip-secrets          Skip SSH key and secrets generation
        --no-confirm            Non-interactive mode
    -h, --help                  Show this help message

EXAMPLES:
    # FKS on Oryx (full setup)
    sudo ./setup-production-server.sh -p fks -u jordan --no-confirm

    # Skip NVIDIA (no GPU on this host)
    sudo ./setup-production-server.sh -p fks -u jordan --skip-nvidia

    # CI/CD re-run (idempotent — safe to re-run)
    sudo ./setup-production-server.sh -p fks --skip-secrets --no-confirm

WHAT THIS DOES:
    1.  System update + core packages
    2.  Docker Engine + Compose + BuildKit
    3.  NVIDIA Container Toolkit (optional, auto-detected)
    4.  CI/CD user + project directory
    5.  SSH configuration
    6.  UFW firewall (SSH + tailscale only — NO public 80/443)
    7.  Tailscale install
    8.  tailscale serve (HTTPS → loopback nginx)
    9.  System optimizations (sysctl, log rotation)
    10. Generate SSH keys + application secrets

EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project)          PROJECT_NAME="$2";         shift 2 ;;
        -u|--user)             ADMIN_USER="$2";            shift 2 ;;
        -a|--actions-user)     ACTIONS_USER="$2";          shift 2 ;;
        -s|--ssh-port)         SSH_PORT_OVERRIDE="$2";     shift 2 ;;
        --serve-port)          TAILSCALE_SERVE_PORT="$2";  shift 2 ;;
        --skip-docker)         SKIP_DOCKER=true;           shift ;;
        --skip-tailscale)      SKIP_TAILSCALE=true;        shift ;;
        --skip-tailscale-serve) SKIP_TAILSCALE_SERVE=true; shift ;;
        --skip-nvidia)         SKIP_NVIDIA=true;           shift ;;
        --skip-firewall)       SKIP_FIREWALL=true;         shift ;;
        --skip-secrets)        SKIP_SECRETS=true;          shift ;;
        --no-confirm)          NO_CONFIRM=true;            shift ;;
        -h|--help)             show_help ;;
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
generate_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-24
}

generate_hex_secret() {
    local length="${1:-32}"
    openssl rand -hex "$length"
}

generate_base64_secret() {
    local length="${1:-32}"
    openssl rand -base64 "$length" | tr -d "=+/" | head -c "$length"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1;  then echo "apt"
    elif command -v dnf >/dev/null 2>&1;    then echo "dnf"
    elif command -v yum >/dev/null 2>&1;    then echo "yum"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v apk >/dev/null 2>&1;    then echo "apk"
    else echo "unknown"
    fi
}

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

# =============================================================================
# Pre-flight
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script with sudo"
    exit 1
fi

if [ "$SKIP_SECRETS" = false ] && ! command -v openssl >/dev/null 2>&1; then
    log_warn "OpenSSL not found — will be installed with system packages"
fi

# =============================================================================
# System Detection
# =============================================================================
log_header "Production Server Setup"
log_subheader "System Detection"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_NORMALIZED="amd64" ;;
    aarch64|arm64) ARCH_NORMALIZED="arm64" ;;
    armv7l|armhf)  ARCH_NORMALIZED="armv7" ;;
    *)             ARCH_NORMALIZED="$ARCH"  ;;
esac
log_info "Architecture: $ARCH ($ARCH_NORMALIZED)"

IS_PI=false
PI_MODEL=""
if [ -f /proc/device-tree/model ]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    if echo "$PI_MODEL" | grep -qi "raspberry"; then
        IS_PI=true
        log_success "Raspberry Pi detected: $PI_MODEL"
    fi
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_VERSION="${VERSION_ID:-Unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_ID="${ID:-unknown}"
    log_info "OS: $OS_NAME $OS_VERSION ${OS_CODENAME:+(${OS_CODENAME})}"
else
    log_warn "Cannot detect OS version"
    OS_NAME="Unknown"; OS_VERSION="Unknown"; OS_ID="unknown"; OS_CODENAME=""
fi

# NVIDIA GPU detection
HAS_NVIDIA=false
if lspci 2>/dev/null | grep -qi nvidia || ls /dev/nvidia* >/dev/null 2>&1; then
    HAS_NVIDIA=true
    log_success "NVIDIA GPU detected"
    # Auto-enable nvidia setup unless explicitly skipped
else
    log_info "No NVIDIA GPU detected — skipping NVIDIA toolkit"
    SKIP_NVIDIA=true
fi

PKG_MANAGER=$(detect_package_manager)
log_info "Package manager: $PKG_MANAGER"

HOSTNAME_VAL=$(hostname 2>/dev/null || echo "server")
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
log_info "Hostname: $HOSTNAME_VAL | IP: $SERVER_IP"

if [ -n "$SSH_PORT_OVERRIDE" ]; then
    SSH_PORT="$SSH_PORT_OVERRIDE"
else
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$SSH_PORT" ] && SSH_PORT=22
fi
log_info "SSH port: $SSH_PORT"

# Summary
printf "\n${BOLD}Configuration:${NC}\n"
printf "  Project:            ${CYAN}%s${NC}\n" "$PROJECT_NAME"
printf "  CI/CD User:         ${CYAN}%s${NC}\n" "$ACTIONS_USER"
[ -n "$ADMIN_USER" ] && printf "  Admin User:         ${CYAN}%s${NC}\n" "$ADMIN_USER"
printf "\n${BOLD}Components:${NC}\n"
printf "  Docker + BuildKit:  %s\n" "$([ "$SKIP_DOCKER"          = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "  NVIDIA Toolkit:     %s\n" "$([ "$SKIP_NVIDIA"          = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "  Tailscale:          %s\n" "$([ "$SKIP_TAILSCALE"       = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Install${NC}")"
printf "  Tailscale Serve:    %s\n" "$([ "$SKIP_TAILSCALE_SERVE" = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}HTTPS → 127.0.0.1:${TAILSCALE_SERVE_PORT}${NC}")"
printf "  Firewall (UFW):     %s\n" "$([ "$SKIP_FIREWALL"        = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}SSH + tailscale only${NC}")"
printf "  Secrets:            %s\n" "$([ "$SKIP_SECRETS"         = true ] && printf "${YELLOW}SKIP${NC}" || printf "${GREEN}Generate${NC}")"
printf "\n"

[ "$IS_PI" = true ] && printf "${GREEN}✓${NC} Raspberry Pi optimizations will be applied\n"

confirm "Continue with setup?" || { log_info "Setup cancelled"; exit 0; }

# =============================================================================
# Step 1: System Update
# =============================================================================
log_header "Step 1: System Update"

case "$PKG_MANAGER" in
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get upgrade -y
        apt-get install -y \
            curl wget git ca-certificates gnupg lsb-release \
            ufw htop vim openssh-server openssl jq unzip
        ;;
    dnf)
        dnf update -y
        dnf install -y \
            curl wget git ca-certificates gnupg \
            ufw htop vim openssh-server openssl jq unzip
        ;;
    yum)
        yum update -y
        yum install -y \
            curl wget git ca-certificates gnupg \
            ufw htop vim openssh-server openssl jq unzip
        ;;
    pacman)
        pacman -Syu --noconfirm
        pacman -S --noconfirm --needed \
            curl wget git ca-certificates gnupg \
            ufw htop vim openssh openssl jq unzip
        ;;
    apk)
        apk update && apk upgrade
        apk add curl wget git ca-certificates gnupg \
            ufw htop vim openssh openssl jq unzip
        ;;
    *)
        log_error "Unsupported package manager: $PKG_MANAGER"
        confirm "Continue anyway?" || exit 1
        ;;
esac

log_success "System updated"

# =============================================================================
# Step 2: Docker Engine + BuildKit
# =============================================================================
log_header "Step 2: Docker Engine"

if [ "$SKIP_DOCKER" = true ]; then
    log_skip "Docker installation skipped"
else
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker already installed: $(docker --version)"
    else
        log_info "Installing Docker (official install script)..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        log_success "Docker installed: $(docker --version)"
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start  docker 2>/dev/null || true

    # Docker Compose plugin
    if ! docker compose version >/dev/null 2>&1; then
        log_info "Installing Docker Compose plugin..."
        case "$PKG_MANAGER" in
            apt)    apt-get install -y docker-compose-plugin 2>/dev/null || true ;;
            dnf|yum) dnf install -y docker-compose-plugin 2>/dev/null || true ;;
            pacman) pacman -S --noconfirm docker-compose 2>/dev/null || true ;;
        esac
    fi
    docker compose version >/dev/null 2>&1 && \
        log_success "Docker Compose: $(docker compose version | head -1)" || \
        log_warn "Docker Compose not available — install manually"

    # ARM / Raspberry Pi: enable cgroup memory
    if [ "$IS_PI" = true ] || [ "$ARCH_NORMALIZED" = "arm64" ]; then
        log_subheader "ARM/Pi Optimizations"
        CMDLINE_FILE=""
        [ -f /boot/firmware/cmdline.txt ] && CMDLINE_FILE="/boot/firmware/cmdline.txt"
        [ -z "$CMDLINE_FILE" ] && [ -f /boot/cmdline.txt ] && CMDLINE_FILE="/boot/cmdline.txt"
        if [ -n "$CMDLINE_FILE" ]; then
            if ! grep -q "cgroup_memory=1 cgroup_enable=memory" "$CMDLINE_FILE" 2>/dev/null; then
                cp "$CMDLINE_FILE" "${CMDLINE_FILE}.backup"
                sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_FILE"
                log_warn "REBOOT REQUIRED for cgroup changes"
                NEEDS_REBOOT=true
            else
                log_info "cgroup memory already enabled"
            fi
        fi
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$TOTAL_MEM" -lt 2048 ] && [ -f /etc/dphys-swapfile ]; then
            CURRENT_SWAP=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
            if [ "${CURRENT_SWAP:-0}" -lt 2048 ]; then
                sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
                systemctl restart dphys-swapfile 2>/dev/null || true
                log_success "Swap increased to 2GB"
            fi
        fi
    fi

    # Docker daemon — enable BuildKit + log rotation
    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
    mkdir -p /etc/docker
    if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
        log_info "Writing Docker daemon config (BuildKit + log rotation)..."
        cat > "$DOCKER_DAEMON_CONFIG" <<'DOCKEREOF'
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
DOCKEREOF
        systemctl restart docker 2>/dev/null || true
        log_success "Docker daemon configured"
    else
        # Ensure BuildKit is enabled in existing config
        if ! grep -q '"buildkit"' "$DOCKER_DAEMON_CONFIG" 2>/dev/null; then
            log_info "Patching BuildKit into existing daemon.json..."
            python3 - <<'PYEOF'
import json
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.setdefault("features", {})["buildkit"] = True
cfg.setdefault("log-driver", "json-file")
cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("daemon.json updated")
PYEOF
            systemctl restart docker 2>/dev/null || true
            log_success "BuildKit enabled in daemon.json"
        else
            log_info "Docker daemon already configured"
        fi
    fi
fi

# =============================================================================
# Step 3: NVIDIA Container Toolkit
#
# Only runs if an NVIDIA GPU is detected AND --skip-nvidia is not set.
# Configures Docker's default runtime to nvidia so `docker run --gpus all`
# works without extra flags — required for the fks_trainer service.
# =============================================================================
log_header "Step 3: NVIDIA Container Toolkit"

if [ "$SKIP_NVIDIA" = true ]; then
    log_skip "NVIDIA toolkit skipped"
else
    if command -v nvidia-container-toolkit >/dev/null 2>&1 || \
       dpkg -l nvidia-container-toolkit >/dev/null 2>&1; then
        log_info "nvidia-container-toolkit already installed"
    else
        log_info "Installing NVIDIA Container Toolkit..."

        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list

        apt-get update
        apt-get install -y nvidia-container-toolkit
        log_success "nvidia-container-toolkit installed"
    fi

    log_info "Configuring NVIDIA Docker runtime..."
    nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true

    # Ensure nvidia runtime + default-runtime in daemon.json
    python3 - <<'PYEOF'
import json
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.setdefault("features", {})["buildkit"] = True
cfg.setdefault("log-driver", "json-file")
cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})
cfg["default-runtime"] = "nvidia"
cfg.setdefault("runtimes", {})["nvidia"] = {
    "path": "nvidia-container-runtime",
    "runtimeArgs": []
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("daemon.json updated with nvidia runtime")
PYEOF

    systemctl restart docker 2>/dev/null || true
    log_success "NVIDIA runtime configured as Docker default"

    log_info "Smoke test (nvidia-smi in container)..."
    if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi 2>/dev/null; then
        log_success "CUDA container test passed"
    else
        log_warn "Smoke test failed — expected if drivers not yet installed"
        log_warn "Install drivers: sudo ubuntu-drivers install"
        log_warn "Re-test: docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
    fi
fi

# =============================================================================
# Step 4: Create CI/CD User
# =============================================================================
log_header "Step 4: CI/CD User"

ACTIONS_HOME="/home/$ACTIONS_USER"

if id "$ACTIONS_USER" >/dev/null 2>&1; then
    log_warn "User '$ACTIONS_USER' already exists"
else
    useradd -m -s /bin/bash -c "CI/CD Deployment User" "$ACTIONS_USER"
    log_success "User '$ACTIONS_USER' created"
fi

if [ "$SKIP_DOCKER" = false ] && command -v docker >/dev/null 2>&1; then
    usermod -aG docker "$ACTIONS_USER"
    log_success "User '$ACTIONS_USER' added to docker group"
fi

if [ -n "$ADMIN_USER" ] && id "$ADMIN_USER" >/dev/null 2>&1; then
    [ "$SKIP_DOCKER" = false ] && usermod -aG docker "$ADMIN_USER"
    log_success "User '$ADMIN_USER' added to docker group"
fi

mkdir -p "$ACTIONS_HOME"
chown "$ACTIONS_USER:$ACTIONS_USER" "$ACTIONS_HOME"
chmod 755 "$ACTIONS_HOME"

PROJECT_DIR="$ACTIONS_HOME/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR"
chown "$ACTIONS_USER:$ACTIONS_USER" "$PROJECT_DIR"
log_success "Project directory: $PROJECT_DIR"

# =============================================================================
# Step 5: SSH Configuration
# =============================================================================
log_header "Step 5: SSH Configuration"

SSH_DIR="$ACTIONS_HOME/.ssh"
mkdir -p "$SSH_DIR"
chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$SSH_DIR/authorized_keys" ]; then
    touch "$SSH_DIR/authorized_keys"
    chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    log_success "authorized_keys created"
fi

systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl start  ssh 2>/dev/null || systemctl start  sshd 2>/dev/null || true
log_success "SSH service enabled on port $SSH_PORT"

# =============================================================================
# Step 6: Firewall (UFW)
#
# Access model: SSH + Tailscale interface only.
# Ports 80 and 443 are intentionally NOT opened here.
# HTTPS access is provided by `tailscale serve` (Step 8),
# which terminates TLS on the Tailscale interface and proxies
# to nginx on 127.0.0.1:TAILSCALE_SERVE_PORT.
# =============================================================================
log_header "Step 6: Firewall (UFW)"

if [ "$SKIP_FIREWALL" = true ]; then
    log_skip "Firewall configuration skipped"
else
    if command -v ufw >/dev/null 2>&1; then
        log_info "Configuring UFW..."

        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1

        # SSH — the only public port
        ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null 2>&1
        log_info "Allowed: SSH port $SSH_PORT"

        # Tailscale interface — allows all traffic from tailnet peers
        if [ "$SKIP_TAILSCALE" = false ]; then
            ufw allow in on tailscale0 >/dev/null 2>&1
            log_info "Allowed: tailscale0 interface (all tailnet traffic)"
        fi

        # NOTE: Ports 80 and 443 are deliberately NOT opened.
        # External HTTPS access is provided by `tailscale serve` only.
        # This keeps all web traffic inside the Tailscale WireGuard tunnel.
        log_info "Note: ports 80/443 intentionally closed — HTTPS via tailscale serve only"

        ufw --force enable >/dev/null 2>&1
        log_success "Firewall enabled (SSH + tailscale only)"
        ufw status verbose 2>/dev/null | grep -E "Status|80|443|$SSH_PORT|tailscale" || true
    else
        log_warn "UFW not available — configure firewall manually"
    fi
fi

# =============================================================================
# Step 7: Tailscale
# =============================================================================
log_header "Step 7: Tailscale"

TAILSCALE_IP=""

if [ "$SKIP_TAILSCALE" = true ]; then
    log_skip "Tailscale installation skipped"
else
    if command -v tailscale >/dev/null 2>&1; then
        log_info "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
    else
        log_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale installed"
    fi

    # Get current Tailscale IP if already connected
    if tailscale status >/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
        if [ -n "$TAILSCALE_IP" ]; then
            log_success "Tailscale connected: $TAILSCALE_IP"
        else
            log_warn "Tailscale installed but not connected — run: sudo tailscale up"
        fi
    else
        log_warn "Tailscale not connected — run: sudo tailscale up"
    fi
fi

# =============================================================================
# Step 8: tailscale serve
#
# Routes HTTPS traffic from the Tailscale network to nginx on loopback.
# This is the ONLY way to reach the web dashboard — no public port needed.
#
# Result: https://<hostname>.<tailnet>.ts.net -> http://127.0.0.1:SERVE_PORT
#
# Idempotent: checks if already configured before setting up.
# Safe to re-run on every CI/CD deploy.
# =============================================================================
log_header "Step 8: Tailscale Serve (HTTPS → loopback)"

if [ "$SKIP_TAILSCALE" = true ] || [ "$SKIP_TAILSCALE_SERVE" = true ]; then
    log_skip "tailscale serve skipped"
else
    if ! command -v tailscale >/dev/null 2>&1; then
        log_warn "tailscale not installed — skipping serve setup"
    else
        SERVE_TARGET="http://127.0.0.1:${TAILSCALE_SERVE_PORT}"

        # Check if already configured (idempotent guard)
        if tailscale serve status 2>/dev/null | grep -q "127.0.0.1:${TAILSCALE_SERVE_PORT}"; then
            log_info "tailscale serve already configured for ${SERVE_TARGET}"
        else
            log_info "Configuring tailscale serve: HTTPS → ${SERVE_TARGET}..."
            tailscale serve --bg "$SERVE_TARGET"
            log_success "tailscale serve configured"
        fi

        # Show status
        TS_SERVE_URL=$(tailscale serve status 2>/dev/null | grep "https://" | awk '{print $1}' | head -1 || echo "")
        if [ -n "$TS_SERVE_URL" ]; then
            log_success "Accessible at: ${TS_SERVE_URL} (tailnet only)"
        else
            log_warn "Could not determine tailscale serve URL — check: tailscale serve status"
        fi

        log_info "To verify: tailscale serve status"
    fi
fi

# =============================================================================
# Step 9: System Optimizations
# =============================================================================
log_header "Step 9: System Optimizations"

SYSCTL_CONF="/etc/sysctl.d/99-production.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    log_info "Writing sysctl optimizations..."
    cat > "$SYSCTL_CONF" <<'EOF'
# Production server optimizations
fs.file-max                   = 65536
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 256
net.core.somaxconn            = 65535
EOF
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    log_success "sysctl optimizations applied"
else
    log_info "sysctl already configured"
fi

# Log rotation for application logs
if ! [ -f "/etc/logrotate.d/${PROJECT_NAME}" ]; then
    cat > "/etc/logrotate.d/${PROJECT_NAME}" <<EOF
$PROJECT_DIR/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    log_success "Log rotation configured for $PROJECT_NAME"
fi

if command -v timedatectl >/dev/null 2>&1; then
    log_info "Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'unknown')"
fi

# =============================================================================
# Step 10: Generate Secrets
# =============================================================================
log_header "Step 10: Secrets Generation"

if [ "$SKIP_SECRETS" = true ]; then
    log_skip "Secrets generation skipped"
else
    log_subheader "SSH Keys"

    REGENERATE_KEY=false
    if [ -f "$SSH_DIR/id_ed25519" ]; then
        log_warn "SSH key already exists"
        if confirm_no "Regenerate SSH key? (invalidates current GitHub secret)"; then
            REGENERATE_KEY=true
            rm -f "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub"
        else
            log_info "Using existing SSH key"
        fi
    fi

    if [ ! -f "$SSH_DIR/id_ed25519" ]; then
        log_info "Generating Ed25519 SSH key..."
        sudo -u "$ACTIONS_USER" ssh-keygen \
            -t ed25519 \
            -f "$SSH_DIR/id_ed25519" \
            -N "" \
            -C "${ACTIONS_USER}@${HOSTNAME_VAL}-$(date +%Y%m%d)"
        chmod 600 "$SSH_DIR/id_ed25519"
        chmod 644 "$SSH_DIR/id_ed25519.pub"
        log_success "SSH key generated"
    fi

    # Self-authorize (CI/CD SSHes in as this user)
    PUB_KEY=$(cat "$SSH_DIR/id_ed25519.pub")
    if ! grep -qF "$PUB_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
        chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR/authorized_keys"
        log_success "Public key added to authorized_keys"
    fi

    log_subheader "Application Secrets"

    API_KEY=$(generate_base64_secret 32)
    JWT_SECRET=$(generate_hex_secret 64)
    ENCRYPTION_KEY=$(generate_hex_secret 32)
    SESSION_SECRET=$(generate_hex_secret 32)
    ADMIN_PASSWORD=$(generate_password)
    DB_PASSWORD=$(generate_password)
    REDIS_PASSWORD=$(generate_password)
    POSTGRES_PASSWORD=$(generate_password)

    log_success "Application secrets generated"

    SSH_PRIVATE_KEY=$(cat "$SSH_DIR/id_ed25519")
    SSH_PUBLIC_KEY=$(cat "$SSH_DIR/id_ed25519.pub")

    # Re-check Tailscale IP in case it connected during setup
    if [ -z "$TAILSCALE_IP" ] && command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    fi

    # Tailscale serve URL
    TS_URL=$(tailscale serve status 2>/dev/null | grep "https://" | awk '{print $1}' | head -1 || echo "")

    log_subheader "Saving Credentials"

    CREDENTIALS_FILE="/root/${PROJECT_NAME}_credentials_$(date +%Y%m%d_%H%M%S).txt"
    touch "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    cat > "$CREDENTIALS_FILE" <<EOF
################################################################################
#                         Server Credentials
#                         Project: $PROJECT_NAME
################################################################################
#
# Generated:    $(date)
# Hostname:     $HOSTNAME_VAL
# Server IP:    $SERVER_IP
# Tailscale IP: ${TAILSCALE_IP:-Not connected yet}
# Tailscale URL:${TS_URL:-Run: tailscale serve status}
# SSH Port:     $SSH_PORT
# Arch:         $ARCH ($ARCH_NORMALIZED)
# OS:           $OS_NAME $OS_VERSION
#
# Access model: Tailscale-only. No public ports 80/443.
# HTTPS via tailscale serve → 127.0.0.1:${TAILSCALE_SERVE_PORT}
#
################################################################################

================================================================================
GITHUB ACTIONS SECRETS (REQUIRED)
================================================================================
Go to: https://github.com/YOUR_USERNAME/$PROJECT_NAME/settings/secrets/actions

SECRET NAME                  VALUE
---------------------------  --------------------------------------------------
PROD_TAILSCALE_IP            ${TAILSCALE_IP:-CONNECT_TAILSCALE_FIRST}
PROD_SSH_PORT                $SSH_PORT
PROD_SSH_USER                $ACTIONS_USER
PROD_SSH_KEY                 (see SSH PRIVATE KEY section below)

DOCKER_USERNAME              (your Docker Hub username)
DOCKER_TOKEN                 (your Docker Hub access token)

TAILSCALE_OAUTH_CLIENT_ID    (from Tailscale Admin Console → OAuth clients)
TAILSCALE_OAUTH_SECRET       (from Tailscale Admin Console → OAuth clients)

================================================================================
GITHUB ACTIONS SECRETS (OPTIONAL)
================================================================================
DISCORD_WEBHOOK              (Discord webhook for deploy notifications)

================================================================================
SSH PRIVATE KEY  →  PROD_SSH_KEY
================================================================================
Copy the ENTIRE block below including the BEGIN and END lines:

$SSH_PRIVATE_KEY

================================================================================
SSH PUBLIC KEY
================================================================================
$SSH_PUBLIC_KEY

================================================================================
APPLICATION SECRETS  →  .env file
================================================================================

# API & Auth
API_KEY=$API_KEY
JWT_SECRET=$JWT_SECRET
SESSION_SECRET=$SESSION_SECRET

# Encryption
ENCRYPTION_KEY=$ENCRYPTION_KEY

# Admin
ADMIN_PASSWORD=$ADMIN_PASSWORD

# Databases
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
DB_PASSWORD=$DB_PASSWORD

================================================================================
TAILSCALE SERVE
================================================================================
Status:   tailscale serve status
URL:      ${TS_URL:-run: tailscale serve status}
Reset:    tailscale serve reset

Re-configure (idempotent, safe in CI/CD):
  tailscale serve status | grep -q '127.0.0.1:${TAILSCALE_SERVE_PORT}' \\
    || tailscale serve --bg http://127.0.0.1:${TAILSCALE_SERVE_PORT}

================================================================================
QUICK REFERENCE
================================================================================

# View this file
cat $CREDENTIALS_FILE

# Check Tailscale
tailscale status
tailscale ip -4

# SSH test (from another tailnet machine)
ssh -p $SSH_PORT $ACTIONS_USER@${TAILSCALE_IP:-TAILSCALE_IP}

# Docker
docker info | grep -E "Architecture|Server Version|Default Runtime"

# Check serve
tailscale serve status

# DELETE WHEN DONE
sudo rm $CREDENTIALS_FILE

################################################################################
EOF

    log_success "Credentials saved: $CREDENTIALS_FILE"
fi

# =============================================================================
# Final Summary
# =============================================================================
log_header "Setup Complete!"

printf "${BOLD}${GREEN}Server:${NC}\n"
printf "  Project:        ${CYAN}%s${NC}\n"  "$PROJECT_NAME"
printf "  Hostname:       ${CYAN}%s${NC}\n"  "$HOSTNAME_VAL"
printf "  Server IP:      ${CYAN}%s${NC}\n"  "$SERVER_IP"
printf "  Tailscale IP:   ${CYAN}%s${NC}\n"  "${TAILSCALE_IP:-not connected}"
printf "  SSH Port:       ${CYAN}%s${NC}\n"  "$SSH_PORT"
printf "  Arch:           ${CYAN}%s (%s)${NC}\n" "$ARCH" "$ARCH_NORMALIZED"
printf "  OS:             ${CYAN}%s %s${NC}\n" "$OS_NAME" "$OS_VERSION"
printf "  CI/CD User:     ${CYAN}%s${NC}\n"  "$ACTIONS_USER"
printf "  Project Dir:    ${CYAN}%s${NC}\n"  "$PROJECT_DIR"
printf "\n"

printf "${BOLD}Access:${NC}\n"
printf "  SSH:            ${CYAN}ssh -p %s %s@%s${NC}\n" "$SSH_PORT" "$ACTIONS_USER" "${TAILSCALE_IP:-<tailscale_ip>}"
TS_URL_FINAL=$(tailscale serve status 2>/dev/null | grep "https://" | awk '{print $1}' | head -1 || echo "")
if [ -n "$TS_URL_FINAL" ]; then
    printf "  HTTPS:          ${CYAN}%s${NC} (tailnet only)\n" "$TS_URL_FINAL"
else
    printf "  HTTPS:          ${YELLOW}Run tailscale up, then: tailscale serve --bg http://127.0.0.1:%s${NC}\n" "$TAILSCALE_SERVE_PORT"
fi
printf "\n"

[ "$IS_PI" = true ] && printf "${MAGENTA}Raspberry Pi:${NC} ARM64 optimizations applied\n\n"
[ "$NEEDS_REBOOT" = true ] && printf "${RED}⚠  REBOOT REQUIRED${NC} — run: ${CYAN}sudo reboot${NC}\n\n"

printf "${BOLD}${YELLOW}Next Steps:${NC}\n"
N=1

if [ "$SKIP_TAILSCALE" = false ] && [ -z "$TAILSCALE_IP" ]; then
    printf "  ${GREEN}%d.${NC} Connect Tailscale: ${CYAN}sudo tailscale up${NC}\n" "$N"
    N=$((N+1))
    printf "  ${GREEN}%d.${NC} Re-run serve setup: ${CYAN}tailscale serve --bg http://127.0.0.1:%s${NC}\n" "$N" "$TAILSCALE_SERVE_PORT"
    N=$((N+1))
fi

if [ "$SKIP_SECRETS" = false ]; then
    printf "  ${GREEN}%d.${NC} Copy credentials: ${CYAN}cat %s${NC}\n" "$N" "$CREDENTIALS_FILE"
    N=$((N+1))
    printf "  ${GREEN}%d.${NC} Add GitHub secrets: ${CYAN}https://github.com/YOUR_USERNAME/%s/settings/secrets/actions${NC}\n" "$N" "$PROJECT_NAME"
    N=$((N+1))
    printf "  ${GREEN}%d.${NC} Delete credentials: ${CYAN}sudo rm %s${NC}\n" "$N" "$CREDENTIALS_FILE"
    N=$((N+1))
fi

[ "$NEEDS_REBOOT" = true ] && printf "  ${GREEN}%d.${NC} ${RED}Reboot:${NC} ${CYAN}sudo reboot${NC}\n" "$N"

printf "\n"
log_success "Server is ready for deployments!"
printf "\n"

exit 0
