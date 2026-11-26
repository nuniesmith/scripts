# AGENTS.md — scripts

Homelab scripts monorepo: the backup system (`src/backup/`), media cleanup (`src/utils/media_cleanup.py`), host provisioning helpers (including secret generation), and assorted utilities the hosts run directly.

## Shared context

Read the shared agent context first: `soul.md` and `memory.md` (especially §1) in the [agents repo](https://github.com/nuniesmith/agents).

## Rules

- **`~/github/scripts` on each host must stay on `main`** — systemd units run straight from the checkout. A stray branch or dirty tree on a host silently changes what runs at 3 AM.
- Backups: Tier 1 (databases + config) is pulled to oryx nightly (freddy 03:20, sullivan 04:10); Tier 2 is chunked `tar.zst` for Glacier Deep Archive. Restore rehearsals run Sundays and assert **named content**. Judge backup health by `systemctl --user list-units --failed` and the newest archive's age — never by `list-timers`.
- After a homelab change that adds or removes a stateful service, the affected host's backup script here changes **in the same change**.
- `media_cleanup.py` previews by default and decides from filesystem timestamps, **not playback history** — timestamps are unreliable for "unwatched" (`noatime`/`relatime` mounts). Never run it in delete mode without Jordan approving the exact previewed batch.
- Secret-generating scripts run on the host and write secrets in place. Never print generated values into logs, commits or chat; presence and length only.
