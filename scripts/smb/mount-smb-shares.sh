#!/usr/bin/env bash
# mount-smb-shares.sh
# Mount fleet SMB shares on a Linux client. Run as root (or with sudo).
#
# The counterpart to setup-smb-shares.sh: that script publishes the shares,
# this one connects to them. Both read the same smb-fleet.conf, so a share
# added there shows up on both sides.
#
# What it does, per selected server:
#   1. installs cifs-utils
#   2. writes /etc/samba/credentials/<server>, mode 0600, root-owned, so no
#      password ever lands in /etc/fstab (which is world-readable)
#   3. creates mount points under /mnt/<server>/<share>
#   4. writes a marked block in /etc/fstab with systemd automount entries, so
#      shares mount on first access and a server that is down never blocks
#      boot or hangs a shell
#   5. starts the automount units and reports what actually mounted
#
# Re-running is safe: each server owns one marked block in /etc/fstab, which
# is replaced wholesale. Anything outside those markers is left alone.
#
# Usage:
#   sudo bash mount-smb-shares.sh --server sullivan --user jordan
#   sudo bash mount-smb-shares.sh --all
#   sudo bash mount-smb-shares.sh --server freddy --share storage
#   sudo bash mount-smb-shares.sh --server sullivan --remove
#
# Options:
#   -S, --server NAME   Server to mount from. Repeatable. Required unless --all.
#   -A, --all           Every server in the registry except this machine
#   -s, --share SPEC    Limit to these shares: SHARE or SERVER/SHARE. Repeatable.
#   -u, --user NAME     SMB username                     (default: jordan)
#       --address ADDR  Override the registry address. Only with one --server.
#       --uid UID       Local owner of mounted files     (default: invoking user)
#       --gid GID       Local group of mounted files     (default: invoking user)
#   -m, --mount-root D  Where to put mount points        (default: /mnt)
#       --vers V        SMB dialect                      (default: 3.1.1)
#       --secure        Require encrypted transport (seal)
#       --no-automount  Mount at boot instead of on first access
#       --reset-password  Rewrite the credentials file even if it exists
#       --credentials-dir D  Where credentials files live
#                            (default: /etc/samba/credentials)
#       --fstab PATH    fstab to edit (default: /etc/fstab). Mostly useful for
#                       testing or for editing a chroot's fstab.
#   -c, --config PATH   Registry file (default: smb-fleet.conf beside this
#                       script, then /etc/smb-fleet.conf, then built-in)
#   -l, --list          Print the registry and exit
#   -t, --test          Probe each server with smbclient; change nothing
#   -r, --remove        Unmount and remove entries for the selected servers
#       --purge         With --remove, also delete credentials and mount points
#       --dry-run       Show what would change; write nothing
#   -h, --help          Show this help
#
# Non-interactive use: set SMB_PASSWORD in the environment and pass --user.

set -euo pipefail

# ─────────────────────────────────────────────
# Shared fleet registry
# ─────────────────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/smb"
_LIB="$(dirname "${BASH_SOURCE[0]}")/smb-fleet.sh"

if [[ -f "$_LIB" ]]; then
    # shellcheck source=smb-fleet.sh
    . "$_LIB"
else
    _TMP=$(mktemp /tmp/smb-fleet.XXXXXX.sh)
    printf "  Fetching fleet registry from GitHub...\n"
    curl -fsSL "${REPO_RAW}/smb-fleet.sh" -o "$_TMP"
    # shellcheck source=/dev/null
    . "$_TMP"
    rm -f "$_TMP"
fi

DEFAULT_USER="jordan"
SMB_USER=""
SERVERS=()
WANT_SHARES=()
ADDRESS_OVERRIDE=""
MOUNT_ROOT="/mnt"
SMB_VERS="3.1.1"
CRED_DIR="/etc/samba/credentials"
FSTAB="/etc/fstab"
LOCAL_UID=""
LOCAL_GID=""
ALL_SERVERS=false
SECURE=false
AUTOMOUNT=true
RESET_PASSWORD=false
CONFIG_FILE=""
LIST_ONLY=false
TEST_ONLY=false
REMOVE=false
PURGE=false
DRY_RUN=false
SMB_PASSWORD="${SMB_PASSWORD:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

show_help() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S|--server)      SERVERS+=("$2");        shift 2 ;;
        -A|--all)         ALL_SERVERS=true;       shift ;;
        -s|--share)       WANT_SHARES+=("$2");    shift 2 ;;
        -u|--user)        SMB_USER="$2";          shift 2 ;;
        --address)        ADDRESS_OVERRIDE="$2";  shift 2 ;;
        --uid)            LOCAL_UID="$2";         shift 2 ;;
        --gid)            LOCAL_GID="$2";         shift 2 ;;
        -m|--mount-root)  MOUNT_ROOT="${2%/}";    shift 2 ;;
        --credentials-dir) CRED_DIR="${2%/}";    shift 2 ;;
        --fstab)          FSTAB="$2";            shift 2 ;;
        --vers)           SMB_VERS="$2";          shift 2 ;;
        --secure)         SECURE=true;            shift ;;
        --no-automount)   AUTOMOUNT=false;        shift ;;
        --reset-password) RESET_PASSWORD=true;    shift ;;
        -c|--config)      CONFIG_FILE="$2";       shift 2 ;;
        -l|--list)        LIST_ONLY=true;         shift ;;
        -t|--test)        TEST_ONLY=true;         shift ;;
        -r|--remove)      REMOVE=true;            shift ;;
        --purge)          PURGE=true;             shift ;;
        --dry-run)        DRY_RUN=true;           shift ;;
        -h|--help)        show_help ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

fleet_load "${CONFIG_FILE}"

if [[ "${LIST_ONLY}" == true ]]; then
    fleet_print
    exit 0
fi

# ─────────────────────────────────────────────
# Work out which servers and shares are in play
# ─────────────────────────────────────────────
THIS_HOST="$(hostname -s)"

if [[ "${ALL_SERVERS}" == true ]]; then
    while read -r name; do
        [[ -n "${name}" ]] || continue
        # Mounting a machine's own shares over the network is never what
        # --all means.
        [[ "${name}" == "${THIS_HOST}" ]] && continue
        SERVERS+=("${name}")
    done < <(fleet_host_names)
fi

if [[ ${#SERVERS[@]} -eq 0 ]]; then
    die "Nothing to do: pass --server NAME (repeatable) or --all.
       Known servers: $(fleet_host_names | tr '\n' ' ')
       See them with --list."
fi

# De-duplicate while preserving order, and validate against the registry.
_seen=""
_servers=()
for srv in "${SERVERS[@]}"; do
    [[ " ${_seen} " == *" ${srv} "* ]] && continue
    _seen="${_seen} ${srv}"
    fleet_have_host "${srv}" \
        || die "No registry entry for server '${srv}'.
       Known servers: $(fleet_host_names | tr '\n' ' ')
       Add it to ${FLEET_CONF_SOURCE}."
    _servers+=("${srv}")
done
SERVERS=("${_servers[@]}")

if [[ -n "${ADDRESS_OVERRIDE}" && ${#SERVERS[@]} -ne 1 ]]; then
    die "--address applies to a single server; you selected ${#SERVERS[@]}."
fi

# want_share SERVER SHARE -> 0 if selected
want_share() {
    local srv="$1" share="$2" spec
    [[ ${#WANT_SHARES[@]} -eq 0 ]] && return 0
    for spec in "${WANT_SHARES[@]}"; do
        case "${spec}" in
            */*) [[ "${spec}" == "${srv}/${share}" ]] && return 0 ;;
            *)   [[ "${spec}" == "${share}" ]] && return 0 ;;
        esac
    done
    return 1
}

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
# /etc/fstab is whitespace-separated, so spaces in a path have to be escaped.
fstab_escape() {
    local s="$1"
    s="${s// /\\040}"
    s="${s//$'\t'/\\011}"
    printf '%s' "${s}"
}

marker_begin() { printf '# >>> smb-fleet:%s >>> managed by mount-smb-shares.sh — do not edit inside' "$1"; }
marker_end()   { printf '# <<< smb-fleet:%s <<<' "$1"; }

# Drop an existing block for SERVER from a copy of fstab on stdout.
strip_block() {  # strip_block SERVER < fstab
    awk -v begin=">>> smb-fleet:$1 >>>" -v end="<<< smb-fleet:$1 <<<" '
        index($0, begin) { skip = 1; next }
        index($0, end)   { skip = 0; next }
        !skip            { print }
    '
}

automount_unit() {  # automount_unit MOUNTPOINT
    systemd-escape -p --suffix=automount "$1"
}

mount_unit() {  # mount_unit MOUNTPOINT
    systemd-escape -p --suffix=mount "$1"
}

have_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

run() {  # run CMD...  — honours --dry-run
    if [[ "${DRY_RUN}" == true ]]; then
        printf '    would run: %s\n' "$*"
    else
        "$@"
    fi
}

# ─────────────────────────────────────────────
# --test: probe only, no changes, no root needed
# ─────────────────────────────────────────────
if [[ "${TEST_ONLY}" == true ]]; then
    command -v smbclient >/dev/null 2>&1 \
        || die "smbclient not installed. Install it with: apt-get install -y smbclient"
    SMB_USER="${SMB_USER:-${DEFAULT_USER}}"
    echo "=== Probing servers as '${SMB_USER}' ==="
    rc=0
    for srv in "${SERVERS[@]}"; do
        addr="${ADDRESS_OVERRIDE:-$(fleet_host_address "${srv}")}"
        printf '\n--- %s (%s) ---\n' "${srv}" "${addr}"
        if ! ping -c1 -W2 "${addr}" >/dev/null 2>&1; then
            echo "  WARNING: ${addr} does not answer ICMP (may still serve SMB)."
        fi
        # smbclient reads $PASSWD, which keeps the secret out of the process
        # table; with none set it prompts on the terminal as usual.
        if PASSWD="${SMB_PASSWORD}" smbclient -L "//${addr}" -U "${SMB_USER}" 2>&1 \
            | sed 's/^/  /'; then
            :
        else
            echo "  FAILED to list shares on ${addr}"
            rc=1
        fi
    done
    exit "${rc}"
fi

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0 ..."

# ─────────────────────────────────────────────
# --remove: unmount and strip
# ─────────────────────────────────────────────
if [[ "${REMOVE}" == true ]]; then
    echo "=== Removing mounts for: ${SERVERS[*]} ==="
    for srv in "${SERVERS[@]}"; do
        echo "--- ${srv} ---"
        while IFS='|' read -r share _ _ _; do
            [[ -n "${share}" ]] || continue
            want_share "${srv}" "${share}" || continue
            mp="${MOUNT_ROOT}/${srv}/${share}"
            if have_systemd; then
                run systemctl stop "$(automount_unit "${mp}")" 2>/dev/null || true
                run systemctl stop "$(mount_unit "${mp}")" 2>/dev/null || true
            fi
            if mountpoint -q "${mp}" 2>/dev/null; then
                run umount "${mp}" || run umount -l "${mp}" || true
            fi
            echo "  unmounted ${mp}"
            if [[ "${PURGE}" == true && -d "${mp}" ]]; then
                run rmdir "${mp}" 2>/dev/null || true
            fi
        done < <(fleet_shares_for "${srv}")

        if grep -q ">>> smb-fleet:${srv} >>>" "${FSTAB}" 2>/dev/null; then
            if [[ "${DRY_RUN}" == true ]]; then
                echo "  would strip the ${srv} block from ${FSTAB}"
            else
                cp "${FSTAB}" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
                tmp="$(mktemp)"
                strip_block "${srv}" < "${FSTAB}" > "${tmp}"
                cat "${tmp}" > "${FSTAB}"
                rm -f "${tmp}"
                echo "  stripped the ${srv} block from ${FSTAB}"
            fi
        else
            echo "  no ${srv} block in ${FSTAB}"
        fi

        if [[ "${PURGE}" == true && -f "${CRED_DIR}/${srv}" ]]; then
            run rm -f "${CRED_DIR}/${srv}"
            echo "  removed ${CRED_DIR}/${srv}"
        fi
        [[ "${PURGE}" == true ]] && run rmdir "${MOUNT_ROOT}/${srv}" 2>/dev/null || true
    done
    have_systemd && run systemctl daemon-reload
    echo ""
    echo "=== Done. ==="
    exit 0
fi

# ─────────────────────────────────────────────
# 0. Credentials, asked up front
# ─────────────────────────────────────────────
if [[ -z "${SMB_USER}" ]]; then
    fleet_ask SMB_USER "  SMB username" "${DEFAULT_USER}"
fi

# Local ownership of the mounted files. The server decides the real ownership;
# these options only control what this machine displays and enforces locally,
# so default them to whoever invoked sudo rather than to root.
INVOKER="${SUDO_USER:-root}"
if [[ -z "${LOCAL_UID}" ]]; then
    LOCAL_UID="$(id -u "${INVOKER}" 2>/dev/null || echo 0)"
fi
if [[ -z "${LOCAL_GID}" ]]; then
    LOCAL_GID="$(id -g "${INVOKER}" 2>/dev/null || echo 0)"
fi

# One password covers every selected server; a server that already has a
# credentials file keeps it unless --reset-password says otherwise.
NEED_PASSWORD=false
for srv in "${SERVERS[@]}"; do
    if [[ "${RESET_PASSWORD}" == true || ! -f "${CRED_DIR}/${srv}" ]]; then
        NEED_PASSWORD=true
    fi
done

if [[ "${NEED_PASSWORD}" == true && -z "${SMB_PASSWORD}" && "${DRY_RUN}" != true ]]; then
    echo "=== SMB login ==="
    echo "  The password you set on the server for '${SMB_USER}'."
    fleet_ask_password SMB_PASSWORD "${SMB_USER}"
    echo ""
fi

echo "=== Mounting fleet shares on ${THIS_HOST} ==="
echo "  Registry:   ${FLEET_CONF_SOURCE}"
echo "  SMB user:   ${SMB_USER}"
echo "  Local uid:  ${LOCAL_UID}:${LOCAL_GID} (${INVOKER})"
echo "  Mount root: ${MOUNT_ROOT}"
echo "  Dialect:    SMB ${SMB_VERS}$([[ "${SECURE}" == true ]] && echo ", encrypted")"
echo "  Mode:       $([[ "${AUTOMOUNT}" == true ]] && echo "systemd automount (on first access)" || echo "mounted at boot")"
[[ "${DRY_RUN}" == true ]] && echo "  DRY RUN — nothing will be changed"
echo ""

# ─────────────────────────────────────────────
# 1. cifs-utils
# ─────────────────────────────────────────────
echo "[1/5] Installing cifs-utils..."
if command -v mount.cifs >/dev/null 2>&1; then
    echo "  Already present."
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update -qq
    run apt-get install -y cifs-utils smbclient
elif command -v pacman >/dev/null 2>&1; then
    run pacman -Sy --noconfirm cifs-utils smbclient
elif command -v dnf >/dev/null 2>&1; then
    run dnf install -y cifs-utils samba-client
else
    die "No supported package manager found; install cifs-utils yourself."
fi

# ─────────────────────────────────────────────
# 2. Credentials files
# ─────────────────────────────────────────────
echo "[2/5] Writing credentials..."
run mkdir -p "${CRED_DIR}"
run chmod 0700 "${CRED_DIR}"
for srv in "${SERVERS[@]}"; do
    cred="${CRED_DIR}/${srv}"
    if [[ -f "${cred}" && "${RESET_PASSWORD}" != true ]]; then
        echo "  ${cred} exists, keeping it (--reset-password to replace)."
        continue
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        echo "    would write ${cred} (0600, root:root)"
        continue
    fi
    # Create empty and lock it down *before* the secret goes in, so there is
    # no window where the file is readable by anyone else.
    install -m 0600 -o root -g root /dev/null "${cred}"
    {
        printf 'username=%s\n' "${SMB_USER}"
        printf 'password=%s\n' "${SMB_PASSWORD}"
        printf 'domain=WORKGROUP\n'
    } > "${cred}"
    echo "  Wrote ${cred} (0600, root:root)."
done
SMB_PASSWORD=""

# ─────────────────────────────────────────────
# 3. Mount points and fstab entries
# ─────────────────────────────────────────────
echo "[3/5] Preparing mount points and ${FSTAB}..."

MOUNTPOINTS=()

if [[ "${DRY_RUN}" != true ]]; then
    cp "${FSTAB}" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
fi

for srv in "${SERVERS[@]}"; do
    addr="${ADDRESS_OVERRIDE:-$(fleet_host_address "${srv}")}"
    block="$(mktemp)"
    n=0

    {
        marker_begin "${srv}"; printf '\n'
        printf '# server %s at %s, SMB user %s, written %s\n' \
            "${srv}" "${addr}" "${SMB_USER}" "$(date -Is)"
    } > "${block}"

    while IFS='|' read -r share path mode comment; do
        [[ -n "${share}" ]] || continue
        want_share "${srv}" "${share}" || continue

        mp="${MOUNT_ROOT}/${srv}/${share}"
        MOUNTPOINTS+=("${mp}")

        # Mirror the server's mode: group shares are group-writable there, so
        # make them group-writable here too; owner shares stay 0644/0755.
        if [[ "${mode}" == "group" ]]; then
            fmode=0664; dmode=0775
        else
            fmode=0644; dmode=0755
        fi

        opts="credentials=${CRED_DIR}/${srv}"
        opts+=",uid=${LOCAL_UID},gid=${LOCAL_GID}"
        opts+=",file_mode=${fmode},dir_mode=${dmode}"
        opts+=",vers=${SMB_VERS},iocharset=utf8,mfsymlinks"
        # nofail + _netdev: a server that is down must not wedge boot.
        opts+=",nofail,_netdev"
        [[ "${SECURE}" == true ]] && opts+=",seal"
        if [[ "${AUTOMOUNT}" == true ]]; then
            # noauto keeps `mount -a` from forcing these; systemd mounts them
            # on first access and unmounts them again after 10 idle minutes.
            opts+=",noauto,x-systemd.automount,x-systemd.idle-timeout=600"
            opts+=",x-systemd.mount-timeout=15"
        fi

        printf '# %s\n' "${comment:-${share}}" >> "${block}"
        printf '%s %s cifs %s 0 0\n' \
            "$(fstab_escape "//${addr}/${share}")" \
            "$(fstab_escape "${mp}")" \
            "${opts}" >> "${block}"

        if [[ ! -d "${mp}" ]]; then
            run mkdir -p "${mp}"
            [[ "${DRY_RUN}" == true ]] || echo "  Created ${mp}"
        fi
        n=$((n + 1))
    done < <(fleet_shares_for "${srv}")

    { marker_end "${srv}"; printf '\n'; } >> "${block}"

    if [[ ${n} -eq 0 ]]; then
        echo "  ${srv}: no shares matched the --share filter, skipped."
        rm -f "${block}"
        continue
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        echo "  ${srv}: would write this block to ${FSTAB}:"
        sed 's/^/    /' "${block}"
    else
        tmp="$(mktemp)"
        # Replace this server's block wholesale, leaving everything else in
        # the file untouched.
        strip_block "${srv}" < "${FSTAB}" > "${tmp}"
        # Collapse trailing blank lines so repeated runs don't grow the file.
        printf '%s\n' "$(cat "${tmp}")" > "${FSTAB}"
        cat "${block}" >> "${FSTAB}"
        rm -f "${tmp}"
        echo "  ${srv}: wrote ${n} entr$([[ ${n} -eq 1 ]] && echo y || echo ies) to ${FSTAB}"
    fi
    rm -f "${block}"
done

if [[ ${#MOUNTPOINTS[@]} -eq 0 ]]; then
    die "No shares selected. Check --share against --list."
fi

# ─────────────────────────────────────────────
# 4. Activate
# ─────────────────────────────────────────────
echo "[4/5] Activating mounts..."
if [[ "${DRY_RUN}" == true ]]; then
    echo "  Skipped (dry run)."
elif have_systemd; then
    systemctl daemon-reload
    for mp in "${MOUNTPOINTS[@]}"; do
        if [[ "${AUTOMOUNT}" == true ]]; then
            unit="$(automount_unit "${mp}")"
        else
            unit="$(mount_unit "${mp}")"
        fi
        if systemctl start "${unit}" 2>/dev/null; then
            echo "  started ${unit}"
        else
            echo "  WARNING: ${unit} failed to start — systemctl status ${unit}"
        fi
    done
else
    echo "  No systemd; mounting directly."
    for mp in "${MOUNTPOINTS[@]}"; do
        mountpoint -q "${mp}" && continue
        mount "${mp}" 2>/dev/null \
            && echo "  mounted ${mp}" \
            || echo "  WARNING: could not mount ${mp}"
    done
fi

# ─────────────────────────────────────────────
# 5. Verify
# ─────────────────────────────────────────────
echo "[5/5] Verifying..."
FAILED=0
if [[ "${DRY_RUN}" == true ]]; then
    echo "  Skipped (dry run)."
else
    for mp in "${MOUNTPOINTS[@]}"; do
        # With automount the share is only mounted once something touches it,
        # so touch it: this is the test that proves the credentials work.
        if ls "${mp}" >/dev/null 2>&1 && mountpoint -q "${mp}"; then
            printf '  OK       %s\n' "${mp}"
        elif [[ "${AUTOMOUNT}" == true ]] && have_systemd; then
            printf '  FAILED   %s — check: journalctl -u %s\n' \
                "${mp}" "$(mount_unit "${mp}")"
            FAILED=$((FAILED + 1))
        else
            printf '  FAILED   %s\n' "${mp}"
            FAILED=$((FAILED + 1))
        fi
    done
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "=== Dry run complete, nothing changed. ==="
elif [[ ${FAILED} -eq 0 ]]; then
    echo "=== Done! ==="
else
    echo "=== Done, with ${FAILED} share(s) not mounted. ==="
fi
echo "$([[ "${DRY_RUN}" == true ]] && echo "Would mount" || echo "Mounted") under ${MOUNT_ROOT}:"
for mp in "${MOUNTPOINTS[@]}"; do
    printf '  %s\n' "${mp}"
done
echo ""
echo "Key details:"
if [[ "${AUTOMOUNT}" == true ]]; then
    echo "  - Shares mount on first access and unmount after 10 idle minutes;"
    echo "    a server being down costs a timeout, not a hung boot."
else
    echo "  - Shares mount at boot (nofail, so a missing server won't block it)."
fi
echo "  - Credentials live in ${CRED_DIR}/<server>, mode 0600 — /etc/fstab"
echo "    is world-readable, so no password is written there"
echo "  - Undo with: sudo bash $0 --server <name> --remove [--purge]"
echo "  - Probe a server without changing anything: $0 --server <name> --test"
[[ ${FAILED} -gt 0 ]] && exit 1
exit 0
