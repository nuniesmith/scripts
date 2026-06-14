#!/usr/bin/env bash
#
# gh_sync.sh — mirror every repo you own into ~/github, keep submodules
# in sync, and (optionally) prune repos that no longer exist on GitHub.
#
# Runs unattended (hourly via systemd) without ever destroying local work.
# When run by hand in a terminal it will also walk you through first-time
# setup: prompting for a GitHub token and helping register an SSH key.

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
