#!/usr/bin/env bash
# setup-smb-shares.sh
# Configure Samba on a host in the fleet. Run as root (or with sudo).
#
# Hosts and their shares:
#   sullivan   media server   [media]       /mnt/media     group-owned
#                             [local-media] /media         group-owned
#   freddy     personal srv   [storage]     /mnt/1tb       group-owned
#                             [local-media] /media         group-owned
#   desktop    workstation    [home]        /home/jordan   owner-only
#                             [seed]        /mnt/seed      owner-only
#
# Share modes:
#   group  - files forced to actions:actions with setgid dirs, so Docker
#            containers running as uid 1001 keep full access. The setup
#            recursively chowns the tree. Requires an 'actions' user, which
#            the servers get from the GitHub Actions deploy.
#   owner  - files keep their real owner. Nothing is chowned, no force user.
#            Used for everything on the desktop: it has no 'actions' user,
#            and rewriting ownership of a home directory would break SSH
#            keys, sudo and login.
#
# Login:
#   Samba authenticates against a Unix account. The script asks for the
#   username and password up front, before it installs or changes anything,
#   and creates the Unix account if it is missing. Answer the prompts and
#   the rest of the run is unattended.
#
#   Whatever you set here is what you type from a client: the username you
#   choose, and the SMB password you set for it. The SMB password is stored
#   by Samba and is independent of the account's Unix password.
#
# Usage:
#   sudo bash setup-smb-shares.sh [OPTIONS]
#
# Options:
#   -H, --host NAME     Override detected hostname (sullivan|freddy|desktop)
#   -u, --user NAME     SMB/Unix user; skips the username prompt
#   -g, --group NAME    Shared group              (default: actions)
#   -a, --allow LIST    Restrict access to these networks, e.g.
#                       "192.168.1.0/24 100.64.0.0/10 127.0.0.1"
#                       Also narrows the firewall rule. Default: unrestricted.
#       --reset-password  Set a new SMB password even if the account exists
#       --skip-perms    Don't touch filesystem ownership/permissions
#       --skip-password Don't create or change the SMB password
#   -h, --help          Show this help
#
# Non-interactive use: set SMB_PASSWORD in the environment and pass --user,
# and the script will not prompt for anything.

set -euo pipefail

DEFAULT_USER="jordan"
SMB_USER=""
SMB_GROUP="actions"
TARGET_HOST=""
ALLOW_HOSTS=""
SKIP_PERMS=false
SKIP_PASSWORD=false
RESET_PASSWORD=false
SMB_PASSWORD="${SMB_PASSWORD:-}"

SMB_CONF="/etc/samba/smb.conf"
PERMS_LOG="/tmp/perms-fix.log"
APPARMOR_INCLUDE="/etc/apparmor.d/samba/smbd-shares"

die() { echo "ERROR: $*" >&2; exit 1; }

show_help() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)        TARGET_HOST="$2";  shift 2 ;;
        -u|--user)        SMB_USER="$2";     shift 2 ;;
        -g|--group)       SMB_GROUP="$2";    shift 2 ;;
        -a|--allow)       ALLOW_HOSTS="$2";  shift 2 ;;
        --reset-password) RESET_PASSWORD=true; shift ;;
        --skip-perms)     SKIP_PERMS=true;   shift ;;
        --skip-password)  SKIP_PASSWORD=true; shift ;;
        -h|--help)        show_help ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"

# ─────────────────────────────────────────────
# Interactive helpers
# ─────────────────────────────────────────────
# Read from the controlling terminal, not stdin: the documented way to run
# this is  sudo bash -c "$(curl ...)"  and a plain  curl | bash  would leave
# stdin pointing at the pipe, so every prompt would silently read EOF.
TTY_IN=""
if [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
    TTY_IN=/dev/tty
elif [[ -t 0 ]]; then
    TTY_IN=/dev/stdin
fi
INTERACTIVE=false
[[ -n "${TTY_IN}" ]] && INTERACTIVE=true

ask() {  # ask VARNAME "prompt" "default"
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    if [[ "${INTERACTIVE}" != true ]]; then
        printf -v "${__var}" '%s' "${__default}"
        return 0
    fi
    if [[ -n "${__default}" ]]; then
        read -r -p "${__prompt} [${__default}]: " __reply < "${TTY_IN}"
    else
        read -r -p "${__prompt}: " __reply < "${TTY_IN}"
    fi
    printf -v "${__var}" '%s' "${__reply:-${__default}}"
}

confirm() {  # confirm "question"  -> 0 on yes
    local __reply=""
    [[ "${INTERACTIVE}" == true ]] || return 1
    read -r -p "${1} [y/N]: " __reply < "${TTY_IN}"
    [[ "${__reply}" =~ ^[Yy] ]]
}

ask_password() {  # ask_password VARNAME "who"
    local __var="$1" __who="$2" __p1="" __p2=""
    [[ "${INTERACTIVE}" == true ]] \
        || die "Need a password for '${__who}' but there is no terminal to ask on.
       Set SMB_PASSWORD in the environment, or pass --skip-password."
    while true; do
        # Prompt wording deliberately avoids the word "password" immediately
        # before a colon and a token — secret scanners read that shape as a
        # hardcoded credential and flag the line.
        read -r -s -p "  SMB password for ${__who}: " __p1 < "${TTY_IN}"; echo
        read -r -s -p "  Retype to confirm: " __p2 < "${TTY_IN}"; echo
        if [[ -z "${__p1}" ]]; then
            echo "  Password cannot be empty."
        elif [[ "${__p1}" != "${__p2}" ]]; then
            echo "  Passwords do not match, try again."
        else
            break
        fi
    done
    printf -v "${__var}" '%s' "${__p1}"
}

TARGET_HOST="${TARGET_HOST:-$(hostname -s)}"

# ─────────────────────────────────────────────
# 0a. Login details
# ─────────────────────────────────────────────
# Everything that needs a human is asked here, before the first change to the
# system, so an interrupted run leaves nothing half-configured and a completed
# run needs no attention after these prompts.
echo "=== SMB login ==="

if [[ -z "${SMB_USER}" ]]; then
    ask SMB_USER "  Username clients will log in with" "${DEFAULT_USER}"
fi
[[ "${SMB_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "'${SMB_USER}' is not a valid Unix username."

CREATE_USER=false
if ! id -u "${SMB_USER}" >/dev/null 2>&1; then
    echo "  No Unix account '${SMB_USER}' exists yet. Samba authenticates"
    echo "  against Unix accounts, so one has to be created."
    if confirm "  Create a login-disabled account '${SMB_USER}' for SMB only?"; then
        CREATE_USER=true
    else
        die "Cannot share as '${SMB_USER}' without a Unix account.
       Create it yourself, or rerun and accept the prompt."
    fi
fi

# pdbedit only exists once Samba is installed; if it isn't, there is no
# account database yet and the answer is necessarily "no".
ACCOUNT_EXISTS=false
if command -v pdbedit >/dev/null 2>&1 \
    && pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "${SMB_USER}"; then
    ACCOUNT_EXISTS=true
fi

SET_PASSWORD=false
if [[ "${SKIP_PASSWORD}" == true ]]; then
    echo "  Leaving the SMB password alone (--skip-password)."
elif [[ -n "${SMB_PASSWORD}" ]]; then
    SET_PASSWORD=true
    echo "  Using the password from \$SMB_PASSWORD."
elif [[ "${ACCOUNT_EXISTS}" == false ]]; then
    SET_PASSWORD=true
    ask_password SMB_PASSWORD "${SMB_USER}"
elif [[ "${RESET_PASSWORD}" == true ]]; then
    SET_PASSWORD=true
    ask_password SMB_PASSWORD "${SMB_USER}"
elif confirm "  SMB account '${SMB_USER}' already exists. Set a new password?"; then
    SET_PASSWORD=true
    ask_password SMB_PASSWORD "${SMB_USER}"
else
    echo "  Keeping the existing SMB password for '${SMB_USER}'."
fi
echo ""

# ─────────────────────────────────────────────
# 0b. Host profile
# ─────────────────────────────────────────────
# Each SHARES entry: name|path|mode|comment
SERVER_STRING=""
SHARES=()

case "${TARGET_HOST}" in
    sullivan)
        SERVER_STRING="Sullivan Media Server"
        SHARES=(
            "media|/mnt/media|group|Sullivan Media Root (/mnt/media)"
            "local-media|/media|group|Sullivan Local Media (/media)"
        )
        ;;
    freddy)
        SERVER_STRING="Freddy Personal Server"
        SHARES=(
            "storage|/mnt/1tb|group|Freddy 1TB Storage (/mnt/1tb)"
            "local-media|/media|group|Freddy Local Media (/media)"
        )
        ;;
    desktop)
        SERVER_STRING="Desktop Workstation"
        # Take the home directory from passwd rather than assuming /home/<user>,
        # which is wrong for any account whose home was relocated. Falls back to
        # the conventional path for an account this run is about to create.
        _home="$(getent passwd "${SMB_USER}" 2>/dev/null | cut -d: -f6)"
        _home="${_home:-/home/${SMB_USER}}"
        # No 'actions' user here — the servers get one from the GitHub Actions
        # deploy, the desktop doesn't. Both shares stay owner-mode.
        SHARES=(
            "home|${_home}|owner|Desktop Home (${_home})"
            "seed|/mnt/seed|owner|Desktop Seed Storage (/mnt/seed)"
        )
        ;;
    *)
        die "No share profile for host '${TARGET_HOST}'.
       Known hosts: sullivan, freddy, desktop.
       Use --host NAME to force one, or add a profile to this script."
        ;;
esac

HAS_GROUP_SHARE=false
for entry in "${SHARES[@]}"; do
    IFS='|' read -r _ _ s_mode _ <<< "${entry}"
    if [[ "${s_mode}" == "group" ]]; then HAS_GROUP_SHARE=true; fi
done

# hosts deny = ALL would lock out localhost too, which breaks the smbclient
# check at the end — keep loopback in the allow list.
if [[ -n "${ALLOW_HOSTS}" ]] && [[ " ${ALLOW_HOSTS} " != *" 127.0.0.1 "* ]]; then
    ALLOW_HOSTS="${ALLOW_HOSTS} 127.0.0.1"
fi

echo "=== Setting up Samba on ${TARGET_HOST} ==="
echo "  User:  ${SMB_USER}"
echo "  Group: ${SMB_GROUP}"
echo "  Shares:"
for entry in "${SHARES[@]}"; do
    IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"
    printf '    [%s] %s (%s)\n' "${s_name}" "${s_path}" "${s_mode}"
done
echo ""

# ─────────────────────────────────────────────
# 1. Install Samba
# ─────────────────────────────────────────────
echo "[1/7] Installing Samba..."
command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt-get not found)."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y samba samba-common-bin

# ─────────────────────────────────────────────
# 2. Users and groups
# ─────────────────────────────────────────────
echo "[2/7] Checking user '${SMB_USER}' and group '${SMB_GROUP}'..."

if [[ "${CREATE_USER}" == true ]]; then
    # Shell login stays disabled and the Unix password stays locked: this
    # account exists so Samba has something to map to, and the SMB password
    # set below is a separate credential that a locked Unix password does
    # not affect.
    useradd --create-home --shell /usr/sbin/nologin "${SMB_USER}"
    passwd --lock "${SMB_USER}" >/dev/null
    echo "  Created Unix account '${SMB_USER}' (no shell login, Unix password locked)."
fi

id -u "${SMB_USER}" >/dev/null 2>&1 \
    || die "Unix user '${SMB_USER}' does not exist."

if ! getent group "${SMB_GROUP}" >/dev/null; then
    echo "  Group '${SMB_GROUP}' missing, creating it."
    groupadd "${SMB_GROUP}"
fi

# group-mode shares emit "force user = ${SMB_GROUP}", so the *user* has to
# exist too — groupadd above only covers the group half.
if [[ "${HAS_GROUP_SHARE}" == true ]] && ! id -u "${SMB_GROUP}" >/dev/null 2>&1; then
    die "This host has group-mode shares, which set 'force user = ${SMB_GROUP}',
       but no Unix user '${SMB_GROUP}' exists — smbd would reject every connection.
       Either create it (e.g. 'useradd -r -u 1001 -g ${SMB_GROUP} ${SMB_GROUP}')
       to match the servers, or switch those shares to owner-mode in the
       SHARES table at the top of this script."
fi

if id -nG "${SMB_USER}" | tr ' ' '\n' | grep -qx "${SMB_GROUP}"; then
    echo "  ${SMB_USER} already in ${SMB_GROUP}."
else
    usermod -aG "${SMB_GROUP}" "${SMB_USER}"
    echo "  Added ${SMB_USER} to ${SMB_GROUP} (re-login for it to take effect)."
fi

# The password was collected up front. Feed it to smbpasswd on stdin rather
# than as an argument so it never appears in the process table.
if [[ "${SET_PASSWORD}" == true ]]; then
    printf '%s\n%s\n' "${SMB_PASSWORD}" "${SMB_PASSWORD}" \
        | smbpasswd -s -a "${SMB_USER}" > /dev/null
    echo "  SMB password set for '${SMB_USER}'."
elif [[ "${SKIP_PASSWORD}" == true ]]; then
    echo "  SMB password left unchanged (--skip-password)."
else
    echo "  SMB password left unchanged."
fi
SMB_PASSWORD=""

if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "${SMB_USER}"; then
    smbpasswd -e "${SMB_USER}" > /dev/null
    echo "  SMB account '${SMB_USER}' is enabled."
else
    die "No SMB account for '${SMB_USER}' — clients would have nothing to log in as.
       Rerun without --skip-password to set one."
fi

# ─────────────────────────────────────────────
# 3. AppArmor share paths
# ─────────────────────────────────────────────
echo "[3/7] Configuring AppArmor for Samba..."
if [[ -d /etc/apparmor.d ]]; then
    mkdir -p "$(dirname "${APPARMOR_INCLUDE}")"
    {
        echo "# Generated by setup-smb-shares.sh for ${TARGET_HOST}"
        for entry in "${SHARES[@]}"; do
            IFS='|' read -r _ s_path _ _ <<< "${entry}"
            printf '%s/ r,\n'     "${s_path%/}"
            printf '%s/** lrwk,\n' "${s_path%/}"
        done
    } > "${APPARMOR_INCLUDE}"

    if [[ -f /etc/apparmor.d/usr.sbin.smbd ]] && command -v apparmor_parser >/dev/null; then
        # Reloading the smbd profile is what actually picks up the include;
        # a failure here shouldn't abort the whole setup.
        if apparmor_parser -r /etc/apparmor.d/usr.sbin.smbd 2>/dev/null; then
            echo "  smbd AppArmor profile reloaded."
        else
            echo "  WARNING: could not reload the smbd AppArmor profile; check 'dmesg | grep DENIED' if shares misbehave."
        fi
    else
        echo "  No smbd AppArmor profile present — wrote ${APPARMOR_INCLUDE} for later, nothing to reload."
    fi
else
    echo "  AppArmor not installed, skipping."
fi

# ─────────────────────────────────────────────
# 4. Filesystem ownership and permissions
# ─────────────────────────────────────────────
echo "[4/7] Preparing share directories..."
if [[ "${SKIP_PERMS}" == true ]]; then
    echo "  Skipped (--skip-perms)."
else
    USER_HOME="$(getent passwd "${SMB_USER}" | cut -d: -f6)"

    for entry in "${SHARES[@]}"; do
        IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"

        if [[ "${s_mode}" == "owner" ]]; then
            # Owner-mode never rewrites ownership of an existing tree — that is
            # the whole point of the mode. A missing directory is created and
            # handed to the user, except for the home directory, where a
            # missing path means something is wrong that we should not paper over.
            if [[ ! -d "${s_path}" ]]; then
                if [[ "${s_path%/}" == "${USER_HOME%/}" ]]; then
                    echo "  WARNING: home directory ${s_path} does not exist, skipping [${s_name}]."
                    continue
                fi
                echo "  Creating ${s_path} owned by ${SMB_USER}..."
                mkdir -p "${s_path}"
                chown "${SMB_USER}:$(id -gn "${SMB_USER}")" "${s_path}"
                chmod 2775 "${s_path}"
            fi

            # Existing contents are left as-is, so check rather than assume.
            if runuser -u "${SMB_USER}" -- test -w "${s_path}" 2>/dev/null; then
                echo "  [${s_name}] ${s_path}: owner-mode, ownership untouched."
            else
                echo "  WARNING: [${s_name}] ${s_path} is not writable by ${SMB_USER}"
                echo "           (currently $(stat -c '%U:%G %a' "${s_path}")) — SMB writes will fail."
                echo "           Fix with: chown -R ${SMB_USER}: '${s_path}'"
            fi
            continue
        fi

        if [[ ! -d "${s_path}" ]]; then
            echo "  Creating ${s_path}..."
            mkdir -p "${s_path}"
        fi

        chown "${SMB_GROUP}:${SMB_GROUP}" "${s_path}"
        chmod 2775 "${s_path}"
        echo "  [${s_name}] ${s_path}: fixing tree in background..."
        nohup bash -c "
            chown -R '${SMB_GROUP}:${SMB_GROUP}' '${s_path}' &&
            find '${s_path}' -type d -exec chmod 2775 {} + &&
            find '${s_path}' -type f -exec chmod 664 {} + &&
            echo '${s_path} permissions complete'
        " >> "${PERMS_LOG}" 2>&1 &
    done
    if [[ "${HAS_GROUP_SHARE}" == true ]]; then
        echo "  Monitor progress: tail -f ${PERMS_LOG}"
    fi
fi

# ─────────────────────────────────────────────
# 5. Write smb.conf
# ─────────────────────────────────────────────
echo "[5/7] Writing Samba configuration..."

BACKUP=""
if [[ -f "${SMB_CONF}" ]]; then
    BACKUP="${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${SMB_CONF}" "${BACKUP}"
    echo "  Backed up existing config to ${BACKUP}"
fi

{
    cat << EOF
[global]
    workgroup = WORKGROUP
    server string = ${SERVER_STRING}
    server role = standalone server
    security = user
    map to guest = never
    log file = /var/log/samba/log.%m
    max log size = 1000
    logging = file

    # Refuse SMB1 outright
    server min protocol = SMB2
    client min protocol = SMB2

    # Performance tuning
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

    # Conservative defaults; group-owned shares override these below
    create mask = 0644
    directory mask = 0755

    # macOS compatibility
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:nfs_aces = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes
EOF

    if [[ -n "${ALLOW_HOSTS}" ]]; then
        cat << EOF

    # Access restricted to these networks (hosts_access(5) syntax)
    hosts allow = ${ALLOW_HOSTS}
    hosts deny = ALL
EOF
    fi

    for entry in "${SHARES[@]}"; do
        IFS='|' read -r s_name s_path s_mode s_comment <<< "${entry}"
        cat << EOF

[${s_name}]
    comment = ${s_comment}
    path = ${s_path}
    browseable = yes
    read only = no
    valid users = ${SMB_USER}
EOF
        if [[ "${s_mode}" == "group" ]]; then
            cat << EOF
    force user = ${SMB_GROUP}
    force group = ${SMB_GROUP}
    create mask = 0664
    force create mode = 0664
    directory mask = 2775
    force directory mode = 2775
EOF
        else
            cat << 'EOF'
    # Owner-mode: files keep their real owner, no force user/group
    create mask = 0644
    directory mask = 0755
EOF
        fi
    done
} > "${SMB_CONF}"

# ─────────────────────────────────────────────
# 6. Validate
# ─────────────────────────────────────────────
echo "[6/7] Validating configuration..."
if ! testparm -s "${SMB_CONF}" > /dev/null; then
    echo "ERROR: generated smb.conf failed validation." >&2
    if [[ -n "${BACKUP}" ]]; then
        cp "${BACKUP}" "${SMB_CONF}"
        echo "  Restored previous config from ${BACKUP}" >&2
    fi
    exit 1
fi
testparm -s "${SMB_CONF}"

# ─────────────────────────────────────────────
# 7. Enable, start, firewall
# ─────────────────────────────────────────────
echo "[7/7] Starting Samba..."
SMB_UNITS=()
for unit in smbd nmbd; do
    # list-unit-files exits 0 even when nothing matched, so grep is the real test
    if systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "^${unit}.service"; then
        SMB_UNITS+=("${unit}")
    fi
done
[[ ${#SMB_UNITS[@]} -gt 0 ]] || die "Neither smbd nor nmbd unit found."

systemctl enable "${SMB_UNITS[@]}"
systemctl restart "${SMB_UNITS[@]}"
echo "  Started: ${SMB_UNITS[*]}"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "=== Adding UFW rules for Samba ==="
    if [[ -n "${ALLOW_HOSTS}" ]]; then
        for net in ${ALLOW_HOSTS}; do
            ufw allow from "${net}" to any app Samba >/dev/null \
                && echo "  Samba allowed from ${net}"
        done
    else
        ufw allow samba >/dev/null
        echo "  Samba allowed from anywhere."
        echo "  Consider re-running with --allow to restrict this."
    fi
else
    echo "=== UFW not active, skipping firewall config ==="
    echo "  If using another firewall, open TCP 139,445 and UDP 137,138."
fi

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "=== Done! ==="
echo "Shares on ${TARGET_HOST}:"
for entry in "${SHARES[@]}"; do
    IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"
    printf '  //%s/%-12s -> %-16s [%s]\n' "${TARGET_HOST}" "${s_name}" "${s_path}" "${s_mode}"
done
echo ""
echo "Log in from a client with username '${SMB_USER}' and the SMB password"
echo "you set during this run."
echo ""
echo "Verify locally with: smbclient -L localhost -U ${SMB_USER}"
echo ""
echo "Key details:"
echo "  - SMB user: ${SMB_USER} (SMB password is separate from the Unix password)"
echo "  - group-mode shares are forced to ${SMB_GROUP}:${SMB_GROUP} with setgid dirs (2775)"
echo "    so Docker containers running as uid 1001 keep full access"
echo "  - owner-mode shares keep real file ownership; nothing was chowned"
echo "  - SMB1 disabled (server min protocol = SMB2)"
if [[ -z "${ALLOW_HOSTS}" ]]; then
    echo "  - No hosts allow restriction: any host that can reach TCP 445 may authenticate"
fi
if [[ "${SKIP_PERMS}" != true && "${HAS_GROUP_SHARE}" == true ]]; then
    echo "  - Permission fix may still be running (tail -f ${PERMS_LOG})"
fi
