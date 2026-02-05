#!/bin/bash

# Configuration
GH_USER="nuniesmith"
TARGET_DIR="$HOME/github"
SCRIPT_PATH="$HOME/.local/bin/gh_sync.sh"
SERVICE_NAME="github-sync"
ANDROID_HOME="$HOME/android-sdk"

# OS Detection
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ Cannot detect OS. /etc/os-release missing."
    exit 1
fi

echo "🚀 Starting Dev Environment Setup for $NAME ($OS)..."

# 1. Base Tooling & Package Manager Setup
install_base() {
    case $OS in
        ubuntu|debian)
            sudo apt update && sudo apt upgrade -y
            sudo apt install -y jq git curl wget unzip build-essential pkg-config \
            libssl-dev python3-full python3-pip openjdk-21-jdk clang cmake
            ;;
        fedora)
            sudo dnf update -y
            sudo dnf groupinstall -y "Development Tools" "C Development Tools and Libraries"
            sudo dnf install -y jq git curl wget unzip openssl-devel python3-pip \
            java-21-openjdk-devel clang cmake
            ;;
        arch)
            sudo pacman -Syu --noconfirm
            sudo pacman -S --noconfirm --needed base-devel jq git curl wget unzip \
            openssl python-pip jdk-openjdk clang cmake
            ;;
        *)
            echo "OS $OS not supported for base tools."
            exit 1
            ;;
    esac
}

# 2. Docker Engine Setup
install_docker() {
    if command -v docker &> /dev/null; then
        echo "✅ Docker already installed."
        return
    fi

    case $OS in
        ubuntu)
            sudo install -m 0755 -d /etc/apt/keyrings
            sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora)
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        arch)
            sudo pacman -S --noconfirm docker docker-compose
            ;;
    esac
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
}

# 3. Rust Installation
install_rust() {
    if ! command -v rustc &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
}

# 4. Android SDK (Headless)
install_android() {
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
        echo "Installing Android SDK tools..."
        cd /tmp
        # Using a fixed version or latest link if available
        wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
        unzip commandlinetools-linux-*.zip
        mv cmdline-tools latest
        mv latest "$ANDROID_HOME/cmdline-tools/"

        export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin"
        yes | sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-34" "build-tools;34.0.0"
    fi
}

# --- Execution ---
install_base
install_docker
install_rust
install_android

# 5. Create the Enhanced Sync + Cleanup Script
mkdir -p "$(dirname "$SCRIPT_PATH")"
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash
GH_USER="nuniesmith"
TARGET_DIR="$HOME/github"

echo "--- [$(date)] GitHub Sync Starting ---"
mkdir -p "$TARGET_DIR" && cd "$TARGET_DIR" || exit

REPO_DATA=$(curl -s "https://api.github.com/users/$GH_USER/repos?per_page=100" | jq -r '.[] | "\(.name)|\(.clone_url)"')
ACTIVE_REPOS=$(echo "$REPO_DATA" | cut -d'|' -f1)

# Cleanup
for local_dir in */; do
    [ -d "$local_dir" ] || continue
    dir_name="${local_dir%/}"
    if ! echo "$ACTIVE_REPOS" | grep -qx "$dir_name"; then
        echo "Cleanup: Removing $dir_name"
        rm -rf "$dir_name"
    fi
done

# Pull or Clone
while IFS='|' read -r REPO_NAME REPO_URL; do
    if [ -n "$REPO_NAME" ]; then
        if [ -d "$REPO_NAME" ]; then
            git -C "$REPO_NAME" pull --ff-only
        else
            git clone "$REPO_URL"
        fi
    fi
done <<< "$REPO_DATA"

echo "--- [$(date)] Docker Maintenance ---"
docker system prune -af --filter "until=168h"
docker volume prune -f
EOF

chmod +x "$SCRIPT_PATH"

# 6. Systemd Service & Timer (Same for all distros)
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null << EOF
[Unit]
Description=Sync GitHub and Cleanup Docker
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
User=$USER
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/$USER/.cargo/bin"

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/$SERVICE_NAME.timer > /dev/null << EOF
[Unit]
Description=Hourly GitHub and Docker Maintenance

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now $SERVICE_NAME.timer

# 7. Environment Variables
SHELL_RC="$HOME/.bashrc"
[[ $SHELL == *"zsh"* ]] && SHELL_RC="$HOME/.zshrc"

if ! grep -q "ANDROID_HOME" "$SHELL_RC"; then
    {
        echo "export ANDROID_HOME=$ANDROID_HOME"
        echo "export PATH=\$PATH:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin"
        echo "source \$HOME/.cargo/env"
    } >> "$SHELL_RC"
fi

echo "✅ ALL DONE!"
echo "Please restart your terminal or log out/in to apply changes."
