#!/usr/bin/env bash
# cc — attach to the Claude session, start one, or update Claude in place.
#
#   claude.sh            attach (creating the session if needed)
#   claude.sh <dir>      same, but start a new session in <dir>
#   claude.sh update     update Claude, then relaunch RESUMING the conversation
#   claude.sh version    what is installed vs what is running
#
# WHY `update` RELAUNCHES
#
# `claude update` replaces the binary on disk. A process already running keeps
# its own inode, so the live session carries on -- on the OLD version, for as
# long as it lives. There is no way to hot-swap the binary or the model of a
# running process.
#
# `--continue` is what makes that survivable: it resumes the most recent
# conversation, so restarting the pane costs the process but not the context.
# That is the only way to be on a new version and still have your session.

set -uo pipefail

SESSION="${CLAUDE_TMUX_SESSION:-claude}"
# An alias resolves to the LATEST model of that family, which is what you want
# when chasing a new release -- naming a specific version goes stale.
# `fable` currently resolves to Fable 5.1, which requires usage credits.
MODEL="${CLAUDE_MODEL:-opus}"
# Valid levels are low|medium|high|xhigh|max. Anything else is accepted at the
# command line and then ignored, so a typo here costs you effort silently --
# which is how `--effort ultracode` went unnoticed.
EFFORT="${CLAUDE_EFFORT:-max}"

launch_cmd() {  # $1 = extra flags
  printf 'unset ANTHROPIC_API_KEY; claude %s--model %s --effort %s' \
    "${1:+$1 }" "$MODEL" "$EFFORT"
}

ensure_auth() {
  if ! claude auth status >/dev/null 2>&1; then
    echo "Not logged in — starting login (choose the Claude account option)..."
    claude auth login || { echo "Login failed."; exit 1; }
  fi
}

case "${1:-}" in
  version)
    echo "installed : $(claude --version 2>/dev/null)"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      # The running session may predate an update; the symlink does not tell
      # you what a live process is actually executing.
      pid=$(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
      running=$(pgrep -P "${pid:-0}" -f claude 2>/dev/null | head -1)
      if [ -n "$running" ]; then
        echo "running   : $(readlink -f "/proc/$running/exe" 2>/dev/null || echo unknown)"
        echo "            (a session started before an update stays on the old build)"
      fi
    else
      echo "running   : no '$SESSION' session"
    fi
    exit 0
    ;;

  update)
    ensure_auth
    before="$(claude --version 2>/dev/null)"
    echo "current: $before"
    claude update || { echo "update failed — leaving the session alone."; exit 1; }
    after="$(claude --version 2>/dev/null)"
    echo "now    : $after"

    if [ "$before" = "$after" ]; then
      echo "Already up to date; not restarting the session."
      exit 0
    fi

    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "No '$SESSION' session to restart — next launch picks up $after."
      exit 0
    fi

    # C-c the running claude, then relaunch with --continue. The pane is
    # reused so the working directory and scrollback survive alongside the
    # conversation.
    echo "Restarting '$SESSION' on $after, resuming the conversation..."
    tmux send-keys -t "$SESSION" C-c
    sleep 2
    tmux send-keys -t "$SESSION" "$(launch_cmd --continue)" Enter
    echo "Done. --continue resumed the most recent conversation."
    echo "If it opened a blank session, your history is still there:"
    echo "  claude --resume    (pick the session from the list)"
    exit 0
    ;;
esac

DIR="${1:-$HOME}"
unset ANTHROPIC_API_KEY
ensure_auth

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR"
  tmux send-keys -t "$SESSION" "$(launch_cmd '')" Enter
elif [ -n "${1:-}" ]; then
  # The old script took a directory and then ignored it whenever a session
  # already existed, which looks like it worked and silently does not.
  echo "note: '$SESSION' already exists; ignoring directory '$DIR'."
  echo "      kill it first to start elsewhere:  tmux kill-session -t $SESSION"
fi

if [ -n "${TMUX:-}" ]; then
  exec tmux switch-client -t "$SESSION"   # already inside — switch, don't nest
else
  exec tmux attach -t "$SESSION"
fi
