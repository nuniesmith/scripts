#!/usr/bin/env bash
# Install or refresh the backup units in systemd --user and enable the timers.
#
# The units are COPIES in ~/.config/systemd/user, not links, so a change merged
# to this repo reaches systemd only when this runs. Idempotent.
set -euo pipefail
SRC="$(dirname "$(readlink -f "$0")")"
DEST="$HOME/.config/systemd/user"
mkdir -p "$DEST"
install -m 644 "$SRC"/*.service "$SRC"/*.timer "$DEST"/
systemctl --user daemon-reload
for timer in "$SRC"/*.timer; do systemctl --user enable --now "$(basename "$timer")"; done
# User timers only fire without a login session when lingering is on.
[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ] \
  || echo "WARNING: lingering is off -- run: sudo loginctl enable-linger $USER" >&2
systemctl --user list-timers --no-pager | grep -E 'backup|verify' || true
