#!/usr/bin/env bash
# Create the `claude` automation user and install its public key.
#
# Run this ON the target host (princess via the Lish console, freddy and
# sullivan over ssh). Idempotent -- safe to re-run.
#
#   sudo ./add-claude-user.sh --key 'ssh-ed25519 AAAA... claude@oryx'
#   sudo ./add-claude-user.sh --key '...' --docker        # freddy / sullivan
#   sudo ./add-claude-user.sh --key '...' --no-sudo       # key only, no root
#
# WHY A SEPARATE USER AT ALL
#
# Access already works on freddy and sullivan as `jordan`. The reason to add
# this anyway is that automation acting as `jordan` is indistinguishable from
# jordan in every log, and cannot be revoked without rotating jordan's own
# key. A named user makes both possible: `userdel -r claude` ends it.
#
# BE CLEAR-EYED ABOUT WHAT --sudo AND --docker GRANT
#
# Both are root. `NOPASSWD:ALL` obviously so. Membership of `docker` is the
# same thing wearing a different hat: anyone who can talk to the docker socket
# can start a privileged container that mounts the host filesystem. Scoping
# sudo to "just nginx and certbot" would not help either -- `certbot
# --deploy-hook` runs arbitrary commands as root, and an nginx config can
# serve any file on the box. Grant it because the work needs it, not because
# a narrower-looking rule feels safer.

set -euo pipefail

USERNAME="claude"
KEY=""
WANT_SUDO=1
WANT_DOCKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --user)     USERNAME="$2"; shift 2 ;;
    --docker)   WANT_DOCKER=1; shift ;;
    --no-sudo)  WANT_SUDO=0; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KEY" ] || { echo "need --key 'ssh-ed25519 ...'" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }

case "$KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*) ;;
  *) echo "that does not look like a public key: ${KEY:0:40}..." >&2; exit 2 ;;
esac

id "$USERNAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USERNAME"
echo "user:    $USERNAME"

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.ssh"

# Append rather than overwrite, and never add the same key twice -- re-running
# this must not silently drop a key someone else added.
AUTH="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH"
if grep -qF "$(echo "$KEY" | awk '{print $2}')" "$AUTH" 2>/dev/null; then
  echo "key:     already present"
else
  echo "$KEY" >> "$AUTH"
  echo "key:     added"
fi
chown "$USERNAME:$USERNAME" "$AUTH"
chmod 600 "$AUTH"

if [ "$WANT_SUDO" -eq 1 ]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
  chmod 440 "/etc/sudoers.d/$USERNAME"
  # A malformed sudoers file can lock everyone out of root on this machine, so
  # validate before trusting it -- and remove ours if it does not parse.
  if ! visudo -c >/dev/null 2>&1; then
    rm -f "/etc/sudoers.d/$USERNAME"
    echo "sudo:    REFUSED -- sudoers did not validate, change reverted" >&2
    exit 1
  fi
  echo "sudo:    NOPASSWD:ALL (this is root)"
else
  rm -f "/etc/sudoers.d/$USERNAME"
  echo "sudo:    none"
fi

if [ "$WANT_DOCKER" -eq 1 ]; then
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$USERNAME"
    echo "docker:  added to group (this is also root)"
  else
    echo "docker:  no docker group on this host -- skipped"
  fi
fi

# sshd can silently refuse a perfectly good key. Surface the two settings that
# do it rather than leaving the caller to wonder why login fails.
echo
echo "sshd settings that would block this:"
grep -rhiE '^\s*(AllowUsers|AllowGroups|DenyUsers|PubkeyAuthentication)' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/  /' \
  || echo "  (none set -- defaults allow pubkey auth for all users)"
echo
echo "If AllowUsers or AllowGroups is set, add $USERNAME to it and: systemctl reload sshd"
echo
echo "Now VERIFY FROM ORYX -- a key that is installed is not the same as a"
echo "login that works, and only the positive test tells them apart:"
echo "  ssh -o BatchMode=yes $USERNAME@<host> 'id; sudo -n true && echo SUDO_OK'"
