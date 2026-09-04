#!/usr/bin/env bash
# Persistent Codex terminal session; optional experimental ChatGPT remote access.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: chatgpt.sh [--remote] [--device-auth] [DIRECTORY]
       chatgpt.sh --pair [--device-auth]

Attach to the chatgpt tmux session, or start Codex in DIRECTORY (default: $HOME).
An existing session keeps its original directory, model, and permissions.

  --remote       Enable the experimental Codex remote-control daemon first.
  --pair         Enable remote control, print a pairing code, and exit (no tmux).
  --device-auth  Use browser/device-code login; selected automatically over SSH.
  -h, --help     Show this help.

CHATGPT_SESSION sets the tmux session name (default: chatgpt).
Codex uses your configured model/effort, ChatGPT login, workspace-write sandbox,
and on-request approvals. Detach with Ctrl-b then d; closing SSH is also safe.
Remote access is opt-in, host-wide, and can outlive tmux. To disable it, explicitly
run: codex remote-control stop (this stops the shared Codex daemon).
Linux phone/app pairing depends on CLI/app version and account availability.
USAGE
}

die() { printf 'chatgpt.sh: %s\n' "$*" >&2; exit 1; }

remote=false
pair=false
device_auth=false
directory_set=false
work_dir="$HOME"
session="${CHATGPT_SESSION:-chatgpt}"

while (($#)); do
    case "$1" in
        --remote) remote=true ;;
        --pair) pair=true; remote=true ;;
        --device-auth) device_auth=true ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "Unknown option: $1 (see --help)" ;;
        *)
            $directory_set && die 'Only one directory is accepted.'
            work_dir="$1"; directory_set=true
            ;;
    esac
    shift
done
if (($#)); then
    if $directory_set || (($# != 1)); then
        die 'Only one directory is accepted.'
    fi
    work_dir="$1"; directory_set=true
fi
$pair && $directory_set && die '--pair does not take a directory.'
[[ "$session" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'CHATGPT_SESSION must contain only letters, numbers, _ or -.'

attach() {
    if [[ -n "${TMUX:-}" ]]; then
        exec tmux switch-client -t "=$session"
    else
        exec tmux attach-session -t "=$session"
    fi
}

# A detached terminal is already running; do not relogin or replace it.
if ! $pair; then
    command -v tmux >/dev/null 2>&1 || die 'tmux is missing. Install it with: sudo apt install tmux'
    if tmux has-session -t "=$session" 2>/dev/null; then
        if ! $remote; then attach; fi
    else
        [[ -d "$work_dir" ]] || die "Directory does not exist: $work_dir"
        work_dir="$(cd -- "$work_dir" && pwd -P)"
    fi
fi

codex_bin="$(command -v codex)" || die 'Codex is missing. Install the official Codex CLI and ensure codex is on PATH.'
# An absolute path also works when an older tmux server has a different PATH.
[[ "$codex_bin" = /* ]] || die 'codex must resolve to an executable on PATH, not a shell function.'
unset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN

if $remote; then
    remote_help="$("$codex_bin" remote-control --help 2>/dev/null)" || die 'This Codex CLI does not support remote-control. Use normal tmux/SSH or update Codex.'
    [[ "$remote_help" == *'codex remote-control'* ]] || die 'This Codex CLI does not support remote-control. Use normal tmux/SSH or update Codex.'
fi

if login_status="$("$codex_bin" login status 2>&1)"; then
    [[ "$login_status" == *'Logged in using ChatGPT'* ]] || die 'Stored login is not ChatGPT account login. Run codex login explicitly, then retry; no credentials were removed.'
else
    printf 'Not logged in to Codex — sign in with your ChatGPT account.\n'
    login_args=(login)
    if $device_auth || [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
        login_args+=(--device-auth)
    fi
    "$codex_bin" "${login_args[@]}" || die 'Login failed. For device login, check that it is enabled in ChatGPT security settings.'
    login_status="$("$codex_bin" login status 2>&1)" || die 'Login could not be verified.'
    [[ "$login_status" == *'Logged in using ChatGPT'* ]] || die 'ChatGPT account login was not confirmed; refusing to start.'
fi
unset login_status

if $remote; then
    printf 'Enabling experimental, host-wide Codex remote control; existing daemon settings may apply.\n'
    "$codex_bin" -c 'forced_login_method="chatgpt"' remote-control start || die 'Remote control did not start; no new tmux session was launched.'
    if $pair; then
        printf 'Keep the short-lived pairing code private. Pair only your own trusted devices.\n'
        exec "$codex_bin" remote-control pair
    fi
fi

if ! tmux has-session -t "=$session" 2>/dev/null; then
    # Multiple command arguments make tmux exec directly: no send-keys startup
    # race and no interpolation of directory names through another shell.
    # Clear API credentials AGAIN: tmux may retain them in its server environment.
    if ! tmux new-session -d -s "$session" -c "$work_dir" \
        -e "PATH=$PATH" -e "CODEX_HOME=${CODEX_HOME:-$HOME/.codex}" \
        /usr/bin/env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN \
        "$codex_bin" -c 'forced_login_method="chatgpt"' \
        --sandbox workspace-write --ask-for-approval on-request; then
        # Another invocation may have won the create race. Never overwrite it.
        tmux has-session -t "=$session" 2>/dev/null || die 'Could not create the tmux session.'
    fi
fi
attach
