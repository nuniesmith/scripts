#!/usr/bin/env bash
# Install homelab-apt-upgrade and the one sudoers rule that lets the deploy
# user run it. Run as root on each host the daily update workflow reaches:
#
#     sudo ./install.sh            # deploy user: actions
#     sudo ./install.sh deployer   # some other deploy user
#
# Idempotent; re-run it after changing homelab-apt-upgrade (the installed copy
# is a COPY, so a change merged here reaches a host only when this runs).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 ${1:-}" >&2; exit 1; }
user=${1:-actions}
id "$user" >/dev/null
src="$(dirname "$(readlink -f "$0")")"
target=/usr/local/sbin/homelab-apt-upgrade
rule=/etc/sudoers.d/homelab-apt-upgrade

bash -n "$src/homelab-apt-upgrade"
install -o root -g root -m 0755 "$src/homelab-apt-upgrade" "$target"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# The trailing "" means NO arguments; without it sudo would allow any.
printf '%s ALL=(root) NOPASSWD: %s ""\n' "$user" "$target" >"$tmp"
visudo -cqf "$tmp" >/dev/null
install -o root -g root -m 0440 "$tmp" "$rule"
visudo -cq >/dev/null

# Prove what was granted rather than trusting the file. Positive capability
# first: a rule that grants nothing would pass every "cannot" check below.
sudo -u "$user" sudo -n -l "$target" >/dev/null \
    || { echo "FAIL: $user cannot run $target" >&2; exit 1; }
if sudo -u "$user" sudo -n -l "$target" --worker >/dev/null 2>&1; then
    echo "FAIL: $user can pass arguments to $target" >&2; exit 1
fi
if sudo -u "$user" sudo -n -l /usr/bin/apt-get >/dev/null 2>&1; then
    echo "FAIL: $user can run apt-get directly" >&2; exit 1
fi
echo "installed $target; $user may run it (no arguments) and nothing else via this rule"
