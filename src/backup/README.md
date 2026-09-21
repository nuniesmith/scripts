# Backups

## What exists

| script | what it does |
|---|---|
| `backup-freddy-tier1.sh` | Nightly snapshot of freddy's irreplaceable databases and config. Pull model — runs on the backup host, reaches into freddy. |
| `verify-freddy-tier1.sh` | Restore rehearsal. Restores an archive into throwaway containers and asserts real, named content comes back. |

```bash
./backup-freddy-tier1.sh                  # nightly job
./backup-freddy-tier1.sh --dry-run        # stage everything, archive nothing
./verify-freddy-tier1.sh                  # rehearse the newest archive
./verify-freddy-tier1.sh path/to/x.tar.zst
```

Defaults: `BACKUP_DEST=~/backups/freddy`, `BACKUP_HOST=freddy`, `BACKUP_KEEP=14`.
First archive: 34 MB compressed from ~82 MB staged.

## Why these files and not others

Tier 1 is the ~190 MB that costs the most **per byte** to lose. It is explicitly
**not** full protection for freddy:

| tier | what | size | covered |
|---|---|---|---|
| 1 | databases + config + curated metadata | ~82 MB | **yes** |
| 2 | Nextcloud files, PhotoPrism originals | ~158 GB | **no** |
| 3 | audiobook/ebook library | ~80 GB | no — re-downloadable, that is what shelfmark is for |

Anyone reading a green tick from this job should know tier 2 is still
single-copy. Say it out loud rather than letting the job look like more than
it is.

## Design decisions worth keeping

**Pull, not push.** The backup host reaches into freddy, so nothing running on
freddy can reach back and delete its own history. That is the half of "backup"
that ransomware actually tests.

**SQLite goes through the online backup API, never a file copy.** Every SQLite
database here is in WAL mode — `kuma.db-wal` and friends are on disk. A plain
copy of the `.db` silently drops every write still sitting in the write-ahead
log. `sqlite3 ".backup"` takes a read lock and produces a consistent file while
the application keeps running.

**`--entrypoint sh` on the SQLite helper is load-bearing.** The helper image is
`louislam/uptime-kuma` (chosen because it is already on freddy and ships
sqlite3, so the 03:00 job does not depend on a registry). Its entrypoint starts
the uptime-kuma server, which greets stdout with `==> Performing startup jobs`.
Without the override those bytes land at offset 0 of every artifact — a corrupt
database that still weighs about the right amount.

**Content checks, not exit codes.** Every producer writes to `.part` and is
promoted only after passing a magic-byte check. A failed source aborts the whole
archive rather than shipping a partial one, because an incomplete archive that
looks successful is worse than no archive.

**The manifest is built outside the staging directory.** Redirecting into
`$STAGE/MANIFEST.txt` creates the file empty *before* `sha256sum ./*` runs, so
the manifest records its own checksum as the empty file's and every archive
reports itself corrupt. Caught by the rehearsal on the first run.

**The rehearsal asserts positive capability.** `PRAGMA integrity_check` proves
the file is sound; it does not prove it is the *right* file — a pristine empty
database passes it. So every check demands named content: 190 library items,
Kayla's `mediaProgresses` rows, `reconciled_torrents`, real authentik accounts,
`oc_filecache` rows. Checks phrased as prohibitions are passed trivially by
empty data, which is how a hollow backup earns a green tick for months.

**Assertions must be true of the real system.** The first rehearsal failed on
`authentik applications >= 1`. Live authentik has zero applications configured,
so the backup was faithful and the *check* was wrong. It asserts flows now. A
check that lies about the archive is worse than no check.

## Two outages this work uncovered

### PhotoPrism has been down since roughly 2026-08-25

`docker ps` reports it **healthy**. It is not. It has been sitting in
`config: waiting for the database to become available` continuously.

- It is configured for postgres (`PHOTOPRISM_DATABASE_DRIVER=postgres`).
- `photoprism-postgres` has **zero tables** and has never been written to.
- Password authentication fails over TCP even though `POSTGRES_PASSWORD` in the
  postgres container matches what PhotoPrism is configured with — `POSTGRES_PASSWORD`
  only applies when the data directory is **first initialised**, so changing it
  later in compose does nothing to the already-initialised volume.
- The real index is the SQLite left behind at the migration: `index.db`,
  **11,290 photos**, frozen at 2026-08-25.

The one-line fix is `ALTER USER photoprism WITH PASSWORD '…'` over the unix
socket, then restart. **Do not run it blind.** PhotoPrism would then connect to
an empty postgres and adopt it as truth, and the 11,290-photo index with its
albums, labels and faces stays stranded in SQLite. Decide the migration first;
back up before either way. This script already captures both stores for exactly
that reason.

### Duplicati on sullivan is crashing, not backing up

Configured `/home/jordan` → `/mnt/media/backup`. It crash-loops at startup on
`EncryptedFieldHelper.Decrypt` — it cannot decrypt its own settings database,
so it never gets as far as running a job. Container state reads `unhealthy`,
which is easy to scroll past. A backup tool that looks present and does nothing
is worse than an empty slot, because it stops anyone asking the question.

## Install

```bash
systemctl --user enable --now backup-freddy-tier1.timer
systemctl --user list-timers backup-freddy-tier1.timer
journalctl --user -u backup-freddy-tier1 -n 50
```

Units live in `systemd/`. The timer runs 03:20 daily with a randomised delay;
the rehearsal runs weekly, because a backup nobody has restored is a hypothesis.

## sullivan

`backup-sullivan-tier1.sh` / `verify-sullivan-tier1.sh`, same engine (`lib.sh`).
First archive 290 MB; rehearsal 27 assertions, 0 failures.

Sullivan's volumes are dominated by **cache** — `plex_data` alone is 86 GB of
artwork and transcode metadata that regenerates itself. What actually hurts is
small and buried inside those volumes:

- `radarr/sonarr/lidarr.db` — indexers, quality profiles, custom formats and
  the library index. Months of tuning. (187 movies, 97 series, 72 artists.)
- `prowlarr.db` + `Definitions/` — every indexer and its credentials.
- **`qBittorrent/BT_backup`** — 238 `.fastresume` files. Without them a
  restore re-checks 18 TB against the array before seeding resumes.
- `com.plexapp.plugins.library.db` — 13,999 items and 537 rows of watch
  state. Unrecoverable, and the one users notice.
- compose + `.env` from `/home/jordan/sullivan` and `/home/actions/sullivan`.
  A backup of every database and none of these restores a pile of data nobody
  can start.

18 TB of media is **not** covered and is not meant to be. It is re-acquirable;
a decade of watch history is not.

### Plex needs Plex's own SQLite

Stock `sqlite3` cannot run `PRAGMA integrity_check` on Plex's database — it
registers a custom FTS tokenizer (`collating`) in its own build, so an
ordinary SQLite reports `unknown tokenizer: collating`. The page-level
`.backup` is still faithful (it copies pages and never parses the schema) and
the row counts still prove real content, but **restoring it needs the
`Plex SQLite` binary from inside the Plex container**, not `sqlite3`.

### The bug that found: a verifier that failed silently

That tokenizer error aborted the rehearsal under `set -e` — and the script
**exited 0 with no verdict**, having skipped every remaining check. A caller,
or a systemd timer, reads that as success. It is the exact hollow green tick
this tool exists to prevent, in the tool itself.

Both verifiers now set `VERDICT_REACHED` only at the summary; the EXIT trap
fails loudly if the script ends before it. Every probe carries `|| true` so a
database that cannot be opened is *reported*, not fatal.

### Assertions must be true of the real system — three times over

The rehearsals rejected three assertions that were simply false:

| assertion | reality |
|---|---|
| `authentik applications >= 1` | zero applications configured |
| `mealie recipes >= 1` | 1 user, zero recipes — installed, unused |
| `grocy products >= 1` | completely empty — installed, unused |

Each time the backup was faithful and the *check* was wrong. A check that lies
about the archive is worse than no check, so each was lowered to something
true and meaningful. Raise them if those services ever get used.

## A third dead service: wiki.js

Same root cause as PhotoPrism, on a different machine. `wiki` crash-loops with
`Database Connection Error: 28P01` — PostgreSQL's `invalid_password`. Its
database has **zero tables**, so wiki.js has never successfully initialised.

`POSTGRES_PASSWORD` applies only at first `initdb`. Changing it in compose
later does nothing to an already-initialised volume, and the app is then
locked out of its own database forever.

Unlike PhotoPrism this one is safe to fix — there is no data to strand:

```bash
docker exec wiki-postgres psql -U wikijs -c "ALTER USER wikijs WITH PASSWORD '<compose value>';"
docker restart wiki
```

**Check every other service sharing this pattern before assuming two is all
there are.** authentik and nextcloud are fine (they dump real data), but the
failure is silent by construction: the app retries forever, the database
container reports healthy, and nothing alerts.
