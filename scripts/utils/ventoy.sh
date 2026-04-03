#!/bin/sh
# =============================================================================
# ventoy.sh — nuniesmith setup launcher  (v3)
# =============================================================================
#
# FOUR MODES:
#
#   1. LAUNCHER  (default)
#      Presents a menu, fetches the matching setup script from GitHub into RAM,
#      and runs it. Nothing is written to the USB.
#
#   2. PARTITION CREATOR  (--create-partition)
#      Adds a 256 MiB ext4 partition labelled SCRIPTS to an existing Ventoy USB.
#      Copies this ventoy.sh onto it so any new machine can bootstrap without
#      needing the internet first.
#
#   3. FULL USB SETUP  (--setup-usb)
#      Wipes the target USB with a fresh Ventoy install, then creates the
#      SCRIPTS partition and copies this ventoy.sh onto it — all in one step.
#
#      Ventoy is downloaded automatically from GitHub if not already present.
#      No separate download step needed.
#
#      Examples:
#        sudo sh ventoy.sh --setup-usb
#        sudo sh ventoy.sh --setup-usb --disk=/dev/sdb
#        sudo sh ventoy.sh --setup-usb --ventoy-version=1.0.99
#        sudo sh ventoy.sh --setup-usb --no-confirm --disk=/dev/sdb
#
#      If you already have the Ventoy release extracted locally:
#        sudo sh ventoy.sh --setup-usb --ventoy-dir=/opt/ventoy-1.0.99
#
#   4. NON-INTERACTIVE  (--no-confirm --script=NAME)
#      For CI / automation. Combines with any mode above.
#
# LAUNCHER usage:
#   sh ventoy.sh                                   # interactive menu
#   sh ventoy.sh --no-confirm --script=dev-server  # automation
#
# PARTITION CREATOR usage:
#   sudo sh ventoy.sh --create-partition
#   sudo sh ventoy.sh --create-partition --disk=/dev/sdb
#
# After creating the SCRIPTS partition, on a new machine:
#   1. Boot from Ventoy USB into a live environment
#   2. mount LABEL=SCRIPTS /mnt/scripts
#   3. sh /mnt/scripts/ventoy.sh
#
# Setup scripts pulled from:
#   https://github.com/nuniesmith/scripts/tree/main/scripts/setup
# =============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"
SCRIPTS_LABEL="SCRIPTS"       # ext4 partition label written to the USB
SCRIPTS_PART_SIZE_MiB=256     # size of that partition
TMPDIR_BASE="${TMPDIR:-/tmp}"

VENTOY_GITHUB_API="https://api.github.com/repos/ventoy/Ventoy/releases/latest"
VENTOY_DL_BASE="https://github.com/ventoy/Ventoy/releases/download"

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
VENTOY_DIR=""        # skip download if user already has the release extracted
VENTOY_VERSION=""    # pin a specific release tag, e.g. 1.0.99

for arg in "$@"; do
    case "$arg" in
        --create-partition)  MODE="create-partition" ;;
        --setup-usb)         MODE="setup-usb" ;;
        --no-confirm)        NO_CONFIRM=true; PASSTHROUGH="$PASSTHROUGH --no-confirm" ;;
        --script=*)          DIRECT_SCRIPT="${arg#--script=}" ;;
        --disk=*)            FORCED_DISK="${arg#--disk=}" ;;
        --ventoy-dir=*)      VENTOY_DIR="${arg#--ventoy-dir=}" ;;
        --ventoy-version=*)  VENTOY_VERSION="${arg#--ventoy-version=}" ;;
        --help|-h)           MODE="help" ;;
        *)                   PASSTHROUGH="$PASSTHROUGH $arg" ;;
    esac
done

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'

ventoy.sh — nuniesmith setup launcher  v3

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

  Adds a 256 MiB ext4 SCRIPTS partition to your Ventoy USB and
  copies this ventoy.sh onto it.

FULL USB SETUP MODE:
  sudo sh ventoy.sh --setup-usb [OPTIONS]

  Options:
    --disk=/dev/sdX           Target USB (prompted if omitted)
    --ventoy-version=1.0.99   Pin a specific Ventoy release (default: latest)
    --ventoy-dir=/path        Use an already-extracted Ventoy release directory
                              (skips the download entirely)

  What it does:
    1. Downloads the latest Ventoy Linux release from GitHub into /tmp
       (skipped if --ventoy-dir given or a cached extract already exists)
    2. Runs the Ventoy installer with force-overwrite (-I flag)
    3. Creates the 256 MiB ext4 SCRIPTS partition
    4. Copies this ventoy.sh onto the SCRIPTS partition

  Fully non-interactive example:
    sudo sh ventoy.sh --setup-usb --no-confirm --disk=/dev/sdb

EOF
    exit 0
}

if [ "$MODE" = "help" ]; then show_help; fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
printf "\n"
printf "${C}${BOLD}"
printf "  ╔══════════════════════════════════════════════════════╗\n"
printf "  ║                                                      ║\n"
printf "  ║      nuniesmith  ·  Ventoy Setup Launcher  v3        ║\n"
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

# NOTE: all root checks use if/fi — never  [ ... ] && die  with set -e active,
# because a false test makes the whole && expression return 1 which set -e
# treats as a hard failure, causing a silent exit.
if [ "$(id -u)" -ne 0 ]; then
    warn "Not root — partition/install operations will need sudo."
fi

# =============================================================================
# HELPER: require_tools
#   Checks that all named commands exist; dies with an install hint if not.
# =============================================================================
require_tools() {
    _rt_missing=""
    for _rt_t in "$@"; do
        if ! command -v "$_rt_t" >/dev/null 2>&1; then
            _rt_missing="$_rt_missing $_rt_t"
        fi
    done
    if [ -n "$_rt_missing" ]; then
        die "Missing required tools:$_rt_missing\n  Install: apt-get install -y$_rt_missing   (or equivalent)"
    fi
}

# =============================================================================
# HELPER: find_disk
#   Populates VENTOY_DISK.
#   mode=ventoy  → look for a partition with the VTOY label (existing Ventoy USB)
#   mode=any     → show lsblk and prompt if --disk= was not supplied
# =============================================================================
find_disk() {
    _fd_mode="${1:-ventoy}"
    VENTOY_DISK="$FORCED_DISK"

    if [ -z "$VENTOY_DISK" ] && [ "$_fd_mode" = "ventoy" ]; then
        info "Auto-detecting Ventoy USB..."
        for _fd_dev in /dev/sd? /dev/vd? /dev/nvme?n?; do
            if [ -b "$_fd_dev" ]; then
                for _fd_p in "${_fd_dev}"? "${_fd_dev}"p? "${_fd_dev}p"??; do
                    if [ -b "$_fd_p" ]; then
                        if blkid "$_fd_p" 2>/dev/null | grep -qiE 'LABEL="?VTOY|ventoy'; then
                            VENTOY_DISK="$_fd_dev"
                            break 2
                        fi
                    fi
                done
            fi
        done
    fi

    if [ -z "$VENTOY_DISK" ]; then
        printf "\n${Y}Available block devices:${NC}\n"
        lsblk -d -o NAME,SIZE,LABEL,MODEL,TRAN 2>/dev/null || \
            lsblk -d -o NAME,SIZE,LABEL,MODEL   2>/dev/null || true
        printf "\n"
        if [ "$NO_CONFIRM" = true ]; then
            die "Cannot auto-detect target disk. Pass --disk=/dev/sdX"
        fi
        printf "  Enter target disk (e.g. /dev/sdb): "
        read -r VENTOY_DISK
    fi

    if [ ! -b "$VENTOY_DISK" ]; then
        die "Not a block device: $VENTOY_DISK"
    fi
}

# =============================================================================
# HELPER: fetch_ventoy
#   Ensures the Ventoy Linux release is extracted in /tmp and ready to use.
#   Sets VENTOY_INSTALL_DIR and VENTOY_VER.
#
#   Priority:
#     1. --ventoy-dir=<path>      (user already has it extracted)
#     2. /tmp/ventoy-*/           (leftover from a previous run — reuse)
#     3. Download from GitHub     (automatic, latest or --ventoy-version=X)
# =============================================================================
fetch_ventoy() {
    VENTOY_INSTALL_DIR=""
    VENTOY_VER=""

    # ── 1. User-supplied local directory ─────────────────────────────────
    if [ -n "$VENTOY_DIR" ]; then
        if [ ! -f "${VENTOY_DIR}/Ventoy2Disk.sh" ]; then
            die "Ventoy2Disk.sh not found in: $VENTOY_DIR"
        fi
        VENTOY_INSTALL_DIR="$VENTOY_DIR"
        VENTOY_VER="(local)"
        ok "Using local Ventoy release: $VENTOY_INSTALL_DIR"
        return 0
    fi

    # ── 2. Cached extract from a previous run ─────────────────────────────
    for _fv_d in "${TMPDIR_BASE}"/ventoy-*/; do
        if [ -f "${_fv_d}Ventoy2Disk.sh" ]; then
            VENTOY_INSTALL_DIR="${_fv_d%/}"
            VENTOY_VER=$(basename "$VENTOY_INSTALL_DIR" | sed 's/ventoy-//')
            ok "Using cached Ventoy release: $VENTOY_INSTALL_DIR  (ver $VENTOY_VER)"
            return 0
        fi
    done

    # ── 3. Download from GitHub ───────────────────────────────────────────
    require_tools curl tar

    if [ -z "$VENTOY_VERSION" ]; then
        info "Fetching latest Ventoy release tag from GitHub..."
        VENTOY_VERSION=$(curl -fsSL --retry 3 "$VENTOY_GITHUB_API" 2>/dev/null \
            | grep '"tag_name"' \
            | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/' \
            | head -1)
        if [ -z "$VENTOY_VERSION" ]; then
            die "Could not determine latest Ventoy version.\n  Try: --ventoy-version=1.0.99  or  --ventoy-dir=/path/to/release"
        fi
    fi

    VENTOY_VER="$VENTOY_VERSION"
    info "Ventoy version: $VENTOY_VER"

    _fv_tarball="ventoy-${VENTOY_VER}-linux.tar.gz"
    _fv_url="${VENTOY_DL_BASE}/v${VENTOY_VER}/${_fv_tarball}"
    _fv_dl_dest="${TMPDIR_BASE}/${_fv_tarball}"
    _fv_extract_dir="${TMPDIR_BASE}/ventoy-${VENTOY_VER}"

    if [ -f "$_fv_dl_dest" ]; then
        ok "Using cached tarball: $_fv_dl_dest"
    else
        step "Downloading Ventoy ${VENTOY_VER}"
        info "Source: $_fv_url"
        if ! curl -fsSL --retry 3 --retry-delay 2 \
                --progress-bar "$_fv_url" -o "$_fv_dl_dest"; then
            die "Download failed.\n  URL: $_fv_url\n  Check internet, or try --ventoy-version=X.Y.Z"
        fi
        ok "Downloaded: $_fv_dl_dest  ($(du -sh "$_fv_dl_dest" 2>/dev/null | cut -f1))"
    fi

    step "Extracting Ventoy ${VENTOY_VER}"
    mkdir -p "$_fv_extract_dir"
    if ! tar -xzf "$_fv_dl_dest" -C "$TMPDIR_BASE" 2>/dev/null; then
        die "Extraction failed — tarball may be corrupt.\n  Delete $_fv_dl_dest and retry."
    fi

    if [ ! -f "${_fv_extract_dir}/Ventoy2Disk.sh" ]; then
        die "Ventoy2Disk.sh not found after extraction in: $_fv_extract_dir\n  Unexpected tarball layout."
    fi

    VENTOY_INSTALL_DIR="$_fv_extract_dir"
    ok "Extracted: $VENTOY_INSTALL_DIR"
}

# =============================================================================
# HELPER: run_ventoy_installer
#   Replicates the logic of Ventoy2Disk.sh — no external file needed at
#   runtime. Calling this is equivalent to:
#       cd <ventoy-release-dir> && sh Ventoy2Disk.sh -I <disk>
#
#   Ventoy2Disk.sh itself only does four things:
#     1. Sets TOOLDIR based on uname -m
#     2. Decompresses any .xz tool binaries
#     3. Swaps in static mkexfatfs on musl libc systems
#     4. Calls VentoyWorker.sh with the original args
#
#   $1 = install flags  (e.g. "-I" for force-overwrite)
#   $2 = target disk    (e.g. /dev/sdb)
# =============================================================================
run_ventoy_installer() {
    _vi_flags="$1"
    _vi_disk="$2"
    _vi_olddir=$(pwd)

    if [ -z "$VENTOY_INSTALL_DIR" ]; then
        die "run_ventoy_installer: VENTOY_INSTALL_DIR not set"
    fi
    if [ ! -f "${VENTOY_INSTALL_DIR}/boot/boot.img" ]; then
        die "Ventoy release incomplete — boot/boot.img missing in $VENTOY_INSTALL_DIR"
    fi
    if [ ! -f "${VENTOY_INSTALL_DIR}/tool/VentoyWorker.sh" ]; then
        die "Ventoy release incomplete — tool/VentoyWorker.sh missing in $VENTOY_INSTALL_DIR"
    fi

    # ── Step 1: resolve arch → tool subdirectory (mirrors Ventoy2Disk.sh) ─
    case "$(uname -m)" in
        aarch64|arm64)  _vi_tooldir=aarch64  ;;
        x86_64|amd64)   _vi_tooldir=x86_64   ;;
        mips64*)        _vi_tooldir=mips64el  ;;
        *)              _vi_tooldir=i386      ;;
    esac
    export TOOLDIR="$_vi_tooldir"

    cd "$VENTOY_INSTALL_DIR"
    export PATH="${VENTOY_INSTALL_DIR}/tool/${_vi_tooldir}:$PATH"
    chmod +x -R "./tool/${_vi_tooldir}" 2>/dev/null || true

    # ── Step 2: decompress .xz tool binaries if still packed ──────────────
    if ls "./tool/${_vi_tooldir}"/*.xz >/dev/null 2>&1; then
        info "Decompressing Ventoy tool binaries (${_vi_tooldir})..."
        _vi_xzcat="./tool/${_vi_tooldir}/xzcat"
        if [ -f "$_vi_xzcat" ]; then
            chmod +x "$_vi_xzcat"
        fi
        for _vi_xf in "./tool/${_vi_tooldir}"/*.xz; do
            _vi_out="${_vi_xf%.xz}"
            if command -v xzcat >/dev/null 2>&1; then
                xzcat "$_vi_xf" > "$_vi_out"
            elif [ -x "$_vi_xzcat" ]; then
                "$_vi_xzcat" "$_vi_xf" > "$_vi_out"
            else
                die "Cannot decompress $_vi_xf — xzcat not found.\n  Install: apt-get install xz-utils"
            fi
            chmod +x "$_vi_out" 2>/dev/null || true
            rm -f "$_vi_xf"
        done
        ok "Tool binaries ready"
    fi

    # ── Step 3: use static mkexfatfs on musl libc (Alpine, some live ISOs) ─
    _vi_mkexfat_static="./tool/${_vi_tooldir}/mkexfatfs_static"
    if [ -f "$_vi_mkexfat_static" ]; then
        if ldd --version 2>&1 | grep -qi musl; then
            mv "./tool/${_vi_tooldir}/mkexfatfs" \
               "./tool/${_vi_tooldir}/mkexfatfs_shared" 2>/dev/null || true
            mv "$_vi_mkexfat_static" "./tool/${_vi_tooldir}/mkexfatfs"
        fi
    fi

    # ── Step 4: invoke VentoyWorker.sh ────────────────────────────────────
    info "Launching VentoyWorker.sh ${_vi_flags} ${_vi_disk}"
    if [ -f /bin/bash ]; then
        /bin/bash ./tool/VentoyWorker.sh ${_vi_flags} "${_vi_disk}"
    else
        ash ./tool/VentoyWorker.sh ${_vi_flags} "${_vi_disk}"
    fi

    cd "$_vi_olddir"
}

# =============================================================================
# HELPER: create_scripts_partition
#   Expects VENTOY_DISK to be set.
#   Creates the ext4 SCRIPTS partition and copies this ventoy.sh onto it.
# =============================================================================
create_scripts_partition() {
    require_tools parted mkfs.ext4 partprobe blkid

    # ── Already exists? ───────────────────────────────────────────────────
    if blkid 2>/dev/null | grep -qi "LABEL=\"${SCRIPTS_LABEL}\""; then
        _csp_existing=$(blkid 2>/dev/null \
            | grep -i "LABEL=\"${SCRIPTS_LABEL}\"" | cut -d: -f1)
        warn "SCRIPTS partition already exists: $_csp_existing"
        if [ "$NO_CONFIRM" = false ]; then
            printf "  Overwrite ventoy.sh on it? (Y/n) "
            read -r _csp_ans
            case "$_csp_ans" in
                n|N) printf "\n  Skipping.\n\n"; return 0 ;;
            esac
        fi
        _csp_mnt=$(mktemp -d)
        mount "$_csp_existing" "$_csp_mnt"
        cp "$0" "$_csp_mnt/ventoy.sh"
        chmod +x "$_csp_mnt/ventoy.sh"
        sync
        umount "$_csp_mnt"
        rmdir "$_csp_mnt"
        ok "Updated ventoy.sh on SCRIPTS partition ($_csp_existing)"
        return 0
    fi

    # ── Find free space after the last existing partition ─────────────────
    step "Reading partition table on $VENTOY_DISK"

    _csp_disk_mib=$(parted -s "$VENTOY_DISK" unit MiB print 2>/dev/null \
        | grep "^Disk $VENTOY_DISK" \
        | grep -oE '[0-9]+(\.[0-9]+)?MiB' | tr -d 'MiB')

    _csp_last_end=$(parted -s "$VENTOY_DISK" unit MiB print 2>/dev/null \
        | grep '^ *[0-9]' | tail -1 | awk '{print $3}' | tr -d 'MiB')

    _csp_start=$(printf "%.0f" "${_csp_last_end:-0}")
    _csp_start=$((_csp_start + 1))
    _csp_end=$((_csp_start + SCRIPTS_PART_SIZE_MiB)); _csp_disk_int="${_csp_disk_mib%.*}"; [ "$_csp_end" -gt "$_csp_disk_int" ] && _csp_end=$((_csp_disk_int - 1))

    if [ -z "$_csp_disk_mib" ]; then
        die "Could not read disk size from parted"
    fi
    if [ "$_csp_end" -gt "${_csp_disk_mib%.*}" ]; then
        free_mb=$(( ${_csp_disk_mib%.*} - _csp_last_end ))
        if [ "$free_mb" -lt "$SCRIPTS_PART_SIZE_MiB" ]; then
            die "Not enough free space on $VENTOY_DISK\n  Need ${SCRIPTS_PART_SIZE_MiB} MiB after existing partitions (found ~${free_mb} MiB)"
        fi
    fi

    info "SCRIPTS partition: ${_csp_start}–${_csp_end} MiB"

    # ── Create the partition ──────────────────────────────────────────────
    step "Creating ext4 SCRIPTS partition"
    parted -s "$VENTOY_DISK" mkpart primary ext4 "${_csp_start}MiB" "${_csp_end}MiB"
    sleep 1
    partprobe "$VENTOY_DISK" 2>/dev/null || true
    sleep 2

    # Discover the newly created partition node
    _csp_part=""
    for _csp_try in 1 2 3 4; do
        for _csp_sfx in 3 p3 4 p4; do
            _csp_cand="${VENTOY_DISK}${_csp_sfx}"
            if [ -b "$_csp_cand" ]; then
                # Skip partitions already owned by Ventoy
                if ! blkid "$_csp_cand" 2>/dev/null | grep -qiE 'VTOY|EFI'; then
                    _csp_part="$_csp_cand"
                    break 2
                fi
            fi
        done
        sleep 1
    done

    if [ -z "$_csp_part" ]; then
        die "New partition not found after creation — check: lsblk $VENTOY_DISK"
    fi

    mkfs.ext4 -L "$SCRIPTS_LABEL" -q "$_csp_part"
    ok "Partition created: $_csp_part  (label: $SCRIPTS_LABEL)"

    # ── Copy ventoy.sh ────────────────────────────────────────────────────
    step "Installing ventoy.sh on SCRIPTS partition"
    _csp_mnt=$(mktemp -d)
    mount "$_csp_part" "$_csp_mnt"
    cp "$0" "$_csp_mnt/ventoy.sh"
    chmod +x "$_csp_mnt/ventoy.sh"
    sync
    umount "$_csp_mnt"
    rmdir "$_csp_mnt"
    ok "ventoy.sh installed → $_csp_part"
}

# =============================================================================
# MODE: setup-usb
# =============================================================================
if [ "$MODE" = "setup-usb" ]; then

    if [ "$(id -u)" -ne 0 ]; then
        die "USB setup requires root: sudo sh ventoy.sh --setup-usb"
    fi

    step "Full USB Setup — fresh Ventoy install + SCRIPTS partition"
    sep

    # Fetch / locate Ventoy release — sets VENTOY_INSTALL_DIR and VENTOY_VER
    fetch_ventoy

    # Pick target disk
    find_disk "any"

    # Safety: refuse to touch the disk the OS is running from
    _su_root_disk=$(df / 2>/dev/null | tail -1 | awk '{print $1}' \
        | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    if [ "$VENTOY_DISK" = "$_su_root_disk" ]; then
        die "Refusing to overwrite the root disk: $VENTOY_DISK"
    fi

    ok "Target disk: $VENTOY_DISK  (Ventoy $VENTOY_VER)"
    printf "\n"
    lsblk "$VENTOY_DISK" 2>/dev/null || true
    printf "\n"

    # Confirm — require explicit "yes" for a destructive wipe
    if [ "$NO_CONFIRM" = false ]; then
        printf "  ${R}${BOLD}WARNING:${NC}  ALL data on ${BOLD}%s${NC} will be DESTROYED.\n\n" \
            "$VENTOY_DISK"
        printf "  Steps:\n"
        printf "    1. Install Ventoy %s on %s  (force-overwrite + %d MiB reserved)\n" \
            "$VENTOY_VER" "$VENTOY_DISK" "$SCRIPTS_PART_SIZE_MiB"
        printf "    2. Create a %d MiB ext4 SCRIPTS partition\n" \
            "$SCRIPTS_PART_SIZE_MiB"
        printf "    3. Copy ventoy.sh onto the SCRIPTS partition\n\n"
        printf "  Type ${C}yes${NC} to proceed, anything else cancels: "
        read -r _su_confirm
        case "$_su_confirm" in
            yes|YES) : ;;
            *) printf "\n  Cancelled.\n\n"; exit 0 ;;
        esac
    fi

    # Step 1: fresh Ventoy install (-I = force-overwrite)
    step "Installing Ventoy ${VENTOY_VER} on $VENTOY_DISK"
    sep
    run_ventoy_installer "-I -r ${SCRIPTS_PART_SIZE_MiB}" "$VENTOY_DISK"
    ok "Ventoy installed on $VENTOY_DISK"

    # Give udev + kernel time to re-read the partition table
    sleep 2
    partprobe "$VENTOY_DISK" 2>/dev/null || true
    sleep 1

    # Steps 2 + 3: SCRIPTS partition + ventoy.sh
    create_scripts_partition

    printf "\n"
    sep
    printf "\n  ${G}${BOLD}USB fully prepared!${NC}\n\n"
    printf "  ${BOLD}Partition layout:${NC}\n\n"
    lsblk "$VENTOY_DISK" 2>/dev/null || true
    printf "\n"
    printf "  ${BOLD}On any new machine:${NC}\n\n"
    printf "    mkdir -p /mnt/scripts\n"
    printf "    mount LABEL=SCRIPTS /mnt/scripts\n"
    printf "    sh /mnt/scripts/ventoy.sh\n\n"
    sep
    printf "\n"
    exit 0
fi

# =============================================================================
# MODE: create-partition
# =============================================================================
if [ "$MODE" = "create-partition" ]; then

    if [ "$(id -u)" -ne 0 ]; then
        die "Partition creation requires root: sudo sh ventoy.sh --create-partition"
    fi

    step "Add SCRIPTS partition to existing Ventoy USB"
    sep

    find_disk "ventoy"

    if [ -z "$VENTOY_DISK" ]; then
        printf "\n${R}Could not auto-detect a Ventoy USB.${NC}\n"
        printf "  Plug in your Ventoy USB, then retry:\n"
        printf "  ${C}sudo sh ventoy.sh --create-partition --disk=/dev/sdX${NC}\n\n"
        printf "  Available block devices:\n"
        lsblk -d -o NAME,SIZE,LABEL,MODEL 2>/dev/null || true
        printf "\n"
        exit 1
    fi

    ok "Ventoy USB: $VENTOY_DISK"
    printf "\n"
    lsblk "$VENTOY_DISK"
    printf "\n"

    if [ "$NO_CONFIRM" = false ]; then
        printf "  ${Y}Add a %d MiB ext4 SCRIPTS partition to %s?${NC}\n" \
            "$SCRIPTS_PART_SIZE_MiB" "$VENTOY_DISK"
        printf "  The existing Ventoy data will not be touched.\n"
        printf "  Proceed? (Y/n) "
        read -r _cp_ans
        case "$_cp_ans" in
            n|N|no) printf "\n  Cancelled.\n\n"; exit 0 ;;
        esac
    fi

    create_scripts_partition

    printf "\n"
    sep
    printf "\n  ${G}${BOLD}SCRIPTS partition ready!${NC}\n\n"
    printf "  ${BOLD}On any new machine (live ISO or installed OS):${NC}\n\n"
    printf "    mkdir -p /mnt/scripts\n"
    printf "    mount LABEL=SCRIPTS /mnt/scripts\n"
    printf "    sh /mnt/scripts/ventoy.sh\n\n"
    printf "  ${DIM}The launcher detects the running distro, shows compatible\n"
    printf "  profiles, and downloads the latest script from GitHub.${NC}\n\n"
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
for _l_host in 8.8.8.8 1.1.1.1 github.com; do
    if ping -c1 -W3 "$_l_host" >/dev/null 2>&1; then
        ONLINE=true
        break
    fi
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

# ── Profile list ──────────────────────────────────────────────────────────────
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
printf "%s" "$PROFILES" | while IFS='|' read -r _m_file _m_key _m_desc _m_compat; do
    if [ -z "$_m_file" ]; then continue; fi
    IDX=$((IDX + 1))
    _m_warn=""
    if ! printf "%s" "$_m_compat" | grep -qw "$DETECTED_OS"; then
        _m_warn="  ${Y}⚠ detected: ${DETECTED_DISTRO}${NC}"
    fi
    printf "  ${C}${BOLD}%d)${NC}  %s%s\n" "$IDX" "$_m_desc" "$_m_warn"
    printf "      ${DIM}%s${NC}\n\n" "$_m_key → ${_m_file}"
done

printf "  ${DIM}q)  Quit${NC}\n\n"
sep
printf "\n"

# ── Script selection ──────────────────────────────────────────────────────────
_resolve_script() {
    case "$1" in
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
    if [ -z "$CHOSEN_FILE" ]; then
        die "Unknown --script value: '$DIRECT_SCRIPT'"
    fi
    info "Script pre-selected: $CHOSEN_FILE"
else
    if [ "$NO_CONFIRM" = true ]; then
        die "Use --script=PROFILE together with --no-confirm"
    fi
    while true; do
        printf "  ${BOLD}Choice [1-5 or q]:${NC} "
        read -r CHOICE
        case "$CHOICE" in
            q|Q) printf "\n  Exiting.\n\n"; exit 0 ;;
            *)
                CHOSEN_FILE=$(_resolve_script "$CHOICE")
                if [ -n "$CHOSEN_FILE" ]; then break; fi
                printf "  ${R}Invalid choice.${NC} Enter 1–5 or q.\n"
                ;;
        esac
    done
fi

# ── Fetch setup script from GitHub ───────────────────────────────────────────
SCRIPT_URL="${REPO_RAW}/${CHOSEN_FILE}"
DEST="${TMPDIR_BASE}/${CHOSEN_FILE}"

printf "\n"
sep
info "Fetching ${CHOSEN_FILE}..."

if ! curl -fsSL --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$DEST" 2>/dev/null; then
    warn "Direct fetch failed — trying GitHub API fallback..."
    _fetch_api="https://api.github.com/repos/nuniesmith/scripts/contents/scripts/setup/${CHOSEN_FILE}"
    _fetch_dl=$(curl -fsSL "$_fetch_api" 2>/dev/null \
        | grep '"download_url"' \
        | sed 's/.*"download_url": *"\([^"]*\)".*/\1/')
    if [ -z "$_fetch_dl" ]; then
        die "Cannot fetch ${CHOSEN_FILE}.\nCheck: https://github.com/nuniesmith/scripts/tree/main/scripts/setup"
    fi
    if ! curl -fsSL "$_fetch_dl" -o "$DEST"; then
        die "Both fetch methods failed."
    fi
fi

chmod +x "$DEST"
FSIZE=$(wc -c < "$DEST" 2>/dev/null || echo 0)
if [ "${FSIZE:-0}" -lt 100 ]; then
    die "Downloaded file looks empty (${FSIZE} bytes)"
fi

ok "Saved to RAM: ${DEST}  (${FSIZE} bytes)"
if command -v sha256sum >/dev/null 2>&1; then
    info "SHA256: $(sha256sum "$DEST" | cut -d' ' -f1)"
fi

# ── Pre-fetch base library if needed ─────────────────────────────────────────
case "$CHOSEN_FILE" in
    setup-macbook.sh)
        _base="${TMPDIR_BASE}/setup-arch.sh" ;;
    setup-dev-server.sh|setup-prod-server.sh|setup-staging-server.sh|setup-desktop.sh)
        _base="${TMPDIR_BASE}/setup-ubuntu.sh" ;;
    *)
        _base="" ;;
esac

if [ -n "$_base" ] && [ ! -f "$_base" ]; then
    _base_name=$(basename "$_base")
    info "Pre-fetching base library: ${_base_name}..."
    if curl -fsSL --retry 3 "${REPO_RAW}/${_base_name}" -o "$_base" 2>/dev/null; then
        ok "Base library cached: ${_base}"
    else
        warn "Could not pre-fetch ${_base_name} — setup script will retry on its own"
    fi
fi

printf "\n"
sep

# ── Confirm + launch ──────────────────────────────────────────────────────────
if [ "$NO_CONFIRM" = false ]; then
    printf "\n  ${BOLD}Ready to run:${NC}  ${C}%s${NC}\n" "$CHOSEN_FILE"
    if [ -n "$PASSTHROUGH" ]; then
        printf "  ${BOLD}Extra args:${NC}   %s\n" "$PASSTHROUGH"
    fi
    printf "\n  ${Y}Continue? (Y/n):${NC} "
    read -r OK
    case "$OK" in
        n|N|no|No|NO) printf "\n  Cancelled.\n\n"; exit 0 ;;
    esac
fi

printf "\n${G}${BOLD}━━━  Launching %s  ━━━${NC}\n\n" "$CHOSEN_FILE"

if command -v bash >/dev/null 2>&1; then
    exec bash "$DEST" $PASSTHROUGH
else
    exec sh "$DEST" $PASSTHROUGH
fi
