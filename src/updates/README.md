# Updates

The host half of the daily update workflows (`daily-update.yml` in freddy,
sullivan and princess, built on nuniesmith/actions `host-update`).

| file | what it does |
|---|---|
| `homelab-apt-upgrade` | `apt-get update` + `upgrade --with-new-pkgs`, run as a systemd unit, then a `key=value` report: what changed, what is held back, whether a reboot is needed. |
| `install.sh` | Installs it root-owned at `/usr/local/sbin/`, plus the one sudoers rule that lets the deploy user run it with no arguments, then proves what was granted. |

```bash
sudo ./install.sh              # once per host; again after changing the helper
sudo -u actions sudo -n /usr/local/sbin/homelab-apt-upgrade    # what the workflow runs
journalctl -u homelab-apt-upgrade                              # a run's full apt output
```

## Design decisions worth keeping

**A systemd unit, not a child of the SSH session.** Upgrading tailscale
restarts the tunnel the workflow's SSH session rides on. A dpkg killed halfway
leaves the host needing `dpkg --configure -a` by hand, so the upgrade must not
die with the session. Running the helper again attaches to the upgrade still
in progress, or prints the report of one that finished while nobody was
connected, instead of starting another.

**It never reboots, and never restarts services by itself.** needrestart runs
in list mode, because on sullivan (no `live-restore`) a restarted dockerd is
every container restarted. The report says what still runs old code, and
whether the kernel needs a reboot. Choosing when to reboot stays with a person.

**No removals, no conffile surprises.** `upgrade --with-new-pkgs` can pull in a
new dependency, such as a new kernel package, but never removes one. And
`--force-confold` keeps any config file that was edited by hand.

**One sudo rule, no arguments.** The deploy user is in the docker group, which
is root-equivalent already. The narrow rule is about the workflow not needing
more than it uses, not about containing it. `install.sh` proves the grant both
ways: first that the user CAN run the helper, then that it cannot pass
arguments or run `apt-get` directly. A rule granting nothing would pass every
"cannot" check on its own.

**unattended-upgrades stays on.** It still installs security updates on its
own schedule. This adds everything else (`-updates`, Docker's and Tailscale's
repositories) once a day, with a report, and at a time chosen to fall after
the nightly backups.
