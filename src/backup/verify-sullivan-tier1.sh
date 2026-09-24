#!/usr/bin/env bash
# Restore rehearsal for a sullivan tier-1 archive.
#
# Same rule as the freddy rehearsal: ASSERT THE POSITIVE CAPABILITY. Every
# check demands named, human-meaningful content -- real movies in radarr, real
# indexers in prowlarr, real watch history in Plex, real .fastresume files for
# qBittorrent. A check phrased as a prohibition is passed trivially by an empty
# database, which is how a hollow backup earns a green tick for months.
#
# Usage: verify-sullivan-tier1.sh [ARCHIVE]   (default: newest, which must
#                                              also be recent)

set -euo pipefail

DEST="${BACKUP_DEST:-$HOME/backups/sullivan}"
ARCHIVE="${1:-}"
MAX_AGE_HOURS="${VERIFY_MAX_AGE_HOURS:-36}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
bad()  { echo -e "${RED}[FAIL]${NC} $1" >&2; }

PASS=0; FAIL=0
assert() {
  local what="$1" actual="$2" want="$3"
  if [ "${actual:-0}" -ge "$want" ] 2>/dev/null; then
    ok "$what: $actual (>= $want)"; PASS=$((PASS + 1))
  else
    bad "$what: got '${actual:-<nothing>}', wanted >= $want"; FAIL=$((FAIL + 1))
  fi
}

CHECK_AGE=0
if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(ls -1t "$DEST"/sullivan-tier1-*.tar.zst 2>/dev/null | head -1 || true)"
  CHECK_AGE=1
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then bad "no archive found in $DEST"; exit 1; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sullivan-verify.XXXXXX")"
# A verifier that dies early must NEVER look like a pass. Without this guard
# `set -e` can end the run mid-way with status 0 and no verdict, and a caller
# (or a systemd timer) reads that as success. Reached the summary sets
# VERDICT_REACHED; anything else exits non-zero and says why.
VERDICT_REACHED=0
on_exit() {
  local rc=$?
  rm -rf "$WORK"
  if [ "$VERDICT_REACHED" -eq 0 ]; then
    bad "rehearsal ENDED EARLY without a verdict (rc=$rc) -- treat as FAILED"
    exit 1
  fi
}
trap on_exit EXIT

info "rehearsing $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
zstd -dc "$ARCHIVE" | tar -xf - -C "$WORK"
ok "archive extracted"

if ( cd "$WORK" && sha256sum --quiet -c <(grep -E '^\s+[0-9a-f]{64}' MANIFEST.txt | sed 's/^\s*//') ) 2>/dev/null; then
  ok "every member matches its recorded sha256"; PASS=$((PASS + 1))
else
  bad "checksum mismatch -- the archive is corrupt"; FAIL=$((FAIL + 1))
fi

# Restorable is not enough; the newest archive also has to be NEW. Without
# this a nightly job that has quietly failed for a week still earns a green
# rehearsal on whatever it last managed to write -- which is how freddy's
# stood on 2026-09-24. An archive named on the command line skips this.
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
    bad "  $(date -u -d "@$created_epoch" '+%Y-%m-%d %H:%M UTC'); check: journalctl --user -u backup-sullivan-tier1"
    FAIL=$((FAIL + 1))
  fi
fi

sq() {  # sq <file> <label> <sql> <what> <min>
  local file="$1" label="$2" sql="$3" what="$4" min="$5"
  if [ ! -f "$WORK/$file" ]; then bad "$label: missing from archive"; FAIL=$((FAIL + 1)); return 0; fi
  local integrity count
  # `|| true` on every probe is deliberate. Without it a database that stock
  # SQLite cannot even open aborts the whole run under `set -e` -- and the
  # script then EXITS 0 having silently skipped every remaining check, which
  # is the exact hollow green tick this tool exists to prevent.
  integrity="$(python3 -c "
import sqlite3
c=sqlite3.connect('file:$WORK/$file?mode=ro',uri=True)
print(c.execute('PRAGMA integrity_check').fetchone()[0])" 2>&1 | tail -1 || true)"
  case "$integrity" in
    ok)
      ok "$label integrity: ok"; PASS=$((PASS + 1)) ;;
    *"unknown tokenizer"*|*"no such module"*)
      # Plex registers custom FTS tokenizers in its OWN SQLite build, so stock
      # sqlite3 cannot walk its virtual tables. The page-level copy is still
      # faithful -- `.backup` copies pages and never parses the schema -- and
      # the row counts below still prove real content. Worth knowing at
      # restore time: this database needs Plex's own `Plex SQLite` binary.
      warn "$label integrity: not checkable by stock sqlite ($integrity)"
      warn "$label restores with Plex's own 'Plex SQLite' binary, not sqlite3" ;;
    *)
      bad "$label integrity: $integrity"; FAIL=$((FAIL + 1)) ;;
  esac
  count="$(python3 -c "
import sqlite3
c=sqlite3.connect('file:$WORK/$file?mode=ro',uri=True)
print(c.execute(\"\"\"$sql\"\"\").fetchone()[0])" 2>/dev/null || true)"
  assert "$label $what" "$count" "$min"
  return 0
}

info "--- *arr configuration"
# Not "the file opens" but "the library and the tuning are in there". Quality
# profiles and indexers are the months of work; a restore without them is a
# fresh install wearing the right filename.
sq radarr.sqlite   "radarr"   "SELECT count(*) FROM Movies"          "movies"           1
sq radarr.sqlite   "radarr"   "SELECT count(*) FROM QualityProfiles" "quality profiles" 1
sq sonarr.sqlite   "sonarr"   "SELECT count(*) FROM Series"          "series"           1
sq sonarr.sqlite   "sonarr"   "SELECT count(*) FROM QualityProfiles" "quality profiles" 1
sq lidarr.sqlite   "lidarr"   "SELECT count(*) FROM Artists"         "artists"          1
sq prowlarr.sqlite "prowlarr" "SELECT count(*) FROM Indexers"        "indexers"         1
sq bazarr.sqlite   "bazarr"   "SELECT count(*) FROM table_settings_languages" "languages" 1

info "--- Plex"
# Watch history is the thing nobody can rebuild and everybody notices.
sq plex_library.sqlite "plex" "SELECT count(*) FROM metadata_items"         "library items" 100
sq plex_library.sqlite "plex" "SELECT count(*) FROM metadata_item_settings" "watch state"   1

info "--- other services"
# Mealie and grocy are installed but UNUSED as of 2026-09-21: mealie has one
# user and zero recipes, grocy zero products. Asserting content would fail on
# a perfectly faithful backup, so these assert that the schema and what little
# data exists came back. Raise the bar if they ever get used -- a check that
# lies about the archive is worse than no check.
sq mealie.sqlite "mealie" "SELECT count(*) FROM users" "users" 1
sq grocy.sqlite  "grocy" \
  "SELECT count(*) FROM sqlite_master WHERE type='table'" "tables" 10

info "--- config trees"
th() {  # th <file> <label> <pattern> <min>
  local file="$1" label="$2" pattern="$3" min="$4" n
  if [ ! -f "$WORK/$file" ]; then bad "$label: missing"; FAIL=$((FAIL + 1)); return; fi
  n="$(tar -tzf "$WORK/$file" 2>/dev/null | grep -cE "$pattern" || true)"
  assert "$label contains $pattern" "$n" "$min"
}
# BT_backup is the reason qBittorrent's config is worth backing up at all:
# without the .fastresume files a restore re-checks 18TB against the array.
th qbittorrent_config.tar.gz   "qbittorrent" 'BT_backup/.*\.fastresume' 1
th qbittorrent_config.tar.gz   "qbittorrent" 'qBittorrent\.conf'        1
th recyclarr_config.tar.gz     "recyclarr"   'recyclarr\.yml'           1
th prowlarr_definitions.tar.gz "prowlarr"    '\.yml'                    1
th plex_prefs.tar.gz           "plex"        'Preferences\.xml'         1
# The compose files: a backup of every database and none of these restores a
# pile of data nobody can start.
th compose_jordan.tar.gz       "compose"     'docker-compose\.ya?ml'    1

VERDICT_REACHED=1
echo
if [ "$FAIL" -gt 0 ]; then
  bad "REHEARSAL FAILED -- $PASS passed, $FAIL failed"
  bad "this archive is not known to be restorable; do not rely on it"
  exit 1
fi
ok "REHEARSAL PASSED -- $PASS assertions, 0 failures"
ok "$(basename "$ARCHIVE") restores to real, populated configuration"
