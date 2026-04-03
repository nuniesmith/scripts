#!/usr/bin/env bash
# =============================================================================
# setup-desktop.sh — Workstation / GUI Desktop Setup
# =============================================================================
# Targets: Ubuntu 24.04 / 25.10 (GNOME) — or Arch Linux (Sway/Hyprland)
# Distro is auto-detected; the correct base library is sourced automatically.
#
# Ubuntu installs:
#   GNOME tweaks + extensions + fonts + Zed IDE + full dev toolchain
#   Docker · Rust · Node · Python · Go
#
# Arch installs (non-MacBook, generic hardware):
#   Hyprland or Sway (choose at runtime) + Waybar + Rofi
#   Zed IDE · dev toolchain via yay · fonts + themes
#
# Usage:
#   sudo ./setup-desktop.sh [OPTIONS]
#
# Options:
#   -u, --user NAME         Target user (default: current sudo user)
#       --wm NAME           Window manager: hyprland | sway | gnome (Arch only)
#       --skip-dev          Skip language runtimes
#       --skip-docker       Skip Docker
#       --skip-gui          Skip GUI apps (Zed, fonts, themes)
#       --no-confirm        Non-interactive
#   -h, --help              Show this help
# =============================================================================
set -euo pipefail

# =============================================================================
# Detect distro and source the correct base library
# =============================================================================
REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"

_detect_and_source_base() {
    local _id="unknown"
    [ -f /etc/os-release ] && { . /etc/os-release; _id="${ID:-unknown}"; }

    case "$_id" in
        ubuntu|debian|linuxmint|pop)
            DISTRO_FAMILY="ubuntu"
            local _lib; _lib="$(dirname "${BASH_SOURCE[0]:-$0}")/setup-ubuntu.sh"
            if [ -f "$_lib" ]; then . "$_lib"
            else
                local _t; _t=$(mktemp /tmp/setup-ubuntu.XXXXXX.sh)
                curl -fsSL "${REPO_RAW}/setup-ubuntu.sh" -o "$_t"
                . "$_t"; rm -f "$_t"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            DISTRO_FAMILY="arch"
            local _lib; _lib="$(dirname "${BASH_SOURCE[0]:-$0}")/setup-arch.sh"
            if [ -f "$_lib" ]; then . "$_lib"
            else
                local _t; _t=$(mktemp /tmp/setup-arch.XXXXXX.sh)
                curl -fsSL "${REPO_RAW}/setup-arch.sh" -o "$_t"
                . "$_t"; rm -f "$_t"
            fi
            ;;
        *)
            printf "\033[0;31m[ERROR]\033[0m  Unsupported distro: %s\n" "$_id" >&2
            printf "        Supported: Ubuntu/Debian family  or  Arch family\n" >&2
            exit 1
            ;;
    esac
}

_detect_and_source_base

# =============================================================================
# Defaults
# =============================================================================
DEV_USER="${SUDO_USER:-${USER}}"
USERNAME="$DEV_USER"
WM_CHOICE=""
SKIP_DEV=false
SKIP_DOCKER=false
SKIP_GUI=false
NO_CONFIRM=false

GH_USER="nuniesmith"
NVM_VERSION="v0.40.4"
PYTHON_VERSION="3.13"
GO_VERSION=""

# =============================================================================
# Help
# =============================================================================
show_help() {
    cat << 'EOF'
setup-desktop.sh — Workstation / GUI Desktop
============================================

USAGE:
    sudo ./setup-desktop.sh [OPTIONS]

OPTIONS:
    -u, --user NAME     Target user (default: current sudo user)
        --wm NAME       Window manager: hyprland | sway | gnome (Arch only)
        --skip-dev      Skip language runtimes (Rust, Node, Python, Go)
        --skip-docker   Skip Docker
        --skip-gui      Skip GUI apps (Zed, fonts, themes)
        --no-confirm    Non-interactive
    -h, --help          Show this help

UBUNTU installs:
    GNOME + tweaks + fonts · Zed IDE · full dev toolchain · Docker

ARCH installs:
    Hyprland or Sway + Waybar + Rofi + Zed IDE · dev toolchain · Docker
EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user)      DEV_USER="$2"; USERNAME="$2"; shift 2 ;;
        --wm)           WM_CHOICE="$2";  shift 2 ;;
        --skip-dev)     SKIP_DEV=true;   shift ;;
        --skip-docker)  SKIP_DOCKER=true; shift ;;
        --skip-gui)     SKIP_GUI=true;   shift ;;
        --no-confirm)   NO_CONFIRM=true; shift ;;
        -h|--help)      show_help ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Shared preflight
# =============================================================================
lib_require_root
lib_detect_system

USER_HOME=$(eval echo "~${DEV_USER}")

# =============================================================================
# ── Ubuntu Desktop ────────────────────────────────────────────────────────────
# =============================================================================
setup_ubuntu_desktop() {
    lib_require_apt

    lib_show_banner "Desktop Setup — Ubuntu GNOME"

    lib_confirm "Install Ubuntu desktop environment on $HOSTNAME_VAL?" || exit 0

    # ── Step 1: System update ────────────────────────────────────────────────
    log_header "Step 1: System Update"
    lib_apt_update

    # ── Step 2: Core tools ───────────────────────────────────────────────────
    log_header "Step 2: Core Tools"
    lib_install_base_packages
    lib_setup_git_config

    # ── Step 3: GUI packages ─────────────────────────────────────────────────
    log_header "Step 3: GNOME & Desktop Packages"
    if [ "$SKIP_GUI" = false ]; then
        lib_apt_install \
            gnome-tweaks \
            gnome-shell-extensions \
            gnome-shell-extension-manager \
            dconf-editor \
            gthumb \
            eog \
            nautilus \
            vlc \
            flameshot \
            xdg-utils \
            xdg-user-dirs \
            pipewire pipewire-pulse wireplumber \
            alsa-utils

        # Fonts
        lib_apt_install \
            fonts-jetbrains-mono \
            fonts-firacode \
            fonts-noto-color-emoji \
            fonts-noto \
            2>/dev/null || true

        # Update font cache
        fc-cache -f 2>/dev/null || true
        log_success "Fonts installed + cache refreshed"

        # GNOME settings (dconf)
        lib_run_as_user "gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 11'"          2>/dev/null || true
        lib_run_as_user "gsettings set org.gnome.desktop.interface clock-show-seconds true"                           2>/dev/null || true
        lib_run_as_user "gsettings set org.gnome.desktop.interface show-battery-percentage true"                      2>/dev/null || true
        lib_run_as_user "gsettings set org.gnome.desktop.privacy remember-recent-files false"                         2>/dev/null || true
        lib_run_as_user "gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'" 2>/dev/null || true
        log_success "GNOME settings applied"

        # ── Zed IDE ─────────────────────────────────────────────────────────
        log_subheader "Zed IDE"
        if ! command -v zed >/dev/null 2>&1; then
            lib_run_as_user "curl -fsSL https://zed.dev/install.sh | sh"
            log_success "Zed IDE installed"
        else
            log_info "Zed already installed"
        fi
    else
        log_skip "GUI packages skipped"
    fi

    # ── Step 4: Docker ───────────────────────────────────────────────────────
    log_header "Step 4: Docker"
    if [ "$SKIP_DOCKER" = false ]; then
        lib_install_docker
    else
        log_skip "Docker skipped"
    fi

    # ── Step 5: Language runtimes ────────────────────────────────────────────
    log_header "Step 5: Language Runtimes"
    if [ "$SKIP_DEV" = false ]; then
        lib_install_rust
        lib_install_node "$NVM_VERSION"
        lib_install_python "$PYTHON_VERSION"
        lib_install_go "$GO_VERSION"
    else
        log_skip "Language runtimes skipped"
    fi

    # ── Step 6: sysctl ───────────────────────────────────────────────────────
    log_header "Step 6: System Tuning"
    lib_setup_sysctl "desktop" \
"# Desktop workstation tuning
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 256
fs.file-max                   = 65536"

    # ── Step 7: Directories ──────────────────────────────────────────────────
    log_header "Step 7: Dev Directories"
    lib_setup_directories dev projects github workspace downloads

    # ── Step 8: GitHub sync ──────────────────────────────────────────────────
    log_header "Step 8: GitHub Sync"
    lib_setup_github_sync

    log_header "Ubuntu Desktop Ready!"
    printf "  ${GREEN}✓${NC} GNOME tweaks + fonts\n"
    [ "$SKIP_GUI"    = false ] && printf "  ${GREEN}✓${NC} Zed IDE\n"
    [ "$SKIP_DOCKER" = false ] && printf "  ${GREEN}✓${NC} Docker\n"
    [ "$SKIP_DEV"    = false ] && printf "  ${GREEN}✓${NC} Rust · Node · Python %s · Go\n" "$PYTHON_VERSION"
    printf "  ${GREEN}✓${NC} GitHub sync timer\n\n"
    log_success "Done — enjoy your desktop, Jordan!"
}

# =============================================================================
# ── Arch Desktop ─────────────────────────────────────────────────────────────
# =============================================================================
setup_arch_desktop() {
    lib_require_pacman

    # Choose WM interactively if not set
    if [ -z "$WM_CHOICE" ] && [ "$NO_CONFIRM" = false ]; then
        printf "\n  ${BOLD}Select a window manager:${NC}\n"
        printf "  ${CYAN}1)${NC} Hyprland  ${DIM}(modern Wayland compositor, animations, tiling)${NC}\n"
        printf "  ${CYAN}2)${NC} Sway      ${DIM}(i3-compatible Wayland WM, minimal, stable)${NC}\n\n"
        printf "  Choice [1/2]: "
        read -r _wm_choice
        case "$_wm_choice" in
            2) WM_CHOICE="sway" ;;
            *) WM_CHOICE="hyprland" ;;
        esac
    fi
    WM_CHOICE="${WM_CHOICE:-hyprland}"

    lib_show_banner "Desktop Setup — Arch ${WM_CHOICE^}"
    lib_confirm "Install Arch desktop (${WM_CHOICE}) on $HOSTNAME_VAL?" || exit 0

    # ── Step 1: System update ────────────────────────────────────────────────
    log_header "Step 1: System Update"
    lib_pacman_update
    lib_setup_mirrors

    # ── Step 2: Core tools ───────────────────────────────────────────────────
    log_header "Step 2: Core Tools"
    lib_pacman_install \
        git base-devel curl wget \
        vim nano tmux zsh zsh-completions \
        htop btop jq tree \
        fzf ripgrep fd bat eza \
        man-db unzip zip \
        xdg-utils xdg-user-dirs \
        openssh openssl

    # ── Step 3: Audio ────────────────────────────────────────────────────────
    log_header "Step 3: Audio (PipeWire)"
    lib_pacman_install \
        pipewire pipewire-pulse pipewire-jack wireplumber \
        alsa-utils pavucontrol

    systemctl --user enable --now pipewire pipewire-pulse wireplumber 2>/dev/null || true

    # ── Step 4: Wayland base ─────────────────────────────────────────────────
    log_header "Step 4: Wayland Base"
    lib_pacman_install \
        wayland wayland-utils \
        xorg-xwayland \
        wl-clipboard \
        grim slurp \
        foot \
        mako \
        polkit polkit-gnome

    # ── Step 5: Window Manager ───────────────────────────────────────────────
    log_header "Step 5: Window Manager — ${WM_CHOICE^}"
    if [ "$SKIP_GUI" = false ]; then
        case "$WM_CHOICE" in
            hyprland)
                lib_install_yay
                lib_yay_install hyprland waybar-hyprland rofi-wayland \
                    hyprpaper hypridle hyprlock \
                    nwg-look 2>/dev/null || \
                lib_pacman_install hyprland waybar rofi-wayland
                ;;
            sway)
                lib_pacman_install sway swaybar swaylock swayidle \
                    waybar rofi-wayland bemenu-wayland
                ;;
            gnome)
                lib_pacman_install gnome gnome-tweaks
                systemctl enable gdm
                ;;
        esac
        log_success "${WM_CHOICE^} installed"

        # Fonts
        log_subheader "Fonts"
        lib_pacman_install \
            ttf-jetbrains-mono-nerd \
            ttf-firacode-nerd \
            noto-fonts \
            noto-fonts-emoji
        fc-cache -f 2>/dev/null || true

        # Zed IDE (from AUR)
        log_subheader "Zed IDE"
        lib_install_yay
        if ! command -v zed >/dev/null 2>&1; then
            lib_yay_install zed 2>/dev/null || {
                lib_run_as_user "curl -fsSL https://zed.dev/install.sh | sh"
            }
            log_success "Zed IDE installed"
        else
            log_info "Zed already installed"
        fi

        # Useful GUI apps
        lib_pacman_install \
            thunar \
            mpv \
            imv \
            firefox \
            2>/dev/null || true
    else
        log_skip "GUI skipped"
    fi

    # ── Step 6: Docker ───────────────────────────────────────────────────────
    log_header "Step 6: Docker"
    [ "$SKIP_DOCKER" = false ] && lib_install_docker || log_skip "Docker skipped"

    # ── Step 7: Language runtimes ────────────────────────────────────────────
    log_header "Step 7: Language Runtimes"
    if [ "$SKIP_DEV" = false ]; then
        lib_install_rust
        lib_install_node
        lib_install_python
    else
        log_skip "Runtimes skipped"
    fi

    # ── Step 8: Directories ──────────────────────────────────────────────────
    log_header "Step 8: Dev Directories"
    local _u="$DEV_USER"
    for d in dev projects github workspace downloads; do
        local _p="/home/${_u}/${d}"
        [ -d "$_p" ] || { sudo -u "$_u" mkdir -p "$_p"; log_success "Created: ~/$d"; }
    done

    # ── Step 9: GitHub Sync ──────────────────────────────────────────────────
    log_header "Step 9: GitHub Sync"
    lib_setup_github_sync

    # ── Step 10: Display manager ─────────────────────────────────────────────
    if [ "$WM_CHOICE" != "gnome" ] && [ "$SKIP_GUI" = false ]; then
        log_header "Step 10: Display Manager (SDDM)"
        lib_pacman_install sddm
        systemctl enable sddm
    fi

    log_header "Arch Desktop Ready!"
    printf "  ${GREEN}✓${NC} ${WM_CHOICE^} + Waybar + Rofi\n"
    [ "$SKIP_GUI"    = false ] && printf "  ${GREEN}✓${NC} Zed IDE + fonts\n"
    [ "$SKIP_DOCKER" = false ] && printf "  ${GREEN}✓${NC} Docker\n"
    [ "$SKIP_DEV"    = false ] && printf "  ${GREEN}✓${NC} Rust · Node · Python\n"
    printf "  ${GREEN}✓${NC} GitHub sync timer\n\n"
    printf "  ${YELLOW}Next:${NC} reboot, login via SDDM, start ${WM_CHOICE}\n\n"
    log_success "Done — happy hacking, Jordan!"
}

# =============================================================================
# Dispatch
# =============================================================================
case "$DISTRO_FAMILY" in
    ubuntu) setup_ubuntu_desktop ;;
    arch)   setup_arch_desktop ;;
esac

exit 0
