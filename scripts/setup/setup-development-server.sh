#!/bin/sh
# =============================================================================
# Development Server Setup Script
# A reusable script for setting up development workstations and WSL environments
# Supports x86_64 and ARM64 architectures (including Apple Silicon)
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
#   --minimal               Minimal install (Docker + essential tools only)
#   --full                  Full install (all tools and languages)
#   --no-confirm            Skip confirmation prompts
#   -h, --help              Show this help message
#
# Examples:
#   sudo ./setup-development-server.sh -u jordan
#   sudo ./setup-development-server.sh --minimal
#   sudo ./setup-development-server.sh --full --no-confirm
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
MINIMAL_INSTALL=false
FULL_INSTALL=false
NO_CONFIRM=false
IS_WSL=false
IS_WSL2=false

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
Development Server Setup Script
================================

A reusable script for setting up development workstations and WSL environments.
Optimized for Ubuntu/Debian on WSL, native Linux, and supports multiple architectures.

USAGE:
    sudo ./setup-development-server.sh [OPTIONS]

OPTIONS:
    -u, --user NAME         Development user to configure
                            (default: current user)

    -n, --name NAME         Machine name/identifier for configuration
                            (default: hostname)

    --skip-docker           Skip Docker installation

    --skip-devtools         Skip development tools (git, build-essential, etc.)

    --skip-languages        Skip programming language runtimes (Node, Python, Go, etc.)

    --skip-gui              Skip GUI applications (VS Code, browsers, etc.)
                            Only install CLI tools

    --minimal               Minimal install: Docker + essential CLI tools only
                            Equivalent to: --skip-languages --skip-gui

    --full                  Full install: All tools, languages, and applications
                            (default behavior)

    --no-confirm            Skip all confirmation prompts (for automation)

    -h, --help              Show this help message

EXAMPLES:
    # Basic setup for current user
    sudo ./setup-development-server.sh -u jordan

    # Minimal WSL setup (Docker + essentials)
    sudo ./setup-development-server.sh --minimal

    # Full automated setup
    sudo ./setup-development-server.sh --full --no-confirm

    # Skip GUI apps (headless/WSL)
    sudo ./setup-development-server.sh --skip-gui

WHAT THIS SCRIPT INSTALLS:
    Core Development Tools:
    - Git, curl, wget, build-essential
    - tmux, vim, zsh (with oh-my-zsh optional)
    - jq, httpie, btop/htop
    - Docker and Docker Compose

    Programming Languages (unless --skip-languages):
    - Node.js (via nvm)
    - Python 3 + pip + venv
    - Go (latest stable)
    - Rust (via rustup)

    Optional GUI Applications (unless --skip-gui):
    - VS Code
    - Google Chrome / Chromium

    WSL-Specific:
    - WSL utilities and integrations
    - Windows interop optimizations

SUPPORTED SYSTEMS:
    - Ubuntu 22.04+ / Debian 11+
    - WSL2 (Ubuntu 24.04, 25.10)
    - Raspberry Pi OS (ARM64)
    - x86_64 and ARM64 architectures

EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)
            DEV_USER="$2"
            shift 2
            ;;
        -n|--name)
            MACHINE_NAME="$2"
            shift 2
            ;;
        --skip-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --skip-devtools)
            SKIP_DEVTOOLS=true
            shift
            ;;
        --skip-languages)
            SKIP_LANGUAGES=true
            shift
            ;;
        --skip-gui)
            SKIP_GUI=true
            shift
            ;;
        --minimal)
            MINIMAL_INSTALL=true
            SKIP_LANGUAGES=true
            SKIP_GUI=true
            shift
            ;;
        --full)
            FULL_INSTALL=true
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
    elif command -v brew >/dev/null 2>&1; then
        echo "brew"
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

# Run command as dev user
run_as_user() {
    sudo -u "$DEV_USER" -H sh -c "$*"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Please run this script with sudo"
    exit 1
fi

# Validate dev user exists
if ! id "$DEV_USER" >/dev/null 2>&1; then
    log_error "User '$DEV_USER' does not exist"
    exit 1
fi

# =============================================================================
# System Detection
# =============================================================================
log_header "Development Environment Setup"

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

# Detect WSL
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    if grep -qi wsl2 /proc/version 2>/dev/null || [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
        IS_WSL2=true
        log_success "WSL2 environment detected"
    else
        log_warn "WSL1 environment detected (WSL2 recommended)"
    fi
fi

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
HOSTNAME=$(hostname 2>/dev/null || echo "devmachine")
if [ -z "$MACHINE_NAME" ]; then
    MACHINE_NAME="$HOSTNAME"
fi
log_info "Machine Name: $MACHINE_NAME"

# Get user home directory
USER_HOME=$(eval echo "~$DEV_USER")
log_info "User Home: $USER_HOME"

# Show configuration
printf "\n"
printf "${BOLD}Configuration:${NC}\n"
printf "  Development User: ${CYAN}%s${NC}\n" "$DEV_USER"
printf "  Machine Name:     ${CYAN}%s${NC}\n" "$MACHINE_NAME"
printf "  Install Type:     ${CYAN}%s${NC}\n" "$([ "$MINIMAL_INSTALL" = true ] && echo "Minimal" || echo "Standard")"
printf "\n"

# Show what will be installed
printf "${BOLD}Components:${NC}\n"
if [ "$SKIP_DOCKER" = true ]; then
    printf "  Docker:           ${YELLOW}SKIP${NC}\n"
else
    printf "  Docker:           ${GREEN}Install${NC}\n"
fi
if [ "$SKIP_DEVTOOLS" = true ]; then
    printf "  Dev Tools:        ${YELLOW}SKIP${NC}\n"
else
    printf "  Dev Tools:        ${GREEN}Install${NC}\n"
fi
if [ "$SKIP_LANGUAGES" = true ]; then
    printf "  Languages:        ${YELLOW}SKIP${NC}\n"
else
    printf "  Languages:        ${GREEN}Install (Node, Python, Go, Rust)${NC}\n"
fi
if [ "$SKIP_GUI" = true ] || [ "$IS_WSL" = true ]; then
    printf "  GUI Apps:         ${YELLOW}SKIP${NC}\n"
else
    printf "  GUI Apps:         ${GREEN}Install${NC}\n"
fi
printf "\n"

# Environment notes
if [ "$IS_WSL2" = true ]; then
    printf "${GREEN}✓${NC} WSL2 optimizations will be applied\n"
elif [ "$IS_WSL" = true ]; then
    printf "${YELLOW}⚠${NC} WSL1 detected - consider upgrading to WSL2\n"
fi
if [ "$IS_PI" = true ]; then
    printf "${GREEN}✓${NC} Raspberry Pi optimizations will be applied\n"
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
        log_success "System updated (apt)"
        ;;
    dnf)
        log_info "Updating dnf packages..."
        dnf update -y
        log_success "System updated (dnf)"
        ;;
    yum)
        log_info "Updating yum packages..."
        yum update -y
        log_success "System updated (yum)"
        ;;
    pacman)
        log_info "Updating pacman packages..."
        pacman -Syu --noconfirm
        log_success "System updated (pacman)"
        ;;
    brew)
        log_info "Updating Homebrew..."
        run_as_user "brew update"
        log_success "Homebrew updated"
        ;;
    *)
        log_error "Unsupported package manager: $PKG_MANAGER"
        exit 1
        ;;
esac

# =============================================================================
# Step 2: Install Core Development Tools
# =============================================================================
log_header "Step 2: Core Development Tools"

if [ "$SKIP_DEVTOOLS" = true ]; then
    log_skip "Development tools installation skipped"
else
    case "$PKG_MANAGER" in
        apt)
            log_info "Installing development tools..."
            apt-get install -y \
                curl \
                wget \
                git \
                build-essential \
                ca-certificates \
                gnupg \
                lsb-release \
                software-properties-common \
                apt-transport-https \
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
                tldr \
                ncdu \
                fzf \
                ripgrep \
                fd-find \
                bat \
                2>/dev/null || apt-get install -y \
                curl \
                wget \
                git \
                build-essential \
                ca-certificates \
                gnupg \
                vim \
                tmux \
                zsh \
                htop \
                jq \
                tree \
                unzip \
                zip \
                openssh-client \
                openssl
            log_success "Development tools installed"
            ;;
        dnf|yum)
            log_info "Installing development tools..."
            $PKG_MANAGER install -y \
                curl \
                wget \
                git \
                gcc \
                gcc-c++ \
                make \
                ca-certificates \
                gnupg \
                vim \
                tmux \
                zsh \
                htop \
                jq \
                tree \
                unzip \
                zip \
                openssh-clients \
                openssl
            log_success "Development tools installed"
            ;;
        pacman)
            log_info "Installing development tools..."
            pacman -S --noconfirm --needed \
                curl \
                wget \
                git \
                base-devel \
                ca-certificates \
                gnupg \
                vim \
                tmux \
                zsh \
                htop \
                btop \
                jq \
                tree \
                unzip \
                zip \
                openssh \
                openssl
            log_success "Development tools installed"
            ;;
        brew)
            log_info "Installing development tools..."
            run_as_user "brew install \
                curl \
                wget \
                git \
                vim \
                tmux \
                zsh \
                htop \
                btop \
                jq \
                httpie \
                tree \
                unzip \
                fzf \
                ripgrep \
                fd \
                bat"
            log_success "Development tools installed"
            ;;
    esac

    # Configure Git
    log_subheader "Git Configuration"

    CURRENT_GIT_NAME=$(run_as_user "git config --global user.name" 2>/dev/null || echo "")
    CURRENT_GIT_EMAIL=$(run_as_user "git config --global user.email" 2>/dev/null || echo "")

    if [ -z "$CURRENT_GIT_NAME" ]; then
        log_info "Git user.name not set"
        if [ "$NO_CONFIRM" = false ]; then
            printf "Enter your name for Git commits: "
            read -r GIT_NAME
            if [ -n "$GIT_NAME" ]; then
                run_as_user "git config --global user.name \"$GIT_NAME\""
                log_success "Git user.name configured"
            fi
        fi
    else
        log_info "Git user.name: $CURRENT_GIT_NAME"
    fi

    if [ -z "$CURRENT_GIT_EMAIL" ]; then
        log_info "Git user.email not set"
        if [ "$NO_CONFIRM" = false ]; then
            printf "Enter your email for Git commits: "
            read -r GIT_EMAIL
            if [ -n "$GIT_EMAIL" ]; then
                run_as_user "git config --global user.email \"$GIT_EMAIL\""
                log_success "Git user.email configured"
            fi
        fi
    else
        log_info "Git user.email: $CURRENT_GIT_EMAIL"
    fi

    # Set useful Git defaults
    run_as_user "git config --global init.defaultBranch main" 2>/dev/null || true
    run_as_user "git config --global pull.rebase false" 2>/dev/null || true
    run_as_user "git config --global core.autocrlf input" 2>/dev/null || true
    log_success "Git defaults configured"
fi

# =============================================================================
# Step 3: Install Docker
# =============================================================================
log_header "Step 3: Docker Installation"

if [ "$SKIP_DOCKER" = true ]; then
    log_skip "Docker installation skipped"
else
    if command -v docker >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
        log_warn "Docker already installed: $DOCKER_VERSION"
    else
        log_info "Installing Docker..."

        if [ "$PKG_MANAGER" = "apt" ]; then
            # Official Docker installation for Debian/Ubuntu
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            # Use package manager for other systems
            case "$PKG_MANAGER" in
                dnf|yum)
                    $PKG_MANAGER install -y docker docker-compose
                    ;;
                pacman)
                    pacman -S --noconfirm docker docker-compose
                    ;;
                brew)
                    log_warn "Docker Desktop must be installed manually on macOS"
                    log_info "Download from: https://www.docker.com/products/docker-desktop"
                    ;;
            esac
        fi

        log_success "Docker installed: $(docker --version 2>/dev/null || echo 'installation complete')"
    fi

    # Start and enable Docker (if not WSL1)
    if [ "$IS_WSL" = false ] || [ "$IS_WSL2" = true ]; then
        log_info "Enabling Docker service..."
        systemctl start docker 2>/dev/null || true
        systemctl enable docker 2>/dev/null || true
        log_success "Docker service enabled"
    fi

    # Add user to docker group
    if ! groups "$DEV_USER" | grep -q docker 2>/dev/null; then
        usermod -aG docker "$DEV_USER"
        log_success "User '$DEV_USER' added to docker group"
        log_warn "Logout and login again for docker group changes to take effect"
    else
        log_info "User '$DEV_USER' already in docker group"
    fi

    # Install Docker Compose plugin
    if ! docker compose version >/dev/null 2>&1; then
        log_info "Installing Docker Compose plugin..."

        case "$PKG_MANAGER" in
            apt)
                apt-get install -y docker-compose-plugin 2>/dev/null || true
                ;;
            dnf|yum)
                $PKG_MANAGER install -y docker-compose-plugin 2>/dev/null || true
                ;;
        esac

        if docker compose version >/dev/null 2>&1; then
            log_success "Docker Compose installed: $(docker compose version)"
        else
            log_warn "Docker Compose plugin not available, you may need to install it manually"
        fi
    else
        log_info "Docker Compose already installed: $(docker compose version 2>/dev/null | head -n1)"
    fi

    # Configure Docker daemon for development
    DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
    if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
        log_info "Configuring Docker daemon..."
        mkdir -p /etc/docker
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
        systemctl restart docker 2>/dev/null || true
        log_success "Docker daemon configured"
    else
        log_info "Docker daemon already configured"
    fi
fi

# =============================================================================
# Step 4: Install Programming Languages
# =============================================================================
log_header "Step 4: Programming Languages"

if [ "$SKIP_LANGUAGES" = true ]; then
    log_skip "Programming languages installation skipped"
else
    # Node.js (via nvm)
    log_subheader "Node.js (via nvm)"

    NVM_DIR="$USER_HOME/.nvm"
    if [ -d "$NVM_DIR" ]; then
        log_warn "nvm already installed"
    else
        log_info "Installing nvm..."
        NVM_VERSION="v0.39.7"
        run_as_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
        log_success "nvm installed"
    fi

    # Install latest LTS Node.js
    if [ -d "$NVM_DIR" ]; then
        log_info "Installing Node.js LTS..."
        run_as_user ". $NVM_DIR/nvm.sh && nvm install --lts && nvm use --lts"
        NODE_VERSION=$(run_as_user ". $NVM_DIR/nvm.sh && node --version" 2>/dev/null || echo "")
        if [ -n "$NODE_VERSION" ]; then
            log_success "Node.js installed: $NODE_VERSION"
        fi
    fi

    # Python
    log_subheader "Python"

    if command -v python3 >/dev/null 2>&1; then
        PYTHON_VERSION=$(python3 --version 2>/dev/null || echo "unknown")
        log_info "Python already installed: $PYTHON_VERSION"
    else
        log_info "Installing Python..."
        case "$PKG_MANAGER" in
            apt)
                apt-get install -y python3 python3-pip python3-venv python3-dev
                ;;
            dnf|yum)
                $PKG_MANAGER install -y python3 python3-pip python3-virtualenv
                ;;
            pacman)
                pacman -S --noconfirm python python-pip
                ;;
            brew)
                run_as_user "brew install python3"
                ;;
        esac
        log_success "Python installed: $(python3 --version 2>/dev/null || echo 'complete')"
    fi

    # Upgrade pip
    log_info "Upgrading pip..."
    run_as_user "python3 -m pip install --user --upgrade pip setuptools wheel" 2>/dev/null || true

    # Go
    log_subheader "Go"

    if command -v go >/dev/null 2>&1; then
        GO_VERSION=$(go version 2>/dev/null || echo "unknown")
        log_info "Go already installed: $GO_VERSION"
    else
        log_info "Installing Go..."

        GO_VERSION="1.22.0"
        GO_ARCH="$ARCH_NORMALIZED"
        if [ "$GO_ARCH" = "amd64" ]; then
            GO_ARCH="amd64"
        elif [ "$GO_ARCH" = "arm64" ]; then
            GO_ARCH="arm64"
        fi

        GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
        GO_URL="https://go.dev/dl/${GO_TAR}"

        wget -q "$GO_URL" -O /tmp/"$GO_TAR" 2>/dev/null || curl -fsSL "$GO_URL" -o /tmp/"$GO_TAR"
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/"$GO_TAR"
        rm /tmp/"$GO_TAR"

        # Add to PATH
        if ! grep -q '/usr/local/go/bin' "$USER_HOME/.profile" 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> "$USER_HOME/.profile"
            echo 'export PATH=$PATH:$HOME/go/bin' >> "$USER_HOME/.profile"
        fi

        export PATH=$PATH:/usr/local/go/bin
        log_success "Go installed: $(go version 2>/dev/null || echo "$GO_VERSION")"
    fi

    # Rust
    log_subheader "Rust"

    if command -v rustc >/dev/null 2>&1; then
        RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
        log_info "Rust already installed: $RUST_VERSION"
    else
        log_info "Installing Rust..."
        run_as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"

        # Add to PATH
        CARGO_ENV="$USER_HOME/.cargo/env"
        if [ -f "$CARGO_ENV" ]; then
            . "$CARGO_ENV"
            RUST_VERSION=$(rustc --version 2>/dev/null || echo "installed")
            log_success "Rust installed: $RUST_VERSION"
        fi
    fi
fi

# =============================================================================
# Step 5: Shell Configuration
# =============================================================================
log_header "Step 5: Shell Configuration"

# Detect current shell
CURRENT_SHELL=$(getent passwd "$DEV_USER" | cut -d: -f7)
log_info "Current shell: $CURRENT_SHELL"

# Offer zsh installation
if [ "$SKIP_DEVTOOLS" = false ]; then
    if command -v zsh >/dev/null 2>&1; then
        if [ "$CURRENT_SHELL" != "$(command -v zsh)" ]; then
            if [ "$NO_CONFIRM" = false ]; then
                if confirm_no "Change default shell to zsh?"; then
                    chsh -s "$(command -v zsh)" "$DEV_USER"
                    log_success "Default shell changed to zsh"

                    # Offer oh-my-zsh
                    if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
                        if confirm_no "Install oh-my-zsh?"; then
                            run_as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
                            log_success "oh-my-zsh installed"
                        fi
                    fi
                fi
            fi
        else
            log_info "zsh is already the default shell"
        fi
    fi
fi

# Create useful shell aliases
log_subheader "Shell Aliases"

SHELL_RC=""
if [ -f "$USER_HOME/.zshrc" ]; then
    SHELL_RC="$USER_HOME/.zshrc"
elif [ -f "$USER_HOME/.bashrc" ]; then
    SHELL_RC="$USER_HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    if ! grep -q "# Development aliases" "$SHELL_RC" 2>/dev/null; then
        log_info "Adding development aliases..."
        cat >> "$SHELL_RC" <<'EOF'

# Development aliases
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gp='git pull'
alias gc='git commit'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate'
alias dc='docker compose'
alias dps='docker ps'
alias dimg='docker images'
alias dlog='docker logs'

# Python
alias py='python3'
alias venv='python3 -m venv'

# Quick navigation
alias dev='cd ~/dev'
alias proj='cd ~/projects'

EOF
        chown "$DEV_USER:$DEV_USER" "$SHELL_RC"
        log_success "Shell aliases added"
    else
        log_info "Shell aliases already configured"
    fi
fi

# =============================================================================
# Step 6: GUI Applications (if not skipped)
# =============================================================================
log_header "Step 6: GUI Applications"

if [ "$SKIP_GUI" = true ] || [ "$IS_WSL" = true ]; then
    log_skip "GUI applications skipped"
else
    # VS Code
    log_subheader "Visual Studio Code"

    if command -v code >/dev/null 2>&1; then
        log_info "VS Code already installed"
    else
        case "$PKG_MANAGER" in
            apt)
                log_info "Installing VS Code..."
                wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
                install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
                sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
                rm -f /tmp/packages.microsoft.gpg
                apt-get update
                apt-get install -y code
                log_success "VS Code installed"
                ;;
            dnf|yum)
                log_info "Installing VS Code..."
                rpm --import https://packages.microsoft.com/keys/microsoft.asc
                sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
                $PKG_MANAGER install -y code
                log_success "VS Code installed"
                ;;
            brew)
                run_as_user "brew install --cask visual-studio-code"
                log_success "VS Code installed"
                ;;
            *)
                log_warn "VS Code installation not automated for $PKG_MANAGER"
                log_info "Download from: https://code.visualstudio.com/"
                ;;
        esac
    fi

    # Google Chrome / Chromium
    log_subheader "Web Browser"

    if command -v google-chrome >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
        log_info "Chrome/Chromium already installed"
    else
        case "$PKG_MANAGER" in
            apt)
                if confirm_no "Install Google Chrome?"; then
                    log_info "Installing Google Chrome..."
                    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
                    apt-get install -y /tmp/chrome.deb 2>/dev/null || dpkg -i /tmp/chrome.deb && apt-get install -f -y
                    rm /tmp/chrome.deb
                    log_success "Google Chrome installed"
                else
                    log_info "Installing Chromium..."
                    apt-get install -y chromium-browser 2>/dev/null || apt-get install -y chromium 2>/dev/null || true
                fi
                ;;
            dnf|yum)
                log_info "Installing Chromium..."
                $PKG_MANAGER install -y chromium
                log_success "Chromium installed"
                ;;
            brew)
                run_as_user "brew install --cask google-chrome"
                log_success "Google Chrome installed"
                ;;
        esac
    fi
fi

# =============================================================================
# Step 7: WSL-Specific Configuration
# =============================================================================
if [ "$IS_WSL" = true ]; then
    log_header "Step 7: WSL Configuration"

    # WSL utilities
    if [ "$PKG_MANAGER" = "apt" ]; then
        log_info "Installing WSL utilities..."
        apt-get install -y wslu 2>/dev/null || log_warn "wslu not available"
    fi

    # Configure wsl.conf
    WSL_CONF="/etc/wsl.conf"
    if [ ! -f "$WSL_CONF" ]; then
        log_info "Configuring WSL settings..."
        cat > "$WSL_CONF" <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=true

[user]
default=USER_PLACEHOLDER
EOF
        sed -i "s/USER_PLACEHOLDER/$DEV_USER/g" "$WSL_CONF"
        log_success "WSL configuration created"
        log_warn "Restart WSL for changes to take effect: wsl --shutdown"
    else
        log_info "WSL configuration already exists"
    fi

    # Create Windows shortcuts
    log_subheader "Windows Integration"

    # Add useful Windows aliases if in interactive mode
    if [ -n "$SHELL_RC" ]; then
        if ! grep -q "# WSL Windows aliases" "$SHELL_RC" 2>/dev/null; then
            log_info "Adding Windows integration aliases..."
            cat >> "$SHELL_RC" <<'EOF'

# WSL Windows aliases
alias explorer='explorer.exe'
alias code='/mnt/c/Users/*/AppData/Local/Programs/Microsoft\ VS\ Code/bin/code 2>/dev/null || code'

EOF
            chown "$DEV_USER:$DEV_USER" "$SHELL_RC"
            log_success "Windows aliases added"
        fi
    fi

    log_info "Access Windows files at: /mnt/c/"
    log_info "Access WSL files from Windows: \\\\wsl$\\Ubuntu\\"
fi

# =============================================================================
# Step 8: Development Directories
# =============================================================================
log_header "Step 8: Development Directories"

# Create standard development directories
log_info "Creating development directories..."

for dir in dev projects github workspace tmp; do
    DIR_PATH="$USER_HOME/$dir"
    if [ ! -d "$DIR_PATH" ]; then
        run_as_user "mkdir -p $DIR_PATH"
        log_success "Created: ~/$dir"
    else
        log_info "Exists: ~/$dir"
    fi
done

# =============================================================================
# Step 9: System Optimizations
# =============================================================================
log_header "Step 9: System Optimizations"

# Increase file watchers (for development tools)
if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null; then
    log_info "Increasing file watcher limits..."
    cat >> /etc/sysctl.conf <<EOF

# Development optimizations
fs.inotify.max_user_watches=524288
fs.file-max=65536
EOF
    sysctl -p >/dev/null 2>&1
    log_success "File watcher limits increased"
else
    log_info "File watcher limits already configured"
fi

# Set timezone if not configured
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    log_info "Timezone: $CURRENT_TZ"
fi

# =============================================================================
# Final Summary
# =============================================================================
log_header "Setup Complete!"

printf "${BOLD}${GREEN}Development Environment Ready!${NC}\n\n"

printf "${BOLD}System Information:${NC}\n"
printf "  Machine:      ${CYAN}%s${NC}\n" "$MACHINE_NAME"
printf "  User:         ${CYAN}%s${NC}\n" "$DEV_USER"
printf "  Architecture: ${CYAN}%s (%s)${NC}\n" "$ARCH" "$ARCH_NORMALIZED"
printf "  OS:           ${CYAN}%s %s${NC}\n" "$OS_NAME" "$OS_VERSION"
if [ "$IS_WSL2" = true ]; then
    printf "  Environment:  ${CYAN}WSL2${NC}\n"
elif [ "$IS_WSL" = true ]; then
    printf "  Environment:  ${CYAN}WSL1${NC}\n"
fi
printf "\n"

printf "${BOLD}${GREEN}Installed Components:${NC}\n"

if [ "$SKIP_DEVTOOLS" = false ]; then
    printf "  ${GREEN}✓${NC} Development tools (git, build-essential, etc.)\n"
fi

if [ "$SKIP_DOCKER" = false ] && command -v docker >/dev/null 2>&1; then
    printf "  ${GREEN}✓${NC} Docker $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')\n"
fi

if [ "$SKIP_LANGUAGES" = false ]; then
    if [ -d "$USER_HOME/.nvm" ]; then
        NODE_VER=$(run_as_user ". $USER_HOME/.nvm/nvm.sh && node --version" 2>/dev/null || echo "")
        [ -n "$NODE_VER" ] && printf "  ${GREEN}✓${NC} Node.js %s (via nvm)\n" "$NODE_VER"
    fi

    if command -v python3 >/dev/null 2>&1; then
        printf "  ${GREEN}✓${NC} Python %s\n" "$(python3 --version 2>/dev/null | cut -d' ' -f2)"
    fi

    if command -v go >/dev/null 2>&1; then
        printf "  ${GREEN}✓${NC} Go %s\n" "$(go version 2>/dev/null | cut -d' ' -f3 | tr -d 'go')"
    fi

    if command -v rustc >/dev/null 2>&1; then
        printf "  ${GREEN}✓${NC} Rust %s\n" "$(rustc --version 2>/dev/null | cut -d' ' -f2)"
    fi
fi

if [ "$SKIP_GUI" = false ] && [ "$IS_WSL" = false ]; then
    if command -v code >/dev/null 2>&1; then
        printf "  ${GREEN}✓${NC} Visual Studio Code\n"
    fi
fi

printf "\n"

# Next steps
printf "${BOLD}${YELLOW}Next Steps:${NC}\n"

STEP_NUM=1

if [ "$SKIP_DOCKER" = false ]; then
    printf "  ${GREEN}%d.${NC} Logout and login again (or run: ${CYAN}newgrp docker${NC}) for docker group to take effect\n" "$STEP_NUM"
    STEP_NUM=$((STEP_NUM + 1))
fi

printf "  ${GREEN}%d.${NC} Reload shell: ${CYAN}source ~/.bashrc${NC} (or ${CYAN}~/.zshrc${NC})\n" "$STEP_NUM"
STEP_NUM=$((STEP_NUM + 1))

if [ "$SKIP_DOCKER" = false ]; then
    printf "  ${GREEN}%d.${NC} Test Docker: ${CYAN}docker run hello-world${NC}\n" "$STEP_NUM"
    STEP_NUM=$((STEP_NUM + 1))
fi

if [ "$IS_WSL" = true ] && grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    printf "  ${GREEN}%d.${NC} Restart WSL from PowerShell: ${CYAN}wsl --shutdown${NC}\n" "$STEP_NUM"
    STEP_NUM=$((STEP_NUM + 1))
fi

printf "\n"
printf "${BOLD}${GREEN}Development directories created in:${NC}\n"
printf "  ${CYAN}~/dev${NC}\n"
printf "  ${CYAN}~/projects${NC}\n"
printf "  ${CYAN}~/github${NC}\n"
printf "  ${CYAN}~/workspace${NC}\n"
printf "\n"

log_success "Your development environment is ready to use!"
printf "\n"

exit 0
