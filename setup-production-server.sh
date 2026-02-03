#!/bin/sh
# =============================================================================
# Production Server Setup Script
# A reusable base script for setting up CI/CD deployment servers
# Supports x86_64 and ARM64 architectures (including Raspberry Pi)
# =============================================================================
#
# Usage:
#   chmod +x setup-production-server.sh
#   sudo ./setup-production-server.sh [OPTIONS]
#
# Options:
#   -p, --project NAME      Project name (default: myproject)
#   -u, --user NAME         Admin user to add to docker group (default: none)
#   -a, --actions-user NAME CI/CD user name (default: actions)
#   -s, --ssh-port PORT     SSH port (default: auto-detect or 22)
#   --skip-docker           Skip Docker installation
#   --skip-tailscale        Skip Tailscale installation
#   --skip-firewall         Skip firewall configuration
#   --skip-secrets          Skip secrets generation
#   --no-confirm            Skip confirmation prompts
#   -h, --help              Show this help message
#
# Examples:
#   sudo ./setup-production-server.sh -p myapp -u jordan
#   sudo ./setup-production-server.sh --project api-server --user admin --no-confirm
#   sudo ./setup-production-server.sh -p webapp --skip-tailscale
#
# =============================================================================

set -e

# =============================================================================
# Default Configuration (override with command-line arguments)
# =============================================================================
PROJECT_NAME="myproject"
ADMIN_USER=""
ACTIONS_USER="actions"
SSH_PORT_OVERRIDE=""
SKIP_DOCKER=false
SKIP_TAILSCALE=false
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

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
log_step() { printf "${MAGENTA}[STEP]${NC} ${BOLD}%s${NC}\n" "$*"; }
log_skip() { printf "${YELLOW}[SKIP]${NC} %s\n" "$*"; }

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
# Help Function
# =============================================================================
show_help() {
    cat << 'EOF'
Production Server Setup Script
==============================

A reusable script for setting up CI/CD deployment servers.
Supports x86_64 and ARM64 architectures (including Raspberry Pi).

USAGE:
    sudo ./setup-production-server.sh [OPTIONS]

OPTIONS:
    -p, --project NAME      Project name for directories and credentials
                            (default: myproject)

    -u, --user NAME         Admin user to add to docker group
                            (default: none)

    -a, --actions-user NAME CI/CD deployment user name
                            (default: actions)

    -s, --ssh-port PORT     SSH port override
                            (default: auto-detect from sshd_config or 22)

    --skip-docker           Skip Docker installation

    --skip-tailscale        Skip Tailscale installation

    --skip-firewall         Skip firewall (UFW) configuration

    --skip-secrets          Skip SSH key and secrets generation

    --no-confirm            Skip all confirmation prompts (for automation)

    -h, --help              Show this help message

EXAMPLES:
    # Basic setup with project name and admin user
    sudo ./setup-production-server.sh -p myapp -u jordan

    # Automated setup (no prompts)
    sudo ./setup-production-server.sh -p api-server -u admin --no-confirm

    # Skip Tailscale if using different VPN
    sudo ./setup-production-server.sh -p webapp --skip-tailscale

    # Minimal setup (Docker only)
    sudo ./setup-production-server.sh -p myproject --skip-tailscale --skip-firewall

WHAT THIS SCRIPT DOES:
    1. Detects system architecture (x86_64, ARM64, Raspberry Pi)
    2. Updates system packages
    3. Installs Docker and Docker Compose
    4. Creates CI/CD user with Docker permissions
    5. Configures SSH for deployments
    6. Sets up UFW firewall
    7. Installs Tailscale VPN
    8. Applies system optimizations
    9. Generates SSH keys and application secrets
    10. Outputs credentials file for GitHub Actions

SUPPORTED SYSTEMS:
    - Ubuntu / Debian
    - Raspberry Pi OS
    - Fedora / RHEL / CentOS
    - Arch Linux
    - Alpine Linux
    - x86_64 and ARM64 architectures

EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -u|--user)
            ADMIN_USER="$2"
            shift 2
            ;;
        -a|--actions-user)
            ACTIONS_USER="$2"
            shift 2
            ;;
        -s|--ssh-port)
            SSH_PORT_OVERRIDE="$2"
            shift 2
            ;;
        --skip-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --skip-tailscale)
            SKIP_TAILSCALE=true
            shift
            ;;
        --skip-firewall)
            SKIP_FIREWALL=true
            shift
            ;;
        --skip-secrets)
            SKIP_SECRETS=true
            shift
            ;;
        --no-confirm)
            NO_CONFIRM=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helper Functions
# =============================================================================

# Generate secure password (alphanumeric)
generate_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-24
}

# Generate hex secret (for API keys, encryption keys)
generate_hex_secret() {
    local length="${1:-32}"
    openssl rand -hex "$length"
}

# Generate base64 secret
generate_base64_secret() {
    local length="${1:-32}"
    openssl rand -base64 "$length" | tr -d "=+/" | head -c "$length"
}

# Detect package manager
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# Confirm prompt (skipped with --no-confirm)
confirm() {
    if [ "$NO_CONFIRM" = true ]; then
        return 0
    fi
    printf "%s (Y/n) " "$1"
    read -r reply
    case "$reply" in
        n|N|no|No|NO)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Confirm prompt (default no)
confirm_no() {
    if [ "$NO_CONFIRM" = true ]; then
        return 1
    fi
    printf "%s (y/N) " "$1"
    read -r reply
    case "$reply" in
        y|Y|yes|Yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script with sudo"
    exit 1
fi

# Check for openssl (needed for secrets)
if [ "$SKIP_SECRETS" = false ] && ! command -v openssl >/dev/null 2>&1; then
    log_warn "OpenSSL not found - will be installed with system packages"
fi

# =============================================================================
# System Detection
# =============================================================================
log_header "Production Server Setup"

log_subheader "System Detection"

# Detect architecture
ARCH=$(uname -m)
ARCH_NORMALIZED=""
case "$ARCH" in
    x86_64|amd64)
        ARCH_NORMALIZED="amd64"
        ;;
    aarch64|arm64)
        ARCH_NORMALIZED="arm64"
        ;;
    armv7l|armhf)
        ARCH_NORMALIZED="armv7"
        ;;
    *)
        ARCH_NORMALIZED="$ARCH"
        ;;
esac

log_info "Architecture: $ARCH ($ARCH_NORMALIZED)"

# Detect if Raspberry Pi
IS_PI=false
PI_MODEL=""
if [ -f /proc/device-tree/model ]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    if echo "$PI_MODEL" | grep -qi "raspberry"; then
        IS_PI=true
        log_success "Raspberry Pi detected: $PI_MODEL"
    fi
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_VERSION="${VERSION_ID:-Unknown}"
    OS_ID="${ID:-unknown}"
    log_info "Operating System: $OS_NAME $OS_VERSION"
else
    log_warn "Cannot detect OS version"
    OS_NAME="Unknown"
    OS_VERSION="Unknown"
    OS_ID="unknown"
fi

# Detect package manager
PKG_MANAGER=$(detect_package_manager)
log_info "Package Manager: $PKG_MANAGER"

# Get hostname
HOSTNAME=$(hostname 2>/dev/null || echo "server")
log_info "Hostname: $HOSTNAME"

# Get server IP
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
log_info "Server IP: $SERVER_IP"

# Detect SSH port
if [ -n "$SSH_PORT_OVERRIDE" ]; then
    SSH_PORT="$SSH_PORT_OVERRIDE"
else
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=22
    fi
fi
log_info "SSH Port: $SSH_PORT"

# Show configuration
printf "\n"
printf "${BOLD}Configuration:${NC}\n"
printf "  Project Name:  ${CYAN}%s${NC}\n" "$PROJECT_NAME"
printf "  CI/CD User:    ${CYAN}%s${NC}\n" "$ACTIONS_USER"
if [ -n "$ADMIN_USER" ]; then
    printf "  Admin User:    ${CYAN}%s${NC}\n" "$ADMIN_USER"
fi
printf "\n"

# Show what will be installed
printf "${BOLD}Components:${NC}\n"
if [ "$SKIP_DOCKER" = true ]; then
    printf "  Docker:        ${YELLOW}SKIP${NC}\n"
else
    printf "  Docker:        ${GREEN}Install${NC}\n"
fi
if [ "$SKIP_TAILSCALE" = true ]; then
    printf "  Tailscale:     ${YELLOW}SKIP${NC}\n"
else
    printf "  Tailscale:     ${GREEN}Install${NC}\n"
fi
if [ "$SKIP_FIREWALL" = true ]; then
    printf "  Firewall:      ${YELLOW}SKIP${NC}\n"
else
    printf "  Firewall:      ${GREEN}Configure${NC}\n"
fi
if [ "$SKIP_SECRETS" = true ]; then
    printf "  Secrets:       ${YELLOW}SKIP${NC}\n"
else
    printf "  Secrets:       ${GREEN}Generate${NC}\n"
fi
printf "\n"

# Architecture notes
if [ "$IS_PI" = true ]; then
    printf "${GREEN}✓${NC} Raspberry Pi optimizations will be applied\n"
fi
if [ "$ARCH_NORMALIZED" = "arm64" ]; then
    printf "${GREEN}✓${NC} ARM64 architecture detected\n"
elif [ "$ARCH_NORMALIZED" = "amd64" ]; then
    printf "${GREEN}✓${NC} x86_64 architecture detected\n"
fi

printf "\n"
if ! confirm "Continue with setup?"; then
    log_info "Setup cancelled"
    exit 0
fi

# =============================================================================
# Step 1: Update System
# =============================================================================
log_header "Step 1: System Update"

case "$PKG_MANAGER" in
    apt)
        export DEBIAN_FRONTEND=noninteractive
        log_info "Updating apt packages..."
        apt-get update
        apt-get upgrade -y
        apt-get install -y \
            curl \
            wget \
            git \
            ca-certificates \
            gnupg \
            lsb-release \
            ufw \
            htop \
            vim \
            openssh-server \
            openssl \
            jq
        log_success "System updated (apt)"
        ;;
    dnf)
        log_info "Updating dnf packages..."
        dnf update -y
        dnf install -y \
            curl \
            wget \
            git \
            ca-certificates \
            gnupg \
            ufw \
            htop \
            vim \
            openssh-server \
            openssl \
            jq
        log_success "System updated (dnf)"
        ;;
    yum)
        log_info "Updating yum packages..."
        yum update -y
        yum install -y \
            curl \
            wget \
            git \
            ca-certificates \
            gnupg \
            ufw \
            htop \
            vim \
            openssh-server \
            openssl \
            jq
        log_success "System updated (yum)"
        ;;
    pacman)
        log_info "Updating pacman packages..."
        pacman -Syu --noconfirm
        pacman -S --noconfirm --needed \
            curl \
            wget \
            git \
            ca-certificates \
            gnupg \
            ufw \
            htop \
            vim \
            openssh \
            openssl \
            jq
        log_success "System updated (pacman)"
        ;;
    apk)
        log_info "Updating apk packages..."
        apk update
        apk upgrade
        apk add \
            curl \
            wget \
            git \
            ca-certificates \
            gnupg \
            ufw \
            htop \
            vim \
            openssh \
            openssl \
            jq
        log_success "System updated (apk)"
        ;;
    *)
        log_error "Unsupported package manager: $PKG_MANAGER"
        log_info "Please install required packages manually: curl wget git ca-certificates openssh openssl jq"
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
        ;;
esac

# =============================================================================
# Step 2: Install Docker
# =============================================================================
log_header "Step 2: Docker Installation"

if [ "$SKIP_DOCKER" = true ]; then
    log_skip "Docker installation skipped"
else
    if command -v docker >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
        log_warn "Docker already installed: $DOCKER_VERSION"
    else
        log_info "Installing Docker using official script..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        log_success "Docker installed: $(docker --version)"
    fi

    # Start and enable Docker
    log_info "Enabling Docker service..."
    systemctl start docker 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
    log_success "Docker service started and enabled"

    # Install Docker Compose plugin if not present
    if ! docker compose version >/dev/null 2>&1; then
        log_info "Installing Docker Compose plugin..."
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y docker-compose-plugin 2>/dev/null || true
                ;;
            dnf|yum)
                dnf install -y docker-compose-plugin 2>/dev/null || yum install -y docker-compose-plugin 2>/dev/null || true
                ;;
            pacman)
                pacman -S --noconfirm docker-compose 2>/dev/null || true
                ;;
        esac
        
        if docker compose version >/dev/null 2>&1; then
            log_success "Docker Compose installed"
        else
            log_warn "Docker Compose plugin not installed - you may need to install it manually"
        fi
    else
        log_info "Docker Compose already installed: $(docker compose version 2>/dev/null | head -n1)"
    fi

    # ARM/Raspberry Pi optimizations
    if [ "$IS_PI" = true ] || [ "$ARCH_NORMALIZED" = "arm64" ]; then
        log_subheader "ARM/Raspberry Pi Optimizations"

        # Enable cgroup memory (required for Docker on Raspberry Pi)
        CMDLINE_FILE=""
        if [ -f /boot/firmware/cmdline.txt ]; then
            CMDLINE_FILE="/boot/firmware/cmdline.txt"
        elif [ -f /boot/cmdline.txt ]; then
            CMDLINE_FILE="/boot/cmdline.txt"
        fi

        if [ -n "$CMDLINE_FILE" ]; then
            if ! grep -q "cgroup_memory=1 cgroup_enable=memory" "$CMDLINE_FILE" 2>/dev/null; then
                log_info "Enabling cgroup memory support..."
                cp "$CMDLINE_FILE" "${CMDLINE_FILE}.backup"
                sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_FILE"
                log_warn "REBOOT REQUIRED for cgroup changes"
                NEEDS_REBOOT=true
            else
                log_info "Cgroup memory already enabled"
            fi
        fi

        # Increase swap if low memory
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$TOTAL_MEM" -lt 2048 ]; then
            log_info "Low memory detected (${TOTAL_MEM}MB)..."
            if [ -f /etc/dphys-swapfile ]; then
                CURRENT_SWAP=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
                if [ "${CURRENT_SWAP:-0}" -lt 2048 ]; then
                    log_info "Increasing swap to 2GB..."
                    sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
                    systemctl restart dphys-swapfile 2>/dev/null || true
                    log_success "Swap increased to 2GB"
                fi
            fi
        fi
    fi

    # Configure Docker daemon
    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
    if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
        log_info "Configuring Docker daemon..."
        mkdir -p /etc/docker
        cat > "$DOCKER_DAEMON_CONFIG" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
        systemctl restart docker 2>/dev/null || true
        log_success "Docker daemon configured with log rotation"
    else
        log_info "Docker daemon already configured"
    fi
fi

# =============================================================================
# Step 3: Create CI/CD User
# =============================================================================
log_header "Step 3: Create CI/CD User"

ACTIONS_HOME="/home/$ACTIONS_USER"

if id "$ACTIONS_USER" >/dev/null 2>&1; then
    log_warn "User '$ACTIONS_USER' already exists"
else
    useradd -m -s /bin/bash -c "CI/CD Deployment User" "$ACTIONS_USER"
    log_success "User '$ACTIONS_USER' created"
fi

# Add to docker group if Docker is installed
if [ "$SKIP_DOCKER" = false ] && command -v docker >/dev/null 2>&1; then
    usermod -aG docker "$ACTIONS_USER"
    log_success "User '$ACTIONS_USER' added to docker group"
fi

# Add admin user to docker group if specified and exists
if [ -n "$ADMIN_USER" ] && id "$ADMIN_USER" >/dev/null 2>&1; then
    if [ "$SKIP_DOCKER" = false ] && command -v docker >/dev/null 2>&1; then
        usermod -aG docker "$ADMIN_USER"
        log_success "User '$ADMIN_USER' added to docker group"
    fi
fi

# Setup directories
mkdir -p "$ACTIONS_HOME"
chown "$ACTIONS_USER:$ACTIONS_USER" "$ACTIONS_HOME"
chmod 755 "$ACTIONS_HOME"

# Create project directory
PROJECT_DIR="$ACTIONS_HOME/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR"
chown "$ACTIONS_USER:$ACTIONS_USER" "$PROJECT_DIR"
log_success "Project directory: $PROJECT_DIR"

# =============================================================================
# Step 4: Configure SSH
# =============================================================================
log_header "Step 4: SSH Configuration"

SSH_DIR="$ACTIONS_HOME/.ssh"

mkdir -p "$SSH_DIR"
chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$SSH_DIR/authorized_keys" ]; then
    touch "$SSH_DIR/authorized_keys"
    chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    log_success "Created authorized_keys"
fi

# Ensure SSH service is running
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
log_success "SSH service enabled"
log_info "SSH Port: $SSH_PORT"

# =============================================================================
# Step 5: Configure Firewall
# =============================================================================
log_header "Step 5: Firewall Configuration"

if [ "$SKIP_FIREWALL" = true ]; then
    log_skip "Firewall configuration skipped"
else
    if command -v ufw >/dev/null 2>&1; then
        log_info "Configuring UFW firewall..."

        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1

        # Allow SSH
        ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null 2>&1
        log_info "Allowed SSH on port $SSH_PORT"

        # Allow Tailscale interface (if not skipped)
        if [ "$SKIP_TAILSCALE" = false ]; then
            ufw allow in on tailscale0 >/dev/null 2>&1
            log_info "Allowed Tailscale interface"
        fi

        ufw --force enable >/dev/null 2>&1
        log_success "Firewall configured and enabled"
    else
        log_warn "UFW not available"
        log_info "Consider configuring a firewall manually"
    fi
fi

# =============================================================================
# Step 6: Install Tailscale
# =============================================================================
log_header "Step 6: Tailscale Installation"

TAILSCALE_IP=""

if [ "$SKIP_TAILSCALE" = true ]; then
    log_skip "Tailscale installation skipped"
else
    if command -v tailscale >/dev/null 2>&1; then
        log_warn "Tailscale already installed"

        if tailscale status >/dev/null 2>&1; then
            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
            if [ -n "$TAILSCALE_IP" ]; then
                log_success "Tailscale connected: $TAILSCALE_IP"
            else
                log_warn "Tailscale not connected"
                log_info "Run: sudo tailscale up"
            fi
        else
            log_warn "Tailscale service not running"
            log_info "Run: sudo tailscale up"
        fi
    else
        log_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale installed"
        log_warn "Run 'sudo tailscale up' to connect"
    fi
fi

# =============================================================================
# Step 7: System Optimizations
# =============================================================================
log_header "Step 7: System Optimizations"

# Increase file descriptors
if ! grep -q "fs.file-max = 65536" /etc/sysctl.conf 2>/dev/null; then
    log_info "Configuring system limits..."
    cat >> /etc/sysctl.conf <<EOF

# Server optimizations (added by setup script)
fs.file-max = 65536
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 65535
EOF
    sysctl -p >/dev/null 2>&1
    log_success "System limits configured"
else
    log_info "System limits already configured"
fi

# Show timezone
if command -v timedatectl >/dev/null 2>&1; then
    log_info "Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'unknown')"
fi

# =============================================================================
# Step 8: Generate Secrets
# =============================================================================
log_header "Step 8: Secrets Generation"

if [ "$SKIP_SECRETS" = true ]; then
    log_skip "Secrets generation skipped"
else
    log_subheader "Generating SSH Keys"

    # Generate SSH key
    REGENERATE_KEY=false
    if [ -f "$SSH_DIR/id_ed25519" ]; then
        log_warn "SSH key already exists"
        if confirm_no "Regenerate SSH key? (invalidates old key)"; then
            REGENERATE_KEY=true
            rm -f "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub"
        else
            log_info "Using existing SSH key"
        fi
    fi

    if [ ! -f "$SSH_DIR/id_ed25519" ]; then
        log_info "Generating Ed25519 SSH key..."
        sudo -u "$ACTIONS_USER" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -C "${ACTIONS_USER}@${HOSTNAME}-$(date +%Y%m%d)"
        chmod 600 "$SSH_DIR/id_ed25519"
        chmod 644 "$SSH_DIR/id_ed25519.pub"
        log_success "SSH key generated"
    fi

    # Add to authorized_keys
    PUB_KEY=$(cat "$SSH_DIR/id_ed25519.pub")
    if ! grep -qF "$PUB_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
        chown "$ACTIONS_USER:$ACTIONS_USER" "$SSH_DIR/authorized_keys"
        log_success "Public key added to authorized_keys"
    fi

    log_subheader "Generating Application Secrets"

    # Generate secrets
    API_KEY=$(generate_base64_secret 32)
    JWT_SECRET=$(generate_hex_secret 64)
    ENCRYPTION_KEY=$(generate_hex_secret 32)
    SESSION_SECRET=$(generate_hex_secret 32)
    ADMIN_PASSWORD=$(generate_password)
    DB_PASSWORD=$(generate_password)

    log_success "Application secrets generated"

    # Read SSH keys
    SSH_PRIVATE_KEY=$(cat "$SSH_DIR/id_ed25519")
    SSH_PUBLIC_KEY=$(cat "$SSH_DIR/id_ed25519.pub")

    # Re-check Tailscale IP
    if [ -z "$TAILSCALE_IP" ] && command -v tailscale >/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    fi

    # Create credentials file
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
# Generated: $(date)
# Hostname:  $HOSTNAME
# Server IP: $SERVER_IP
# Tailscale: ${TAILSCALE_IP:-Not configured}
# SSH Port:  $SSH_PORT
# Arch:      $ARCH ($ARCH_NORMALIZED)
# OS:        $OS_NAME $OS_VERSION
#
################################################################################

================================================================================
GITHUB ACTIONS SECRETS (REQUIRED)
================================================================================
Go to: https://github.com/YOUR_USERNAME/$PROJECT_NAME/settings/secrets/actions

SECRET NAME                 VALUE
--------------------------  ---------------------------------------------------
PROD_TAILSCALE_IP           ${TAILSCALE_IP:-CONFIGURE_TAILSCALE_FIRST}
PROD_SSH_PORT               $SSH_PORT
PROD_SSH_USER               $ACTIONS_USER
PROD_SSH_KEY                (see SSH PRIVATE KEY section below)

DOCKER_USERNAME             (your Docker Hub username)
DOCKER_TOKEN                (your Docker Hub access token)

TAILSCALE_OAUTH_CLIENT_ID   (from Tailscale Admin Console)
TAILSCALE_OAUTH_SECRET      (from Tailscale Admin Console)

================================================================================
GITHUB ACTIONS SECRETS (OPTIONAL)
================================================================================

DISCORD_WEBHOOK             (Discord webhook for notifications)
API_KEY                     $API_KEY

================================================================================
SSH PRIVATE KEY (for PROD_SSH_KEY)
================================================================================
Copy entire block including BEGIN and END lines:

$SSH_PRIVATE_KEY

================================================================================
SSH PUBLIC KEY
================================================================================
$SSH_PUBLIC_KEY

================================================================================
APPLICATION SECRETS (for .env file)
================================================================================

# API & Authentication
API_KEY=$API_KEY
JWT_SECRET=$JWT_SECRET
SESSION_SECRET=$SESSION_SECRET

# Encryption
ENCRYPTION_KEY=$ENCRYPTION_KEY

# Admin
ADMIN_PASSWORD=$ADMIN_PASSWORD

# Database (if needed)
DB_PASSWORD=$DB_PASSWORD

================================================================================
QUICK COMMANDS
================================================================================

# View credentials
cat $CREDENTIALS_FILE

# View SSH private key
cat $SSH_DIR/id_ed25519

# Get Tailscale IP
tailscale ip -4

# Test SSH (from another machine)
ssh -p $SSH_PORT $ACTIONS_USER@${TAILSCALE_IP:-TAILSCALE_IP}

# Check Docker
docker info | grep -E "Architecture|Server Version"

# DELETE THIS FILE WHEN DONE
sudo rm $CREDENTIALS_FILE

################################################################################
EOF

    log_success "Credentials saved: $CREDENTIALS_FILE"
fi

# =============================================================================
# Final Summary
# =============================================================================
log_header "Setup Complete!"

printf "${BOLD}${GREEN}Server Information:${NC}\n"
printf "  Project:       ${CYAN}%s${NC}\n" "$PROJECT_NAME"
printf "  Hostname:      ${CYAN}%s${NC}\n" "$HOSTNAME"
printf "  Server IP:     ${CYAN}%s${NC}\n" "$SERVER_IP"
if [ "$SKIP_TAILSCALE" = false ]; then
    printf "  Tailscale IP:  ${CYAN}%s${NC}\n" "${TAILSCALE_IP:-Not configured}"
fi
printf "  Architecture:  ${CYAN}%s (%s)${NC}\n" "$ARCH" "$ARCH_NORMALIZED"
printf "  OS:            ${CYAN}%s %s${NC}\n" "$OS_NAME" "$OS_VERSION"
printf "  SSH Port:      ${CYAN}%s${NC}\n" "$SSH_PORT"
printf "  CI/CD User:    ${CYAN}%s${NC}\n" "$ACTIONS_USER"
printf "  Project Dir:   ${CYAN}%s${NC}\n" "$PROJECT_DIR"
printf "\n"

# Architecture notes
if [ "$IS_PI" = true ]; then
    printf "${BOLD}${MAGENTA}Raspberry Pi:${NC}\n"
    printf "  ${GREEN}✓${NC} ARM64 optimizations applied\n"
    printf "  ${GREEN}✓${NC} Docker pulls ARM64 images automatically\n"
    if [ "$NEEDS_REBOOT" = true ]; then
        printf "  ${YELLOW}⚠${NC} ${BOLD}REBOOT REQUIRED${NC} for cgroup changes\n"
    fi
    printf "\n"
elif [ "$ARCH_NORMALIZED" = "arm64" ]; then
    printf "${BOLD}${MAGENTA}ARM64:${NC}\n"
    printf "  ${GREEN}✓${NC} ARM64 architecture configured\n"
    printf "\n"
fi

# Next steps
printf "${BOLD}${YELLOW}Next Steps:${NC}\n"

STEP_NUM=1

if [ "$SKIP_TAILSCALE" = false ] && [ -z "$TAILSCALE_IP" ]; then
    printf "  ${GREEN}%d.${NC} Connect Tailscale:\n" "$STEP_NUM"
    printf "     ${CYAN}sudo tailscale up${NC}\n\n"
    STEP_NUM=$((STEP_NUM + 1))
fi

if [ "$SKIP_SECRETS" = false ]; then
    printf "  ${GREEN}%d.${NC} View and copy credentials:\n" "$STEP_NUM"
    printf "     ${CYAN}cat %s${NC}\n\n" "$CREDENTIALS_FILE"
    STEP_NUM=$((STEP_NUM + 1))

    printf "  ${GREEN}%d.${NC} Add secrets to GitHub Actions:\n" "$STEP_NUM"
    printf "     ${CYAN}https://github.com/YOUR_USERNAME/%s/settings/secrets/actions${NC}\n\n" "$PROJECT_NAME"
    STEP_NUM=$((STEP_NUM + 1))

    printf "  ${GREEN}%d.${NC} Delete credentials file when done:\n" "$STEP_NUM"
    printf "     ${CYAN}sudo rm %s${NC}\n\n" "$CREDENTIALS_FILE"
    STEP_NUM=$((STEP_NUM + 1))
fi

if [ "$NEEDS_REBOOT" = true ]; then
    printf "${BOLD}${RED}⚠  REBOOT REQUIRED${NC}\n"
    printf "   Run: ${CYAN}sudo reboot${NC}\n\n"
fi

log_success "Server is ready for deployments!"
printf "\n"

exit 0
