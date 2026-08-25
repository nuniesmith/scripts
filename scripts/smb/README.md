# SMB shares

Server setup, client mounts, and the one registry both sides read.

| File | Runs on | Does |
| --- | --- | --- |
| `smb-fleet.conf` | — | Which host serves which share. Edit this, not the scripts. |
| `smb-fleet.sh` | — | Shared library: parses the registry, prompts, logging. Sourced, not run. |
| `setup-smb-shares.sh` | server | Installs and configures Samba, publishes the shares. |
| `mount-smb-shares.sh` | Linux client | Mounts fleet shares via systemd automount. |
| `map-network-drives.ps1` | Windows client | Maps the shares to drive letters. |

The registry is the point: add a share in `smb-fleet.conf` and both the server
setup and the client mounts pick it up, so the two cannot drift apart.

## Server side

```bash
# on the machine that will serve the shares
sudo bash setup-smb-shares.sh

# restrict to the LAN and the tailnet, and require encryption
sudo bash setup-smb-shares.sh --allow "192.168.1.0/24 100.64.0.0/10" --secure

# a host the registry has never heard of
sudo bash setup-smb-shares.sh --host newbox --share "data:/srv/data:group"

# see what it would write, change nothing
sudo bash setup-smb-shares.sh --dry-run
```

It picks the profile matching `hostname -s`, asks for the SMB username and
password up front, then runs unattended. `--help` lists every option.

### Share modes

- **`group`** — files are forced to `actions:actions` with setgid directories,
  so Docker containers running as uid 1001 keep full access. Setup recursively
  chowns the tree, so only point this at data directories.
- **`owner`** — files keep their real owner, nothing is chowned, no `force
  user`. Use this for anything under a real user's home, where rewriting
  ownership would break SSH keys, sudo and login.

A `group` share needs a Unix **user** named after the group (`actions`), not
just the group — `force user` is a user. The servers get one from the GitHub
Actions deploy; the desktop does not, which is why its shares are `owner`.

## Client side — Linux

```bash
# mount everything the registry knows about, except this machine's own shares
sudo bash mount-smb-shares.sh --all

# one server
sudo bash mount-smb-shares.sh --server sullivan --user jordan

# one share from one server
sudo bash mount-smb-shares.sh --server freddy --share storage

# check reachability and credentials without changing anything (no root needed)
bash mount-smb-shares.sh --server sullivan --test

# undo
sudo bash mount-smb-shares.sh --server sullivan --remove --purge
```

Shares land under `/mnt/<server>/<share>`. Re-running is safe: each server owns
one marked block in `/etc/fstab` that gets replaced wholesale, and anything
outside those markers is left alone.

By default the entries use systemd automount, so a share mounts on first access
and unmounts after ten idle minutes. That is what keeps a server being down
from wedging boot or hanging a shell in `/mnt`. Pass `--no-automount` for
plain mount-at-boot entries (still `nofail`).

Passwords go into `/etc/samba/credentials/<server>`, mode 0600, root-owned —
never into `/etc/fstab`, which is world-readable.

## Client side — Windows

```powershell
# as Administrator
powershell -ExecutionPolicy Bypass -File .\map-network-drives.ps1
```

Edit the `$Drives` table at the top to match `smb-fleet.conf`.

## Adding a host

Add it to `smb-fleet.conf`:

```
host |newbox|100.64.0.5|New Box
share|newbox|data|/srv/data|group|New Box Data
```

`ADDRESS` (the third field) is what clients dial — hostname, FQDN, or a
Tailscale IP when DNS is unreliable. It is ignored server-side.

Then run `setup-smb-shares.sh` on `newbox` and `mount-smb-shares.sh --server
newbox` on each client. `--list` on either script prints the registry as
loaded.

The scripts look for the registry in this order, first hit wins:

1. `--config PATH`
2. `$SMB_FLEET_CONF`
3. `smb-fleet.conf` next to the script
4. `/etc/smb-fleet.conf`
5. the identical built-in table in `smb-fleet.sh`

The built-in fallback is what makes `curl … | sudo bash` still work; keep it in
sync when you change the conf file.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| Client can't authenticate | `smbclient -L //<server> -U <user>` from the client; `pdbedit -L` on the server |
| Mounted but writes fail | Share mode. `owner` shares need the SMB user to own the tree; the setup warns when they don't |
| Share missing after setup | `testparm -s` on the server, then `journalctl -u smbd -n 50` |
| Automount never fires | `systemctl status $(systemd-escape -p --suffix=automount /mnt/<server>/<share>)` |
| Permission denied on server paths | AppArmor: `dmesg \| grep DENIED`, and `/etc/apparmor.d/samba/smbd-shares` |
| Group-share chown still running | `tail -f /var/log/smb-perms-fix.log` |
