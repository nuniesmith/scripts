#!/usr/bin/env bash
# setup-smb-shares.sh
# Configure Samba on a host in the fleet. Run as root (or with sudo).
#
# Which host serves what lives in smb-fleet.conf, not in this script — see
# that file to add a host or change a share. mount-smb-shares.sh reads the
# same registry from the client side, so the two cannot drift apart.
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
#   -H, --host NAME     Override detected hostname (must exist in the registry
#                       unless you also pass --share)
#   -u, --user NAME     SMB/Unix user; skips the username prompt
#   -U, --extra-user N  Additional SMB user with access. Repeatable. Created
#                       and given an SMB password like the primary user.
#   -g, --group NAME    Shared group              (default: actions)
#   -a, --allow LIST    Restrict access to these networks, e.g.
#                       "192.168.1.0/24 100.64.0.0/10 127.0.0.1"
#                       Also narrows the firewall rule. Default: unrestricted.
#   -s, --share SPEC    Add or override one share, as NAME:PATH[:MODE[:COMMENT]]
#                       MODE is group (default) or owner. Repeatable. Lets you
#                       set up a host that has no registry entry.
#   -c, --config PATH   Registry file (default: smb-fleet.conf beside this
#                       script, then /etc/smb-fleet.conf, then built-in)
#   -l, --list          Print the registry and exit
#       --secure        Require SMB3 and encrypted transport
#       --dry-run       Show what would change; write nothing
#       --reset-password  Set a new SMB password even if the account exists
#       --skip-perms    Don't touch filesystem ownership/permissions
#       --skip-password Don't create or change the SMB password
#   -h, --help          Show this help
#
# Non-interactive use: set SMB_PASSWORD in the environment and pass --user,
# and the script will not prompt for anything.

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
EXTRA_USERS=()
SMB_GROUP="actions"
TARGET_HOST=""
ALLOW_HOSTS=""
CLI_SHARES=()
CONFIG_FILE=""
LIST_ONLY=false
SECURE=false
DRY_RUN=false
SKIP_PERMS=false
SKIP_PASSWORD=false
RESET_PASSWORD=false
SMB_PASSWORD="${SMB_PASSWORD:-}"

SMB_CONF="/etc/samba/smb.conf"
# Not /tmp: this runs as root and appends to the file for minutes afterwards,
# which in a world-writable directory is a symlink waiting to happen.
PERMS_LOG="/var/log/smb-perms-fix.log"
APPARMOR_INCLUDE="/etc/apparmor.d/samba/smbd-shares"

die() { echo "ERROR: $*" >&2; exit 1; }

show_help() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)        TARGET_HOST="$2";  shift 2 ;;
        -u|--user)        SMB_USER="$2";     shift 2 ;;
        -U|--extra-user)  EXTRA_USERS+=("$2"); shift 2 ;;
        -g|--group)       SMB_GROUP="$2";    shift 2 ;;
        -a|--allow)       ALLOW_HOSTS="$2";  shift 2 ;;
        -s|--share)       CLI_SHARES+=("$2"); shift 2 ;;
        -c|--config)      CONFIG_FILE="$2";  shift 2 ;;
        -l|--list)        LIST_ONLY=true;    shift ;;
        --secure)         SECURE=true;       shift ;;
        --dry-run)        DRY_RUN=true;      shift ;;
        --reset-password) RESET_PASSWORD=true; shift ;;
        --skip-perms)     SKIP_PERMS=true;   shift ;;
        --skip-password)  SKIP_PASSWORD=true; shift ;;
        -h|--help)        show_help ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

fleet_load "${CONFIG_FILE}"

if [[ "${LIST_ONLY}" == true ]]; then
    fleet_print
    exit 0
fi

[[ $EUID -eq 0 ]] || die "Must run as root: sudo bash $0"

TARGET_HOST="${TARGET_HOST:-$(hostname -s)}"

# ─────────────────────────────────────────────
# 0a. Login details
# ─────────────────────────────────────────────
# Everything that needs a human is asked here, before the first change to the
# system, so an interrupted run leaves nothing half-configured and a completed
# run needs no attention after these prompts.
echo "=== SMB login ==="

if [[ -z "${SMB_USER}" ]]; then
    fleet_ask SMB_USER "  Username clients will log in with" "${DEFAULT_USER}"
fi

# Accounts to create, and accounts to set a password for, decided up front and
# acted on in step 2. Parallel arrays keep this working on bash 3.
CREATE_USERS=()
PW_USERS=()
PW_VALUES=()

smb_account_exists() {  # smb_account_exists USER
    # pdbedit only exists once Samba is installed; if it isn't, there is no
    # account database yet and the answer is necessarily "no".
    command -v pdbedit >/dev/null 2>&1 || return 1
    pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$1"
}

plan_user() {  # plan_user USER IS_PRIMARY
    local user="$1" primary="$2" pw=""

    [[ "${user}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "'${user}' is not a valid Unix username."

    if ! id -u "${user}" >/dev/null 2>&1; then
        echo "  No Unix account '${user}' exists yet. Samba authenticates"
        echo "  against Unix accounts, so one has to be created."
        if fleet_confirm "  Create a login-disabled account '${user}' for SMB only?"; then
            CREATE_USERS+=("${user}")
        else
            die "Cannot share as '${user}' without a Unix account.
       Create it yourself, or rerun and accept the prompt."
        fi
    fi

    if [[ "${SKIP_PASSWORD}" == true ]]; then
        echo "  Leaving the SMB password for '${user}' alone (--skip-password)."
        return 0
    fi

    if [[ "${primary}" == true && -n "${SMB_PASSWORD}" ]]; then
        echo "  Using the secret from \$SMB_PASSWORD for '${user}'."
        pw="${SMB_PASSWORD}"
    elif [[ "${primary}" != true && "${FLEET_INTERACTIVE}" != true ]]; then
        # $SMB_PASSWORD covers the primary user only — there is no way to
        # supply one per extra user without a terminal.
        die "Extra user '${user}' needs an SMB password, and there is no terminal
       to ask on. Run this interactively, or add the user afterwards with
       'smbpasswd -a ${user}'."
    elif ! smb_account_exists "${user}"; then
        fleet_ask_password pw "${user}"
    elif [[ "${RESET_PASSWORD}" == true ]]; then
        fleet_ask_password pw "${user}"
    elif fleet_confirm "  SMB account '${user}' already exists. Set a new password?"; then
        fleet_ask_password pw "${user}"
    else
        echo "  Keeping the existing SMB password for '${user}'."
        return 0
    fi

    PW_USERS+=("${user}")
    PW_VALUES+=("${pw}")
}

plan_user "${SMB_USER}" true
for _u in "${EXTRA_USERS[@]:-}"; do
    [[ -n "${_u}" ]] || continue
    plan_user "${_u}" false
done
SMB_PASSWORD=""
echo ""

# valid users list for every share
VALID_USERS="${SMB_USER}"
for _u in "${EXTRA_USERS[@]:-}"; do
    [[ -n "${_u}" ]] && VALID_USERS+=" ${_u}"
done

# ─────────────────────────────────────────────
# 0b. Host profile
# ─────────────────────────────────────────────
# --share entries are layered on top of the registry, so you can extend a
# known host or stand up one the registry has never heard of.
for spec in "${CLI_SHARES[@]:-}"; do
    [[ -n "${spec}" ]] || continue
    IFS=':' read -r c_name c_path c_mode c_comment <<< "${spec}"
    [[ -n "${c_name}" && -n "${c_path}" ]] \
        || die "--share needs at least NAME:PATH, got '${spec}'"
    fleet_upsert_share "${TARGET_HOST}" "${c_name}" "${c_path}" \
        "${c_mode:-group}" "${c_comment:-${c_name}}"
done

fleet_have_host "${TARGET_HOST}" \
    || die "No profile for host '${TARGET_HOST}'.
       Known hosts: $(fleet_host_names | tr '\n' ' ')
       Use --host NAME to force one, add it to ${FLEET_CONF_SOURCE},
       or define shares inline with --share NAME:PATH[:MODE]."

SERVER_STRING="$(fleet_host_string "${TARGET_HOST}")"

# Each SHARES entry: name|path|mode|comment, with '~' already resolved.
SHARES=()
while IFS='|' read -r s_name s_path s_mode s_comment; do
    [[ -n "${s_name}" ]] || continue
    s_path="$(fleet_resolve_path "${s_path}" "${SMB_USER}")"
    SHARES+=("${s_name}|${s_path}|${s_mode}|${s_comment}")
done < <(fleet_shares_for "${TARGET_HOST}")

[[ ${#SHARES[@]} -gt 0 ]] \
    || die "Host '${TARGET_HOST}' has no shares defined. Add some to
       ${FLEET_CONF_SOURCE}, or pass --share NAME:PATH[:MODE]."

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
echo "  Registry: ${FLEET_CONF_SOURCE}"
echo "  Users:    ${VALID_USERS}"
echo "  Group:    ${SMB_GROUP}"
[[ "${SECURE}" == true ]] && echo "  Transport: SMB3, encryption required"
[[ "${DRY_RUN}" == true ]] && echo "  DRY RUN — nothing will be changed"
echo "  Shares:"
for entry in "${SHARES[@]}"; do
    IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"
    printf '    [%s] %s (%s)\n' "${s_name}" "${s_path}" "${s_mode}"
done
echo ""

# ─────────────────────────────────────────────
# smb.conf generation (also used by --dry-run)
# ─────────────────────────────────────────────
generate_smb_conf() {
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

EOF
    if [[ "${SECURE}" == true ]]; then
        cat << 'EOF'
    # --secure: SMB3 only, and refuse to talk in the clear
    server min protocol = SMB3
    client min protocol = SMB3
    smb encrypt = required
EOF
    else
        cat << 'EOF'
    # Refuse SMB1 outright. Re-run with --secure to require SMB3 + encryption.
    server min protocol = SMB2
    client min protocol = SMB2
EOF
    fi
    cat << 'EOF'

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
    valid users = ${VALID_USERS}
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
}

if [[ "${DRY_RUN}" == true ]]; then
    echo "=== smb.conf that would be written to ${SMB_CONF} ==="
    generate_smb_conf
    echo ""
    echo "=== Dry run complete, nothing changed. ==="
    exit 0
fi

# ─────────────────────────────────────────────
# 1. Install Samba
# ─────────────────────────────────────────────
echo "[1/8] Installing Samba..."
command -v apt-get >/dev/null || die "This script targets Debian/Ubuntu (apt-get not found)."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y samba samba-common-bin

# ─────────────────────────────────────────────
# 2. Users and groups
# ─────────────────────────────────────────────
echo "[2/8] Checking users and group '${SMB_GROUP}'..."

for user in "${CREATE_USERS[@]:-}"; do
    [[ -n "${user}" ]] || continue
    # Shell login stays disabled and the Unix password stays locked: this
    # account exists so Samba has something to map to, and the SMB password
    # set below is a separate credential that a locked Unix password does
    # not affect.
    useradd --create-home --shell /usr/sbin/nologin "${user}"
    passwd --lock "${user}" >/dev/null
    echo "  Created Unix account '${user}' (no shell login, Unix password locked)."
done

for user in ${VALID_USERS}; do
    id -u "${user}" >/dev/null 2>&1 || die "Unix user '${user}' does not exist."
done

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
       to match the servers, or switch those shares to owner-mode in
       ${FLEET_CONF_SOURCE}."
fi

for user in ${VALID_USERS}; do
    if id -nG "${user}" | tr ' ' '\n' | grep -qx "${SMB_GROUP}"; then
        echo "  ${user} already in ${SMB_GROUP}."
    else
        usermod -aG "${SMB_GROUP}" "${user}"
        echo "  Added ${user} to ${SMB_GROUP} (re-login for it to take effect)."
    fi
done

# The passwords were collected up front. Feed them to smbpasswd on stdin
# rather than as arguments so they never appear in the process table.
for i in "${!PW_USERS[@]}"; do
    printf '%s\n%s\n' "${PW_VALUES[$i]}" "${PW_VALUES[$i]}" \
        | smbpasswd -s -a "${PW_USERS[$i]}" > /dev/null
    echo "  SMB password set for '${PW_USERS[$i]}'."
    PW_VALUES[i]=""
done
PW_VALUES=()

for user in ${VALID_USERS}; do
    if smb_account_exists "${user}"; then
        smbpasswd -e "${user}" > /dev/null
        echo "  SMB account '${user}' is enabled."
    else
        die "No SMB account for '${user}' — clients would have nothing to log in as.
       Rerun without --skip-password to set one."
    fi
done

# ─────────────────────────────────────────────
# 3. AppArmor share paths
# ─────────────────────────────────────────────
# Samba ships update-apparmor-samba-profile to generate this file, but it is
# only wired into the SysV init script, which systemd hosts never run. The
# smbd profile does 'include if exists <samba/smbd-shares>', so writing it
# here is what actually grants access to the share paths.
echo "[3/8] Configuring AppArmor for Samba..."
if [[ -d /etc/apparmor.d ]]; then
    mkdir -p "$(dirname "${APPARMOR_INCLUDE}")"
    {
        echo "# Generated by setup-smb-shares.sh for ${TARGET_HOST}"
        for entry in "${SHARES[@]}"; do
            IFS='|' read -r _ s_path _ _ <<< "${entry}"
            printf '"%s/" rk,\n'      "${s_path%/}"
            printf '"%s/**" rwkl,\n'  "${s_path%/}"
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
echo "[4/8] Preparing share directories..."
if [[ "${SKIP_PERMS}" == true ]]; then
    echo "  Skipped (--skip-perms)."
else
    # getent exits non-zero for an unknown user, and under `set -e` that would
    # take the script down inside a command substitution.
    USER_HOME="$(getent passwd "${SMB_USER}" 2>/dev/null | cut -d: -f6 || true)"

    for entry in "${SHARES[@]}"; do
        IFS='|' read -r s_name s_path s_mode _ <<< "${entry}"

        if [[ "${s_mode}" == "owner" ]]; then
            # Owner-mode never rewrites ownership of an existing tree — that is
            # the whole point of the mode. A missing directory is created and
            # handed to the user, except for the home directory, where a
            # missing path means something is wrong that we should not paper over.
            if [[ ! -d "${s_path}" ]]; then
                if [[ -n "${USER_HOME}" && "${s_path%/}" == "${USER_HOME%/}" ]]; then
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
        # Path and group go in as arguments, not interpolated into the script
        # text, so a quote or a space in either cannot break out of the shell.
        nohup bash -c '
            chown -R "$1:$1" "$2" &&
            find "$2" -type d -exec chmod 2775 {} + &&
            find "$2" -type f -exec chmod 664 {} + &&
            echo "$2 permissions complete"
        ' _ "${SMB_GROUP}" "${s_path}" >> "${PERMS_LOG}" 2>&1 &
    done
    if [[ "${HAS_GROUP_SHARE}" == true ]]; then
        echo "  Monitor progress: tail -f ${PERMS_LOG}"
    fi
fi

# ─────────────────────────────────────────────
# 5. Write smb.conf
# ─────────────────────────────────────────────
echo "[5/8] Writing Samba configuration..."

BACKUP=""
if [[ -f "${SMB_CONF}" ]]; then
    BACKUP="${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${SMB_CONF}" "${BACKUP}"
    echo "  Backed up existing config to ${BACKUP}"
fi

generate_smb_conf > "${SMB_CONF}"

# ─────────────────────────────────────────────
# 6. Validate
# ─────────────────────────────────────────────
echo "[6/8] Validating configuration..."
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
echo "[7/8] Starting Samba..."
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
# 8. Self-test
# ─────────────────────────────────────────────
# Anonymous share listing: enough to prove smbd is up and the shares parsed,
# without asking for the password again.
echo "[8/8] Verifying smbd answers on localhost..."
if smbclient -L localhost -N >/dev/null 2>&1; then
    echo "  smbd is answering and advertising its share list."
elif smbclient -L localhost -N 2>&1 | grep -qi 'NT_STATUS_ACCESS_DENIED'; then
    echo "  smbd is answering (anonymous listing refused, which is expected)."
else
    echo "  WARNING: could not list shares from localhost."
    echo "           Check: systemctl status smbd; journalctl -u smbd -n 50"
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
echo "Log in from a client with one of: ${VALID_USERS}"
echo "and the SMB password you set during this run."
echo ""
echo "Mount these from a Linux client with:"
echo "  sudo bash mount-smb-shares.sh --server ${TARGET_HOST} --user ${SMB_USER}"
echo "From Windows, run map-network-drives.ps1 as Administrator."
echo ""
echo "Verify locally with: smbclient -L localhost -U ${SMB_USER}"
echo ""
echo "Key details:"
echo "  - SMB passwords are separate from Unix passwords"
echo "  - group-mode shares are forced to ${SMB_GROUP}:${SMB_GROUP} with setgid dirs (2775)"
echo "    so Docker containers running as uid 1001 keep full access"
echo "  - owner-mode shares keep real file ownership; nothing was chowned"
if [[ "${SECURE}" == true ]]; then
    echo "  - SMB3 required, transport encryption required"
else
    echo "  - SMB1 disabled (server min protocol = SMB2); --secure raises this to SMB3 + encryption"
fi
if [[ -z "${ALLOW_HOSTS}" ]]; then
    echo "  - No hosts allow restriction: any host that can reach TCP 445 may authenticate"
fi
if [[ "${SKIP_PERMS}" != true && "${HAS_GROUP_SHARE}" == true ]]; then
    echo "  - Permission fix may still be running (tail -f ${PERMS_LOG})"
fi
