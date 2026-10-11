#!/usr/bin/env python3
"""
Media Server Cleanup Script for Sullivan
- Finds old / untouched media files
- Cleans qBittorrent temporary & incomplete files
- Dry-run by default for safety
"""

import os
import sys
import time
import argparse
import logging
from pathlib import Path
from datetime import datetime, timedelta
from typing import List, Tuple

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

# qBittorrent incomplete / temp / leftover locations
QB_INCOMPLETE_DIRS = [
    "/media/qbittorrent/incomplete",          # active incomplete downloads (fast storage)
    "/mnt/media/qbittorrent/complete",         # completed downloads that *arr hasn't moved yet
    "/media/qbittorrent/shelfmark",            # shelfmark category (optional cleanup)
]

# File extensions considered "media"
MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".flv",
    ".webm", ".ts", ".m2ts", ".mpg", ".mpeg", ".vob",
    ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".wav",
    ".iso", ".img",                           # disc images
    ".m4b", ".epub", ".pdf",                  # audiobooks / ebooks
}

# How old before considering for deletion (days)
MEDIA_AGE_DAYS = 365          # media not touched in 1 year
QB_TEMP_AGE_DAYS = 7          # incomplete/temp files older than 7 days

# Minimum free space target (GB). Set to 0 to ignore.
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
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(num_bytes) < 1024.0:
            return f"{num_bytes:3.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} PB"

def get_file_age_days(path: Path, use_atime: bool = True) -> float:
    """Return age in days based on access time (preferred) or modification time."""
    try:
        stat = path.stat()
        if use_atime and hasattr(stat, "st_atime"):
            timestamp = stat.st_atime
        else:
            timestamp = stat.st_mtime
        age_seconds = time.time() - timestamp
        return age_seconds / 86400.0
    except (OSError, PermissionError):
        return 0.0

def is_media_file(path: Path) -> bool:
    return path.suffix.lower() in MEDIA_EXTENSIONS

def find_old_media(dirs: List[str], age_days: float, use_atime: bool) -> List[Tuple[Path, float, int]]:
    """Return list of (path, age_days, size) for old media files."""
    results = []
    cutoff = age_days

    for root in dirs:
        root_path = Path(root)
        if not root_path.exists():
            logging.warning(f"Media path does not exist: {root}")
            continue

        logging.info(f"Scanning media: {root}")
        for dirpath, dirnames, filenames in os.walk(root):
            # Skip common junk / system folders
            dirnames[:] = [d for d in dirnames if d not in {
                ".Trash", ".recycle", "@eaDir", ".AppleDouble",
                "lost+found", ".snapshots", "#recycle", ".recyclebin"
            }]

            for name in filenames:
                path = Path(dirpath) / name
                if not is_media_file(path):
                    continue
                try:
                    age = get_file_age_days(path, use_atime=use_atime)
                    if age >= cutoff:
                        size = path.stat().st_size
                        results.append((path, age, size))
                except (OSError, PermissionError) as e:
                    logging.debug(f"Skipping {path}: {e}")

    # Sort oldest first
    results.sort(key=lambda x: x[1], reverse=True)
    return results

def find_qb_temp_files(dirs: List[str], age_days: float) -> List[Tuple[Path, float, int]]:
    """Find old incomplete / temporary qBittorrent files."""
    results = []
    # Common incomplete / partial extensions used by qBittorrent
    patterns = ["*.!qB", "*.parts", "*.!ut", "*.tmp", "*.partial"]

    for root in dirs:
        root_path = Path(root)
        if not root_path.exists():
            logging.warning(f"qBittorrent path does not exist: {root}")
            continue

        logging.info(f"Scanning qBittorrent temp: {root}")
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]

            for name in filenames:
                path = Path(dirpath) / name
                is_temp = any(path.match(p) for p in patterns) or path.suffix.lower() in {".!qb", ".parts"}
                try:
                    # Prefer mtime for download temp files
                    age = get_file_age_days(path, use_atime=False)
                    if is_temp or age >= age_days:
                        if age >= age_days:
                            size = path.stat().st_size
                            results.append((path, age, size))
                except (OSError, PermissionError):
                    continue

    results.sort(key=lambda x: x[1], reverse=True)
    return results

def process_files(files: List[Tuple[Path, float, int]], dry_run: bool, label: str) -> int:
    """List or delete files. Returns total bytes that would be / were freed."""
    if not files:
        logging.info(f"No {label} files found matching criteria.")
        return 0

    total_size = sum(size for _, _, size in files)
    logging.info(f"Found {len(files)} {label} files totaling {human_size(total_size)}")

    freed = 0
    for path, age, size in files:
        age_str = f"{age:.0f} days"
        size_str = human_size(size)
        if dry_run:
            logging.info(f"[DRY-RUN] Would delete: {path}  ({size_str}, {age_str} old)")
        else:
            try:
                path.unlink()
                logging.info(f"Deleted: {path}  ({size_str}, {age_str} old)")
                freed += size
            except Exception as e:
                logging.error(f"Failed to delete {path}: {e}")

    if dry_run:
        logging.info(f"[DRY-RUN] Would free approximately {human_size(total_size)}")
    else:
        logging.info(f"Freed {human_size(freed)}")
    return freed if not dry_run else total_size

def main():
    parser = argparse.ArgumentParser(
        description="Scan and clean old media + qBittorrent temporary files on Sullivan"
    )
    parser.add_argument("--dry-run", action="store_true", default=True,
                        help="Only show what would be deleted (default: True)")
    parser.add_argument("--execute", action="store_true",
                        help="Actually delete files (overrides dry-run)")
    parser.add_argument("--media-age", type=int, default=MEDIA_AGE_DAYS,
                        help=f"Days since last access/modify for media (default: {MEDIA_AGE_DAYS})")
    parser.add_argument("--qb-age", type=int, default=QB_TEMP_AGE_DAYS,
                        help=f"Days for qBittorrent temp files (default: {QB_TEMP_AGE_DAYS})")
    parser.add_argument("--use-mtime", action="store_true",
                        help="Use modification time instead of access time for media")
    parser.add_argument("--media-only", action="store_true", help="Only process media files")
    parser.add_argument("--qb-only", action="store_true", help="Only process qBittorrent temp files")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    dry_run = not args.execute
    setup_logging(args.verbose)

    if dry_run:
        logging.info("=== DRY-RUN MODE (no files will be deleted) ===")
        logging.info("Run with --execute to actually delete")
    else:
        logging.warning("=== EXECUTE MODE - FILES WILL BE PERMANENTLY DELETED ===")
        time.sleep(3)  # small safety pause

    total_freed = 0

    # --- Media cleanup ---
    if not args.qb_only:
        media_files = find_old_media(MEDIA_DIRS, args.media_age, use_atime=not args.use_mtime)
        total_freed += process_files(media_files, dry_run, "old media")

    # --- qBittorrent temp cleanup ---
    if not args.media_only:
        qb_files = find_qb_temp_files(QB_INCOMPLETE_DIRS, args.qb_age)
        total_freed += process_files(qb_files, dry_run, "qBittorrent temp/incomplete")

    logging.info(f"Done. Potential space reclaimed: {human_size(total_freed)}")

if __name__ == "__main__":
    main()
