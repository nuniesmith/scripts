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
#                             [seed]        /mnt/seed      group-owned
#
# Share modes:
#   group  - files forced to actions:actions with setgid dirs, so Docker
#            containers running as uid 1001 keep full access. The setup
#            recursively chowns the tree.
#   owner  - files keep their real owner. Nothing is chowned, no force user.
#            Used for /home/jordan: rewriting ownership of a home directory
#            breaks SSH keys, sudo and login.
#
# Usage:
#   sudo bash setup-smb-shares.sh [OPTIONS]
#
# Options:
#   -H, --host NAME     Override detected hostname (sullivan|freddy|desktop)
#   -u, --user NAME     SMB/Unix user             (default: jordan)
#   -g, --group NAME    Shared group              (default: actions)
#   -a, --allow LIST    Restrict access to these networks, e.g.
#                       "192.168.1.0/24 100.64.0.0/10 127.0.0.1"
#                       Also narrows the firewall rule. Default: unrestricted.
#       --skip-perms    Don't touch filesystem ownership/permissions
#       --skip-password Don't create/prompt for the SMB password
#   -h, --help          Show this help

set -euo pipefail

SMB_USER="jordan"
SMB_GROUP="actions"
TARGET_HOST=""
ALLOW_HOSTS=""
SKIP_PERMS=false
SKIP_PASSWORD=false

SMB_CONF="/etc/samba/smb.conf"
PERMS_LOG="/tmp/perms-fix.log"
APPARMOR_INCLUDE="/etc/apparmor.d/samba/smbd-shares"

die() { echo "ERROR: $*" >&2; exit 1; }

show_help() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)       TARGET_HOST="$2";  shift 2 ;;
        -u|--user)       SMB_USER="$2";     shift 2 ;;
        -g|--group)      SMB_GROUP="$2";    shift 2 ;;
        -a|--allow)      ALLOW_HOSTS="$2";  shift 2 ;;
        --skip-perms)    SKIP_PERMS=true;   shift ;;
        --skip-password) SKIP_PASSWORD=true; shift ;;
        -h|--help)       show_help ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"

TARGET_HOST="${TARGET_HOST:-$(hostname -s)}"

# ─────────────────────────────────────────────
# 0. Host profile
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
        SHARES=(
            "home|/home/${SMB_USER}|owner|Desktop Home (/home/${SMB_USER})"
            "seed|/mnt/seed|group|Desktop Seed Storage (/mnt/seed)"
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
    [[ "${s_mode}" == "group" ]] && HAS_GROUP_SHARE=true
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
id -u "${SMB_USER}" >/dev/null 2>&1 \
    || die "Unix user '${SMB_USER}' does not exist. Create it before running this."

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

# Samba password — only prompt when the account doesn't exist yet, so reruns
# are non-interactive.
if [[ "${SKIP_PASSWORD}" == true ]]; then
    echo "  Skipping SMB password (--skip-password)."
elif pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "${SMB_USER}"; then
    echo "  SMB account '${SMB_USER}' already exists, leaving password alone."
    smbpasswd -e "${SMB_USER}" >/dev/null
else
    echo "  Creating SMB account '${SMB_USER}' — you'll be prompted for a password."
    smbpasswd -a "${SMB_USER}"
    smbpasswd -e "${SMB_USER}" >/dev/null
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
    for entry in "${SHARES[@]}"; do
        IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"

        if [[ ! -d "${s_path}" ]]; then
            if [[ "${s_mode}" == "owner" ]]; then
                echo "  WARNING: ${s_path} does not exist, skipping [${s_name}]."
                continue
            fi
            echo "  Creating ${s_path}..."
            mkdir -p "${s_path}"
        fi

        if [[ "${s_mode}" == "owner" ]]; then
            # Never recurse into a home directory. Just make sure the top
            # level is traversable by smbd, which runs as the user anyway.
            echo "  [${s_name}] ${s_path}: owner-mode, leaving ownership untouched."
            continue
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
    echo "  Monitor progress: tail -f ${PERMS_LOG}"
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
echo "Verify with: smbclient -L localhost -U ${SMB_USER}"
echo ""
echo "Key details:"
echo "  - SMB user: ${SMB_USER}"
echo "  - group-mode shares are forced to ${SMB_GROUP}:${SMB_GROUP} with setgid dirs (2775)"
echo "    so Docker containers running as uid 1001 keep full access"
echo "  - owner-mode shares keep real file ownership; nothing was chowned"
echo "  - SMB1 disabled (server min protocol = SMB2)"
if [[ -z "${ALLOW_HOSTS}" ]]; then
    echo "  - No hosts allow restriction: any host that can reach TCP 445 may authenticate"
fi
if [[ "${SKIP_PERMS}" != true ]]; then
    echo "  - Permission fix may still be running (tail -f ${PERMS_LOG})"
fi
