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

## Tier 2 — archival backup for cold storage

`tier2.py` — chunked `tar.zst` with a searchable content index, sized for
Glacier Deep Archive.

```bash
tier2.py plan    --source photos      # chunk plan, nothing written
tier2.py archive --source nextcloud   # create/update archives
tier2.py find    IMG_4471             # WHICH archive holds it
tier2.py verify  photos-2023-06       # sha256 + extract + count
tier2.py status
```

### Archives, not files

Syncing individual files to Glacier costs far more than the storage does.
Glacier bills **40 KB of metadata per archived object** (8 KB at Standard
rates, 32 KB at Deep Archive rates):

| | 186,587 objects | ~79 archives |
|---|---:|---:|
| One-time PUT | $11.20 | $0.02 |
| Metadata overhead | **7.1 GB/mo** | ~0 |
| Full restore (Bulk) | $5.92 | $0.80 |

### Two exclusions worth more than the tool

Measuring the sources before archiving cut tier 2 from 158 GB to ~51 GB:

- **`jordan/files/games` — 101.8 GB**, a Clone Hero library of 43,655
  community chart files. 88% of all Nextcloud bytes, and re-downloadable.
- **`appdata_*` — 5.3 GB** of Nextcloud previews that regenerate on demand.

Nextcloud went from 114.7 GiB to **7.7 GiB**. At Deep Archive rates
(Canada Central, $0.0018/GB/mo) the whole of tier 2 is about **$0.09/month**.

At that scale, do not optimise the storage class. Deep Archive is $3.41/yr
and Flexible Retrieval is $7.68/yr — $4 a year buys retrieval in minutes
instead of 12 hours.

### The index is the point

Once data is in tarballs in cold storage, "which archive holds IMG_4471?"
is unanswerable without retrieving things, and a Deep Archive retrieval takes
12 hours. Every archive gets a manifest; the manifests feed a local SQLite
index that answers it instantly. **Keep that index out of cold storage.**

Manifests are generated **from the finished archive** (`tar -t`), never from
a separate walk of the source. A manifest built by listing the source can
disagree with what actually got archived; one built from the archive cannot.

### Bugs the first real run caught

- **`find` predicates spliced into `du`.** `du -b -d 3 . ! -name appdata_*`
  is not valid — busybox `du` takes them as paths, matches nothing, and
  prints nothing. The result was a silent empty plan, not an error.
- **Excluded data came back as a phantom chunk.** Loose files were computed
  as `size(parent) − sum(included children)`, so excluding `appdata_*`
  reappeared as a 5.3 GB "root" chunk that would have been archived anyway.
  The subtraction has to count *every* child.
- **Double compression.** `tar -czf` piped into `zstd` produced gzip inside
  zstd — one wasted pass, worse ratio, and `tar -t` refuses a gzip stream on
  a pipe (`Archive is compressed. Use -z option`), so every archive failed
  read-back. Single-pass is also ~1% smaller.
- **Zero-file chunks.** `du` counts each directory's own inode, so "loose
  files here" is positive for a directory holding only subdirectories. The
  file count is the honest test, not the byte count.

### Not Duplicati

Duplicati is installed on sullivan, has been configured, and **has never run
a job** — it crash-loops unable to decrypt its own settings database. For a
tool whose whole purpose is to work on the worst day, that is disqualifying
evidence from this very environment.

`restic` is the better managed alternative if chunk-level incremental proves
too coarse — it deduplicates and packs small files automatically. Its caveat
is that index and snapshot objects must stay in warm storage, not Deep
Archive.

What `tar.zst` buys instead is restore simplicity: `zstd -dc x.tar.zst |
tar -x`, with no tool version to match and no repository database to rebuild.
