#!/bin/sh
# =============================================================================
# ventoy.sh — nuniesmith setup launcher
# Drop this file at the root of your Ventoy USB drive.
#
# Presents a menu to choose which machine/role to set up, fetches the
# corresponding script into RAM, and runs it. Nothing is written to the USB.
#
# Usage (from any live environment):
#   sh /run/archiso/bootmnt/ventoy/ventoy.sh           # Arch live CD
#   sh /cdrom/ventoy/ventoy.sh                         # Ubuntu live USB
#   sh /media/*/ventoy/ventoy.sh                       # generic mount
#   sh ventoy.sh --no-confirm --script=macbook         # non-interactive
#
# Scripts pulled from:
#   https://github.com/nuniesmith/scripts/tree/main/scripts/setup
# =============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup"
TMPDIR="${TMPDIR:-/tmp}"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { printf "${B}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${G}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${Y}[WARN]${NC}  %s\n" "$*"; }
die()   { printf "${R}[ERR ]${NC}  %s\n" "$*"; exit 1; }
sep()   { printf "${DIM}──────────────────────────────────────────────────────${NC}\n"; }

# ── Args ──────────────────────────────────────────────────────────────────────
NO_CONFIRM=false
DIRECT_SCRIPT=""
PASSTHROUGH=""

for arg in "$@"; do
    case "$arg" in
        --no-confirm)    NO_CONFIRM=true; PASSTHROUGH="$PASSTHROUGH --no-confirm" ;;
        --script=*)      DIRECT_SCRIPT="${arg#--script=}" ;;
        *)               PASSTHROUGH="$PASSTHROUGH $arg" ;;
    esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
printf "\n"
printf "${C}${BOLD}"
printf "  ╔══════════════════════════════════════════════════════╗\n"
printf "  ║                                                      ║\n"
printf "  ║      nuniesmith  ·  Ventoy Setup Launcher            ║\n"
printf "  ║                                                      ║\n"
printf "  ╚══════════════════════════════════════════════════════╝\n"
printf "${NC}\n"

# ── System detection ──────────────────────────────────────────────────────────
DETECTED_OS="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DETECTED_DISTRO="${NAME:-unknown} ${VERSION_ID:-}"
    DETECTED_OS="${ID:-unknown}"
fi

printf "  ${DIM}host:${NC}  ${BOLD}$(hostname 2>/dev/null || echo unknown)${NC}"
printf "   ${DIM}os:${NC}  ${BOLD}${DETECTED_DISTRO:-$DETECTED_OS}${NC}"
printf "   ${DIM}arch:${NC}  ${BOLD}$(uname -m)${NC}\n\n"

# ── Root warning ──────────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && warn "Not root — most scripts need sudo. Re-run: ${Y}sudo sh ventoy.sh${NC}"

# ── Internet check ────────────────────────────────────────────────────────────
sep
info "Checking internet..."
ONLINE=false
for host in 8.8.8.8 1.1.1.1 github.com; do
    ping -c1 -W3 "$host" >/dev/null 2>&1 && ONLINE=true && break
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
printf "\n"

# ── Menu ──────────────────────────────────────────────────────────────────────
sep
printf "\n  ${BOLD}Select a setup profile:${NC}\n\n"

# ── Option 1: MacBook ─────────────────────────────────────────────────────────
COMPAT1=""
[ "$DETECTED_OS" != "arch" ] && COMPAT1="  ${Y}⚠ boot Arch live ISO first${NC}"
printf "  ${C}${BOLD}1)${NC}  MacBook Pro 11,1${COMPAT1}\n"
printf "      ${DIM}Arch Linux · Btrfs · Sway · BCM4360 WiFi driver${NC}\n"
printf "      ${DIM}Rust · Go · Node · Python · .NET · Android SDK · Zed${NC}\n\n"

# ── Option 2: Dev Server / Desktop ────────────────────────────────────────────
COMPAT2=""
[ "$DETECTED_OS" != "ubuntu" ] && COMPAT2="  ${Y}⚠ run on Ubuntu 25.10${NC}"
printf "  ${C}${BOLD}2)${NC}  Dev Server / Desktop${COMPAT2}\n"
printf "      ${DIM}Ubuntu 25.10 · Docker · CUDA/NVIDIA toolkit · Zed${NC}\n"
printf "      ${DIM}Rust · Go · Node · Python 3.13 · protoc/buf/gRPC · GitHub sync${NC}\n\n"

# ── Option 3: Production / Cloud Server ──────────────────────────────────────
COMPAT3=""
[ "$DETECTED_OS" != "ubuntu" ] && COMPAT3="  ${Y}⚠ run on Ubuntu${NC}"
printf "  ${C}${BOLD}3)${NC}  Production / Cloud Server${COMPAT3}\n"
printf "      ${DIM}Ubuntu LTS · Docker · UFW · fail2ban · Tailscale · SSH hardening${NC}\n"
printf "      ${DIM}Node exporter · swap · unattended upgrades · GitHub sync${NC}\n\n"

printf "  ${DIM}q)  Quit${NC}\n\n"
sep
printf "\n"

# ── Selection ─────────────────────────────────────────────────────────────────
CHOSEN_FILE=""

if [ -n "$DIRECT_SCRIPT" ]; then
    case "$DIRECT_SCRIPT" in
        1|macbook)     CHOSEN_FILE="setup-macbook.sh" ;;
        2|devserver)   CHOSEN_FILE="setup-dev-server.sh" ;;
        3|prodserver)  CHOSEN_FILE="setup-prod-server.sh" ;;
        *)             die "Unknown --script value: $DIRECT_SCRIPT" ;;
    esac
    info "Script pre-selected: $CHOSEN_FILE"
else
    if [ "$NO_CONFIRM" = "true" ]; then
        die "Use --script=1|2|3 together with --no-confirm"
    fi
    while true; do
        printf "  ${BOLD}Choice [1-3 or q]:${NC} "
        read -r CHOICE
        case "$CHOICE" in
            1|macbook)    CHOSEN_FILE="setup-macbook.sh";     break ;;
            2|devserver)  CHOSEN_FILE="setup-dev-server.sh";  break ;;
            3|prodserver) CHOSEN_FILE="setup-prod-server.sh"; break ;;
            q|Q)          printf "\n  Exiting.\n\n"; exit 0 ;;
            *)            printf "  ${R}Invalid.${NC} Enter 1, 2, 3, or q.\n" ;;
        esac
    done
fi

# ── Fetch ─────────────────────────────────────────────────────────────────────
SCRIPT_URL="${REPO_RAW}/${CHOSEN_FILE}"
DEST="${TMPDIR}/${CHOSEN_FILE}"

printf "\n"
sep
info "Fetching ${CHOSEN_FILE}..."

# Primary: direct raw URL
if ! curl -fsSL --retry 3 --retry-delay 2 "$SCRIPT_URL" -o "$DEST" 2>/dev/null; then
    warn "Direct fetch failed — trying GitHub API fallback..."
    API="https://api.github.com/repos/nuniesmith/scripts/contents/scripts/setup/${CHOSEN_FILE}"
    DL=$(curl -fsSL "$API" 2>/dev/null \
         | grep '"download_url"' \
         | sed 's/.*"download_url": *"\([^"]*\)".*/\1/')
    [ -z "$DL" ] && die "Cannot fetch ${CHOSEN_FILE}.\nCheck the file exists at:\n  https://github.com/nuniesmith/scripts/tree/main/scripts/setup"
    curl -fsSL "$DL" -o "$DEST" || die "Both fetch methods failed."
fi

chmod +x "$DEST"

FSIZE=$(wc -c < "$DEST" 2>/dev/null || echo "0")
[ "${FSIZE:-0}" -lt 100 ] 2>/dev/null && \
    die "File looks empty (${FSIZE} bytes). Is it pushed to GitHub yet?"

ok "Saved to RAM: ${DEST}  (${FSIZE} bytes)"
command -v sha256sum >/dev/null 2>&1 && \
    info "SHA256: $(sha256sum "$DEST" | cut -d' ' -f1)"

printf "\n"
sep

# ── Confirm ───────────────────────────────────────────────────────────────────
if [ "$NO_CONFIRM" = "false" ]; then
    printf "\n  ${BOLD}Ready to run:${NC}  ${C}${CHOSEN_FILE}${NC}\n"
    [ -n "$PASSTHROUGH" ] && printf "  ${BOLD}Extra args:${NC}   ${PASSTHROUGH}\n"
    printf "\n  ${Y}Continue? (Y/n):${NC} "
    read -r OK
    case "$OK" in n|N|no|No|NO) printf "\n  Cancelled.\n\n"; exit 0 ;; esac
fi

# ── Launch ────────────────────────────────────────────────────────────────────
printf "\n${G}${BOLD}━━━  Launching ${CHOSEN_FILE}  ━━━${NC}\n\n"

if command -v bash >/dev/null 2>&1; then
    exec bash "$DEST" $PASSTHROUGH
else
    exec sh "$DEST" $PASSTHROUGH
fi
