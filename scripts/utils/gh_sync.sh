#!/usr/bin/env bash
#
# gh_sync.sh — mirror every repo you own into ~/github, keep submodules
# in sync, and (optionally) prune repos that no longer exist on GitHub.
#
# Runs unattended (hourly via systemd) without ever destroying local work.
# When run by hand in a terminal it will also walk you through first-time
# setup: prompting for a GitHub token and helping register an SSH key.
#
# Usage:
#   gh_sync.sh [sync]                 Run one sync now (default).
#   gh_sync.sh install [--user|--system]
#                                     Install a systemd service + hourly timer
#                                     so the sync keeps running on its own.
#                                     Defaults to --user unless run as root.
#   gh_sync.sh uninstall [--user|--system]   Stop and remove the units.
#   gh_sync.sh status    [--user|--system]   Show timer/service state + logs.
#   gh_sync.sh help                   Show this help.

set -uo pipefail

# ---- Config (all overridable via env) -------------------------------------
GH_USER="${GH_USER:-nuniesmith}"
TARGET_DIR="${TARGET_DIR:-$HOME/github}"
PROTOCOL="${PROTOCOL:-ssh}"              # ssh | https  (ssh recommended)
PRUNE="${PRUNE:-1}"                      # 1 = remove repos deleted from GitHub
PROTECT_DIRTY="${PROTECT_DIRTY:-1}"      # 1 = never delete/clobber local work
DOCKER_MAINT="${DOCKER_MAINT:-1}"        # 1 = docker prune at the end
SUBMODULE_REMOTE="${SUBMODULE_REMOTE:-0}" # 1 = bump submodules to latest (see notes)

# Repos to clone/pull WITHOUT recursing submodules (space-separated names).
# Good for forks that carry hundreds of unrelated third-party submodules.
NO_SUBMODULE_REPOS="${NO_SUBMODULE_REPOS:-zed-extensions}"

# 1 = when a submodule's remote is dead (404), permanently skip it so future
# runs stop retrying. Off by default; each skip logs its undo command.
AUTO_QUARANTINE="${AUTO_QUARANTINE:-0}"

# The token is used ONLY to list repos (unlocks private repos + 5000/hr limit).
# Git transport still uses ssh/https. Stored in a 600-perm file.
GH_TOKEN="${GH_TOKEN:-}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/gh_sync/token}"

# Where to send people to create credentials.
TOKEN_URL="https://github.com/settings/tokens"
SSHKEY_URL="https://github.com/settings/ssh/new"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# Interactive only if BOTH stdin and stdout are terminals (never under systemd).
is_tty() { [ -t 0 ] && [ -t 1 ]; }

# ---- systemd service management (install / uninstall / status) ------------
SERVICE_NAME="${SERVICE_NAME:-gh-sync}"
# Absolute path to *this* script, so the unit keeps working after a `cd`.
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

usage() {
    sed -n '3,18p' "$SELF_PATH" | sed 's/^# \{0,1\}//'
}

# Decide user- vs system-scope from an optional flag, defaulting by privilege.
# Echoes "user" or "system"; non-zero on an unrecognised flag.
systemd_scope() {
    case "${1:-}" in
        --system) echo system ;;
        --user)   echo user ;;
        "")       [ "$(id -u)" -eq 0 ] && echo system || echo user ;;
        *)        return 1 ;;
    esac
}

# Write the config env-file (referenced by the unit) with the CURRENTLY
# effective settings, so `install` captures whatever overrides you passed.
# Never clobbers an existing file — that's yours to edit.
write_env_file() {
    local env_file="$1"
    if [ -e "$env_file" ]; then
        log "Keeping existing config: $env_file (edit it to change settings)."
        return 0
    fi
    mkdir -p "$(dirname "$env_file")"
    {
        echo "# gh_sync settings — read by the ${SERVICE_NAME} systemd service."
        echo "# Edit values here, then: systemctl ${2} restart ${SERVICE_NAME}.service"
        echo "GH_USER=${GH_USER}"
        echo "TARGET_DIR=${TARGET_DIR}"
        echo "PROTOCOL=${PROTOCOL}"
        echo "PRUNE=${PRUNE}"
        echo "PROTECT_DIRTY=${PROTECT_DIRTY}"
        echo "DOCKER_MAINT=${DOCKER_MAINT}"
        echo "SUBMODULE_REMOTE=${SUBMODULE_REMOTE}"
        echo "AUTO_QUARANTINE=${AUTO_QUARANTINE}"
        echo "NO_SUBMODULE_REPOS=${NO_SUBMODULE_REPOS}"
    } > "$env_file"
    log "Wrote config: $env_file"
}

cmd_install() {
    local scope; scope="$(systemd_scope "${1:-}")" \
        || die "unknown option '$1' (use --user or --system)."
    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found — this system doesn't use systemd."

    local unit_dir run_user run_home env_file user_line jctl
    local -a sc=()
    if [ "$scope" = system ]; then
        [ "$(id -u)" -eq 0 ] \
            || die "a --system service needs root; re-run with sudo, or use: $SELF_PATH install --user"
        run_user="${SUDO_USER:-root}"
        run_home="$(getent passwd "$run_user" | cut -d: -f6)"
        [ -n "$run_home" ] || run_home="$HOME"
        unit_dir="/etc/systemd/system"
        user_line="User=${run_user}"
        jctl="journalctl -u ${SERVICE_NAME}.service"
    else
        sc=(--user)
        run_user="$(id -un)"
        run_home="$HOME"
        unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        user_line=""
        jctl="journalctl --user -u ${SERVICE_NAME}.service"
    fi

    env_file="${run_home}/.config/gh_sync/gh_sync.env"
    write_env_file "$env_file" "${sc[*]}"

    mkdir -p "$unit_dir" || die "cannot create $unit_dir"

    {
        echo "[Unit]"
        echo "Description=Sync all of ${GH_USER}'s GitHub repos into ${TARGET_DIR}"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo
        echo "[Service]"
        echo "Type=oneshot"
        [ -n "$user_line" ] && echo "$user_line"
        echo "Environment=HOME=${run_home}"
        echo "Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${run_home}/.local/bin:${run_home}/.cargo/bin"
        echo "EnvironmentFile=-${env_file}"
        echo "ExecStart=${SELF_PATH} sync"
        echo "Nice=10"
        echo "IOSchedulingClass=idle"
    } > "${unit_dir}/${SERVICE_NAME}.service"

    cat > "${unit_dir}/${SERVICE_NAME}.timer" <<UNIT
[Unit]
Description=Run ${SERVICE_NAME} (GitHub repo sync) hourly

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl "${sc[@]}" daemon-reload
    systemctl "${sc[@]}" enable --now "${SERVICE_NAME}.timer" \
        || die "failed to enable ${SERVICE_NAME}.timer"
    log "Installed ${scope} timer: ${SERVICE_NAME}.timer (boots +3min, then hourly)."

    # A user timer only fires while you're logged in unless lingering is on.
    if [ "$scope" = user ] && command -v loginctl >/dev/null 2>&1; then
        if loginctl enable-linger "$run_user" 2>/dev/null; then
            log "Enabled linger for ${run_user} — the timer runs even when logged out."
        else
            log "NOTE: could not enable linger. To run when logged out: sudo loginctl enable-linger ${run_user}"
        fi
    fi

    if ! [ -r "$TOKEN_FILE" ] && [ -z "$GH_TOKEN" ]; then
        log "TIP: run '${SELF_PATH}' once by hand to add a GitHub token (private repos + higher rate limit) and set up SSH."
    fi
    log "Check status any time:  ${SELF_PATH} status ${1:-}"
    log "Follow logs with:       ${jctl} -f"
}

cmd_uninstall() {
    local scope; scope="$(systemd_scope "${1:-}")" \
        || die "unknown option '$1' (use --user or --system)."
    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found — this system doesn't use systemd."

    local unit_dir; local -a sc=()
    if [ "$scope" = system ]; then
        [ "$(id -u)" -eq 0 ] || die "a --system uninstall needs root (sudo)."
        unit_dir="/etc/systemd/system"
    else
        sc=(--user)
        unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    fi

    systemctl "${sc[@]}" disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    rm -f "${unit_dir}/${SERVICE_NAME}.timer" "${unit_dir}/${SERVICE_NAME}.service"
    systemctl "${sc[@]}" daemon-reload
    log "Removed ${scope} ${SERVICE_NAME} timer + service. (Config env-file left in place.)"
}

cmd_status() {
    local scope; scope="$(systemd_scope "${1:-}")" \
        || die "unknown option '$1' (use --user or --system)."
    local -a sc=(); local jctl="journalctl"
    if [ "$scope" = user ]; then sc=(--user); jctl="journalctl --user"; fi
    systemctl "${sc[@]}" list-timers "${SERVICE_NAME}.timer" --no-pager 2>/dev/null || true
    echo
    systemctl "${sc[@]}" status "${SERVICE_NAME}.service" --no-pager 2>/dev/null || true
    echo
    $jctl -u "${SERVICE_NAME}.service" -n 20 --no-pager 2>/dev/null || true
}

# ---- Command dispatch -----------------------------------------------------
# Sub-commands act and exit here; "sync" (or no argument) falls through to the
# rest of the script, which performs the actual mirror.
case "${1:-sync}" in
    install)          shift; cmd_install   "${1:-}"; exit $? ;;
    uninstall|remove) shift; cmd_uninstall "${1:-}"; exit $? ;;
    status)           shift; cmd_status    "${1:-}"; exit $? ;;
    -h|--help|help)   usage; exit 0 ;;
    sync)             shift ;;   # fall through to the sync engine below
    -*)               die "unknown option '$1' (try: $SELF_PATH help)" ;;
    *)                die "unknown command '$1' (try: $SELF_PATH help)" ;;
esac

save_token() {
    mkdir -p "$(dirname "$TOKEN_FILE")"
    ( umask 077; printf '%s' "$1" > "$TOKEN_FILE" )
    chmod 600 "$TOKEN_FILE"
}

# Validate a token against the API. Returns: 0 ok, 1 bad/expired, 2 unreachable.
validate_token() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
                -H "Authorization: Bearer $1" \
                -H "Accept: application/vnd.github+json" \
                https://api.github.com/user 2>/dev/null)"
    case "$code" in
        200)     return 0 ;;
        401|403) return 1 ;;
        *)       return 2 ;;   # 000 == couldn't connect
    esac
}

# True if this machine can authenticate to GitHub over SSH.
# (ssh returns 1 on success because GitHub gives no shell, so we grep the text
#  rather than trusting the exit code.)
ssh_ok() {
    local out
    out="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
               -o ConnectTimeout=8 git@github.com 2>&1)"
    printf '%s' "$out" | grep -q 'successfully authenticated'
}

# ---- Preflight 1: GitHub token -------------------------------------------
if [ -z "$GH_TOKEN" ] && [ -r "$TOKEN_FILE" ]; then
    GH_TOKEN="$(<"$TOKEN_FILE")"
fi

if [ -n "$GH_TOKEN" ]; then
    case "$(validate_token "$GH_TOKEN"; echo $?)" in
        1) log "Stored GitHub token is invalid or expired."; GH_TOKEN="" ;;
        2) log "WARN: couldn't reach GitHub to validate the token (network?). Proceeding." ;;
    esac
fi

if [ -z "$GH_TOKEN" ]; then
    if is_tty; then
        printf '\n' >&2
        {
            echo "No valid GitHub token found. A token lets the sync see your PRIVATE"
            echo "repos and raises the API rate limit. Create a fine-grained token here:"
            echo ""
            echo "    $TOKEN_URL"
            echo ""
            echo "    Resource owner:    your account ($GH_USER)"
            echo "    Repository access: All repositories"
            echo "    Permissions -> Metadata: Read-only   (that's all that's needed)"
            echo ""
            echo "Do not share or paste this token anywhere afterward."
            echo ""
        } >&2
        while :; do
            GH_TOKEN=""
            read -rsp "  Paste token (input hidden), or press Enter to skip (public repos only): " GH_TOKEN
            printf '\n' >&2
            [ -z "$GH_TOKEN" ] && { log "No token entered — continuing with PUBLIC repos only."; break; }
            case "$(validate_token "$GH_TOKEN"; echo $?)" in
                0) save_token "$GH_TOKEN"; log "Token validated and saved to $TOKEN_FILE."; break ;;
                1) printf '  That token was rejected (bad or expired). Try again.\n' >&2 ;;
                2) save_token "$GH_TOKEN"; log "WARN: couldn't reach GitHub to validate; saved it anyway."; break ;;
            esac
        done
    else
        log "WARN: no valid token and not a terminal — listing PUBLIC repos only."
        log "WARN: run this script by hand once to add a token."
    fi
fi

# Safety invariant: prune deletes local repos that aren't in the remote list.
# Without a token that list is incomplete (no private repos), so pruning could
# delete private clones. Never prune unless we have a complete, authed view.
if [ -z "$GH_TOKEN" ] && [ "$PRUNE" = "1" ]; then
    log "WARN: no token → prune disabled (won't risk deleting unseen private repos)."
    PRUNE=0
fi

# Build the API request now that the token is settled.
AUTH_ARGS=()
if [ -n "$GH_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer $GH_TOKEN")
    API_PATH="user/repos"
    API_QS="affiliation=owner&per_page=100"
else
    API_PATH="users/$GH_USER/repos"
    API_QS="per_page=100"
fi

# ---- Preflight 2: SSH key (only when cloning over SSH) --------------------
if [ "$PROTOCOL" = "ssh" ]; then
    if ssh_ok; then
        log "SSH to GitHub OK."
    elif is_tty; then
        printf '\n' >&2
        echo "SSH auth to GitHub failed — github.com doesn't recognize a key from this machine." >&2
        keyfile="$HOME/.ssh/id_ed25519"
        shopt -s nullglob; pubs=("$HOME"/.ssh/*.pub); shopt -u nullglob
        if [ "${#pubs[@]}" -eq 0 ]; then
            ans=""
            read -rp "  No SSH key found. Generate an ed25519 key now? [Y/n] " ans
            case "$ans" in
                [Nn]*) echo "  Skipped. Add a key manually or set PROTOCOL=https." >&2 ;;
                *)     ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f "$keyfile" -N "" ;;
            esac
        else
            keyfile="${pubs[0]%.pub}"
        fi
        if [ -r "${keyfile}.pub" ]; then
            {
                echo ""
                echo "  Add this PUBLIC key to your GitHub account (safe to share):"
                echo ""
                sed 's/^/      /' "${keyfile}.pub"
                echo ""
                echo "    $SSHKEY_URL"
                echo ""
                echo "  Recommended too (so HTTPS-pinned submodules use SSH):"
                echo '      git config --global url."git@github.com:".insteadOf "https://github.com/"'
                echo ""
            } >&2
            while :; do
                ans=""
                read -rp "  Press Enter to re-test after adding the key, or 's' to skip: " ans
                [ "$ans" = "s" ] && { log "WARN: continuing without SSH — new clones may fail."; break; }
                if ssh_ok; then log "SSH authentication succeeded."; break; fi
                echo "  Still failing — confirm the key was added to GitHub, then retry." >&2
            done
        fi
    else
        log "WARN: SSH to GitHub failed and not a terminal — new SSH clones will fail."
        log "WARN: run by hand once to set up a key, or set PROTOCOL=https."
    fi
fi

# ---- Fetch the FULL repo list, following pagination -----------------------
# Emits: name<TAB>ssh_url<TAB>clone_url
fetch_repos() {
    local page=1 resp count
    while :; do
        resp="$(curl -fsSL "${AUTH_ARGS[@]}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/${API_PATH}?${API_QS}&page=${page}")" \
            || return 1
        echo "$resp" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
        count="$(echo "$resp" | jq 'length')"
        [ "$count" -eq 0 ] && break
        echo "$resp" | jq -r '.[] | "\(.name)\t\(.ssh_url)\t\(.clone_url)"'
        [ "$count" -lt 100 ] && break
        page=$((page + 1))
    done
}

REPO_DATA="$(fetch_repos)" \
    || die "GitHub API request failed — aborting, no changes made."
[ -n "$REPO_DATA" ] \
    || die "Repo list came back empty — aborting BEFORE any deletion."

mkdir -p "$TARGET_DIR" || die "cannot create $TARGET_DIR"
cd "$TARGET_DIR"       || die "cannot cd to $TARGET_DIR"

ACTIVE_REPOS="$(echo "$REPO_DATA" | cut -f1)"

# ---- Helpers --------------------------------------------------------------
repo_has_local_work() {
    local d="$1"
    [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && return 0
    [ -n "$(git -C "$d" stash list 2>/dev/null)" ]         && return 0
    local ahead
    ahead="$(git -C "$d" for-each-ref --format='%(upstream:track)' refs/heads 2>/dev/null \
             | grep -c 'ahead')"
    [ "${ahead:-0}" -gt 0 ] && return 0
    return 1
}

want_submodules() {
    case " $NO_SUBMODULE_REPOS " in *" $1 "*) return 1 ;; *) return 0 ;; esac
}

quarantine_submodules() {
    local d="$1" paths="$2" p name
    for p in $paths; do
        name="$(git -C "$d" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null \
                | awk -v w="$p" '$2==w{k=$1; sub(/^submodule\./,"",k); sub(/\.path$/,"",k); print k}')"
        [ -n "$name" ] || name="$p"
        git -C "$d" config "submodule.$name.update" none
        log "    quarantined dead submodule '$p' (undo: git -C $d config --unset submodule.$name.update)"
    done
}

update_submodules() {
    local d="$1" out rc failed
    local -a remote_flag=()
    git -C "$d" submodule sync --recursive --quiet
    [ "$SUBMODULE_REMOTE" = "1" ] && remote_flag=(--remote)
    out="$(git -C "$d" submodule update --init --recursive "${remote_flag[@]}" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    failed="$(grep -oE "Failed to clone '[^']+'" <<< "$out" \
              | sed "s/Failed to clone '//; s/'$//" | sort -u | tr '\n' ' ')"
    log "  submodule issues in $d (non-fatal): ${failed:-see git output}"
    if [ "$AUTO_QUARANTINE" = "1" ] && [ -n "$failed" ]; then
        quarantine_submodules "$d" "$failed"
    fi
    return 0
}

# ---- Prune repos that no longer exist remotely ----------------------------
if [ "$PRUNE" = "1" ]; then
    for local_dir in */; do
        dir_name="${local_dir%/}"
        [ -d "$dir_name/.git" ] || continue
        grep -qxF "$dir_name" <<< "$ACTIVE_REPOS" && continue
        if [ "$PROTECT_DIRTY" = "1" ] && repo_has_local_work "$dir_name"; then
            log "SKIP prune (local work present): $dir_name"
            continue
        fi
        log "PRUNE removing $dir_name (gone from GitHub)"
        rm -rf -- "$dir_name"
    done
fi

# ---- Clone new repos / update existing ones, with submodules --------------
while IFS=$'\t' read -r REPO_NAME SSH_URL CLONE_URL; do
    [ -n "$REPO_NAME" ] || continue
    [ "$PROTOCOL" = "ssh" ] && URL="$SSH_URL" || URL="$CLONE_URL"

    if [ -d "$REPO_NAME/.git" ]; then
        if [ "$PROTECT_DIRTY" = "1" ] && [ -n "$(git -C "$REPO_NAME" status --porcelain)" ]; then
            log "SKIP pull (uncommitted changes): $REPO_NAME"
        else
            log "PULL $REPO_NAME"
            git -C "$REPO_NAME" pull --ff-only --quiet \
                || log "  pull failed (diverged history?) — left untouched: $REPO_NAME"
        fi
        if want_submodules "$REPO_NAME"; then
            update_submodules "$REPO_NAME"
        fi
    elif [ -e "$REPO_NAME" ]; then
        log "SKIP $REPO_NAME (path exists but is not a git repo)"
    else
        log "CLONE $REPO_NAME"
        if want_submodules "$REPO_NAME"; then
            git clone --recurse-submodules --quiet "$URL" "$REPO_NAME" \
                || log "  clone failed: $REPO_NAME"
        else
            git clone --quiet "$URL" "$REPO_NAME" \
                || log "  clone failed: $REPO_NAME"
        fi
    fi
done <<< "$REPO_DATA"

# ---- Docker maintenance (optional, guarded) -------------------------------
if [ "$DOCKER_MAINT" = "1" ] && command -v docker >/dev/null 2>&1; then
    log "Docker maintenance"
    docker system prune -af --filter "until=168h" || true
    # NOTE: volume prune deletes any volume not referenced by a container.
    docker volume prune -f || true
fi

log "Sync complete."
