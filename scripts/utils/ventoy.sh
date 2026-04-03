#!/bin/sh
# =============================================================================
# ventoy.sh — nuniesmith setup launcher  (v2)
# =============================================================================
#
# THREE MODES:
#
#   1. LAUNCHER  (default)
#      Presents a menu, fetches the matching setup script from GitHub into RAM,
#      and runs it. Nothing is written to the USB.
#
#   2. PARTITION CREATOR  (--create-partition)
#      Adds a 256 MiB ext4 partition labelled SCRIPTS to your Ventoy USB.
#      Copies this ventoy.sh onto it so any new machine can bootstrap itself
#      without needing the internet first.
#
#   3. NON-INTERACTIVE  (--no-confirm --script=NAME)
#      For CI / automation. Combines with either mode above.
#
# LAUNCHER usage:
#   sh ventoy.sh                                   # interactive menu
#   sh ventoy.sh --no-confirm --script=dev-server  # automation
#
# PARTITION CREATOR usage (run as root on any Linux with the Ventoy USB plugged in):
#   sudo sh ventoy.sh --create-partition
#   sudo sh ventoy.sh --create-partition --disk=/dev/sdb
#
# After creating the SCRIPTS partition, on a new machine:
#   1. Boot from Ventoy USB into a live environment
#   2. mount LABEL=SCRIPTS /mnt/scripts   (or the launcher auto-mounts it)
#   3. sh /mnt/scripts/ventoy.sh
#
# Scripts pulled from:
#   https://github.com/nuniesmith/scripts/tree/main/scripts/setup
# =============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"
SCRIPTS_LABEL="SCRIPTS"          # ext4 partition label
SCRIPTS_PART_SIZE_MiB=256        # partition size
TMPDIR_BASE="${TMPDIR:-/tmp}"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  M='\033[0;35m'
BOLD='\033[1m'  DIM='\033[2m'   NC='\033[0m'

info()  { printf "${B}[INFO]${NC}   %s\n" "$*"; }
ok()    { printf "${G}[ OK ]${NC}   %s\n" "$*"; }
warn()  { printf "${Y}[WARN]${NC}   %s\n" "$*"; }
die()   { printf "${R}[ERR ]${NC}   %s\n" "$*" >&2; exit 1; }
sep()   { printf "${DIM}──────────────────────────────────────────────────────────${NC}\n"; }
step()  { printf "\n${M}${BOLD}▶  %s${NC}\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
MODE="launcher"
NO_CONFIRM=false
DIRECT_SCRIPT=""
PASSTHROUGH=""
FORCED_DISK=""

for arg in "$@"; do
    case "$arg" in
        --create-partition)  MODE="create-partition" ;;
        --no-confirm)        NO_CONFIRM=true; PASSTHROUGH="$PASSTHROUGH --no-confirm" ;;
        --script=*)          DIRECT_SCRIPT="${arg#--script=}" ;;
        --disk=*)            FORCED_DISK="${arg#--disk=}" ;;
        --help|-h)           MODE="help" ;;
        *)                   PASSTHROUGH="$PASSTHROUGH $arg" ;;
    esac
done

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'

ventoy.sh — nuniesmith setup launcher

LAUNCHER MODE (default):
  sh ventoy.sh
  sh ventoy.sh --no-confirm --script=PROFILE

  PROFILE values:
    macbook         Arch Linux on MacBook Pro 11,1
    dev-server      Ubuntu dev server (full toolchain + Docker + CUDA)
    prod-server     Ubuntu production server (Tailscale, UFW, hardened)
    staging-server  Ubuntu staging / QA server (lighter, debug-friendly)
    desktop         GUI desktop (Ubuntu GNOME  or  Arch Hyprland/Sway)

PARTITION CREATOR MODE:
  sudo sh ventoy.sh --create-partition [--disk=/dev/sdX]

  Adds a 256 MiB ext4 partition labelled SCRIPTS to your Ventoy USB and
  copies this ventoy.sh onto it.  On a new machine:

    mount LABEL=SCRIPTS /mnt/scripts
    sh /mnt/scripts/ventoy.sh

EOF
    exit 0
}

[ "$MODE" = "help" ] && show_help

# ── Banner ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
printf "\n"
printf "${C}${BOLD}"
printf "  ╔══════════════════════════════════════════════════════╗\n"
printf "  ║                                                      ║\n"
printf "  ║      nuniesmith  ·  Ventoy Setup Launcher  v2        ║\n"
printf "  ║                                                      ║\n"
printf "  ╚══════════════════════════════════════════════════════╝\n"
printf "${NC}\n"

# ── Detect running OS ─────────────────────────────────────────────────────────
DETECTED_OS="unknown"
DETECTED_DISTRO="Unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DETECTED_OS="${ID:-unknown}"
    DETECTED_DISTRO="${NAME:-Unknown} ${VERSION_ID:-}"
fi
DETECTED_ARCH=$(uname -m)

printf "  ${DIM}host:${NC}  ${BOLD}%s${NC}" "$(hostname 2>/dev/null || echo unknown)"
printf "   ${DIM}os:${NC}  ${BOLD}%s${NC}" "$DETECTED_DISTRO"
printf "   ${DIM}arch:${NC}  ${BOLD}%s${NC}\n\n" "$DETECTED_ARCH"

[ "$(id -u)" -ne 0 ] && warn "Not root — most setup scripts need sudo."

# =============================================================================
# MODE: create-partition
# =============================================================================
if [ "$MODE" = "create-partition" ]; then

    [ "$(id -u)" -ne 0 ] && die "Partition creation requires root: sudo sh ventoy.sh --create-partition"

    step "Create SCRIPTS partition on Ventoy USB"
    sep

    # ── Require tools ─────────────────────────────────────────────────────────
    for _tool in parted mkfs.ext4 partprobe blkid; do
        command -v "$_tool" >/dev/null 2>&1 || die "Required tool not found: $_tool  (install e2fsprogs parted)"
    done

    # ── Find Ventoy USB (or use --disk=) ─────────────────────────────────────
    VENTOY_DISK="$FORCED_DISK"

    if [ -z "$VENTOY_DISK" ]; then
        info "Auto-detecting Ventoy USB..."
        for _dev in /dev/sd? /dev/vd? /dev/nvme?n?; do
            [ -b "$_dev" ] || continue
            # Look for VTOY label on any partition of this disk
            for _p in "${_dev}"? "${_dev}"p? "${_dev}p"??; do
                [ -b "$_p" ] || continue
                blkid "$_p" 2>/dev/null | grep -qiE 'LABEL="?VTOY|ventoy' && {
                    VENTOY_DISK="$_dev"
                    break 2
                }
            done
        done
    fi

    [ -z "$VENTOY_DISK" ] && {
        printf "\n${R}Could not auto-detect Ventoy USB.${NC}\n"
        printf "  Plug in your Ventoy USB, then retry:\n"
        printf "  ${C}sudo sh ventoy.sh --create-partition --disk=/dev/sdX${NC}\n\n"
        printf "  Available block devices:\n"
        lsblk -d -o NAME,SIZE,LABEL,MODEL 2>/dev/null || true
        printf "\n"
        exit 1
    }

    ok "Ventoy USB: $VENTOY_DISK"
    printf "\n"
    lsblk "$VENTOY_DISK"
    printf "\n"

    # ── Check for existing SCRIPTS partition ──────────────────────────────────
    if blkid 2>/dev/null | grep -qi "LABEL=\"${SCRIPTS_LABEL}\""; then
        EXISTING=$(blkid 2>/dev/null | grep -i "LABEL=\"${SCRIPTS_LABEL}\"" | cut -d: -f1)
        warn "SCRIPTS partition already exists: $EXISTING"
        if [ "$NO_CONFIRM" = false ]; then
            printf "  Update ventoy.sh on it? (Y/n) "
            read -r _ans
            case "$_ans" in n|N) printf "\n  Nothing to do.\n\n"; exit 0 ;; esac
        fi
        # Just copy the updated ventoy.sh
        _mnt=$(mktemp -d)
        mount "$EXISTING" "$_mnt"
        cp "$0" "$_mnt/ventoy.sh"
        chmod +x "$_mnt/ventoy.sh"
        sync
        umount "$_mnt"; rmdir "$_mnt"
        ok "Updated ventoy.sh on SCRIPTS partition ($EXISTING)"
        exit 0
    fi

    # ── Confirm ───────────────────────────────────────────────────────────────
    if [ "$NO_CONFIRM" = false ]; then
        printf "  ${Y}Add a %d MiB ext4 partition (SCRIPTS) to %s?${NC}\n" \
            "$SCRIPTS_PART_SIZE_MiB" "$VENTOY_DISK"
        printf "  This does NOT touch the existing Ventoy data.\n"
        printf "  Proceed? (Y/n) "
        read -r _ans
        case "$_ans" in n|N|no) printf "\n  Cancelled.\n\n"; exit 0 ;; esac
    fi

    # ── Find free space after last partition ──────────────────────────────────
    step "Reading partition table"

    # Use parted to get disk size and last partition end (in MiB)
    DISK_SIZE_MiB=$(parted -s "$VENTOY_DISK" unit MiB print 2>/dev/null \
        | grep "^Disk $VENTOY_DISK" | grep -oE '[0-9]+(\.[0-9]+)?MiB' | tr -d 'MiB')

    LAST_END_MiB=$(parted -s "$VENTOY_DISK" unit MiB print 2>/dev/null \
        | grep '^ *[0-9]' | tail -1 | awk '{print $3}' | tr -d 'MiB')

    # Round up
    START_MiB=$(printf "%.0f" "${LAST_END_MiB:-0}")
    START_MiB=$((START_MiB + 1))
    END_MiB=$((START_MiB + SCRIPTS_PART_SIZE_MiB))

    [ -z "$DISK_SIZE_MiB" ] && die "Could not read disk size from parted"
    [ "$END_MiB" -gt "${DISK_SIZE_MiB%.*}" ] && \
        die "Not enough free space on $VENTOY_DISK — need ${SCRIPTS_PART_SIZE_MiB} MiB after current partitions"

    info "Free space starts at ${START_MiB} MiB — creating partition ${START_MiB}–${END_MiB} MiB"

    # ── Create partition ──────────────────────────────────────────────────────
    step "Creating ext4 partition"
    parted -s "$VENTOY_DISK" mkpart primary ext4 "${START_MiB}MiB" "${END_MiB}MiB"
    sleep 1
    partprobe "$VENTOY_DISK" 2>/dev/null || true
    sleep 1

    # Discover the new partition device
    SCRIPTS_PART=""
    for _try in 1 2 3; do
        for _sfx in 3 p3; do
            _candidate="${VENTOY_DISK}${_sfx}"
            [ -b "$_candidate" ] && { SCRIPTS_PART="$_candidate"; break 2; }
        done
        sleep 1
    done
    [ -z "$SCRIPTS_PART" ] && die "New partition not found — check: lsblk $VENTOY_DISK"

    mkfs.ext4 -L "$SCRIPTS_LABEL" -q "$SCRIPTS_PART"
    ok "Partition created: $SCRIPTS_PART  (label: $SCRIPTS_LABEL)"

    # ── Copy ventoy.sh onto it ────────────────────────────────────────────────
    step "Installing ventoy.sh on SCRIPTS partition"
    _mnt=$(mktemp -d)
    mount "$SCRIPTS_PART" "$_mnt"
    cp "$0" "$_mnt/ventoy.sh"
    chmod +x "$_mnt/ventoy.sh"
    sync
    umount "$_mnt"
    rmdir "$_mnt"
    ok "ventoy.sh installed on SCRIPTS partition"

    printf "\n"
    sep
    printf "\n  ${G}${BOLD}SCRIPTS partition ready!${NC}\n\n"
    printf "  ${BOLD}On any new machine (live ISO or installed OS):${NC}\n\n"
    printf "    ${C}# Mount the SCRIPTS partition:${NC}\n"
    printf "    mkdir -p /mnt/scripts\n"
    printf "    mount LABEL=SCRIPTS /mnt/scripts\n\n"
    printf "    ${C}# Run the launcher:${NC}\n"
    printf "    sh /mnt/scripts/ventoy.sh\n\n"
    printf "  ${DIM}The launcher will detect the running distro, show compatible\n"
    printf "  profiles, and download the latest script from GitHub.${NC}\n\n"
    sep
    printf "\n"
    exit 0
fi

# =============================================================================
# MODE: launcher
# =============================================================================

# ── Internet check ────────────────────────────────────────────────────────────
sep
info "Checking internet..."
ONLINE=false
for _host in 8.8.8.8 1.1.1.1 github.com; do
    ping -c1 -W3 "$_host" >/dev/null 2>&1 && ONLINE=true && break
done

if [ "$ONLINE" = "false" ]; then
    printf "\n${R}${BOLD}  No internet connection.${NC}\n\n"
    printf "  Scripts are fetched from GitHub — internet is required.\n\n"
    printf "  ${Y}iPhone:${NC}   Settings → Personal Hotspot → USB only\n"
    printf "  ${Y}Android:${NC}  Settings → Hotspot → USB tethering\n"
    printf "  ${Y}Adapter:${NC}  USB-C / USB-A ethernet dongle\n\n"
    printf "  Then re-run: ${C}sh ventoy.sh${NC}\n\n"
    exit 1
fi
ok "Internet OK"

# ── Build profile list with compatibility hints ───────────────────────────────
# Format: "script_file|label|description|compatible_os_ids"
PROFILES="
setup-macbook.sh|macbook|MacBook Pro 11,1 — Arch · Btrfs · Sway · BCM4360 WiFi|arch
setup-dev-server.sh|dev-server|Dev Server — Ubuntu · Docker · CUDA · Rust · Node · Go · Zed|ubuntu debian pop
setup-prod-server.sh|prod-server|Production Server — Ubuntu · Docker · Tailscale · UFW · hardened|ubuntu debian
setup-staging-server.sh|staging-server|Staging / QA Server — Ubuntu · Docker · Tailscale · debug-friendly|ubuntu debian
setup-desktop.sh|desktop|Desktop Workstation — Ubuntu GNOME  or  Arch Hyprland/Sway|ubuntu debian arch manjaro
"

# ── Menu ──────────────────────────────────────────────────────────────────────
printf "\n"
sep
printf "\n  ${BOLD}Select a setup profile:${NC}\n\n"

IDX=0
MENU_SCRIPTS=""
MENU_FILES=""

printf "%s" "$PROFILES" | while IFS='|' read -r _file _key _desc _compat; do
    [ -z "$_file" ] && continue
    IDX=$((IDX + 1))

    # Compat check
    _compat_warn=""
    if ! printf "%s" "$_compat" | grep -qw "$DETECTED_OS"; then
        _compat_warn="  ${Y}⚠ detected: ${DETECTED_DISTRO}${NC}"
    fi

    printf "  ${C}${BOLD}%d)${NC}  %s%s\n" "$IDX" "$_desc" "$_compat_warn"
    printf "      ${DIM}%s${NC}\n\n" "$_key → ${_file}"
done

printf "  ${DIM}q)  Quit${NC}\n\n"
sep
printf "\n"

# ── Script selection ──────────────────────────────────────────────────────────
# Map user input → filename
_resolve_script() {
    local _input="$1"
    case "$_input" in
        1|macbook)          echo "setup-macbook.sh" ;;
        2|dev-server)       echo "setup-dev-server.sh" ;;
        3|prod-server)      echo "setup-prod-server.sh" ;;
        4|staging-server)   echo "setup-staging-server.sh" ;;
        5|desktop)          echo "setup-desktop.sh" ;;
        *)                  echo "" ;;
    esac
}

CHOSEN_FILE=""

if [ -n "$DIRECT_SCRIPT" ]; then
    CHOSEN_FILE=$(_resolve_script "$DIRECT_SCRIPT")
    [ -z "$CHOSEN_FILE" ] && die "Unknown --script value: '$DIRECT_SCRIPT'"
    info "Script pre-selected: $CHOSEN_FILE"
else
    [ "$NO_CONFIRM" = true ] && die "Use --script=PROFILE together with --no-confirm"
    while true; do
        printf "  ${BOLD}Choice [1-5 or q]:${NC} "
        read -r CHOICE
        case "$CHOICE" in
            q|Q) printf "\n  Exiting.\n\n"; exit 0 ;;
            *)
                CHOSEN_FILE=$(_resolve_script "$CHOICE")
                [ -n "$CHOSEN_FILE" ] && break
                printf "  ${R}Invalid choice.${NC} Enter 1–5 or q.\n"
                ;;
        esac
    done
fi

# ── Fetch script from GitHub ──────────────────────────────────────────────────
SCRIPT_URL="${REPO_RAW}/${CHOSEN_FILE}"
DEST="${TMPDIR_BASE}/${CHOSEN_FILE}"

printf "\n"
sep
info "Fetching ${CHOSEN_FILE}..."

if ! curl -fsSL --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$DEST" 2>/dev/null; then
    warn "Direct fetch failed — trying GitHub API fallback..."
    _api="https://api.github.com/repos/nuniesmith/scripts/contents/scripts/setup/${CHOSEN_FILE}"
    _dl=$(curl -fsSL "$_api" 2>/dev/null \
        | grep '"download_url"' \
        | sed 's/.*"download_url": *"\([^"]*\)".*/\1/')
    [ -z "$_dl" ] && die "Cannot fetch ${CHOSEN_FILE}.\nCheck: https://github.com/nuniesmith/scripts/tree/main/scripts/setup"
    curl -fsSL "$_dl" -o "$DEST" || die "Both fetch methods failed."
fi

chmod +x "$DEST"
FSIZE=$(wc -c < "$DEST" 2>/dev/null || echo 0)
[ "${FSIZE:-0}" -lt 100 ] && die "Downloaded file looks empty (${FSIZE} bytes)"

ok "Saved to RAM: ${DEST}  (${FSIZE} bytes)"
command -v sha256sum >/dev/null 2>&1 && \
    info "SHA256: $(sha256sum "$DEST" | cut -d' ' -f1)"

# ── Also fetch base library if needed ────────────────────────────────────────
case "$CHOSEN_FILE" in
    setup-macbook.sh)
        _base="${TMPDIR_BASE}/setup-arch.sh"
        ;;
    setup-dev-server.sh|setup-prod-server.sh|setup-staging-server.sh|setup-desktop.sh)
        _base="${TMPDIR_BASE}/setup-ubuntu.sh"
        ;;
    *)
        _base=""
        ;;
esac

if [ -n "$_base" ] && [ ! -f "$_base" ]; then
    _base_name=$(basename "$_base")
    info "Pre-fetching base library: ${_base_name}..."
    curl -fsSL --retry 3 "${REPO_RAW}/${_base_name}" -o "$_base" 2>/dev/null && \
        ok "Base library cached: ${_base}" || \
        warn "Could not pre-fetch ${_base_name} — script will attempt its own fetch"
fi

printf "\n"
sep

# ── Confirm + launch ──────────────────────────────────────────────────────────
if [ "$NO_CONFIRM" = false ]; then
    printf "\n  ${BOLD}Ready to run:${NC}  ${C}%s${NC}\n" "$CHOSEN_FILE"
    [ -n "$PASSTHROUGH" ] && printf "  ${BOLD}Extra args:${NC}   %s\n" "$PASSTHROUGH"
    printf "\n  ${Y}Continue? (Y/n):${NC} "
    read -r OK
    case "$OK" in n|N|no|No|NO) printf "\n  Cancelled.\n\n"; exit 0 ;; esac
fi

printf "\n${G}${BOLD}━━━  Launching %s  ━━━${NC}\n\n" "$CHOSEN_FILE"

if command -v bash >/dev/null 2>&1; then
    exec bash "$DEST" $PASSTHROUGH
else
    exec sh "$DEST" $PASSTHROUGH
fi
