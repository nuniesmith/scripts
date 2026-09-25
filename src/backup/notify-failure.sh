#!/usr/bin/env bash
# Tell Discord that a systemd user unit failed. The backup and restore-rehearsal
# units run this through OnFailure=: a backup that fails where nobody looks is
# how freddy went two nights without one (2026-09-23/24) while its timer read
# "active (waiting)".
#
#   notify-failure.sh <unit>    what OnFailure= runs (systemd passes %i)
#   notify-failure.sh --test    send a test message
#
# The webhook is read from ~/.config/homelab/discord-webhook (one line, mode
# 600) -- the same file Uptime-Kuma's notification is provisioned from -- so it
# never appears in a unit file, an argument list or this repository.
set -euo pipefail

UNIT="${1:?usage: notify-failure.sh <unit>|--test}"
HOOK_FILE="${ALERT_WEBHOOK_FILE:-$HOME/.config/homelab/discord-webhook}"

# Exit non-zero loudly: an alert path that cannot alert must not look fine.
[ -s "$HOOK_FILE" ] || { echo "no webhook at $HOOK_FILE -- this failure alerts NOBODY" >&2; exit 1; }
HOOK="$(head -n 1 "$HOOK_FILE" | tr -d '[:space:]')"

if [ "$UNIT" = "--test" ]; then
  TEXT="✅ Test from $(hostname): failed backups and restore rehearsals will be reported here."
else
  # The failed run's own output, so the alert says WHY, not just that.
  LOG="$(journalctl --user -u "$UNIT" -n 15 --no-pager -o cat 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;]*m//g' | tail -c 1400 || true)"
  TEXT="❌ **${UNIT}** failed on $(hostname), $(date '+%Y-%m-%d %H:%M %Z')
\`\`\`
${LOG:-(no log lines)}
\`\`\`
More: \`journalctl --user -u ${UNIT} -n 50\`"
fi

BODY="$(python3 -c 'import json, sys; print(json.dumps({"content": sys.stdin.read()[:1990]}))' <<<"$TEXT")"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H 'Content-Type: application/json' -d "$BODY" "$HOOK")"
# Discord answers 204 No Content on success; anything else means not delivered.
[ "$CODE" = "204" ] || { echo "Discord answered HTTP $CODE -- alert NOT delivered" >&2; exit 1; }
echo "alert delivered for $UNIT"
