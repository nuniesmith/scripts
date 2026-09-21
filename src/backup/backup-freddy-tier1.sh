#!/usr/bin/env bash
# Nightly snapshot of freddy's TIER 1 state: the databases and configuration
# that cannot be re-downloaded and would take days to rebuild by hand.
#
# Tier 1 is deliberately NOT everything on freddy. It is the ~190MB that costs
# the most per byte to lose:
#
#   authentik postgres     every account and SSO application
#   nextcloud postgres     shares, sync state, user table
#   photoprism postgres    albums, labels, faces -- the human-made metadata
#   absdatabase.sqlite     Audiobookshelf: accounts AND reading progress
#   shelfmark.db           jobs + reconciled_torrents, which must never be lost
#   kuma.db                every monitor and notification target
#   home-assistant_v2.db   entity history
#   config trees           HA .storage, authentik certs/templates, ABS authors
#   library metadata.json  94 of these were hand-repaired on 2026-09-12
#
# The 158GB of photos and Nextcloud files are tier 2 and are NOT covered here.
# Say so out loud rather than letting this script look like full protection.
#
# PULL model: this runs on the BACKUP host and reaches into freddy. The backup
# host holds the credentials, so nothing on freddy can reach in and delete its
# own history -- which is the half of "backup" that ransomware actually tests.
#
# Usage:
#   backup-freddy-tier1.sh [--dest DIR] [--host HOST] [--keep N] [--dry-run]

set -euo pipefail

DEST="${BACKUP_DEST:-$HOME/backups/freddy}"
HOST="${BACKUP_HOST:-freddy}"
KEEP="${BACKUP_KEEP:-14}"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)    DEST="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --keep)    KEEP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1" >&2; }

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/freddy-tier1.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# An image that is already on freddy AND ships sqlite3. Pulling a fresh image
# at 03:00 would make this job depend on a registry being up.
SQLITE_IMAGE="louislam/uptime-kuma:latest"
TAR_IMAGE="alpine:latest"

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

# A dump that fails must not leave a plausible-looking short file behind. Every
# producer below writes to .part and is only renamed once it has both exited 0
# AND passed its own shape check -- so a half-written artifact can never be
# archived as a successful backup.
promote() {
  local part="$1" final="$2" min="$3" what="$4"
  local size
  size="$(stat -c %s "$part" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min" ]; then
    fail "$what: only ${size}B (expected >= ${min}B) -- refusing to keep it"
    rm -f "$part"
    return 1
  fi
  mv "$part" "$final"
  ok "$what ($(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B"))"
}

# A genuinely empty directory is a FACT worth capturing, not a failure: an
# authentik with no custom certificates should restore as an authentik with no
# custom certificates. A gzipped empty tar is ~85 bytes, which is why these
# cannot share the size floor that catches truncated dumps.
EMPTY_TAR_BYTES=60

dump_pg() {
  local container="$1" user="$2" db="$3" name="$4"
  info "pg_dump $container/$db"
  # -Fc so pg_restore can list and selectively restore it; already compressed.
  if ! remote "docker exec -i '$container' pg_dump -U '$user' -d '$db' -Fc" \
       > "$STAGE/$name.dump.part"; then
    fail "pg_dump $container/$db exited non-zero"
    rm -f "$STAGE/$name.dump.part"
    return 1
  fi
  # A custom-format dump starts with the literal magic "PGDMP". Checking it
  # catches the case where the dump "succeeded" but stdout carried an error
  # page or an empty database.
  if [ "$(head -c 5 "$STAGE/$name.dump.part")" != "PGDMP" ]; then
    fail "$name: not a postgres custom dump (bad magic)"
    rm -f "$STAGE/$name.dump.part"
    return 1
  fi
  # The magic is what proves validity; size is a separate signal. An EMPTY
  # database dumps to a valid ~830B archive, so a size floor here would reject
  # a correct backup -- while a database that silently emptied would sail past
  # any floor low enough to admit it. Report the smell, keep the artifact, and
  # let the restore rehearsal be the thing that asserts real content.
  local size
  size="$(stat -c %s "$STAGE/$name.dump.part" 2>/dev/null || echo 0)"
  if [ "$size" -lt 2048 ]; then
    warn "$name: ${size}B -- valid dump of an essentially EMPTY database"
  fi
  promote "$STAGE/$name.dump.part" "$STAGE/$name.dump" 256 "$name.dump"
}

dump_sqlite() {
  local volume="$1" dbfile="$2" name="$3"
  info "sqlite .backup $volume/$dbfile"
  # `.backup` is SQLite's ONLINE backup API: it takes a read lock, copies
  # pages, and produces a consistent file while the application keeps writing.
  # Copying the file directly would be wrong here -- every one of these
  # databases is in WAL mode (kuma.db-wal etc. are on disk), so a plain copy
  # silently loses every write still sitting in the write-ahead log.
  #
  # The volume is mounted READ-WRITE on purpose: SQLite needs to map the -shm
  # index to read a WAL database. Mounting it ro makes the backup fail rather
  # than make it safer.
  #
  # sqlite3's own stdout goes to stderr so that only the database bytes reach
  # the pipe; a stray "Error:" line on stdout would corrupt the artifact.
  #
  # `--entrypoint sh` is not optional. This image's entrypoint runs the
  # uptime-kuma server, which greets stdout with "==> Performing startup jobs"
  # -- and those bytes land at offset 0 of the backup, ahead of the SQLite
  # header. Without the override every artifact here is a corrupt database
  # that still weighs the right amount.
  if ! remote "docker run --rm --entrypoint sh -v '$volume':/src '$SQLITE_IMAGE' \
        -c 'sqlite3 \"/src/$dbfile\" \".backup /tmp/b.db\" 1>&2 && cat /tmp/b.db'" \
       > "$STAGE/$name.sqlite.part"; then
    fail "sqlite backup of $volume/$dbfile failed"
    rm -f "$STAGE/$name.sqlite.part"
    return 1
  fi
  if [ "$(head -c 15 "$STAGE/$name.sqlite.part")" != "SQLite format 3" ]; then
    fail "$name: not a SQLite database (bad magic)"
    rm -f "$STAGE/$name.sqlite.part"
    return 1
  fi
  promote "$STAGE/$name.sqlite.part" "$STAGE/$name.sqlite" 4096 "$name.sqlite"
}

# tar a volume subtree. Extra arguments are tar --exclude patterns.
dump_tree() {
  local volume="$1" subdir="$2" name="$3"; shift 3
  local excludes=""
  for pat in "$@"; do excludes="$excludes --exclude='$pat'"; done
  info "tar $volume/$subdir"
  # `tar -C dir .` includes DOTFILES, which matters more here than anywhere
  # else: Home Assistant keeps its entire entity and auth registry in
  # `.storage`, and a glob-based copy would quietly skip all of it.
  if ! remote "docker run --rm -v '$volume':/src:ro '$TAR_IMAGE' \
        sh -c \"tar -czf - $excludes -C '/src/$subdir' . \"" \
       > "$STAGE/$name.tar.gz.part"; then
    fail "tar of $volume/$subdir failed"
    rm -f "$STAGE/$name.tar.gz.part"
    return 1
  fi
  promote "$STAGE/$name.tar.gz.part" "$STAGE/$name.tar.gz" "$EMPTY_TAR_BYTES" "$name.tar.gz"
}

# The per-book metadata.json files inside the (huge, re-downloadable) library.
# The audio is tier 3; these are not. 94 of them were repaired by hand after
# Audiobookshelf invented an author for them, and that work is only recorded
# here.
dump_library_metadata() {
  info "tar library metadata.json files"
  # Alpine's tar is BusyBox tar: no --null, and -T must name a real file
  # rather than read stdin. Writing the list to a temp file inside the
  # throwaway container is the portable form, and it keeps this working on
  # whatever minimal image happens to be on the host.
  if ! remote "docker run --rm -v freddy_audiobookshelf_data:/src:ro '$TAR_IMAGE' \
        sh -c 'cd /src && find . -name metadata.json > /tmp/l && tar -czf - -T /tmp/l'" \
       > "$STAGE/library_metadata.tar.gz.part"; then
    fail "library metadata tar failed"
    rm -f "$STAGE/library_metadata.tar.gz.part"
    return 1
  fi
  promote "$STAGE/library_metadata.tar.gz.part" "$STAGE/library_metadata.tar.gz" \
    "$EMPTY_TAR_BYTES" "library_metadata.tar.gz"
}

info "freddy tier-1 backup -> $DEST  (host=$HOST keep=$KEEP)"
if ! remote true; then
  fail "cannot reach $HOST over ssh"
  exit 1
fi

FAILED=0
run() { "$@" || FAILED=$((FAILED + 1)); }

run dump_pg authentik-postgres   authentik   authentik   authentik_pg
run dump_pg nextcloud-postgres   nextcloud   nextcloud   nextcloud_pg

# PhotoPrism is a special case and the reason this script checks content
# rather than exit codes. It is CONFIGURED for postgres, but as of
# 2026-09-21 that database has zero tables and the app has never connected
# to it (see the outage note in README.md). Its real index -- every album,
# label and face ever curated -- is the SQLite file left behind at the
# migration, frozen since 2026-08-25.
#
# So back up BOTH: the postgres dump would be a perfectly valid, perfectly
# empty archive, and shipping only that is precisely how a backup ends up
# hollow. Once the outage is resolved, whichever store loses is the one to
# drop from this list.
run dump_pg photoprism-postgres  photoprism  photoprism  photoprism_pg_EMPTY
run dump_sqlite freddy_photoprism_storage index.db photoprism_index
run dump_tree freddy_photoprism_storage . photoprism_curated \
  './cache' './sidecar' './backups' 'index.db*'

run dump_sqlite freddy_audiobookshelf_config absdatabase.sqlite   audiobookshelf
run dump_sqlite freddy_shelfmark_data        shelfmark.db         shelfmark
run dump_sqlite freddy_uptime_kuma_data      kuma.db              uptime_kuma
run dump_sqlite freddy_homeassistant_config  home-assistant_v2.db homeassistant

# Config trees. Exclusions are all regenerable noise -- logs, caches, the
# SQLite databases already captured above by their own online backup, and
# uptime-kuma's 40MB error.log, which is 99% of that volume and worth nothing.
run dump_tree freddy_homeassistant_config . homeassistant_config \
  'home-assistant_v2.db*' '*.log' '*.log.*' './deps' './tts' '.ha_run.lock'
run dump_tree freddy_audiobookshelf_metadata . audiobookshelf_metadata \
  './cache' './logs' './streams'
run dump_tree freddy_shelfmark_data . shelfmark_manifests 'shelfmark.db*'
run dump_tree freddy_authentik_certs     . authentik_certs
run dump_tree freddy_authentik_templates . authentik_templates
run dump_tree freddy_authentik_media     . authentik_media
run dump_tree freddy_uptime_kuma_data docker-tls uptime_kuma_tls
run dump_library_metadata

if [ "$FAILED" -gt 0 ]; then
  fail "$FAILED source(s) failed -- NOT writing an archive"
  fail "an incomplete archive that looks successful is worse than no archive"
  exit 1
fi

# A manifest travels INSIDE the archive so a restorer can tell, from the
# archive alone, what it was supposed to contain and whether it still does.
# Built OUTSIDE the staging directory and moved in afterwards. Redirecting
# into $STAGE/MANIFEST.txt would create the file empty before the block runs,
# so `sha256sum ./*` would hash the empty manifest and record a checksum that
# is wrong the instant the content lands -- a self-inflicted corruption report
# on every single archive.
MANIFEST_TMP="$(mktemp)"
{
  echo "# freddy tier-1 backup"
  echo "created_utc: $STAMP"
  echo "source_host: $HOST"
  echo "created_by:  $(whoami)@$(hostname)"
  echo "members:"
  ( cd "$STAGE" && sha256sum ./* | sed 's/^/  /' )
} > "$MANIFEST_TMP"
mv "$MANIFEST_TMP" "$STAGE/MANIFEST.txt"

mkdir -p "$DEST"
ARCHIVE="$DEST/freddy-tier1-$STAMP.tar.zst"
if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry run -- staged but not archived:"
  ls -la "$STAGE"
  exit 0
fi

tar -C "$STAGE" -cf - . | zstd -q -19 -T0 -o "$ARCHIVE"
chmod 600 "$ARCHIVE"
ok "archive $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# Prove the archive is readable before trusting it enough to prune older ones.
# Listing is not a restore -- verify-freddy-tier1.sh does that -- but an
# archive that cannot even be listed must never cause history to be deleted.
if ! zstd -dc "$ARCHIVE" | tar -tf - > /dev/null; then
  fail "archive is not readable -- keeping ALL older backups"
  exit 1
fi
ok "archive reads back cleanly"

mapfile -t OLD < <(ls -1t "$DEST"/freddy-tier1-*.tar.zst 2>/dev/null | tail -n "+$((KEEP + 1))")
if [ "${#OLD[@]}" -gt 0 ]; then
  for f in "${OLD[@]}"; do
    info "pruning $(basename "$f")"
    rm -f "$f"
  done
fi

COUNT="$(ls -1 "$DEST"/freddy-tier1-*.tar.zst 2>/dev/null | wc -l)"
ok "done -- $COUNT archive(s) retained in $DEST"
