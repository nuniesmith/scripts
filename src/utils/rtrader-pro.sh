#!/usr/bin/env bash
# rtrader-pro.sh — install Rithmic's R|Trader Pro under Wine on Linux.
#
#   ./rtrader-pro.sh ~/Downloads/RTraderPro.msi          # install
#   ./rtrader-pro.sh --check                             # what is missing?
#   ./rtrader-pro.sh --dry-run ~/Downloads/RTraderPro.msi
#   ./rtrader-pro.sh --launch                            # run it afterwards
#   ./rtrader-pro.sh --remove                            # delete the prefix
#
# WHY A DEDICATED PREFIX. Everything lands in ~/.wine-rithmic, not the default
# ~/.wine. A trading terminal is not something to debug alongside whatever else
# Wine is being used for, and a broken install is then one `--remove` away
# rather than a decision about which of your other Windows programs to sacrifice.
#
# WHAT I CANNOT PROMISE. R|Trader Pro's exact dependency set is not published,
# and I have not run this installer. The components below are the ones a .NET
# desktop trading client normally needs, and the script tells you what it did so
# a missing one is diagnosable rather than mysterious. If the app starts and
# immediately dies, that is almost always a missing runtime — see TROUBLESHOOTING
# at the bottom of this file.
set -Eeuo pipefail

PREFIX="${WINEPREFIX_RITHMIC:-$HOME/.wine-rithmic}"
ARCH="${WINEARCH_RITHMIC:-win64}"

# .NET is the one that actually matters. 4.8 is the last of the Framework line
# and is what current .NET Framework apps target; override if the installer
# complains about a specific version.
DOTNET="${RITHMIC_DOTNET:-dotnet48}"
EXTRAS="${RITHMIC_EXTRAS:-corefonts vcrun2019}"

say()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

DRY_RUN=false
MODE=install
MSI=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --check)   MODE=check ;;
        --launch)  MODE=launch ;;
        --remove)  MODE=remove ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        -*)        die "unknown option: $arg" ;;
        *)         MSI="$arg" ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '    would run: %s\n' "$*"
    else
        "$@"
    fi
}

# ─── what the host is missing ──────────────────────────────────────────────
#
# Reported all at once rather than failing on the first: being told to install
# wine, then winetricks, then a 32-bit library, one reboot at a time, is how a
# ten-minute job becomes an evening.
missing_prerequisites() {
    local missing=()
    command -v wine       >/dev/null 2>&1 || missing+=("wine")
    command -v winetricks >/dev/null 2>&1 || missing+=("winetricks")
    command -v cabextract >/dev/null 2>&1 || missing+=("cabextract")   # winetricks needs it for .NET
    printf '%s\n' "${missing[@]:-}"
}

install_hint() {
    if command -v apt-get >/dev/null 2>&1; then
        cat <<'HINT'
    Debian/Ubuntu — enable 32-bit first, or the .NET install will fail in a
    way that looks like a Wine bug:

        sudo dpkg --add-architecture i386
        sudo apt update
        sudo apt install -y wine wine64 wine32 winetricks cabextract
HINT
    elif command -v pacman >/dev/null 2>&1; then
        echo "    Arch:   sudo pacman -S wine wine-mono wine-gecko winetricks cabextract"
        echo "            (enable [multilib] in /etc/pacman.conf first)"
    elif command -v dnf >/dev/null 2>&1; then
        echo "    Fedora: sudo dnf install wine winetricks cabextract"
    else
        echo "    Install: wine, winetricks, cabextract (and 32-bit support)"
    fi
}

check() {
    say "Host"
    printf '    %-14s %s\n' "distro" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -o)"
    printf '    %-14s %s\n' "display" "${DISPLAY:-${WAYLAND_DISPLAY:-NONE — this needs a desktop, not a server}}"
    for t in wine winetricks cabextract; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '    %-14s %s\n' "$t" "$("$t" --version 2>/dev/null | head -1)"
        else
            printf '    %-14s \033[31mmissing\033[0m\n' "$t"
        fi
    done
    printf '    %-14s %s\n' "prefix" "$PREFIX $([[ -d "$PREFIX" ]] && echo '(exists)' || echo '(not created)')"

    local miss
    miss="$(missing_prerequisites)"
    if [[ -n "${miss// /}" ]]; then
        echo
        warn "missing: $(echo "$miss" | tr '\n' ' ')"
        install_hint
        return 1
    fi
    echo
    ok "prerequisites present"
}

case "$MODE" in
    check)  check; exit $? ;;
    remove)
        [[ -d "$PREFIX" ]] || die "no prefix at $PREFIX"
        say "Removing $PREFIX"
        run rm -rf "$PREFIX"
        ok "removed — re-run this script with the .msi to start over"
        exit 0
        ;;
    launch)
        [[ -d "$PREFIX" ]] || die "no prefix at $PREFIX — install first"
        exe="$(find "$PREFIX/drive_c" -iname 'RTraderPro*.exe' -o -iname 'R Trader Pro*.exe' 2>/dev/null | head -1)"
        [[ -n "$exe" ]] || die "could not find the executable under $PREFIX/drive_c"
        say "Launching $(basename "$exe")"
        exec env WINEPREFIX="$PREFIX" wine "$exe"
        ;;
esac

# ─── install ───────────────────────────────────────────────────────────────
[[ -n "$MSI" ]] || die "give me the path to RTraderPro.msi (or --check / --launch / --remove)"
[[ -f "$MSI" ]] || die "no such file: $MSI"
[[ "${MSI,,}" == *.msi ]] || warn "that does not look like an .msi — continuing anyway"

check || die "install the missing prerequisites above, then re-run"

if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    die "no display — the installer is a GUI. Run this on the laptop, not over a plain ssh session."
fi

export WINEPREFIX="$PREFIX"
export WINEARCH="$ARCH"
# The Mono/Gecko prompts are noise here: .NET Framework is installed properly by
# winetricks below, and Gecko is only needed for embedded browsers.
export WINEDLLOVERRIDES="mscoree,mshtml="

if [[ ! -d "$PREFIX" ]]; then
    say "Creating a $ARCH prefix at $PREFIX"
    run wineboot --init
    ok "prefix created"
else
    ok "prefix already exists at $PREFIX (re-running is safe)"
fi

say "Installing runtimes: $DOTNET $EXTRAS"
echo "    This is the slow part — .NET takes several minutes and prints alarming"
echo "    things. Let it finish."
# shellcheck disable=SC2086
run winetricks -q $DOTNET $EXTRAS
ok "runtimes installed"

say "Running the installer"
run wine msiexec /i "$(readlink -f "$MSI")"

if [[ "$DRY_RUN" == true ]]; then
    echo
    ok "dry run — nothing was changed"
    exit 0
fi

echo
ok "done"
cat <<EOF

  Launch it with:      $0 --launch
  Start over with:     $0 --remove

  ── the setting you actually came for ──

  TakeProfit Trader confirmed (2026-09-08) that ticking **"Allow Plugins" on the
  R|Trader Pro login screen** lets the terminal and a separate R|API application
  share ONE credential. Rithmic otherwise permits a single session per login, and
  whichever connects second takes it from the first.

  Tick it BEFORE you log in — it is a pre-connection setting.

  Test it away from an opening range. If the setting does not do what it says,
  logging in will take the session from the connector, which is precisely the
  failure this is meant to prevent.
EOF

# ── TROUBLESHOOTING ────────────────────────────────────────────────────────
#
# "starts and immediately exits"      — almost always a missing runtime. Run
#                                       without -q to see the real error:
#                                         WINEPREFIX=$PREFIX winetricks dotnet48
#
# ".NET install fails on Ubuntu"      — 32-bit support is not enabled. See the
#                                       dpkg --add-architecture line above; the
#                                       .NET installers are 32-bit even in a
#                                       win64 prefix.
#
# "installer window is blank/black"   — try a virtual desktop, which sidesteps a
#                                       lot of window-manager grief:
#                                         WINEPREFIX=$PREFIX winetricks vd=1280x1024
#
# "wants a different .NET version"    — override and re-run:
#                                         RITHMIC_DOTNET=dotnet472 $0 the.msi
#
# "logs in but no market data"        — that is not Wine. Check whether another
#                                       session holds the credential (the
#                                       connector, or the mobile app).
