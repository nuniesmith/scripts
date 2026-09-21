#!/usr/bin/env bash
# Nightly snapshot of sullivan's TIER 1 state: the service configuration that
# defines how the media stack behaves.
#
# Sullivan's volumes are dominated by CACHE -- plex_data alone is 86GB, almost
# all of it artwork and transcode metadata that regenerates itself. The part
# that would actually hurt is small and buried inside those volumes:
#
#   radarr/sonarr/lidarr.db  indexers, quality profiles, root folders, custom
#                            formats, and the entire library index -- the thing
#                            that took months of tuning
#   prowlarr.db              every indexer definition and its credentials
#   qBittorrent + BT_backup  client settings AND the resume data for every
#                            active torrent; losing BT_backup means re-checking
#                            18TB against the array
#   plex library.db          watch history, playlists, collections, ratings --
#                            unrecoverable, and the one users notice
#   recyclarr YAML           the custom-format sync config
#   compose + .env           how the whole stack is assembled
#
# 18TB of media is NOT covered and is not meant to be. It is re-acquirable;
# a decade of watch history is not.
#
# PULL model and every artifact rule are shared with the freddy job -- see
# lib.sh and README.md.
#
# Usage: backup-sullivan-tier1.sh [--dest DIR] [--host HOST] [--keep N] [--dry-run]

set -euo pipefail

DEST="${BACKUP_DEST:-$HOME/backups/sullivan}"
HOST="${BACKUP_HOST:-sullivan}"
KEEP="${BACKUP_KEEP:-14}"
PREFIX="sullivan"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sullivan-tier1.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

info "sullivan tier-1 backup -> $DEST  (host=$HOST keep=$KEEP)"
remote true || { fail "cannot reach $HOST over ssh"; exit 1; }

# --- the *arr databases -------------------------------------------------
# Each of these IS the service's configuration. logs.db sits beside them and
# is deliberately skipped: it is the largest file in several of these volumes
# and restoring yesterday's log lines helps nobody.
run dump_sqlite sullivan_radarr_data   radarr.db      radarr
run dump_sqlite sullivan_sonarr_data   sonarr.db      sonarr
run dump_sqlite sullivan_lidarr_data   lidarr.db      lidarr
run dump_sqlite sullivan_prowlarr_data prowlarr.db    prowlarr
run dump_sqlite sullivan_bazarr_data   db/bazarr.db   bazarr

# --- Plex ---------------------------------------------------------------
# The library database carries watch history, playlists, collections and
# ratings. Its 86GB volume is otherwise artwork and transcode cache, so this
# takes the two things that matter and leaves the rest.
PLEX_APP='Library/Application Support/Plex Media Server'
run dump_sqlite sullivan_plex_data \
  "$PLEX_APP/Plug-in Support/Databases/com.plexapp.plugins.library.db" plex_library
run dump_tree sullivan_plex_data "$PLEX_APP" plex_prefs \
  './Cache' './Logs' './Media' './Metadata' './Plug-in Support/Caches' \
  './Plug-in Support/Databases' './Crash Reports' './Diagnostics' './Codecs'

# --- other service databases --------------------------------------------
run dump_sqlite sullivan_mealie_data mealie.db     mealie
run dump_sqlite sullivan_grocy_data  data/grocy.db grocy
run dump_pg     wiki-postgres wikijs wiki wiki_pg

# --- config trees -------------------------------------------------------
# qBittorrent's BT_backup holds the .fastresume for every active torrent.
# Without it a restore re-checks 18TB against the array before seeding
# resumes, so it is worth every one of its 4.6MB.
run dump_tree sullivan_qbittorrent_data qBittorrent qbittorrent_config \
  './logs' './data/logs' '*.log'
run dump_tree sullivan_recyclarr_data   . recyclarr_config './repositories' './logs' '*.log'
run dump_tree sullivan_prowlarr_data    Definitions prowlarr_definitions
run dump_tree sullivan_tdarr_server_data . tdarr_config './logs' './Tdarr/Logs' '*.log'
run dump_tree sullivan_seerr_data       . seerr_config './logs' '*.log' '.machinelogs*'
run dump_tree sullivan_dispatcharr_data . dispatcharr_config './logs' '*.log'
run dump_tree sullivan_jellyfin_data    . jellyfin_config \
  './cache' './log' './logs' './metadata' './transcodes' './data/subtitles'

# --- how the stack is assembled -----------------------------------------
# A backup of every database and none of the compose files restores a pile of
# data nobody can start. .env travels with it ON PURPOSE: the archive is
# chmod 600 on a host the operator controls, and a compose file whose secrets
# are missing does not bring the stack back either.
run dump_host_files /home/jordan/sullivan  compose_jordan  './node_modules' '.git'
run dump_host_files /home/actions/sullivan compose_actions './node_modules' '.git'

finish
