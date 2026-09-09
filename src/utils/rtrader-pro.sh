#!/usr/bin/env bash
# rtrader-pro.sh — install Rithmic's R|Trader Pro under Wine on Linux.
#
#   ./rtrader-pro.sh ~/Downloads/RTraderPro.msi          # install
#   ./rtrader-pro.sh --check                             # what is missing?
#   ./rtrader-pro.sh --dry-run ~/Downloads/RTraderPro.msi
#   ./rtrader-pro.sh --launch                            # run it afterwards
#   ./rtrader-pro.sh --remove                            # delete the prefix
#   ./rtrader-pro.sh --dotnet the.msi                    # real .NET, if Mono fails
#   ./rtrader-pro.sh --fonts  the.msi                    # MS corefonts, if text looks wrong
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

# Wine Mono FIRST, real .NET only if that fails.
#
# Wine ships Mono, its own .NET Framework implementation, already installed in
# every new prefix. It costs nothing and handles a good many .NET applications.
#
# The alternative — winetricks' dotnet verbs — is not one download. Each version
# depends on the one before it, so `dotnet472` pulls 462, which pulls 461, which
# pulls 46, and so on down to dotnet20: roughly ten packages and 500 MB, each
# needing a working 32-bit stack. On Ubuntu's wine 10.0, which runs the new
# WoW64 mode with no separate 32-bit binary, it usually fails somewhere in the
# middle after twenty minutes of downloading.
#
# So: try Mono, and only reach for the chain with --dotnet if the app actually
# refuses to run.
# And nothing else by default either.
#
# `corefonts` looked harmless and is not: it is a metapackage of about a dozen
# separate font downloads, each followed by a slow regedit round-trip through
# Wine. First run on real hardware got five fonts deep and was still going. It
# affects how text LOOKS, not whether the application runs.
#
# The minimal path — create a prefix, run the installer — takes seconds. Add
# things only when something actually fails, which is the opposite of how the
# first two versions of this script behaved.
USE_DOTNET=false
USE_FONTS=false
DOTNET="${RITHMIC_DOTNET:-dotnet48}"
EXTRAS="${RITHMIC_EXTRAS:-}"

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
        --dotnet)  USE_DOTNET=true ;;
        --fonts)   USE_FONTS=true ;;
        --check)   MODE=check ;;
        --launch)  MODE=launch ;;
        --remove)  MODE=remove ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
    Debian/Ubuntu. The i386 line only matters for --dotnet, but adding it now
    costs nothing and saves a confusing failure later:

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
# winetricks says it plainly — "32-bit prefixes may work better" — and the .NET
# installers are 32-bit regardless of the prefix. Only relevant on the --dotnet
# path; Mono is happy in win64.
if [[ "$USE_DOTNET" == true && -z "${WINEARCH_RITHMIC:-}" ]]; then
    ARCH=win32
fi
export WINEARCH="$ARCH"

# Gecko is only needed for embedded browsers and its prompt is noise. mscoree is
# deliberately NOT overridden here: that disables Wine Mono, which is the whole
# point of the default path.
export WINEDLLOVERRIDES="mshtml="
if [[ "$USE_DOTNET" == true ]]; then
    # Real .NET replaces Mono, so Mono has to be out of the way for it.
    export WINEDLLOVERRIDES="mscoree,mshtml="
fi

if [[ ! -d "$PREFIX" ]]; then
    say "Creating a $ARCH prefix at $PREFIX"
    run wineboot --init
    ok "prefix created"
else
    ok "prefix already exists at $PREFIX (re-running is safe)"
fi

VERBS="$EXTRAS"
[[ "$USE_FONTS"  == true ]] && VERBS="corefonts $VERBS"
[[ "$USE_DOTNET" == true ]] && VERBS="$DOTNET $VERBS"

if [[ "$USE_DOTNET" == true ]]; then
    warn "Installing real .NET ($DOTNET) — this pulls EVERY earlier version too"
    echo "    Roughly ten packages and 500 MB. Twenty minutes on a good line, and"
    echo "    it can still fail on new-WoW64 Wine. Only worth it if Mono did not"
    echo "    work. Ctrl-C now if you have not already tried without --dotnet."
fi
[[ "$USE_FONTS" == true ]] && warn "corefonts is a dozen separate downloads — it is slow"

if [[ -n "${VERBS// /}" ]]; then
    say "Installing: $VERBS"
    # shellcheck disable=SC2086
    run winetricks -q $VERBS
    ok "extras installed"
else
    say "No extras — Wine Mono is already in the prefix, going straight to the installer"
    echo "    If it will not START afterwards, try --dotnet. If the TEXT looks"
    echo "    wrong, try --fonts. Neither is needed until it is."
fi

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

  If the TEXT looks wrong, add Microsoft's fonts:

      $0 --fonts ~/Downloads/rtraderpro.msi

  If it installed but will not START, that is Mono not being enough for it:

      $0 --remove
      $0 --dotnet ~/Downloads/rtraderpro.msi

  which builds a 32-bit prefix and installs the real .NET Framework. Budget
  half an hour and a few hundred megabytes.

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
