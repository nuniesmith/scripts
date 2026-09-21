#!/usr/bin/env bash
# Nightly snapshot of freddy's TIER 1 state: the databases and configuration
# that cannot be re-downloaded and would take days to rebuild by hand.
#
# Tier 1 is deliberately NOT everything on freddy. It is the ~82MB that costs
# the most per byte to lose. The 158GB of photos and Nextcloud files is tier 2
# and is NOT covered here -- say so out loud rather than letting this script
# look like full protection.
#
# PULL model: this runs on the BACKUP host and reaches into freddy. The backup
# host holds the credentials, so nothing on freddy can reach in and delete its
# own history -- the half of "backup" that ransomware actually tests.
#
# See README.md for the design rules and the two outages this uncovered.
#
# Usage: backup-freddy-tier1.sh [--dest DIR] [--host HOST] [--keep N] [--dry-run]

set -euo pipefail

DEST="${BACKUP_DEST:-$HOME/backups/freddy}"
HOST="${BACKUP_HOST:-freddy}"
KEEP="${BACKUP_KEEP:-14}"
PREFIX="freddy"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/freddy-tier1.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

info "freddy tier-1 backup -> $DEST  (host=$HOST keep=$KEEP)"
remote true || { fail "cannot reach $HOST over ssh"; exit 1; }

run dump_pg authentik-postgres authentik authentik authentik_pg
run dump_pg nextcloud-postgres nextcloud nextcloud nextcloud_pg

# PhotoPrism is a special case and the reason this script checks content
# rather than exit codes. It is CONFIGURED for postgres, but as of 2026-09-21
# that database has zero tables and the app has never connected to it (see the
# outage note in README.md). Its real index -- every album, label and face ever
# curated -- is the SQLite left behind at the migration, frozen since
# 2026-08-25.
#
# So back up BOTH: the postgres dump would be a perfectly valid, perfectly
# empty archive, and shipping only that is precisely how a backup ends up
# hollow. Once the outage is resolved, whichever store loses is the one to drop.
run dump_pg photoprism-postgres photoprism photoprism photoprism_pg_EMPTY
run dump_sqlite freddy_photoprism_storage index.db photoprism_index
run dump_tree freddy_photoprism_storage . photoprism_curated \
  './cache' './sidecar' './backups' 'index.db*'

# absdatabase.sqlite is the point of this whole tier: it carries Kayla's
# account AND her reading position in every book.
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

# The per-book metadata.json files inside the (huge, re-downloadable) library.
# The audio is tier 3; these are not -- 94 of them were repaired by hand on
# 2026-09-12 after Audiobookshelf invented an author for them, and that work is
# recorded nowhere else.
#
# Alpine's tar is BusyBox tar: no --null, and -T must name a real file rather
# than read stdin.
dump_library_metadata() {
  info "tar library metadata.json files"
  if ! remote "docker run --rm -v freddy_audiobookshelf_data:/src:ro '$TAR_IMAGE' \
        sh -c 'cd /src && find . -name metadata.json > /tmp/l && tar -czf - -T /tmp/l'" \
       > "$STAGE/library_metadata.tar.gz.part"; then
    fail "library metadata tar failed"; rm -f "$STAGE/library_metadata.tar.gz.part"; return 1
  fi
  promote "$STAGE/library_metadata.tar.gz.part" "$STAGE/library_metadata.tar.gz" \
    "$EMPTY_TAR_BYTES" "library_metadata.tar.gz"
}
run dump_library_metadata

finish
