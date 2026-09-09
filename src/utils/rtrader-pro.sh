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
#   ./rtrader-pro.sh --mono                              # install Wine Mono (Ubuntu omits it)
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
        --mono)    MODE=mono ;;
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

# ─── Wine Mono ─────────────────────────────────────────────────────────────
#
# Ubuntu does not package it. `apt-cache policy wine-mono` returns nothing on
# 26.04, and Wine's own download prompt did not appear during wineboot, so a
# fresh prefix has no .NET implementation at all — the application installs
# perfectly and then dies with:
#
#     err:mscoree:CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed
#
# The version has to MATCH the Wine build: Wine looks for one specific filename
# in ~/.cache/wine and ignores anything else. Rather than hardcode a number that
# goes stale, the version is read out of Wine's own appwiz.cpl, which is where
# the installer prompt gets it from.
mono_wanted_version() {
    # appwiz.cpl builds the filename from a WIDE string literal:
    #     L"wine-mono-" MONO_VERSION "-" MONO_ARCH ".msi"
    # so it is UTF-16LE in the binary. Plain `strings` scans for ASCII and can
    # never match it — that is why every earlier attempt came back empty on a
    # machine where the file was present and readable. -el scans 16-bit LE.
    local cpl f v
    for cpl in $(find /usr/lib /usr/lib64 /opt -name 'appwiz.cpl' 2>/dev/null); do
        for enc in -el -e l ""; do
            v="$(strings $enc "$cpl" 2>/dev/null \
                 | grep -oE 'wine-mono-[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
            [[ -n "$v" ]] && { echo "${v#wine-mono-}"; return 0; }
        done
    done
    # Wine's version is the reliable fallback: the mapping is fixed per release.
    case "$(wine --version 2>/dev/null)" in
        wine-10.0*) echo "9.4.0"; return 0 ;;
        wine-9.0*)  echo "8.1.0"; return 0 ;;
    esac
    return 1
}


install_mono() {
    command -v strings >/dev/null 2>&1 || die "need 'strings' (apt install binutils) to read the version Wine wants"
    local ver
    ver="$(mono_wanted_version)"
    [[ -n "$ver" ]] || die "could not read the Wine Mono version from appwiz.cpl — install it by hand from https://dl.winehq.org/wine/wine-mono/"

    local msi="wine-mono-${ver}-x86.msi"
    local url="https://dl.winehq.org/wine/wine-mono/${ver}/${msi}"
    local cache="$HOME/.cache/wine"

    say "Wine wants Mono $ver (read from appwiz.cpl, not guessed)"
    run mkdir -p "$cache"
    if [[ -f "$cache/$msi" ]]; then
        ok "already downloaded: $cache/$msi"
    else
        say "Fetching $url"
        run curl -fL --retry 3 -o "$cache/$msi" "$url" \
            || die "download failed — check https://dl.winehq.org/wine/wine-mono/ for $ver"
    fi

    # Wine searches ~/.cache/wine for exactly this filename and installs it
    # itself. Preferred over `msiexec /i` because it is the path Wine tests.
    say "Installing into $PREFIX via wineboot -u"
    run env WINEPREFIX="$PREFIX" wineboot -u

    # Verify rather than announce. msiexec under Wine exits 0 in situations
    # where nothing was installed, and "Wine Mono installed" is a claim worth
    # checking before the next failure sends someone down a different path.
    if [[ "$DRY_RUN" == true ]]; then
        ok "dry run"
    elif find "$PREFIX/drive_c" -maxdepth 4 -iname 'mono' -type d 2>/dev/null | grep -q . \
      || ls "$PREFIX/drive_c/windows/mono" >/dev/null 2>&1; then
        ok "Wine Mono $ver is in the prefix — try: $0 --launch"
    else
        warn "msiexec finished but no Mono directory appeared under drive_c"
        echo "    Look for it by hand:"
        echo "      find $PREFIX/drive_c -iname 'mono*' -maxdepth 4"
        echo "    If it really is not there, the fallback is real .NET:"
        echo "      $0 --remove && $0 --dotnet <the.msi>"
        exit 1
    fi
}

diagnose() {
    export WINEPREFIX="$PREFIX"
    echo "── wine ──────────────────────────────────────────────"
    echo "  binary   : $(command -v wine || echo MISSING)"
    echo "  version  : $(wine --version 2>&1 | head -1)"
    echo "  prefix   : $PREFIX $([[ -d $PREFIX ]] && echo '(exists)' || echo '(MISSING)')"
    echo "  arch     : $(grep -a '#arch' "$PREFIX/system.reg" 2>/dev/null | head -1)"

    echo "── where wine keeps its appwiz (the file that names the Mono version) ──"
    local found=false
    for d in /usr/lib/x86_64-linux-gnu/wine /usr/lib/wine /opt/wine-stable/lib/wine \
             /opt/wine-devel/lib/wine /usr/lib64/wine; do
        for f in "$d"/x86_64-unix/appwiz.cpl.so "$d"/i386-unix/appwiz.cpl.so \
                 "$d"/x86_64-windows/appwiz.cpl "$d"/i386-windows/appwiz.cpl; do
            [[ -r "$f" ]] || continue
            found=true
            printf '  %s\n' "$f"
            strings "$f" 2>/dev/null | grep -oE 'wine-mono-[0-9]+\.[0-9]+\.[0-9]+' \
                | sort -u | sed 's/^/      names: /'
            strings "$f" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' \
                | sort -u | head -5 | sed 's/^/      bare versions: /'
        done
    done
    $found || echo "  NONE FOUND — that is why --mono could not work out a version"

    echo "── what is actually installed ────────────────────────"
    echo "  mono dirs under drive_c:"
    find "$PREFIX/drive_c" -maxdepth 4 -iname '*mono*' 2>/dev/null | sed 's/^/    /' \
        | head -10 || true
    [[ -d "$PREFIX/drive_c/windows/mono" ]] \
        && echo "    windows/mono EXISTS" || echo "    windows/mono is ABSENT"

    echo "  msi files cached in ~/.cache/wine:"
    ls -la "$HOME/.cache/wine" 2>/dev/null | sed 's/^/    /' || echo "    (no such directory)"

    echo "── network reachability of the Mono download host ────"
    if command -v curl >/dev/null; then
        curl -sSI --max-time 15 https://dl.winehq.org/wine/wine-mono/ 2>&1 \
            | head -1 | sed 's/^/    /'
    else
        echo "    curl is not installed"
    fi
}

case "$MODE" in
    check)  check; exit $? ;;
    diagnose) diagnose; exit 0 ;;
    mono)
        [[ -d "$PREFIX" ]] || die "no prefix at $PREFIX — install first"
        export WINEPREFIX="$PREFIX"
        install_mono
        exit 0
        ;;
    remove)
        # Deleting the prefix also deletes the settings inside it — including
        # "Allow Plugins", which is set once and easy to forget you ever set.
        # Save them first; an unwanted tarball is cheaper than rediscovering
        # a preference at 08:25 ET.
        if [[ -d "$PREFIX" ]]; then
            backup="$HOME/rtrader-settings-$(date +%F-%H%M).tgz"
            say "Saving settings to $backup before removing the prefix"
            ( cd "$PREFIX" && tar czf "$backup" user.reg \
                $(find drive_c/users -ipath '*ithmic*' -prune -print 2>/dev/null) \
              ) 2>/dev/null && ok "saved" || warn "could not save settings — continuing"
        fi
        [[ -d "$PREFIX" ]] || die "no prefix at $PREFIX"
        say "Removing $PREFIX"
        run rm -rf "$PREFIX"
        ok "removed — re-run this script with the .msi to start over"
        exit 0
        ;;
    launch)
        [[ -d "$PREFIX" ]] || die "no prefix at $PREFIX — install first"
        # The installed name is "Rithmic Trader Pro.exe", which neither of the
        # first two guesses ("RTraderPro*.exe", "R Trader Pro*.exe") matched —
        # the .msi is called rtraderpro.msi and the program is not. Matched on
        # the words now, in either order, and the -not filters keep the
        # uninstaller and bundled helpers out of the way.
        exe="$(find "$PREFIX/drive_c" -type f \
                    \( -iname '*rithmic*trader*.exe' -o -iname '*rtrader*.exe' \) \
                    -not -iname '*unins*' -not -iname '*setup*' \
                    2>/dev/null | sort | head -1)"
        if [[ -z "$exe" ]]; then
            printf '\033[31m✘\033[0m %s\n' "could not find the executable under $PREFIX/drive_c" >&2
            echo "  .exe files that ARE there:" >&2
            find "$PREFIX/drive_c" -type f -iname '*.exe' 2>/dev/null \
                | grep -viE 'windows/|winsxs' | head -15 | sed 's|^|    |' >&2
            exit 1
        fi
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

  If it dies with "Wine Mono is not installed" — Ubuntu does not ship it:

      $0 --mono

  If it installed but will not START for some other reason:

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
