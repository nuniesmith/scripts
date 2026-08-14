#!/usr/bin/env bash
# cc — attach to the Claude session, or start one
SESSION="claude"
DIR="${1:-$HOME}"

unset ANTHROPIC_API_KEY

if ! claude auth status >/dev/null 2>&1; then
  echo "Not logged in — starting login (choose the Claude account option)..."
  claude auth login || { echo "Login failed."; exit 1; }
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$DIR"
  tmux send-keys -t "$SESSION" \
    'unset ANTHROPIC_API_KEY; claude --rc --model fable --effort ultracode' Enter
fi

if [ -n "$TMUX" ]; then
  exec tmux switch-client -t "$SESSION"   # already inside — switch, don't nest
else
  exec tmux attach -t "$SESSION"
fi
