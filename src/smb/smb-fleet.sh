#!/usr/bin/env bash
# =============================================================================
# smb-fleet.sh — shared fleet registry + helpers for the SMB scripts
# =============================================================================
# SOURCE this file; do NOT run it directly.
#
#   . "$(dirname "$0")/smb-fleet.sh"
#   # or fetch from GitHub:
#   _b=$(mktemp); curl -fsSL "${REPO_RAW}/smb-fleet.sh" -o "$_b"; . "$_b"; rm -f "$_b"
#
# Holds the single description of which host serves which share, so that
# setup-smb-shares.sh (server side) and mount-smb-shares.sh (client side)
# cannot drift apart. The built-in table below is the fallback; an on-disk
# smb-fleet.conf overrides it entirely.
#
# All public functions are prefixed  fleet_
# Internal helpers are prefixed      _fleet_
# =============================================================================

# Guard against double-sourcing
[ -n "${_SMB_FLEET_LOADED:-}" ] && return 0
_SMB_FLEET_LOADED=1

# =============================================================================
# Colors & logging  (skipped if setup-ubuntu.sh already provided them)
# =============================================================================
if [ -z "${_SETUP_UBUNTU_LOADED:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    # shellcheck disable=SC2034  # part of the shared palette, used by callers
    DIM='\033[2m'
    NC='\033[0m'

    log_info()    { printf "${BLUE}[INFO]${NC}    %s\n"  "$*"; }
    log_success() { printf "${GREEN}[OK]${NC}      %s\n" "$*"; }
    log_warn()    { printf "${YELLOW}[WARN]${NC}   %s\n" "$*"; }
    log_error()   { printf "${RED}[ERROR]${NC}   %s\n"   "$*" >&2; }
    log_step()    { printf "${MAGENTA}[STEP]${NC}  ${BOLD}%s${NC}\n" "$*"; }
    log_skip()    { printf "${YELLOW}[SKIP]${NC}   %s\n" "$*"; }
    log_die()     { printf "${RED}[FATAL]${NC}  %s\n" "$*" >&2; exit 1; }

    log_header() {
        printf "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════════${NC}\n"
        printf   "${BOLD}${CYAN}  %s${NC}\n" "$*"
        printf   "${BOLD}${CYAN}══════════════════════════════════════════════════════════════════${NC}\n\n"
    }
fi

# =============================================================================
# Prompting
# =============================================================================
# Read from the controlling terminal, not stdin: the documented way to run
# these scripts is  sudo bash -c "$(curl ...)"  and a plain  curl | bash  would
# leave stdin pointing at the pipe, so every prompt would silently read EOF.
FLEET_TTY_IN=""
if [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
    FLEET_TTY_IN=/dev/tty
elif [ -t 0 ]; then
    FLEET_TTY_IN=/dev/stdin
fi
FLEET_INTERACTIVE=false
[ -n "${FLEET_TTY_IN}" ] && FLEET_INTERACTIVE=true

fleet_ask() {  # fleet_ask VARNAME "prompt" "default"
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    if [ "${FLEET_INTERACTIVE}" != true ]; then
        printf -v "${__var}" '%s' "${__default}"
        return 0
    fi
    if [ -n "${__default}" ]; then
        read -r -p "${__prompt} [${__default}]: " __reply < "${FLEET_TTY_IN}"
    else
        read -r -p "${__prompt}: " __reply < "${FLEET_TTY_IN}"
    fi
    printf -v "${__var}" '%s' "${__reply:-${__default}}"
}

fleet_confirm() {  # fleet_confirm "question"  -> 0 on yes
    local __reply=""
    [ "${FLEET_INTERACTIVE}" = true ] || return 1
    read -r -p "${1} [y/N]: " __reply < "${FLEET_TTY_IN}"
    [[ "${__reply}" =~ ^[Yy] ]]
}

fleet_ask_password() {  # fleet_ask_password VARNAME "who"
    local __var="$1" __who="$2" __p1="" __p2=""
    [ "${FLEET_INTERACTIVE}" = true ] \
        || log_die "Need a secret for '${__who}' but there is no terminal to ask on.
        Set SMB_PASSWORD in the environment instead."
    while true; do
        # Prompt wording deliberately avoids the word "password" immediately
        # before a colon and a token — secret scanners read that shape as a
        # hardcoded credential and flag the line.
        read -r -s -p "  SMB password for ${__who}: " __p1 < "${FLEET_TTY_IN}"; echo
        read -r -s -p "  Retype to confirm: " __p2 < "${FLEET_TTY_IN}"; echo
        if [ -z "${__p1}" ]; then
            echo "  Cannot be empty."
        elif [ "${__p1}" != "${__p2}" ]; then
            echo "  Entries do not match, try again."
        else
            break
        fi
    done
    printf -v "${__var}" '%s' "${__p1}"
}

# =============================================================================
# Built-in registry
# =============================================================================
# Record types, '|' separated:
#   host |NAME|ADDRESS|SERVER STRING
#   share|HOST|SHARE|PATH|MODE|COMMENT
#
# ADDRESS is what a *client* dials: hostname, FQDN or Tailscale IP. It defaults
# to NAME when left empty.
#
# MODE:
#   group  files forced to the shared group (default 'actions') with setgid
#          dirs, so Docker containers running as that uid keep full access.
#          The server setup recursively chowns the tree.
#   owner  files keep their real owner. Nothing is chowned, no force user.
#          Used for anything under a real user's home, where rewriting
#          ownership would break SSH keys, sudo and login.
#
# PATH may be '~' or '~/sub' to mean the SMB user's home directory, resolved
# from passwd at run time.
#
# Keep this in sync with smb-fleet.conf, which overrides it when present.
_FLEET_BUILTIN='
host |sullivan|sullivan|Sullivan Media Server
share|sullivan|media|/mnt/media|group|Sullivan Media Root (/mnt/media)
share|sullivan|local-media|/media|group|Sullivan Local Media (/media)

host |freddy|freddy|Freddy Personal Server
share|freddy|storage|/mnt/1tb|group|Freddy 1TB Storage (/mnt/1tb)
share|freddy|local-media|/media|group|Freddy Local Media (/media)

host |desktop|desktop|Desktop Workstation
share|desktop|home|~|owner|Desktop Home
share|desktop|seed|/mnt/seed|owner|Desktop Seed Storage (/mnt/seed)
'

# Populated by fleet_load
FLEET_HOSTS=()          # NAME|ADDRESS|SERVER STRING
FLEET_SHARES=()         # HOST|SHARE|PATH|MODE|COMMENT
FLEET_CONF_SOURCE=""    # path the registry came from, or "built-in"

_fleet_trim() {  # _fleet_trim STRING -> stdout
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_fleet_parse() {  # _fleet_parse < stream
    local line type f1 f2 f3 f4 f5 rest lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        line="${line%%#*}"
        line="$(_fleet_trim "${line}")"
        [ -n "${line}" ] || continue

        IFS='|' read -r type f1 f2 f3 f4 rest <<< "${line}"
        type="$(_fleet_trim "${type}")"
        f1="$(_fleet_trim "${f1}")"
        f2="$(_fleet_trim "${f2}")"
        f3="$(_fleet_trim "${f3}")"
        f4="$(_fleet_trim "${f4}")"
        f5="$(_fleet_trim "${rest}")"

        case "${type}" in
            host)
                [ -n "${f1}" ] || { log_warn "registry line ${lineno}: host with no name, ignored"; continue; }
                fleet_upsert_host "${f1}" "${f2:-${f1}}" "${f3:-${f1}}"
                ;;
            share)
                [ -n "${f1}" ] && [ -n "${f2}" ] && [ -n "${f3}" ] \
                    || { log_warn "registry line ${lineno}: share needs HOST|SHARE|PATH, ignored"; continue; }
                fleet_upsert_share "${f1}" "${f2}" "${f3}" "${f4:-group}" "${f5:-${f2}}"
                ;;
            *)
                log_warn "registry line ${lineno}: unknown record type '${type}', ignored"
                ;;
        esac
    done
}

# fleet_load [FILE]
# Loads the first registry found among: $1, $SMB_FLEET_CONF, smb-fleet.conf
# next to the script, /etc/smb-fleet.conf. Falls back to the built-in table.
fleet_load() {
    local explicit="${1:-}" candidate here
    FLEET_HOSTS=()
    FLEET_SHARES=()

    here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"

    if [ -n "${explicit}" ]; then
        [ -f "${explicit}" ] || log_die "Registry file not found: ${explicit}"
        FLEET_CONF_SOURCE="${explicit}"
        _fleet_parse < "${explicit}"
        return 0
    fi

    for candidate in \
        "${SMB_FLEET_CONF:-}" \
        "${here:+${here}/smb-fleet.conf}" \
        /etc/smb-fleet.conf
    do
        [ -n "${candidate}" ] && [ -f "${candidate}" ] || continue
        FLEET_CONF_SOURCE="${candidate}"
        _fleet_parse < "${candidate}"
        return 0
    done

    FLEET_CONF_SOURCE="built-in"
    _fleet_parse <<< "${_FLEET_BUILTIN}"
}

# fleet_upsert_host NAME ADDRESS "SERVER STRING"
fleet_upsert_host() {
    local name="$1" addr="${2:-$1}" str="${3:-$1}" i
    for i in "${!FLEET_HOSTS[@]}"; do
        if [ "${FLEET_HOSTS[$i]%%|*}" = "${name}" ]; then
            FLEET_HOSTS[i]="${name}|${addr}|${str}"
            return 0
        fi
    done
    FLEET_HOSTS+=("${name}|${addr}|${str}")
}

# fleet_upsert_share HOST SHARE PATH MODE "COMMENT"
fleet_upsert_share() {
    local host="$1" share="$2" path="$3" mode="${4:-group}" comment="${5:-$2}" i
    case "${mode}" in
        group|owner) ;;
        *) log_die "Share ${host}/${share}: mode must be 'group' or 'owner', got '${mode}'." ;;
    esac
    # A host referenced only by a share still needs an entry so clients can
    # look up its address.
    fleet_have_host "${host}" || fleet_upsert_host "${host}" "${host}" "${host}"
    for i in "${!FLEET_SHARES[@]}"; do
        IFS='|' read -r _h _s _ _ _ <<< "${FLEET_SHARES[$i]}"
        if [ "${_h}" = "${host}" ] && [ "${_s}" = "${share}" ]; then
            FLEET_SHARES[i]="${host}|${share}|${path}|${mode}|${comment}"
            return 0
        fi
    done
    FLEET_SHARES+=("${host}|${share}|${path}|${mode}|${comment}")
}

fleet_host_names() {
    local entry
    for entry in "${FLEET_HOSTS[@]}"; do printf '%s\n' "${entry%%|*}"; done
}

fleet_have_host() {  # fleet_have_host NAME
    local entry
    for entry in "${FLEET_HOSTS[@]:-}"; do
        [ "${entry%%|*}" = "$1" ] && return 0
    done
    return 1
}

fleet_host_address() {  # fleet_host_address NAME -> stdout
    local entry name addr
    for entry in "${FLEET_HOSTS[@]}"; do
        IFS='|' read -r name addr _ <<< "${entry}"
        [ "${name}" = "$1" ] || continue
        printf '%s' "${addr:-${name}}"
        return 0
    done
    return 1
}

fleet_host_string() {  # fleet_host_string NAME -> stdout
    local entry name str
    for entry in "${FLEET_HOSTS[@]}"; do
        IFS='|' read -r name _ str <<< "${entry}"
        [ "${name}" = "$1" ] || continue
        printf '%s' "${str:-${name}}"
        return 0
    done
    return 1
}

# fleet_shares_for HOST -> SHARE|PATH|MODE|COMMENT per line
fleet_shares_for() {
    local entry host
    for entry in "${FLEET_SHARES[@]:-}"; do
        host="${entry%%|*}"
        [ "${host}" = "$1" ] || continue
        printf '%s\n' "${entry#*|}"
    done
}

# fleet_resolve_path PATH USER -> stdout
# Expands a leading '~' to USER's home, from passwd, with the conventional
# path as a fallback for an account that does not exist yet.
fleet_resolve_path() {
    local path="$1" user="$2" home=""
    # A literal tilde is what the registry stores; expanding it against the
    # invoking shell's $HOME (root's) is exactly what we must not do.
    # shellcheck disable=SC2088
    case "${path}" in
        '~'|'~/'*) ;;
        *) printf '%s' "${path}"; return 0 ;;
    esac
    # getent exits non-zero for an unknown user; under `set -e` an unguarded
    # command substitution would take the whole script down before the
    # fallback below could run.
    home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)"
    home="${home:-/home/${user}}"
    home="${home%/}"
    if [ "${path}" = '~' ]; then
        printf '%s' "${home}"
    else
        printf '%s%s' "${home}" "${path#\~}"
    fi
}

# fleet_print — human-readable dump of the loaded registry
fleet_print() {
    local host name addr str line share path mode comment
    printf '%bRegistry:%b %s\n\n' "${BOLD}" "${NC}" "${FLEET_CONF_SOURCE}"
    for host in $(fleet_host_names); do
        IFS='|' read -r name addr str <<< "$(printf '%s|%s|%s' \
            "${host}" "$(fleet_host_address "${host}")" "$(fleet_host_string "${host}")")"
        printf '  %b%s%b  (%s) — %s\n' "${BOLD}" "${name}" "${NC}" "${addr}" "${str}"
        while IFS='|' read -r share path mode comment; do
            [ -n "${share}" ] || continue
            printf '      %-34s -> %-18s [%s] %s\n' \
                "//${addr}/${share}" "${path}" "${mode}" "${comment}"
        done < <(fleet_shares_for "${host}")
        printf '\n'
    done
}
