#!/usr/bin/env bash
# =============================================================================
# setup-macbook.sh — Arch Linux on MacBook Pro 11,1
# =============================================================================
# PHASE 1  (live CD, run as root)
#   • Partitions /dev/sda — GPT, 512 MiB EFI + Btrfs root
#   • Btrfs subvolumes: @  @home  @var  @log  @pkg  @snapshots
#   • Installs base system via pacstrap
#   • Configures GRUB (EFI, --removable for Apple)
#   • Embeds Phase 2 onto the new system as a first-boot systemd service
#   • Embeds GitHub sync as a systemd timer (always-on)
#
# PHASE 2  (first boot, runs automatically as a systemd one-shot service)
#   • Installs yay (AUR helper)
#   • Broadcom BCM4360 driver  (broadcom-wl-dkms)
#   • Sway desktop  (slim Wayland WM, ~60 MB idle — ideal for 4 GB RAM)
#   • Zed IDE + dev fonts
#   • Rust / Go / Node (fnm) / Python (uv) / .NET / Android SDK
#   • Docker + docker-compose
#   • Configures Zed, shell aliases, TLP battery tuning
#   • Disables itself after completion  (never runs again)
#
# GITHUB SYNC  (systemd timer, hourly after boot)
#   • Clones / pulls all public repos for nuniesmith into ~/github
#   • Prunes stale repos
#   • Docker system prune (>7 d)
#
# Usage (from Arch live CD):
#   bash setup-macbook.sh [OPTIONS]
#
# Options:
#   --no-confirm        Skip all prompts  (for Ventoy / automation)
#   --skip-gui          Skip Sway + Zed
#   --skip-dev          Skip language runtimes + dev tools
#   --skip-sync         Skip GitHub sync service setup
#   --user NAME         System username  (default: jordan)
#   --hostname NAME     Hostname         (default: macbook)
#   --help              Show this help
#
# =============================================================================
set -euo pipefail

# ── Script meta ───────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup/setup-macbook.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
DISK="/dev/sda"
USERNAME="jordan"
HOSTNAME_VAL="macbook"
TIMEZONE="America/Toronto"
LOCALE="en_CA.UTF-8"
GH_USER="nuniesmith"

NO_CONFIRM=false
SKIP_GUI=false
SKIP_DEV=false
SKIP_SYNC=false

# Btrfs
BTRFS_OPTS="noatime,compress=zstd:1,discard=async,space_cache=v2,autodefrag"
SUBVOLS=("@" "@home" "@var" "@log" "@pkg" "@snapshots")

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' NC='\033[0m' BOLD='\033[1m'
info()    { echo -e "${B}[INFO]${NC}  $*"; }
ok()      { echo -e "${G}[OK]${NC}    $*"; }
warn()    { echo -e "${Y}[WARN]${NC}  $*"; }
die()     { echo -e "${R}[ERR]${NC}   $*"; exit 1; }
header()  { echo -e "\n${C}${BOLD}━━━━━  $*  ━━━━━${NC}\n"; }
step()    { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-confirm)  NO_CONFIRM=true;         shift ;;
        --skip-gui)    SKIP_GUI=true;            shift ;;
        --skip-dev)    SKIP_DEV=true;            shift ;;
        --skip-sync)   SKIP_SYNC=true;           shift ;;
        --user)        USERNAME="$2";            shift 2 ;;
        --hostname)    HOSTNAME_VAL="$2";        shift 2 ;;
        --disk)        DISK="$2";               shift 2 ;;
        --help|-h)
            sed -n '/^# Usage/,/^# ===/p' "$0" | head -40
            exit 0 ;;
        *) die "Unknown option: $1 — use --help" ;;
    esac
done

confirm() {
    [[ "$NO_CONFIRM" == "true" ]] && return 0
    read -rp "$1 (Y/n) " r
    [[ "${r,,}" == "n" || "${r,,}" == "no" ]] && return 1 || return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 1 — Live CD Installation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
phase1_install() {

header "Arch Linux — MacBook Pro 11,1 — v${SCRIPT_VERSION}"
echo -e "  User: ${BOLD}${USERNAME}${NC}  |  Host: ${BOLD}${HOSTNAME_VAL}${NC}  |  Disk: ${BOLD}${DISK}${NC}"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"
ping -c1 -W3 archlinux.org &>/dev/null || die "No internet — use USB ethernet or phone USB tethering"
[[ -b "$DISK" ]] || die "Disk $DISK not found (check lsblk)"

# ── Passwords ─────────────────────────────────────────────────────────────────
if [[ "$NO_CONFIRM" == "true" ]]; then
    ROOT_PASS="changeme123"
    USER_PASS="changeme123"
    warn "Using placeholder passwords — CHANGE THEM after first login!"
else
    echo ""
    read -rsp "Root password: "       ROOT_PASS; echo
    read -rsp "Password for ${USERNAME}: " USER_PASS; echo
fi

# ── Confirm wipe ──────────────────────────────────────────────────────────────
echo ""
warn "This will WIPE ALL DATA on ${DISK}:"
lsblk "$DISK"
echo ""
confirm "Proceed?" || { info "Aborted."; exit 0; }

# ── Clock ─────────────────────────────────────────────────────────────────────
header "Sync clock"
timedatectl set-ntp true
ok "NTP enabled"

# ── Partition ─────────────────────────────────────────────────────────────────
header "Partitioning"

parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP  fat32   1MiB  513MiB \
    set 1 esp on \
    mkpart root btrfs 513MiB 100%

sleep 1; partprobe "$DISK"

EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
ok "EFI: ${EFI_PART}  |  Root: ${ROOT_PART}"

# ── Format ────────────────────────────────────────────────────────────────────
header "Formatting"
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.btrfs -f -L archlinux "$ROOT_PART"
ok "EFI = FAT32  |  Root = Btrfs"

# ── Btrfs subvolumes ──────────────────────────────────────────────────────────
header "Btrfs subvolumes"
mount "$ROOT_PART" /mnt
for sv in "${SUBVOLS[@]}"; do
    btrfs subvolume create "/mnt/${sv}"
    ok "Created: ${sv}"
done
umount /mnt

# ── Mount ─────────────────────────────────────────────────────────────────────
header "Mounting"
mount -o "${BTRFS_OPTS},subvol=@"          "$ROOT_PART" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home"      "$ROOT_PART" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"       "$ROOT_PART" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@pkg"       "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi
ok "All filesystems mounted"

# ── pacstrap ──────────────────────────────────────────────────────────────────
header "pacstrap — base system"

pacstrap -K /mnt \
    base base-devel linux linux-headers linux-firmware \
    grub efibootmgr \
    btrfs-progs \
    networkmanager iwd dhcpcd \
    openssh sudo git curl wget \
    vim nano zsh zsh-completions \
    htop btop tree fd ripgrep bat eza fzf \
    cmake ninja meson \
    python python-pip python-pipx \
    go nodejs npm \
    dotnet-sdk rustup \
    dkms linux-headers \
    thermald tlp \
    lm_sensors man-db \
    ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji \
    jq reflector \
    xdg-user-dirs \
    pipewire pipewire-pulse wireplumber \
    alsa-utils

ok "Base system installed"

# ── fstab ─────────────────────────────────────────────────────────────────────
genfstab -U /mnt >> /mnt/etc/fstab
ok "fstab written"

# ── Write embedded scripts to new system before chroot ────────────────────────
header "Embedding first-boot and sync scripts"

# first-boot-setup.sh is written here as a heredoc
mkdir -p /mnt/usr/local/bin

# ── Embed: first-boot-setup.sh ────────────────────────────────────────────────
cat > /mnt/usr/local/bin/first-boot-setup.sh << 'FIRSTBOOT'
#!/usr/bin/env bash
# =============================================================================
# first-boot-setup.sh — Phase 2
# Runs ONCE on first boot via systemd. Disables itself when done.
# =============================================================================
set -euo pipefail

LOG="/var/log/first-boot-setup.log"
exec > >(tee -a "$LOG") 2>&1

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' NC='\033[0m'
info()   { echo -e "${B}[INFO]${NC}  $*"; }
ok()     { echo -e "${G}[OK]${NC}    $*"; }
warn()   { echo -e "${Y}[WARN]${NC}  $*"; }
header() { echo -e "\n${C}━━━  $*  ━━━${NC}\n"; }

USERNAME="jordan"
USER_HOME="/home/${USERNAME}"

header "First Boot Setup — $(date)"

# ── Wait for network ──────────────────────────────────────────────────────────
info "Waiting for network..."
for i in $(seq 1 30); do
    ping -c1 -W2 8.8.8.8 &>/dev/null && break
    sleep 2
done
ping -c1 -W2 8.8.8.8 &>/dev/null || { warn "No internet after 60s — aborting"; exit 1; }
ok "Network OK"

# ── Reflector: fast mirrors ───────────────────────────────────────────────────
header "Updating mirrors"
reflector --country Canada,US --age 12 --protocol https --sort rate \
    --save /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm
ok "Mirrors updated"

# ── Install yay (AUR helper) ──────────────────────────────────────────────────
header "Installing yay"

# Temporarily allow passwordless sudo for AUR builds
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/firstboot_temp

if ! command -v yay &>/dev/null; then
    sudo -u "$USERNAME" -H bash -c '
        cd /tmp
        rm -rf yay
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
        cd /tmp && rm -rf yay
    '
    ok "yay installed"
else
    ok "yay already present"
fi

# ── Broadcom BCM4360 driver ───────────────────────────────────────────────────
header "Broadcom BCM4360 (broadcom-wl-dkms)"

sudo -u "$USERNAME" -H bash -c 'yay -S --noconfirm broadcom-wl-dkms'

# Blacklist conflicting modules
cat > /etc/modprobe.d/broadcom-wl.conf << 'MOD'
blacklist b43
blacklist b43legacy
blacklist bcm43xx
blacklist brcm80211
blacklist brcmfmac
blacklist brcmsmac
blacklist ssb
MOD

echo "wl" > /etc/modules-load.d/broadcom-wl.conf
modprobe wl 2>/dev/null || true
ok "BCM4360 driver installed and loaded"

# ── Sway desktop stack (slim — ~60 MB idle) ───────────────────────────────────
header "Sway desktop (Wayland, slim for 4 GB RAM)"

pacman -S --noconfirm \
    sway swaybar swaybg swayidle swaylock \
    waybar \
    wofi \
    foot \
    mako \
    grim slurp wl-clipboard \
    xorg-xwayland \
    qt5-wayland qt6-wayland \
    polkit polkit-gnome \
    brightnessctl \
    thunar gvfs tumbler \
    imv mpv \
    firefox

ok "Sway stack installed"

# Sway config for the user
mkdir -p "${USER_HOME}/.config/sway"
cat > "${USER_HOME}/.config/sway/config" << 'SWAYCONF'
# ── Sway config — MacBook Pro 11,1 ───────────────────────────────────────────
set $mod Mod4
set $term foot
set $menu wofi --show drun

# Retina display (2560×1600) — 1.5x scaling feels right
output * scale 1.5

# Background
output * bg #1a1b26 solid_color

# Font
font pango:JetBrainsMono Nerd Font 10

# Key bindings
bindsym $mod+Return exec $term
bindsym $mod+d      exec $menu
bindsym $mod+q      kill
bindsym $mod+Shift+r reload
bindsym $mod+Shift+e exec swaymsg exit

# Focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Layout
bindsym $mod+b layout splith
bindsym $mod+v layout splitv
bindsym $mod+f fullscreen
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Workspaces
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5

# Screenshots
bindsym Print exec grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png
bindsym $mod+Print exec grim -g "$(slurp)" ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png

# Volume (Apple keyboard)
bindsym XF86AudioRaiseVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym XF86AudioLowerVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym XF86AudioMute        exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

# Brightness (Apple keyboard)
bindsym XF86MonBrightnessUp   exec brightnessctl set 5%+
bindsym XF86MonBrightnessDown exec brightnessctl set 5%-

# Status bar
bar {
    swaybar_command waybar
}

# Gaps
gaps inner 6
gaps outer 4
default_border pixel 2

# Colors (Tokyo Night-ish)
client.focused          #7aa2f7 #1a1b26 #c0caf5 #7aa2f7 #7aa2f7
client.unfocused        #414868 #1a1b26 #565f89 #414868 #414868

# Startup
exec polkit-gnome-authentication-agent-1
exec mako
exec --no-startup-id wl-paste --watch cliphist store
SWAYCONF

# waybar minimal config
mkdir -p "${USER_HOME}/.config/waybar"
cat > "${USER_HOME}/.config/waybar/config.jsonc" << 'WAYBAR'
{
    "layer": "top",
    "position": "top",
    "height": 28,
    "modules-left":   ["sway/workspaces", "sway/mode"],
    "modules-center": ["clock"],
    "modules-right":  ["network", "memory", "cpu", "battery", "pulseaudio", "tray"],
    "sway/workspaces": { "disable-scroll": true },
    "clock": { "format": "{:%a %b %d  %H:%M}" },
    "cpu":    { "format": " {usage}%", "interval": 5 },
    "memory": { "format": " {used:0.1f}G", "interval": 10 },
    "battery": {
        "format": "{icon} {capacity}%",
        "format-icons": ["", "", "", "", ""],
        "states": { "warning": 30, "critical": 15 }
    },
    "network": {
        "format-wifi":         " {essid}",
        "format-disconnected": "⚠ Disconnected",
        "tooltip-format":      "{ifname}: {ipaddr}"
    },
    "pulseaudio": { "format": " {volume}%", "on-click": "pavucontrol" },
    "tray": { "spacing": 10 }
}
WAYBAR

cat > "${USER_HOME}/.config/waybar/style.css" << 'CSS'
* { font-family: "JetBrainsMono Nerd Font"; font-size: 12px; }
window#waybar { background: #1a1b26; color: #c0caf5; border-bottom: 1px solid #414868; }
#workspaces button { padding: 0 8px; color: #565f89; }
#workspaces button.focused { color: #7aa2f7; border-bottom: 2px solid #7aa2f7; }
#clock, #cpu, #memory, #battery, #network, #pulseaudio { padding: 0 10px; }
#battery.warning { color: #e0af68; }
#battery.critical { color: #f7768e; }
CSS

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/.config"
ok "Sway configured"

# ── Zed IDE ───────────────────────────────────────────────────────────────────
header "Zed IDE"

sudo -u "$USERNAME" -H bash -c 'yay -S --noconfirm zed'

mkdir -p "${USER_HOME}/.config/zed"
cat > "${USER_HOME}/.config/zed/settings.json" << 'ZED'
{
  "theme": "One Dark",
  "ui_font_size": 15,
  "buffer_font_family": "JetBrainsMono Nerd Font",
  "buffer_font_size": 13,
  "buffer_font_features": { "calt": true },
  "tab_size": 2,
  "soft_wrap": "editor_width",
  "autosave": "on_focus_change",
  "format_on_save": "on",
  "inlay_hints": { "enabled": true },
  "git": { "inline_blame": { "enabled": true } },
  "terminal": {
    "font_family": "JetBrainsMono Nerd Font",
    "font_size": 13,
    "shell": { "program": "/bin/zsh" }
  },
  "lsp": {
    "rust-analyzer": {
      "initialization_options": {
        "check": { "command": "clippy" },
        "inlayHints": {
          "parameterHints": { "enable": true },
          "typeHints":      { "enable": true }
        }
      }
    }
  },
  "languages": {
    "Rust":   { "tab_size": 4, "format_on_save": "on" },
    "Go":     { "tab_size": 4, "format_on_save": "on" },
    "Python": { "tab_size": 4, "format_on_save": "on" }
  }
}
ZED

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/.config/zed"
ok "Zed configured"

# ── Dev tools ─────────────────────────────────────────────────────────────────
header "Dev tools (AUR + pacman)"

AUR_PKGS=(
    fnm-bin
    uv
    lazygit
    just
    mold
    sccache
    zellij
    ttf-cascadia-code-nerd
    android-sdk
    android-sdk-platform-tools
    android-sdk-build-tools
    github-cli
)

sudo -u "$USERNAME" -H bash -c "yay -S --noconfirm ${AUR_PKGS[*]}"
ok "AUR packages installed"

# ── Rust ──────────────────────────────────────────────────────────────────────
header "Rust toolchain"

sudo -u "$USERNAME" -H bash -c '
    rustup default stable
    rustup component add rust-analyzer clippy rustfmt
    rustup target add x86_64-unknown-linux-musl

    mkdir -p ~/.cargo
    cat >> ~/.cargo/config.toml << CARGO
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
[build]
jobs = 4
incremental = true
CARGO
'
ok "Rust configured"

# ── Go tools ──────────────────────────────────────────────────────────────────
header "Go tools"
sudo -u "$USERNAME" -H bash -c '
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    go install golang.org/x/tools/gopls@latest
    go install github.com/go-delve/delve/cmd/dlv@latest
'
ok "Go LSP + debugger installed"

# ── Node via fnm ──────────────────────────────────────────────────────────────
header "Node.js"
sudo -u "$USERNAME" -H bash -c '
    export PATH=$HOME/.local/bin:$PATH
    eval "$(fnm env)"
    fnm install --lts
    fnm use lts-latest
    fnm default lts-latest
    npm install -g typescript ts-node prettier eslint yarn pnpm
'
ok "Node LTS installed"

# ── Docker ────────────────────────────────────────────────────────────────────
header "Docker"
pacman -S --noconfirm docker docker-compose docker-buildx
systemctl enable --now docker
usermod -aG docker "$USERNAME"

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKERD'
{
  "log-driver":    "json-file",
  "log-opts":      { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "features":      { "buildkit": true }
}
DOCKERD
systemctl restart docker
ok "Docker installed"

# ── Android SDK ───────────────────────────────────────────────────────────────
header "Android SDK"
if [[ -d /opt/android-sdk ]]; then
    yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses 2>/dev/null || true
    /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager \
        "platform-tools" "platforms;android-35" "build-tools;35.0.0" \
        2>/dev/null || warn "SDK manager failed — run manually"
fi

# ── Zsh config ────────────────────────────────────────────────────────────────
header "Zsh config"

pacman -S --noconfirm zsh-syntax-highlighting zsh-autosuggestions

cat >> "${USER_HOME}/.zshrc" << 'ZSH'

# Plugins
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# PATH
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"
export ANDROID_HOME="/opt/android-sdk"
export PATH="$PATH:$ANDROID_HOME/platform-tools"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# fnm
eval "$(fnm env --use-on-cd --shell zsh)"

# Aliases
alias ls='eza --icons'
alias ll='eza -la --icons --git'
alias lt='eza --tree --icons --level=2'
alias cat='bat'
alias grep='rg'
alias find='fd'
alias top='btop'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias gs='git status'
alias gl='lazygit'
alias dev='cd ~/dev'
alias py='python3'

# Auto-start zellij in SSH sessions
if [[ -n "$SSH_CONNECTION" ]] && [[ -z "$ZELLIJ" ]]; then
    exec zellij attach --create main
fi
ZSH

chown "$USERNAME:$USERNAME" "${USER_HOME}/.zshrc"
chsh -s /bin/zsh "$USERNAME"
ok "Zsh configured"

# ── TLP / kernel tuning ───────────────────────────────────────────────────────
header "TLP battery + kernel tuning"

cat > /etc/tlp.d/01-macbook.conf << 'TLP'
START_CHARGE_THRESH_BAT0=40
STOP_CHARGE_THRESH_BAT0=80
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
PCIE_ASPM_ON_BAT=powersupersave
TLP

cat > /etc/sysctl.d/99-macbook.conf << 'SYSCTL'
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=256
SYSCTL

systemctl enable tlp
sysctl --system &>/dev/null || true
ok "TLP + sysctl applied"

# ── Enable GitHub sync timer ───────────────────────────────────────────────────
systemctl enable --now github-sync.timer && ok "GitHub sync timer enabled" || \
    warn "github-sync.timer not found — skipped"

# ── Remove temp sudo rule ──────────────────────────────────────────────────────
rm -f /etc/sudoers.d/firstboot_temp

# ── DONE — disable this service ───────────────────────────────────────────────
rm -f /etc/first-boot-pending
systemctl disable first-boot-setup.service

header "First Boot Setup COMPLETE — $(date)"
info "Log: ${LOG}"
info "Reboot recommended for all drivers to activate."
FIRSTBOOT

chmod +x /mnt/usr/local/bin/first-boot-setup.sh
ok "first-boot-setup.sh embedded"

# ── Embed: gh_sync.sh ─────────────────────────────────────────────────────────
cat > /mnt/usr/local/bin/gh_sync.sh << SYNCEOF
#!/usr/bin/env bash
# GitHub repo sync — ${GH_USER} (all public repos) + Docker prune
set -euo pipefail

GH_USER="${GH_USER}"
TARGET_DIR="\$HOME/github"
LOG_TAG="gh_sync"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [\$LOG_TAG] \$*"; }

log "--- Sync starting ---"
mkdir -p "\$TARGET_DIR"
cd "\$TARGET_DIR"

log "Fetching repo list for \$GH_USER..."
REPO_DATA=""
PAGE=1
while true; do
    PAGE_DATA=\$(curl -sf \\
        -H "Accept: application/vnd.github.v3+json" \\
        "https://api.github.com/users/\$GH_USER/repos?per_page=100&page=\$PAGE&type=public" \\
        | jq -r '.[] | "\(.name)|\(.clone_url)"')
    [ -z "\$PAGE_DATA" ] && break
    REPO_DATA="\${REPO_DATA}\${PAGE_DATA}\$'\\n'"
    PAGE=\$((PAGE + 1))
done

if [ -z "\$REPO_DATA" ]; then
    log "ERROR: Failed to fetch repo list — check network / GitHub API rate limit"
    exit 1
fi

ACTIVE_REPOS=\$(echo "\$REPO_DATA" | cut -d'|' -f1 | sort)
REPO_COUNT=\$(echo "\$ACTIVE_REPOS" | grep -c . || echo 0)
log "Found \${REPO_COUNT} repos"

# Remove stale local dirs
for local_dir in */; do
    [ -d "\$local_dir" ] || continue
    dir_name="\${local_dir%/}"
    if ! echo "\$ACTIVE_REPOS" | grep -qx "\$dir_name"; then
        log "Removing stale: \$dir_name"
        rm -rf "\$dir_name"
    fi
done

CLONED=0; PULLED=0; FAILED=0
while IFS='|' read -r REPO_NAME REPO_URL; do
    [ -z "\$REPO_NAME" ] && continue
    if [ -d "\$REPO_NAME/.git" ]; then
        if git -C "\$REPO_NAME" pull --ff-only --quiet 2>/dev/null; then
            PULLED=\$((PULLED + 1))
        else
            log "WARN: ff-only pull failed for \$REPO_NAME — skipping"
            FAILED=\$((FAILED + 1))
        fi
    else
        if git clone --quiet "\$REPO_URL" 2>/dev/null; then
            log "Cloned: \$REPO_NAME"
            CLONED=\$((CLONED + 1))
        else
            log "ERROR: Failed to clone \$REPO_NAME"
            FAILED=\$((FAILED + 1))
        fi
    fi
done <<< "\$REPO_DATA"

log "Sync complete — cloned=\$CLONED pulled=\$PULLED failed=\$FAILED"

# Docker prune (images/containers older than 7 days)
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    log "Docker prune (>7d)..."
    docker system prune -af --filter "until=168h" --quiet 2>/dev/null || true
    docker volume prune -f --quiet 2>/dev/null || true
    log "Docker prune done"
fi

log "--- Done ---"
SYNCEOF

chmod +x /mnt/usr/local/bin/gh_sync.sh
ok "gh_sync.sh embedded"

# ── Chroot configuration ───────────────────────────────────────────────────────
header "Chroot — system configuration"

arch-chroot /mnt /bin/bash << CHROOT
set -euo pipefail

# Timezone + clock
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Keymap
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME_VAL}" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}
HOSTS

# mkinitcpio — add btrfs
sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB — Apple needs --removable
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id=GRUB --removable
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"/' \
    /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Users
echo "root:${ROOT_PASS}" | chpasswd
useradd -m -G wheel,audio,video,optical,storage -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Core services
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable fstrim.timer

# SSH hardening
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/'    /etc/ssh/sshd_config

# ── First-boot systemd service ────────────────────────────────────────────────
touch /etc/first-boot-pending

cat > /etc/systemd/system/first-boot-setup.service << UNIT
[Unit]
Description=Arch MacBook First-Boot Post-Install
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/first-boot-pending

[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-setup.sh
RemainAfterExit=yes
User=root
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable first-boot-setup.service

# ── GitHub sync service + timer ───────────────────────────────────────────────
cat > /etc/systemd/system/github-sync.service << SVCUNIT
[Unit]
Description=Sync ${GH_USER} GitHub repos + Docker prune
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gh_sync.sh
User=${USERNAME}
Environment=HOME=/home/${USERNAME}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCUNIT

cat > /etc/systemd/system/github-sync.timer << TMRUNIT
[Unit]
Description=Hourly GitHub sync and Docker maintenance

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMRUNIT

systemctl enable github-sync.timer

# ── dev dirs ──────────────────────────────────────────────────────────────────
for d in dev projects github workspace; do
    sudo -u "${USERNAME}" mkdir -p "/home/${USERNAME}/\$d"
done

echo ""
echo "Chroot configuration complete."
CHROOT

ok "Chroot done"

# ── Unmount ───────────────────────────────────────────────────────────────────
header "Unmounting"
umount -R /mnt
ok "All filesystems unmounted"

# ── Done ──────────────────────────────────────────────────────────────────────
header "Phase 1 Complete!"
echo ""
echo -e "  ${G}Next steps:${NC}"
echo -e "  1. Remove live USB / Ventoy drive"
echo -e "  2. ${Y}reboot${NC}"
echo -e "  3. Login as ${BOLD}${USERNAME}${NC}"
echo -e "  4. First-boot service will run automatically in the background"
echo -e "     Monitor: ${C}journalctl -fu first-boot-setup.service${NC}"
echo -e "  5. WiFi (BCM4360) will work after the first-boot service completes"
echo -e "     (you'll need USB ethernet for the first boot or it will wait)"
echo ""
echo -e "  ${B}GitHub sync:${NC} repos in ~/github, running hourly"
echo -e "     Logs: ${C}journalctl -u github-sync.service${NC}"
echo ""

}  # end phase1_install

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Entry point — detect phase
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Detect if we're running in a live CD (archiso) or a real install
if grep -q "archiso" /proc/cmdline 2>/dev/null || \
   [[ "$(uname -n)" == "archiso" ]] || \
   [[ -f /run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux ]]; then
    phase1_install
else
    # Running on installed system — this shouldn't happen interactively
    # (first-boot-setup.sh runs via systemd), but allow manual trigger
    echo -e "\n\033[0;33m[WARN]\033[0m This script's Phase 2 is designed to run via the"
    echo -e "       'first-boot-setup' systemd service on first boot."
    echo -e "\n       To check status: journalctl -fu first-boot-setup.service"
    echo -e "       To re-run:        sudo systemctl start first-boot-setup.service"
fi
