#!/usr/bin/env python3
"""
Media Server Cleanup Script for Sullivan
- Finds media by filesystem age, not playback history
- Cleans confirmed abandoned qBittorrent temporary files
- Dry-run by default for safety
"""

import argparse
import logging
import math
import os
import shutil
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List

# ====================== CONFIGURATION (Sullivan paths) ======================

MEDIA_DIRS = [
    "/mnt/media/movies",
    "/mnt/media/shows",
    "/mnt/media/music",
    "/mnt/media/music_videos",
    "/mnt/media/edu",
    "/mnt/media/books/audiobooks",
    "/mnt/media/books/ebooks",
    # Optional extras you can enable:
    # "/mnt/media/seed",
    # "/mnt/media/clean",
]

# Only directories containing confirmed abandoned files, no longer tracked by
# qBittorrent or an importer. Never configure live incomplete/complete directories.
# Empty by default; configure here or supply --qb-dir explicitly.
QB_INCOMPLETE_DIRS = []

# File extensions considered "media"
MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".flv",
    ".webm", ".ts", ".m2ts", ".mpg", ".mpeg", ".vob",
    ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".wav",
    ".iso", ".img",                           # disc images
    ".m4b", ".epub", ".pdf",                  # audiobooks / ebooks
}

# How old before considering for deletion (days)
MEDIA_AGE_DAYS = 365          # filesystem timestamps, NOT playback history
QB_TEMP_AGE_DAYS = 7          # incomplete/temp files older than 7 days

# Minimum free space target per filesystem (GiB). Set to 0 to ignore.
TARGET_FREE_GB = 0

# ====================== END CONFIG ======================


def setup_logging(verbose: bool):
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if abs(size) < 1024.0:
            return f"{size:3.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} PiB"


@dataclass(frozen=True)
class Candidate:
    path: Path
    snapshot: os.stat_result
    age_days: float
    cutoff_days: float
    use_atime: bool


def file_age_days(snapshot: os.stat_result, use_atime: bool) -> float:
    # A recent modification must not qualify just because atime is stale.
    timestamp = max(snapshot.st_atime, snapshot.st_mtime) if use_atime else snapshot.st_mtime
    return (time.time() - timestamp) / 86400.0


def get_file_age_days(path: Path, use_atime: bool = True) -> float:
    """Return filesystem age; propagate stat failures rather than treating them as age zero."""
    return file_age_days(path.lstat(), use_atime)


def is_media_file(path: Path) -> bool:
    return path.suffix.lower() in MEDIA_EXTENSIONS


def log_walk_error(error: OSError):
    logging.warning(f"Could not scan directory: {error}")


def find_candidates(dirs: List[str], age_days: float, use_atime: bool,
                    qb_temp: bool = False) -> List[Candidate]:
    if not math.isfinite(age_days) or age_days <= 0:
        raise ValueError("Age must be a positive number of days")
    results = []
    seen = set()
    junk_dirs = {
        ".Trash", ".recycle", "@eaDir", ".AppleDouble",
        "lost+found", ".snapshots", "#recycle", ".recyclebin"
    }
    temp_extensions = {".!qb", ".parts", ".!ut", ".tmp", ".partial"}

    for root in dirs:
        root_path = Path(os.path.abspath(root))
        try:
            # Reject symlink roots and ancestors as well as symlink entries.
            if root_path.resolve(strict=True) != root_path or not root_path.is_dir():
                logging.warning(f"Skipping non-directory or symlinked root: {root}")
                continue
        except (OSError, RuntimeError) as error:
            logging.warning(f"Cannot scan {root}: {error}")
            continue

        logging.info(f"Scanning {'abandoned qBittorrent files' if qb_temp else 'media'}: {root}")
        for dirpath, dirnames, filenames in os.walk(root_path, onerror=log_walk_error):
            dirnames[:] = [d for d in dirnames if d not in junk_dirs
                          and not (qb_temp and d.startswith("."))]
            for name in filenames:
                path = Path(dirpath) / name
                matches = path.suffix.lower() in temp_extensions if qb_temp else is_media_file(path)
                if not matches or path in seen:
                    continue
                seen.add(path)
                try:
                    snapshot = path.lstat()
                    if not stat.S_ISREG(snapshot.st_mode):
                        continue
                    age = file_age_days(snapshot, use_atime)
                    if age >= age_days:
                        results.append(Candidate(path, snapshot, age, age_days, use_atime))
                except OSError as error:
                    logging.warning(f"Skipping {path}: {error}")

    results.sort(key=lambda candidate: candidate.age_days, reverse=True)
    return results


def find_old_media(dirs: List[str], age_days: float, use_atime: bool) -> List[Candidate]:
    """Find media by filesystem age, not by watch/listen history."""
    return find_candidates(dirs, age_days, use_atime)


def find_qb_temp_files(dirs: List[str], age_days: float) -> List[Candidate]:
    """Find old partial files in directories of confirmed abandoned downloads only."""
    return find_candidates(dirs, age_days, use_atime=False, qb_temp=True)


def file_fingerprint(snapshot: os.stat_result):
    return (snapshot.st_dev, snapshot.st_ino, snapshot.st_mode, snapshot.st_size,
            snapshot.st_atime_ns, snapshot.st_mtime_ns, snapshot.st_ctime_ns,
            snapshot.st_nlink)


def process_files(files: List[Candidate], dry_run: bool, label: str,
                  target_free_gb: float = 0) -> int:
    """Return logical bytes selected/deleted, not an estimate of reclaimed space."""
    if not math.isfinite(target_free_gb) or target_free_gb < 0:
        raise ValueError("Free-space target must be finite and nonnegative")
    if not files:
        logging.info(f"No {label} files found matching criteria.")
        return 0

    total_size = sum(candidate.snapshot.st_size for candidate in files)
    logging.info(f"Found {len(files)} {label} files totaling {human_size(total_size)} logical size")
    if dry_run and target_free_gb:
        logging.info("Dry-run checks current free space only; it does not simulate reclaimed space.")

    processed = 0
    seen = set()
    for candidate in files:
        path = candidate.path
        if path in seen:
            continue
        seen.add(path)
        try:
            if path.resolve(strict=True) != path:
                logging.warning(f"Skipping symlinked path: {path}")
                continue
            if target_free_gb and shutil.disk_usage(path.parent).free >= target_free_gb * 1024 ** 3:
                logging.info(f"Free-space target already met on filesystem for {path}; skipping")
                continue
            current = path.lstat()
            if (not stat.S_ISREG(current.st_mode)
                    or file_fingerprint(current) != file_fingerprint(candidate.snapshot)
                    or file_age_days(current, candidate.use_atime) < candidate.cutoff_days):
                logging.warning(f"Skipping file changed since scan: {path}")
                continue
            # Conservatively preserve shared torrent/library data, even if both
            # links might otherwise be eligible. Logical size is not freed space.
            if current.st_nlink > 1:
                logging.warning(f"Skipping hardlinked file ({current.st_nlink} links): {path}")
                continue
            size = current.st_size
            details = f"{human_size(size)} logical size, {candidate.age_days:.0f} days old"
            if dry_run:
                logging.info(f"[DRY-RUN] Would delete: {path}  ({details})")
            else:
                # Revalidation narrows but cannot eliminate concurrent rename/write
                # races. Stop writers/importers before executing this script.
                path.unlink()
                logging.info(f"Deleted: {path}  ({details})")
            processed += size
        except (OSError, RuntimeError) as error:
            logging.error(f"Could not process {path}: {error}")

    action = "[DRY-RUN] Selected" if dry_run else "Deleted"
    logging.info(f"{action} {human_size(processed)} logical size; actual reclaimed space may differ")
    return processed


def positive_days(value: str) -> int:
    try:
        days = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("Age must be a positive integer number of days")
    if days <= 0:
        raise argparse.ArgumentTypeError("Age must be a positive integer number of days")
    return days


def free_space_target(value: str) -> float:
    try:
        target = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("Free-space target must be finite and nonnegative")
    if not math.isfinite(target) or target < 0:
        raise argparse.ArgumentTypeError("Free-space target must be finite and nonnegative")
    return target


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Clean media by filesystem age and confirmed abandoned qBittorrent partial files"
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="Only show what would be deleted (the default)")
    mode.add_argument("--execute", action="store_true", help="Permanently delete eligible files")
    parser.add_argument("--media-age", type=positive_days, default=str(MEDIA_AGE_DAYS),
                        help=f"Filesystem age for media in days (default: {MEDIA_AGE_DAYS})")
    parser.add_argument("--qb-age", type=positive_days, default=str(QB_TEMP_AGE_DAYS),
                        help=f"Modification age for partial files in days (default: {QB_TEMP_AGE_DAYS})")
    parser.add_argument("--use-mtime", action="store_true",
                        help="Use modification time only; default uses the newer of access/modify time")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--media-only", action="store_true", help="Only process media files")
    selection.add_argument("--qb-only", action="store_true", help="Only process abandoned partial files")
    parser.add_argument("--qb-dir", action="append", metavar="DIRECTORY",
                        help="Directory of confirmed abandoned files (repeatable; replaces configured dirs)")
    parser.add_argument("--confirm-filesystem-age", action="store_true",
                        help="Required for media deletion: acknowledge age is not playback history")
    parser.add_argument("--confirm-qb-abandoned", action="store_true",
                        help="Required for partial-file deletion: confirm no torrent/importer tracks these files")
    parser.add_argument("--target-free-gb", type=free_space_target, default=str(TARGET_FREE_GB),
                        help="Stop deleting on each filesystem once it has this many GiB free (0 disables)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    qb_dirs = args.qb_dir if args.qb_dir is not None else QB_INCOMPLETE_DIRS
    if args.execute:
        if not args.qb_only and not args.confirm_filesystem_age:
            parser.error("Media deletion requires --confirm-filesystem-age; timestamps are not playback history")
        if not args.media_only and qb_dirs and not args.confirm_qb_abandoned:
            parser.error("Partial-file deletion requires --confirm-qb-abandoned; never use live download directories")

    dry_run = not args.execute
    setup_logging(args.verbose)
    if not args.qb_only:
        logging.warning("Filesystem age does NOT establish whether media is unwatched/unused; "
                        "atime may be disabled or updated conditionally, and mtime is not playback history.")
    if not args.media_only and not qb_dirs:
        logging.info("qBittorrent cleanup disabled: no abandoned-file directories configured (see --qb-dir)")

    if dry_run:
        logging.info("=== DRY-RUN MODE (no files will be deleted) ===")
    else:
        logging.warning("=== EXECUTE MODE - FILES WILL BE PERMANENTLY DELETED ===")
        logging.warning("Stop writers/importers first; file revalidation cannot eliminate concurrent deletion races.")
        time.sleep(3)

    total_processed = 0
    if not args.qb_only:
        media_files = find_old_media(MEDIA_DIRS, args.media_age, use_atime=not args.use_mtime)
        total_processed += process_files(media_files, dry_run, "old media", args.target_free_gb)
    if not args.media_only and qb_dirs:
        qb_files = find_qb_temp_files(qb_dirs, args.qb_age)
        total_processed += process_files(qb_files, dry_run, "abandoned qBittorrent partials", args.target_free_gb)

    action = "selected (dry-run)" if dry_run else "deleted"
    logging.info(f"Done. Logical file size {action}: {human_size(total_processed)}; "
                 "this is not a measurement of reclaimed disk space")


if __name__ == "__main__":
    main()
