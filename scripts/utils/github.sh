#!/usr/bin/env bash
#
# gh_sync.sh — mirror every repo you own into ~/github, keep submodules
# in sync, and (optionally) prune repos that no longer exist on GitHub.
# Designed to run unattended (hourly via systemd) without ever destroying
# local work, and to tolerate dead/third-party submodules.

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
# Clear this if you actually want their submodules.
NO_SUBMODULE_REPOS="${NO_SUBMODULE_REPOS:-zed-extensions}"

# 1 = when a submodule's remote is dead (404), permanently skip it in that
# repo so future runs stop retrying. Off by default so a transient GitHub
# outage can't silently disable a submodule forever. Each skip is logged
# with the exact command to undo it.
AUTO_QUARANTINE="${AUTO_QUARANTINE:-0}"

# A token is only used to *list* repos: it unlocks private repos and raises the
# API rate limit from 60/hr to 5000/hr. Git transport still uses ssh/https.
# Store it in a 600-perm file; needs only read access to repo metadata.
GH_TOKEN="${GH_TOKEN:-}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/gh_sync/token}"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# ---- Resolve token --------------------------------------------------------
if [ -z "$GH_TOKEN" ] && [ -r "$TOKEN_FILE" ]; then
    GH_TOKEN="$(<"$TOKEN_FILE")"
fi

AUTH_ARGS=()
if [ -n "$GH_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer $GH_TOKEN")
    API_PATH="user/repos"                # authenticated: your private repos too
    API_QS="affiliation=owner&per_page=100"
else
    log "WARN: no token (set GH_TOKEN or populate $TOKEN_FILE)."
    log "WARN: only PUBLIC repos will be listed; rate limit is 60/hr."
    API_PATH="users/$GH_USER/repos"
    API_QS="per_page=100"
fi

# ---- Fetch the FULL repo list, following pagination -----------------------
# Emits: name<TAB>ssh_url<TAB>clone_url   (one repo per line)
fetch_repos() {
    local page=1 resp count
    while :; do
        resp="$(curl -fsSL "${AUTH_ARGS[@]}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/${API_PATH}?${API_QS}&page=${page}")" \
            || return 1
        # A good page is a JSON array; an error response is an object -> bail.
        echo "$resp" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
        count="$(echo "$resp" | jq 'length')"
        [ "$count" -eq 0 ] && break
        echo "$resp" | jq -r '.[] | "\(.name)\t\(.ssh_url)\t\(.clone_url)"'
        [ "$count" -lt 100 ] && break    # short page == last page
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
# True if the repo has uncommitted changes, stashes, or unpushed commits.
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

# Recurse submodules for this repo? (No if it's listed in NO_SUBMODULE_REPOS.)
want_submodules() {
    case " $NO_SUBMODULE_REPOS " in *" $1 "*) return 1 ;; *) return 0 ;; esac
}

# Permanently skip submodules whose clone failed (dead remote). Stored in the
# repo's local .git/config: untracked, survives pulls, never dirties the tree.
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

# Sync submodules to match the parent's pinned commits (handles nesting).
# Non-fatal: a dead third-party submodule logs one concise line, never aborts.
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
        [ -d "$dir_name/.git" ] || continue              # only manage git repos
        grep -qxF "$dir_name" <<< "$ACTIVE_REPOS" && continue  # still on GitHub
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
    # Comment this out if you keep data in detached named volumes.
    docker volume prune -f || true
fi

log "Sync complete."
