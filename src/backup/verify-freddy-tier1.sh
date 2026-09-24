#!/usr/bin/env bash
# Restore rehearsal for a freddy tier-1 archive.
#
# A backup job that exits 0 has proven that a backup job can exit 0. This
# proves the archive can be turned back into working data, which is the only
# property anyone actually wants from it.
#
# The rule this script is built around: ASSERT THE POSITIVE CAPABILITY. Every
# check here demands that specific, named, human-meaningful content comes back
# -- Kayla's reading progress, LifeOS's imported records and the images its
# pages embed, real Nextcloud users.
# Checks phrased as prohibitions ("no errors", "file is non-empty") are passed
# trivially by an empty database, which is exactly how a hollow backup earns a
# green tick for months.
#
# Nothing here touches freddy. The rehearsal restores into throwaway
# containers and temp directories on THIS host, which is also the honest test:
# in a real disaster freddy is what you no longer have.
#
# Usage:
#   verify-freddy-tier1.sh [ARCHIVE]     (default: newest in $BACKUP_DEST,
#                                          which must also be recent)

set -euo pipefail

DEST="${BACKUP_DEST:-$HOME/backups/freddy}"
ARCHIVE="${1:-}"
MAX_AGE_HOURS="${VERIFY_MAX_AGE_HOURS:-36}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
bad()  { echo -e "${RED}[FAIL]${NC} $1" >&2; }

PASS=0; FAIL=0
assert() {  # assert <description> <actual> <predicate: -ge N | = STR>
  local what="$1" actual="$2" op="$3" want="$4"
  if [ "$op" = "-ge" ] && [ "${actual:-0}" -ge "$want" ] 2>/dev/null; then
    ok "$what: $actual (>= $want)"; PASS=$((PASS + 1)); return 0
  fi
  if [ "$op" = "=" ] && [ "$actual" = "$want" ]; then
    ok "$what: $actual"; PASS=$((PASS + 1)); return 0
  fi
  bad "$what: got '${actual:-<nothing>}', wanted $op $want"; FAIL=$((FAIL + 1)); return 0
}

CHECK_AGE=0
if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(ls -1t "$DEST"/freddy-tier1-*.tar.zst 2>/dev/null | head -1 || true)"
  CHECK_AGE=1
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  bad "no archive found (looked in $DEST)"; exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/freddy-verify.XXXXXX")"
# One throwaway per postgres MAJOR version -- see the postgres section.
PG16="freddy-verify-pg16-$$"
PG17="freddy-verify-pg17-$$"
# A verifier that dies early must NEVER look like a pass. Under `set -e` a
# probe that cannot even open a database ends the run with status 0 and no
# verdict, and a caller -- or a systemd timer -- reads that as success. This
# was not hypothetical: the sullivan rehearsal did exactly that on Plex's
# database, which stock sqlite3 cannot open.
VERDICT_REACHED=0
cleanup() {
  local rc=$?
  docker rm -f "$PG16" "$PG17" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  if [ "$VERDICT_REACHED" -eq 0 ]; then
    bad "rehearsal ENDED EARLY without a verdict (rc=$rc) -- treat as FAILED"
    exit 1
  fi
}
trap cleanup EXIT

info "rehearsing $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
zstd -dc "$ARCHIVE" | tar -xf - -C "$WORK"
ok "archive extracted"

# ---------------------------------------------------------------- manifest
if [ -f "$WORK/MANIFEST.txt" ]; then
  if ( cd "$WORK" && sha256sum --quiet -c <(grep -E '^\s+[0-9a-f]{64}' MANIFEST.txt | sed 's/^\s*//') ) 2>/dev/null; then
    ok "every member matches its recorded sha256"; PASS=$((PASS + 1))
  else
    bad "checksum mismatch -- the archive is corrupt"; FAIL=$((FAIL + 1))
  fi
else
  warn "no MANIFEST.txt in archive"
fi

# ---------------------------------------------------------------- freshness
# Restorable is not enough; the newest archive also has to be NEW. On
# 2026-09-24 the nightly job had failed two nights running and the newest
# archive was 48 hours old -- and this rehearsal would have passed it, because
# it took "newest" without asking how new that was. An archive named on the
# command line skips this: rehearsing an old one on purpose is legitimate.
if [ "$CHECK_AGE" -eq 1 ]; then
  created="$(sed -n 's/^created_utc: *//p' "$WORK/MANIFEST.txt" 2>/dev/null | head -1 || true)"
  created_epoch=""
  if [[ "$created" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
    created_epoch="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null || true)"
  fi
  [ -n "$created_epoch" ] || created_epoch="$(stat -c %Y "$ARCHIVE")"
  age_h=$(( ($(date -u +%s) - created_epoch) / 3600 ))
  if [ "$age_h" -le "$MAX_AGE_HOURS" ]; then
    ok "newest archive is ${age_h}h old (<= ${MAX_AGE_HOURS}h)"; PASS=$((PASS + 1))
  else
    bad "newest archive is ${age_h}h old (> ${MAX_AGE_HOURS}h) -- the nightly backup has not produced one since"
    bad "  $(date -u -d "@$created_epoch" '+%Y-%m-%d %H:%M UTC'); check: journalctl --user -u backup-freddy-tier1"
    FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------- sqlite
# `integrity_check` proves the file is sound; the row counts prove it is the
# RIGHT file. A pristine, empty, perfectly valid database passes the first and
# fails the second, and the second is the one that matters.
sqlite_check() {
  local file="$1" label="$2" query="$3" what="$4" min="$5"
  if [ ! -f "$WORK/$file" ]; then bad "$label: missing from archive"; FAIL=$((FAIL + 1)); return; fi
  local integrity count
  integrity="$(python3 -c "
import sqlite3,sys
c=sqlite3.connect('file:$WORK/$file?mode=ro',uri=True)
print(c.execute('PRAGMA integrity_check').fetchone()[0])" 2>&1 | tail -1 || true)"
  assert "$label integrity" "$integrity" = "ok"
  count="$(python3 -c "
import sqlite3
c=sqlite3.connect('file:$WORK/$file?mode=ro',uri=True)
print(c.execute(\"\"\"$query\"\"\").fetchone()[0])" 2>/dev/null || echo "")"
  assert "$label $what" "$count" -ge "$min"
  return 0
}

info "--- SQLite restores"
# Audiobookshelf: the point of this whole tier. `mediaProgresses` IS Kayla's
# place in every book; a library with no progress rows restores her account
# and loses the only thing she would notice.
sqlite_check audiobookshelf.sqlite "audiobookshelf" \
  "SELECT count(*) FROM libraryItems" "books" 100
sqlite_check audiobookshelf.sqlite "audiobookshelf" \
  "SELECT count(*) FROM mediaProgresses" "reading-progress rows" 1
sqlite_check audiobookshelf.sqlite "audiobookshelf" \
  "SELECT count(*) FROM users" "users" 2

# Shelfmark: reconciled_torrents must never be lost -- losing it makes the
# pipeline re-grab things it already has.
sqlite_check shelfmark.sqlite "shelfmark" \
  "SELECT count(*) FROM reconciled_torrents" "reconciled torrents" 1
sqlite_check shelfmark.sqlite "shelfmark" \
  "SELECT count(*) FROM jobs" "jobs" 1

sqlite_check uptime_kuma.sqlite "uptime-kuma" \
  "SELECT count(*) FROM monitor" "monitors" 1
sqlite_check photoprism_index.sqlite "photoprism index" \
  "SELECT count(*) FROM photos" "photos" 1
sqlite_check homeassistant.sqlite "homeassistant" \
  "SELECT count(*) FROM states_meta" "entities" 1

# ---------------------------------------------------------------- postgres
# A real restore into a real, throwaway postgres. Reading the dump's table of
# contents would prove the file parses; only restoring it proves the schema
# and data actually load.
#
# Each dump restores into the MAJOR VERSION it was taken from: nextcloud runs
# postgres 16, LifeOS runs 17, and pg_restore refuses a dump from a newer
# pg_dump. One shared throwaway would either fail the LifeOS restore outright
# or, bumped to 17, rehearse nextcloud against a server it never runs on.
info "--- PostgreSQL restores (throwaway containers)"
start_pg() {  # start_pg <container> <image> -- 0 once it accepts connections
  local name="$1" image="$2"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -e POSTGRES_PASSWORD=rehearsal \
    -e POSTGRES_USER=rehearsal -e POSTGRES_DB=rehearsal "$image" >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    docker exec "$name" pg_isready -U rehearsal >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker exec "$name" pg_isready -U rehearsal >/dev/null 2>&1; then
    bad "throwaway $image never came up"; FAIL=$((FAIL + 1)); return 1
  fi
  ok "throwaway $image ready"
}

# restore_pg <container> <dumpfile> <dbname>
# pg_restore warns about ownership on a database whose roles do not exist
# here; that is expected in a rehearsal and not a restore failure, so the
# verdict comes from the row counts that follow rather than its exit code.
restore_pg() {
  local ctr="$1" file="$2" dbname="$3"
  if [ ! -f "$WORK/$file" ]; then bad "$file: missing from archive"; FAIL=$((FAIL + 1)); return 1; fi
  docker exec "$ctr" psql -U rehearsal -d rehearsal -qc \
    "DROP DATABASE IF EXISTS $dbname;" >/dev/null 2>&1 || true
  docker exec "$ctr" psql -U rehearsal -d rehearsal -qc \
    "CREATE DATABASE $dbname;" >/dev/null 2>&1 || true
  docker exec -i "$ctr" pg_restore -U rehearsal -d "$dbname" --no-owner --no-acl \
    < "$WORK/$file" >/dev/null 2>&1 || true
}

pg_assert() {  # pg_assert <container> <dbname> <label> <query> <what> <min>
  local ctr="$1" dbname="$2" label="$3" query="$4" what="$5" min="$6" count
  count="$(docker exec "$ctr" psql -U rehearsal -d "$dbname" -tAc "$query" 2>/dev/null | tr -d '[:space:]' || true)"
  assert "$label $what" "$count" -ge "$min"
}

if start_pg "$PG16" postgres:16-alpine && restore_pg "$PG16" nextcloud_pg.dump nextcloud_r; then
  pg_assert "$PG16" nextcloud_r nextcloud "SELECT count(*) FROM oc_users;" "users" 1
  pg_assert "$PG16" nextcloud_r nextcloud "SELECT count(*) FROM oc_filecache;" "indexed files" 100
fi

# LifeOS: 448 records imported from Notion. `attachments` is what the pages
# embed; its storage keys are cross-checked against the uploads tar below, so
# the images have to come back too, not merely rows that point at them.
if start_pg "$PG17" postgres:17-bookworm && restore_pg "$PG17" lifeos_pg.dump lifeos_r; then
  pg_assert "$PG17" lifeos_r lifeos "SELECT count(*) FROM source_records;" "imported records" 200
  pg_assert "$PG17" lifeos_r lifeos "SELECT count(*) FROM attachments;" "attachments" 200
  pg_assert "$PG17" lifeos_r lifeos "SELECT count(*) FROM users;" "users" 1
  docker exec "$PG17" psql -U rehearsal -d lifeos_r -tAc \
    "SELECT storage_key FROM attachments WHERE archived_at IS NULL;" \
    > "$WORK/lifeos_keys.txt" 2>/dev/null || true
fi

# ---------------------------------------------------------------- tarballs
# Named paths, not "the tar lists something". Home Assistant's entire entity
# and auth registry lives in `.storage`, and a tar that skipped dotfiles would
# still list plenty of files while restoring an empty Home Assistant.
info "--- config trees"
tar_has() {
  local file="$1" label="$2" pattern="$3"
  if [ ! -f "$WORK/$file" ]; then bad "$label: missing"; FAIL=$((FAIL + 1)); return; fi
  local n
  n="$(tar -tzf "$WORK/$file" 2>/dev/null | grep -cE "$pattern" || true)"
  assert "$label contains $pattern" "$n" -ge 1
}
tar_has homeassistant_config.tar.gz "HA config" '\.storage/core\.config_entries'
tar_has homeassistant_config.tar.gz "HA config" '\.storage/auth$'
tar_has homeassistant_config.tar.gz "HA config" 'configuration\.yaml'
tar_has photoprism_curated.tar.gz   "photoprism" 'albums/'

LIBMETA="$(tar -tzf "$WORK/library_metadata.tar.gz" 2>/dev/null | grep -c 'metadata\.json' || true)"
assert "library metadata.json files" "$LIBMETA" -ge 50

# LifeOS uploads are content-addressed (`ab/cd/<sha256>.png`), so every
# attachment row names exactly one file. Zero missing is only meaningful
# because the restore above already demanded >= 200 attachment rows; an
# empty key list is reported as a failure rather than trivially "nothing
# missing".
if [ -f "$WORK/lifeos_uploads.tar.gz" ]; then
  tar -tzf "$WORK/lifeos_uploads.tar.gz" 2>/dev/null | sed 's#^\./##' | grep -v '/$' \
    | sort > "$WORK/lifeos_files.txt" || true
  assert "lifeos upload files" "$(wc -l < "$WORK/lifeos_files.txt")" -ge 200
  if [ -s "$WORK/lifeos_keys.txt" ]; then
    missing="$(sort "$WORK/lifeos_keys.txt" | sed '/^$/d' | comm -23 - "$WORK/lifeos_files.txt" | wc -l || true)"
    assert "lifeos attachments whose file is missing" "$missing" = "0"
  else
    bad "lifeos: no attachment keys came back from the restore to cross-check"; FAIL=$((FAIL + 1))
  fi
else
  bad "lifeos_uploads.tar.gz: missing from archive"; FAIL=$((FAIL + 1))
fi

VERDICT_REACHED=1
echo
if [ "$FAIL" -gt 0 ]; then
  bad "REHEARSAL FAILED -- $PASS passed, $FAIL failed"
  bad "this archive is not known to be restorable; do not rely on it"
  exit 1
fi
ok "REHEARSAL PASSED -- $PASS assertions, 0 failures"
ok "$(basename "$ARCHIVE") restores to real, populated data"
