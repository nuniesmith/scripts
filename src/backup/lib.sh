# Shared engine for the per-host tier-1 backup jobs. Source it; do not run it.
#
# Everything subtle about producing a trustworthy artifact lives here exactly
# once, because a second copy of the SQLite entrypoint override or the .part
# promotion rule is a second thing to get wrong quietly.
#
# Callers set: HOST, DEST, KEEP, PREFIX, DRY_RUN
# Callers use: dump_pg, dump_sqlite, dump_tree, dump_host_files, run, finish

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1" >&2; }

# An image that is already on the target host AND ships sqlite3. Pulling a
# fresh image at 03:00 would make the whole job depend on a registry being up.
SQLITE_IMAGE="${SQLITE_IMAGE:-louislam/uptime-kuma:latest}"
TAR_IMAGE="${TAR_IMAGE:-alpine:latest}"

# A gzipped EMPTY tar is ~85 bytes. An empty directory is a fact worth
# capturing, not a failure, so these cannot share the floor that catches
# truncated dumps.
EMPTY_TAR_BYTES=60

FAILED=0
run() { "$@" || FAILED=$((FAILED + 1)); }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

# A dump that fails must not leave a plausible-looking short file behind.
# Every producer writes to .part and is promoted only once it has both exited
# 0 AND passed its own shape check, so a half-written artifact can never be
# archived as a successful backup.
promote() {
  local part="$1" final="$2" min="$3" what="$4" size
  size="$(stat -c %s "$part" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min" ]; then
    fail "$what: only ${size}B (expected >= ${min}B) -- refusing to keep it"
    rm -f "$part"; return 1
  fi
  mv "$part" "$final"
  ok "$what ($(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B"))"
}

dump_pg() {
  local container="$1" user="$2" db="$3" name="$4"
  info "pg_dump $container/$db"
  if ! remote "docker exec -i '$container' pg_dump -U '$user' -d '$db' -Fc" \
       > "$STAGE/$name.dump.part"; then
    fail "pg_dump $container/$db exited non-zero"; rm -f "$STAGE/$name.dump.part"; return 1
  fi
  if [ "$(head -c 5 "$STAGE/$name.dump.part")" != "PGDMP" ]; then
    fail "$name: not a postgres custom dump (bad magic)"
    rm -f "$STAGE/$name.dump.part"; return 1
  fi
  # Magic proves validity; size is a separate signal. An EMPTY database dumps
  # to a valid ~830B archive, so a size floor here would reject a correct
  # backup -- while a database that silently emptied would sail past any floor
  # low enough to admit it. Report the smell, keep the artifact, and let the
  # restore rehearsal be the thing that asserts real content.
  local size; size="$(stat -c %s "$STAGE/$name.dump.part" 2>/dev/null || echo 0)"
  [ "$size" -lt 2048 ] && warn "$name: ${size}B -- valid dump of an essentially EMPTY database"
  promote "$STAGE/$name.dump.part" "$STAGE/$name.dump" 256 "$name.dump"
}

dump_sqlite() {
  local volume="$1" dbfile="$2" name="$3"
  info "sqlite .backup $volume/$dbfile"
  # `.backup` is SQLite's ONLINE backup API: it takes a read lock and copies
  # pages, producing a consistent file while the application keeps writing.
  # Copying the file directly would be wrong -- these databases are in WAL
  # mode, and a plain copy silently loses every write still in the
  # write-ahead log.
  #
  # The volume is mounted READ-WRITE on purpose: SQLite needs to map the -shm
  # index to read a WAL database. Mounting it ro makes the backup fail rather
  # than make it safer.
  #
  # `--entrypoint sh` is not optional. This image's entrypoint starts the
  # uptime-kuma server, which greets stdout with "==> Performing startup jobs"
  # -- and those bytes land at offset 0 of the backup, ahead of the SQLite
  # header. Without the override every artifact is a corrupt database that
  # still weighs about the right amount.
  if ! remote "docker run --rm --entrypoint sh -v '$volume':/src '$SQLITE_IMAGE' \
        -c 'sqlite3 \"/src/$dbfile\" \".backup /tmp/b.db\" 1>&2 && cat /tmp/b.db'" \
       > "$STAGE/$name.sqlite.part"; then
    fail "sqlite backup of $volume/$dbfile failed"
    rm -f "$STAGE/$name.sqlite.part"; return 1
  fi
  if [ "$(head -c 15 "$STAGE/$name.sqlite.part")" != "SQLite format 3" ]; then
    fail "$name: not a SQLite database (bad magic)"
    rm -f "$STAGE/$name.sqlite.part"; return 1
  fi
  promote "$STAGE/$name.sqlite.part" "$STAGE/$name.sqlite" 4096 "$name.sqlite"
}

# tar a volume subtree. Extra arguments become tar --exclude patterns.
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
    fail "tar of $volume/$subdir failed"; rm -f "$STAGE/$name.tar.gz.part"; return 1
  fi
  promote "$STAGE/$name.tar.gz.part" "$STAGE/$name.tar.gz" "$EMPTY_TAR_BYTES" "$name.tar.gz"
}

# tar a path on the HOST filesystem rather than inside a volume -- compose
# files, .env, anything that defines how the stack is assembled. A backup of
# every database and none of the compose files restores a pile of data nobody
# can start.
dump_host_files() {
  local path="$1" name="$2"; shift 2
  local excludes=""
  for pat in "$@"; do excludes="$excludes --exclude='$pat'"; done
  info "tar host:$path"
  if ! remote "tar -czf - $excludes -C '$path' . 2>/dev/null" \
       > "$STAGE/$name.tar.gz.part"; then
    fail "tar of host:$path failed"; rm -f "$STAGE/$name.tar.gz.part"; return 1
  fi
  promote "$STAGE/$name.tar.gz.part" "$STAGE/$name.tar.gz" "$EMPTY_TAR_BYTES" "$name.tar.gz"
}

# Write the manifest, build the archive, verify it reads back, prune old ones.
finish() {
  if [ "$FAILED" -gt 0 ]; then
    fail "$FAILED source(s) failed -- NOT writing an archive"
    fail "an incomplete archive that looks successful is worse than no archive"
    exit 1
  fi

  # Built OUTSIDE the staging directory and moved in. Redirecting into
  # $STAGE/MANIFEST.txt would create the file empty before the block runs, so
  # `sha256sum ./*` would hash the empty manifest and record a checksum wrong
  # the instant content lands -- a self-inflicted corruption report on every
  # single archive.
  local mtmp; mtmp="$(mktemp)"
  {
    echo "# $PREFIX tier-1 backup"
    echo "created_utc: $STAMP"
    echo "source_host: $HOST"
    echo "created_by:  $(whoami)@$(hostname)"
    echo "members:"
    ( cd "$STAGE" && sha256sum ./* | sed 's/^/  /' )
  } > "$mtmp"
  mv "$mtmp" "$STAGE/MANIFEST.txt"

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    warn "dry run -- staged but not archived:"; ls -la "$STAGE"; exit 0
  fi

  mkdir -p "$DEST"
  local archive="$DEST/$PREFIX-tier1-$STAMP.tar.zst"
  tar -C "$STAGE" -cf - . | zstd -q -19 -T0 -o "$archive"
  chmod 600 "$archive"
  ok "archive $archive ($(du -h "$archive" | cut -f1))"

  # Prove the archive is readable before trusting it enough to prune older
  # ones. Listing is not a restore -- the verify script does that -- but an
  # archive that cannot even be listed must never cause history to be deleted.
  if ! zstd -dc "$archive" | tar -tf - > /dev/null; then
    fail "archive is not readable -- keeping ALL older backups"; exit 1
  fi
  ok "archive reads back cleanly"

  local old
  mapfile -t old < <(ls -1t "$DEST/$PREFIX-tier1-"*.tar.zst 2>/dev/null | tail -n "+$((KEEP + 1))")
  for f in "${old[@]:-}"; do
    [ -n "$f" ] || continue
    info "pruning $(basename "$f")"; rm -f "$f"
  done
  ok "done -- $(ls -1 "$DEST/$PREFIX-tier1-"*.tar.zst 2>/dev/null | wc -l) archive(s) in $DEST"
}
