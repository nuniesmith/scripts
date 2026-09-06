#!/usr/bin/env python3
"""Bindery — organize a messy audiobook dump for Audiobookshelf.

Final layout (what Audiobookshelf likes):

    Author Name/
      Book Title (2021)/
        01.mp3
        02.mp3
        cover.jpg          (kept if present)
        desc.txt           (kept if present)

Archives (.zip / .rar / .7z / .tar / .tgz) are extracted first.
Junk (.nfo, samples, torrent files, OS metadata) is moved to a trash folder.
If you omit --dest, the source directory is reorganized in place.

Examples:
    python3 main.py "/path/to/dump" --dry-run
    python3 main.py "/path/to/dump" --dest "/path/to/Audiobooks"
    python3 main.py "/path/to/dump" --apply
    python3 main.py "D:\\inbox" --dest "D:\\Audiobooks" --keep-names

RAR files need one of: unrar, unar, 7z, or 7za on your PATH.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

AUDIO_EXT = {
    ".mp3",
    ".m4b",
    ".m4a",
    ".flac",
    ".ogg",
    ".opus",
    ".aac",
    ".wma",
    ".wav",
    ".mp4",
    ".m4v",
}
ARCHIVE_EXT = {".zip", ".rar", ".7z", ".tar", ".tgz", ".gz"}
COVER_STEMS = {"cover", "folder", "poster", "front", "albumart", "album"}
COVER_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
KEEP_TEXT = {"desc.txt", "reader.txt"}
TRASH_EXT = {
    ".nfo",
    ".sfv",
    ".md5",
    ".url",
    ".torrent",
    ".m3u",
    ".m3u8",
    ".pls",
    ".html",
    ".htm",
    ".log",
    ".cue",
    ".txt",
    ".ini",
    ".db",
    ".ds_store",
    ".part",
    ".crc",
    ".par2",
    ".exe",
    ".nzb",
}
JUNK_NAMES = {
    "thumbs.db",
    "desktop.ini",
    ".ds_store",
    "albumartsmall.jpg",
    "albumart_{small}.jpg",
}
SKIP_DIR_NAMES = {
    "trash",
    "_trash",
    ".trash",
    ".main-work",
    "__macosx",
    ".git",
    "@eadir",
    ".spotlight-v100",
    ".trashes",
}
DISC_RE = re.compile(
    r"^(?:cd|disc|disk|dvd|side)[\s._-]*([0-9]{1,3}|[a-d])$",
    re.I,
)
WRAPPER_NAMES = {
    "mp3",
    "m4b",
    "m4a",
    "flac",
    "audio",
    "audiobook",
    "audiobooks",
    "book",
    "files",
    "media",
    "tracks",
    "chapters",
}
STOP_AUTHOR = {
    "cd",
    "disc",
    "disk",
    "downloads",
    "download",
    "incoming",
    "inbox",
    "audiobooks",
    "audiobook",
    "books",
    "torrents",
    "completed",
    "complete",
    "dump",
    "new",
    "misc",
    "temp",
    "tmp",
    "unsorted",
    "import",
    "library",
    "media",
    "audio",
    "files",
}
QUALITY_RE = re.compile(
    r"""
    (?:
        \b(?:unabridged|abridged|audiobooks?|audio\s*book|retail|explicit|
            complete|drm|web-?rip|repack|remux|read\s+by)\b
        |
        \b\d{2,3}\s*kbps\b
        |
        \b(?:64|96|128|192|224|256|320)k\b
        |
        \b(?:mp3|m4b|m4a|flac|opus)\b
        |
        \[\s*(?:unabridged|abridged|audiobook|retail|explicit)\s*\]
    )
    """,
    re.I | re.X,
)
YEAR_RE = re.compile(r"\b((?:19|20)\d{2})\b")
NARRATOR_RE = re.compile(r"\{([^{}]+)\}")
ASIN_RE = re.compile(r"\[(B0[0-9A-Z]{8})\]", re.I)
BRACKET_RE = re.compile(r"[\[(][^\[\]()]{0,80}[\])]")
PERSON_PARTICLES = {"van", "von", "de", "da", "di", "del", "della", "la", "le", "st", "st."}
TITLE_STOP = {
    "part",
    "volume",
    "vol",
    "book",
    "chapter",
    "ch",
    "the",
    "a",
    "an",
    "of",
    "and",
    "series",
    "trilogy",
    "saga",
    "omnibus",
    "collection",
    "anthology",
    "unabridged",
    "abridged",
}
SAMPLE_RE = re.compile(r"(?:^|[\s._-])(?:sample|preview|excerpt)(?:[\s._-]|$)", re.I)
INVALID_FS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def natural_key(value: str) -> list[object]:
    return [int(p) if p.isdigit() else p.casefold() for p in re.split(r"(\d+)", value)]


def is_audio(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_EXT and path.is_file()


def is_archive_name(name: str) -> bool:
    lower = name.lower()
    if lower.endswith(".tar.gz") or lower.endswith(".tgz"):
        return True
    return Path(lower).suffix in {".zip", ".rar", ".7z", ".tar"}


def archive_kind(path: Path) -> str | None:
    name = path.name.lower()
    if name.endswith(".tar.gz") or name.endswith(".tgz"):
        return "tar"
    ext = path.suffix.lower()
    if ext in {".zip", ".rar", ".7z", ".tar"}:
        return ext[1:]
    return None


def is_disc_folder(name: str) -> bool:
    cleaned = name.strip().replace("  ", " ")
    return bool(DISC_RE.match(cleaned))


def disc_number(name: str) -> int:
    m = DISC_RE.match(name.strip())
    if not m:
        return 0
    token = m.group(1).lower()
    if token.isalpha():
        return ord(token) - 96
    return int(token)


def is_cover(path: Path) -> bool:
    if path.suffix.lower() not in COVER_EXT:
        return False
    stem = re.sub(r"[\s._-]+", "", path.stem.lower())
    return any(stem == c or stem.startswith(c) for c in COVER_STEMS)


def is_junk_file(path: Path) -> bool:
    name = path.name.lower()
    if name in JUNK_NAMES or name.startswith("._"):
        return True
    if name in KEEP_TEXT:
        return False
    if is_cover(path):
        return False
    if path.suffix.lower() in TRASH_EXT:
        return True
    if is_audio(path) and SAMPLE_RE.search(path.stem):
        return True
    return False


def humanize(name: str) -> str:
    stem = name
    stem = re.sub(r"\.part\d+$", "", stem, flags=re.I)
    if stem.count(".") >= 3 and " " not in stem:
        stem = stem.replace(".", " ")
    stem = stem.replace("_", " ")
    stem = re.sub(r"\s+", " ", stem).strip()
    return stem


def strip_quality(text: str) -> str:
    text = QUALITY_RE.sub(" ", text)
    text = ASIN_RE.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip(" -_|")
    return text


def extract_year(text: str) -> tuple[str | None, str]:
    found = None
    matches = list(YEAR_RE.finditer(text))
    if matches:
        found = matches[-1].group(1)

        def drop(m: re.Match[str]) -> str:
            return "" if m.group(1) == found else m.group(0)

        text = YEAR_RE.sub(drop, text, count=100)
        text = re.sub(r"\s+", " ", text).strip(" -_|")
    return found, text


def extract_narrator(text: str) -> tuple[str | None, str]:
    m = NARRATOR_RE.search(text)
    if not m:
        return None, text
    return m.group(1).strip(), (text[: m.start()] + text[m.end() :]).strip(" -_|")


def looks_like_person(text: str) -> bool:
    text = text.strip()
    if not text or YEAR_RE.search(text):
        return False
    if "," in text:
        parts = [p.strip() for p in text.split(",") if p.strip()]
        return 1 <= len(parts) <= 3 and all(looks_like_person(p) for p in parts)
    words = text.split()
    if not (1 <= len(words) <= 4):
        return False
    if words[0].casefold() in {"the", "a", "an"}:
        return False
    good = 0
    for w in words:
        wl = w.casefold().strip(".")
        if wl in PERSON_PARTICLES:
            good += 1
            continue
        if wl in TITLE_STOP:
            return False
        if not re.match(r"^[A-Z][A-Za-z.'\-]*$", w) and not re.match(r"^[A-Z]\.$", w):
            return False
        good += 1
    return good >= 1


def peel_trailing_author(title: str) -> tuple[str | None, str]:
    words = title.split()
    for n in (3, 2):
        if len(words) > n + 0 and len(words) - n >= 1:
            cand = " ".join(words[-n:])
            rest = " ".join(words[:-n])
            if looks_like_person(cand) and rest:
                return cand, rest
    return None, title


def split_author_title(name: str) -> tuple[str | None, str]:
    parts = re.split(r"\s+-\s+", name, maxsplit=1)
    if len(parts) != 2:
        author, title = peel_trailing_author(name)
        return author, title
    left, right = parts[0].strip(), parts[1].strip()
    if looks_like_person(left):
        return left, right
    if looks_like_person(right) and not looks_like_person(left):
        return right, left
    return left, right


def sanitize_component(name: str) -> str:
    name = INVALID_FS.sub(" ", name)
    name = name.replace("…", "...")
    name = re.sub(r"\s+", " ", name).strip(" .")
    name = name.rstrip(".")
    return name or "Unknown"


def unique_dir(path: Path) -> Path:
    if not path.exists():
        return path
    i = 2
    while True:
        candidate = path.parent / f"{path.name} ({i})"
        if not candidate.exists():
            return candidate
        i += 1


def pad_width(count: int) -> int:
    return max(2, len(str(max(count, 1))))


def which(names: list[str]) -> str | None:
    for n in names:
        found = shutil.which(n)
        if found:
            return found
    return None


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------


@dataclass
class Meta:
    author: str
    title: str
    year: str | None = None
    narrator: str | None = None


def parse_name(raw: str) -> Meta:
    original = raw
    suffix = Path(raw).suffix.lower()
    if suffix in AUDIO_EXT or suffix in ARCHIVE_EXT:
        original = Path(raw).stem
        lower = raw.lower()
        if lower.endswith(".tar.gz"):
            original = Path(raw).name[: -len(".tar.gz")]
    text = humanize(original)
    narrator, text = extract_narrator(text)

    author: str | None = None
    title = text
    year: str | None = None

    parts = [p.strip() for p in re.split(r"\s+-\s+", text) if p.strip()]
    if len(parts) >= 2:
        left, right = parts[0], " - ".join(parts[1:])
        left_year, left_rest = extract_year(left)
        right_year, right_rest = extract_year(right)
        year = right_year or left_year
        left_clean = strip_quality(BRACKET_RE.sub(" ", left_rest if left_year else left))
        right_clean = strip_quality(BRACKET_RE.sub(" ", right_rest if right_year else right))
        left_clean = re.sub(r"\s+", " ", left_clean).strip(" -_|")
        right_clean = re.sub(r"\s+", " ", right_clean).strip(" -_|")

        if left_year and not left_rest.strip():
            year = left_year
            if looks_like_person(right_clean):
                author, title = right_clean, left_year
            else:
                author, title = None, f"{left_year} - {right_clean}" if right_clean else left_year
        elif looks_like_person(left_clean):
            author, title = left_clean, right
        elif looks_like_person(right_clean) and not looks_like_person(left_clean):
            author, title = right_clean, left
        else:
            author, title = left_clean or None, right
    else:
        year, title = extract_year(text)
        title = strip_quality(title)
        title = BRACKET_RE.sub(" ", title)
        title = re.sub(r"\s+", " ", title).strip(" -_|")
        peeled, rest = peel_trailing_author(title)
        if peeled:
            author, title = peeled, rest

    if not year:
        y, rest = extract_year(title)
        year, title = y, rest or title
    else:
        y, rest = extract_year(title)
        if y == year:
            title = rest or title

    title = strip_quality(title)
    title = BRACKET_RE.sub(" ", title)
    title = re.sub(r"\s+", " ", title).strip(" -_|") or "Unknown Title"
    if author:
        author = strip_quality(author)
        author = BRACKET_RE.sub(" ", author)
        author = re.sub(r"\s+", " ", author).strip(" -_|") or None
    return Meta(author=author or "Unknown Author", title=title, year=year, narrator=narrator)


def meta_from_book_dir(book_dir: Path, source: Path) -> Meta:
    folder_meta = parse_name(book_dir.name)
    author = folder_meta.author
    title = folder_meta.title
    year = folder_meta.year
    narrator = folder_meta.narrator

    parent = book_dir.parent
    if parent != source and parent.name.casefold() not in STOP_AUTHOR:
        parent_clean = humanize(parent.name)
        if looks_like_person(parent_clean):
            author = parent_clean
            if folder_meta.author.casefold() == parent_clean.casefold():
                title = folder_meta.title
            else:
                raw = humanize(book_dir.name)
                narr, raw = extract_narrator(raw)
                narrator = narrator or narr
                y, raw = extract_year(raw)
                year = year or y
                raw = strip_quality(raw)
                raw = BRACKET_RE.sub(" ", raw)
                title = re.sub(r"\s+", " ", raw).strip(" -_|") or folder_meta.title

    if author == "Unknown Author":
        peeled, rest = peel_trailing_author(title)
        if peeled:
            author, title = peeled, rest

    title = re.sub(r"\s+", " ", title).strip(" -_|") or "Unknown Title"
    return Meta(author=author or "Unknown Author", title=title, year=year, narrator=narrator)


def book_folder_name(meta: Meta, fmt: str) -> str:
    title = sanitize_component(meta.title)
    year = meta.year
    if year and title == year:
        name = year
    elif fmt == "year-title" and year:
        name = f"{year} - {title}"
    elif fmt == "title":
        name = title
    else:
        name = f"{title} ({year})" if year else title
    return sanitize_component(name)


# ---------------------------------------------------------------------------
# Book grouping
# ---------------------------------------------------------------------------


def should_skip_dir(path: Path, source: Path, dest: Path, trash: Path) -> bool:
    try:
        if path == trash or trash in path.parents:
            return True
        if path == dest and dest != source:
            return True
        if dest != source and (dest in path.parents):
            return True
    except Exception:
        pass
    return path.name.casefold() in SKIP_DIR_NAMES or path.name.startswith(".")


def iter_files(root: Path, source: Path, dest: Path, trash: Path) -> list[Path]:
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        dirnames[:] = [
            d
            for d in dirnames
            if not should_skip_dir(current / d, source, dest, trash)
        ]
        for name in filenames:
            out.append(current / name)
    return out


def unwrap_book_dir(book_dir: Path, source: Path) -> Path:
    current = book_dir
    while current != source and current.name.casefold() in WRAPPER_NAMES:
        current = current.parent
    if is_disc_folder(current.name) and current.parent != current:
        current = current.parent
    while current != source and current.name.casefold() in WRAPPER_NAMES:
        current = current.parent
    return current


def book_root_for(audio: Path, source: Path) -> Path:
    parent = audio.parent
    if parent == source:
        return source
    if is_disc_folder(parent.name):
        parent = parent.parent
    return unwrap_book_dir(parent, source)


def album_group_key(filename: str) -> str:
    stem = Path(filename).stem
    stem = humanize(stem)
    stem = re.sub(
        r"(?:^|\s)(?:track|tr|ch|chapter|disc|cd|disk|pt|part)[\s._-]*\d+\s*",
        " ",
        stem,
        flags=re.I,
    )
    stem = re.sub(r"^[\s._-]*\d+[\s._-]*", "", stem)
    stem = re.sub(r"[\s._-]*\d+$", "", stem)
    stem = strip_quality(stem)
    year, stem = extract_year(stem)
    stem = re.sub(r"\s+", " ", stem).strip(" -_|")
    return stem.casefold() or Path(filename).stem.casefold()


def group_audio(audio_files: list[Path], source: Path) -> dict[Path, list[Path]]:
    groups: dict[Path, list[Path]] = defaultdict(list)
    loose: list[Path] = []
    for f in audio_files:
        root = book_root_for(f, source)
        if root == source:
            loose.append(f)
        else:
            groups[root].append(f)

    by_key: dict[str, list[Path]] = defaultdict(list)
    for f in loose:
        by_key[album_group_key(f.name)].append(f)
    for key, files in by_key.items():
        marker = source / f".loose.{key}"
        groups[marker].extend(files)
    return groups


def track_sort_key(path: Path, source: Path) -> tuple:
    disc = 0
    for parent in path.parents:
        if parent == source:
            break
        if is_disc_folder(parent.name):
            disc = disc_number(parent.name)
            break
    return (disc, natural_key(path.name), str(path).casefold())


def track_filename(index: int, src: Path, width: int, keep_names: bool) -> str:
    num = str(index).zfill(width)
    ext = src.suffix.lower() or ".mp3"
    if not keep_names:
        return f"{num}{ext}"
    original = humanize(src.stem)
    original = re.sub(r"^(?:track|tr|chapter|ch)[\s._-]*\d+[\s._-]*", "", original, flags=re.I)
    original = re.sub(r"^0*\d+[\s._-]*", "", original)
    original = original.strip(" -_|") or src.stem
    original = sanitize_component(original)
    return f"{num} - {original}{ext}"


# ---------------------------------------------------------------------------
# Archives
# ---------------------------------------------------------------------------


class UnsafeArchive(Exception):
    pass


def _safe_target(dest_dir: Path, member: str) -> Path:
    dest_dir = dest_dir.resolve()
    # zip/rar may use backslashes
    member = member.replace("\\", "/")
    if member.startswith("/") or re.match(r"^[a-zA-Z]:", member):
        raise UnsafeArchive(member)
    target = (dest_dir / member).resolve()
    if dest_dir != target and dest_dir not in target.parents:
        raise UnsafeArchive(member)
    return target


def extract_dir_for(archive: Path) -> Path:
    name = archive.name
    lower = name.lower()
    if lower.endswith(".tar.gz"):
        base = name[: -len(".tar.gz")]
    elif lower.endswith(".tgz"):
        base = name[: -len(".tgz")]
    else:
        base = archive.stem
    dest = archive.parent / base
    return unique_dir(dest) if dest.exists() else dest


def list_zip(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as zf:
        return [i.filename for i in zf.infolist() if not i.is_dir()]


def extract_zip(path: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            _safe_target(dest, info.filename)
        zf.extractall(dest)


def extract_tar(path: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path) as tf:
        for member in tf.getmembers():
            _safe_target(dest, member.name)
        tf.extractall(dest)


def run_cmd(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=False, capture_output=True, text=True)


def extract_rar(path: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    unrar = which(["unrar"])
    if unrar:
        r = run_cmd([unrar, "x", "-o+", "-y", str(path), str(dest) + os.sep])
        if r.returncode == 0:
            return
        raise RuntimeError(r.stderr or r.stdout or "unrar failed")
    unar = which(["unar"])
    if unar:
        r = run_cmd([unar, "-f", "-o", str(dest), str(path)])
        if r.returncode == 0:
            return
        raise RuntimeError(r.stderr or r.stdout or "unar failed")
    seven = which(["7z", "7za", "7zr"])
    if seven:
        r = run_cmd([seven, "x", f"-o{dest}", "-y", str(path)])
        if r.returncode == 0:
            return
        raise RuntimeError(r.stderr or r.stdout or "7z failed")
    raise RuntimeError(
        "No RAR extractor found. Install unrar, unar, or 7-Zip and keep it on PATH."
    )


def extract_7z(path: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    seven = which(["7z", "7za", "7zr"])
    if not seven:
        raise RuntimeError("No 7z binary found. Install 7-Zip and keep it on PATH.")
    r = run_cmd([seven, "x", f"-o{dest}", "-y", str(path)])
    if r.returncode != 0:
        raise RuntimeError(r.stderr or r.stdout or "7z failed")


def extract_archive(path: Path) -> Path:
    kind = archive_kind(path)
    dest = extract_dir_for(path)
    if kind == "zip":
        extract_zip(path, dest)
    elif kind == "tar":
        extract_tar(path, dest)
    elif kind == "rar":
        extract_rar(path, dest)
    elif kind == "7z":
        extract_7z(path, dest)
    else:
        raise RuntimeError(f"Unsupported archive: {path.name}")
    return dest


def find_archives(files: list[Path]) -> list[Path]:
    found = []
    for f in files:
        if f.is_file() and archive_kind(f):
            found.append(f)
    return found


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------


@dataclass
class FileOp:
    src: Path
    dest: Path
    kind: str  # track, cover, keep, trash, extract
    note: str = ""


@dataclass
class BookPlan:
    source_dir: Path
    meta: Meta
    dest_dir: Path
    tracks: list[FileOp] = field(default_factory=list)
    extras: list[FileOp] = field(default_factory=list)


@dataclass
class Plan:
    books: list[BookPlan] = field(default_factory=list)
    extracts: list[FileOp] = field(default_factory=list)
    trash: list[FileOp] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def pick_cover(files: list[Path]) -> Path | None:
    covers = [f for f in files if f.is_file() and is_cover(f)]
    if not covers:
        return None
    rank = {n: i for i, n in enumerate(["cover", "folder", "poster", "front", "album"])}

    def key(p: Path) -> tuple:
        stem = p.stem.lower()
        r = 50
        for name, i in rank.items():
            if stem.startswith(name):
                r = i
                break
        return (r, len(stem), p.name.lower())

    covers.sort(key=key)
    return covers[0]


def collect_sidecars(book_dir: Path, tracks: list[Path], source: Path) -> list[Path]:
    """Files sitting next to the book (including disc subfolders)."""
    if str(book_dir).startswith(str(source / ".loose.")):
        return []
    if not book_dir.exists():
        return []
    sidecars: list[Path] = []
    track_set = {t.resolve() for t in tracks if t.exists()}
    for dirpath, dirnames, filenames in os.walk(book_dir):
        current = Path(dirpath)
        dirnames[:] = [d for d in dirnames if d.casefold() not in SKIP_DIR_NAMES and not d.startswith(".")]
        for name in filenames:
            p = current / name
            try:
                if p.resolve() in track_set:
                    continue
            except OSError:
                continue
            sidecars.append(p)
    return sidecars


def build_plan(
    source: Path,
    dest: Path,
    trash: Path,
    folder_format: str,
    keep_names: bool,
    include_non_cover_images: bool,
) -> Plan:
    plan = Plan()
    files = [p for p in iter_files(source, source, dest, trash) if p.is_file()]
    archives = find_archives(files)
    for arc in archives:
        target = extract_dir_for(arc)
        plan.extracts.append(FileOp(arc, target, "extract", "archive"))

    audio = [
        p
        for p in files
        if p.suffix.lower() in AUDIO_EXT and not SAMPLE_RE.search(p.stem)
    ]
    sample_audio = [
        p for p in files if p.suffix.lower() in AUDIO_EXT and SAMPLE_RE.search(p.stem)
    ]
    for s in sample_audio:
        plan.trash.append(FileOp(s, trash / s.name, "trash", "sample"))

    groups = group_audio(audio, source)
    used_dest_dirs: dict[str, int] = {}

    for book_dir, tracks in sorted(groups.items(), key=lambda kv: str(kv[0]).casefold()):
        tracks = sorted(tracks, key=lambda p: track_sort_key(p, source))
        if not tracks:
            continue
        if str(book_dir).startswith(str(source / ".loose.")):
            meta = parse_name(tracks[0].name)
            if len(tracks) > 1:
                shared = album_group_key(tracks[0].name)
                # Rebuild a title-cased guess from the first file, not the casefolded key
                guess = parse_name(tracks[0].name)
                if shared:
                    meta = guess
        else:
            meta = meta_from_book_dir(book_dir, source)

        author_dir = dest / sanitize_component(meta.author)
        folder = book_folder_name(meta, folder_format)
        dest_dir = author_dir / folder
        key = str(dest_dir).casefold()
        if key in used_dest_dirs:
            used_dest_dirs[key] += 1
            dest_dir = author_dir / f"{folder} ({used_dest_dirs[key]})"
        else:
            used_dest_dirs[key] = 1

        width = pad_width(len(tracks))
        bp = BookPlan(source_dir=book_dir, meta=meta, dest_dir=dest_dir)
        for i, track in enumerate(tracks, start=1):
            dest_name = track_filename(i, track, width, keep_names)
            bp.tracks.append(FileOp(track, dest_dir / dest_name, "track"))
        sidecars = collect_sidecars(book_dir, tracks, source)
        cover = pick_cover(sidecars)
        kept_cover = False
        for sc in sidecars:
            if cover is not None and sc == cover:
                ext = sc.suffix.lower()
                if ext == ".jpeg":
                    ext = ".jpg"
                bp.extras.append(FileOp(sc, dest_dir / f"cover{ext}", "cover", "cover"))
                kept_cover = True
                continue
            if sc.name.lower() in KEEP_TEXT:
                bp.extras.append(FileOp(sc, dest_dir / sc.name.lower(), "keep", "sidecar"))
                continue
            if include_non_cover_images and sc.suffix.lower() in COVER_EXT:
                bp.extras.append(
                    FileOp(sc, dest_dir / sanitize_component(sc.name), "keep", "image")
                )
                continue
            if is_junk_file(sc) or sc.suffix.lower() in COVER_EXT or not is_audio(sc):
                rel = sc.name
                bp.extras.append(FileOp(sc, trash / rel, "trash", "junk"))
        if not kept_cover:
            pass
        plan.books.append(bp)

    claimed: set[Path] = set()
    for op in plan.extracts:
        claimed.add(op.src)
    for book in plan.books:
        for op in book.tracks + book.extras:
            claimed.add(op.src)
    for op in plan.trash:
        claimed.add(op.src)

    for f in files:
        if f in claimed:
            continue
        if archive_kind(f):
            continue
        if is_junk_file(f) or f.suffix.lower() in COVER_EXT or f.suffix.lower() in TRASH_EXT:
            plan.trash.append(FileOp(f, trash / f.name, "trash", "unassigned junk"))
        elif f.suffix.lower() in AUDIO_EXT:
            plan.warnings.append(f"Unassigned audio (skipped): {f}")
        else:
            plan.trash.append(FileOp(f, trash / f.name, "trash", "unassigned"))

    return plan


# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def unique_file(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    n = 2
    while True:
        candidate = path.parent / f"{stem} ({n}){suffix}"
        if not candidate.exists():
            return candidate
        n += 1


def move_file(src: Path, dest: Path) -> None:
    if not src.exists():
        return
    dest = Path(dest)
    if src.resolve() == dest.resolve():
        return
    ensure_parent(dest)
    dest = unique_file(dest)
    shutil.move(str(src), str(dest))


def copy_file(src: Path, dest: Path) -> None:
    if not src.exists():
        return
    ensure_parent(dest)
    dest = unique_file(dest)
    shutil.copy2(str(src), str(dest))


def remove_empty_dirs(root: Path, keep: set[Path]) -> None:
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        current = Path(dirpath)
        if current in keep:
            continue
        if current.name.casefold() in SKIP_DIR_NAMES:
            continue
        try:
            if not any(current.iterdir()):
                current.rmdir()
        except OSError:
            pass


def apply_extracts(plan: Plan, trash: Path, dry_run: bool) -> list[str]:
    errors: list[str] = []
    for op in plan.extracts:
        if dry_run:
            continue
        try:
            extracted = extract_archive(op.src)
            print(f"  extracted {op.src.name} -> {extracted.name}/")
            if op.src.exists():
                move_file(op.src, unique_trash_path(trash, op.src.name))
        except Exception as exc:
            errors.append(f"{op.src.name}: {exc}")
    return errors


def apply_plan(plan: Plan, trash: Path, dry_run: bool, copy: bool) -> None:
    transfer = copy_file if copy else move_file
    if not dry_run:
        trash.mkdir(parents=True, exist_ok=True)
    for book in plan.books:
        for op in book.tracks + book.extras:
            if op.kind == "trash":
                dest = unique_trash_path(trash, op.src.name)
                if dry_run:
                    continue
                transfer(op.src, dest)
            else:
                if dry_run:
                    continue
                transfer(op.src, op.dest)
    for op in plan.trash:
        if dry_run:
            continue
        dest = unique_trash_path(trash, op.src.name)
        transfer(op.src, dest)

    if not dry_run and not copy:
        for op in plan.extracts:
            if op.src.exists():
                move_file(op.src, unique_trash_path(trash, op.src.name))


def unique_trash_path(trash: Path, name: str) -> Path:
    dest = trash / name
    if not dest.exists():
        return dest
    stem, suffix = Path(name).stem, Path(name).suffix
    n = 2
    while True:
        candidate = trash / f"{stem} ({n}){suffix}"
        if not candidate.exists():
            return candidate
        n += 1


def rel(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def print_plan(plan: Plan, source: Path, dest: Path) -> None:
    print()
    print(f"Source      {source}")
    print(f"Destination {dest}")
    print(f"Books       {len(plan.books)}")
    tracks = sum(len(b.tracks) for b in plan.books)
    print(f"Tracks      {tracks}")
    print(f"Archives    {len(plan.extracts)}")
    trash_n = len(plan.trash) + sum(1 for b in plan.books for e in b.extras if e.kind == "trash")
    print(f"Trash       {trash_n}")
    print()

    if plan.extracts:
        print("Extract")
        for op in plan.extracts:
            print(f"  {op.src.name}  ->  {op.dest.name}/")
        print()

    print("Books")
    for book in plan.books:
        year = f" ({book.meta.year})" if book.meta.year else ""
        print(f"  {book.meta.author} / {book.meta.title}{year}")
        print(f"    -> {rel(book.dest_dir, dest)}")
        for op in book.tracks:
            print(f"       {op.src.name}  =>  {op.dest.name}")
        for op in book.extras:
            if op.kind == "trash":
                continue
            print(f"       {op.src.name}  =>  {op.dest.name} ({op.kind})")
        print()

    if plan.warnings:
        print("Warnings")
        for w in plan.warnings:
            print(f"  {w}")
        print()


def confirm(prompt: str) -> bool:
    if not sys.stdin.isatty():
        return False
    try:
        answer = input(prompt).strip().casefold()
    except EOFError:
        return False
    return answer in {"y", "yes"}


# ---------------------------------------------------------------------------
# Two-phase apply: extract then replan
# ---------------------------------------------------------------------------


def run(args: argparse.Namespace) -> int:
    source = Path(args.source).expanduser().resolve()
    if not source.is_dir():
        eprint(f"Source is not a directory: {source}")
        return 2

    dest = Path(args.dest).expanduser().resolve() if args.dest else source
    trash = Path(args.trash).expanduser().resolve() if args.trash else source / args.trash_name

    if dest != source:
        try:
            dest.relative_to(source)
            # dest inside source: skip it while walking — OK if named distinctly
        except ValueError:
            pass

    dry_run = not args.apply
    if args.dry_run:
        dry_run = True

    print("Scanning…")
    plan = build_plan(
        source=source,
        dest=dest,
        trash=trash,
        folder_format=args.format,
        keep_names=args.keep_names,
        include_non_cover_images=args.keep_images,
    )
    print_plan(plan, source, dest)

    if not plan.books and not plan.extracts:
        print("Nothing to do.")
        return 0

    if dry_run and plan.extracts:
        print(
            "Dry run does not extract archives. Re-run with --apply so zip/rar "
            "contents can be grouped into books."
        )
        print()

    if dry_run:
        print("Dry run. No files were changed. Pass --apply to make it real.")
        return 0

    if not args.yes and sys.stdin.isatty():
        if not confirm("Apply this plan? [y/N] "):
            print("Cancelled.")
            return 1

    # Phase 1: extract, then rebuild the plan against real files.
    if plan.extracts:
        print("Extracting archives…")
        errors = apply_extracts(plan, trash=trash, dry_run=False)
        for err in errors:
            eprint(f"  extract failed: {err}")
        for op in plan.extracts:
            if op.src.exists() and archive_kind(op.src):
                # leave failed archives in place; move successes to trash after replan
                pass
        print("Re-scanning after extract…")
        plan = build_plan(
            source=source,
            dest=dest,
            trash=trash,
            folder_format=args.format,
            keep_names=args.keep_names,
            include_non_cover_images=args.keep_images,
        )
        print_plan(plan, source, dest)

    print("Moving files…")
    apply_plan(plan, trash=trash, dry_run=False, copy=args.copy)

    keep = {source, dest, trash}
    if dest != source:
        remove_empty_dirs(source, keep)
    else:
        remove_empty_dirs(source, keep)

    print()
    print(f"Done. {len(plan.books)} books on the shelf.")
    print(f"Junk is in {trash}")
    if dest == source:
        print("Remove the trash folder before pointing Audiobookshelf at this directory.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="main",
        description="Organize messy audiobook folders into Author / Title (Year) / 01.ext for Audiobookshelf.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("source", help="Folder of messy audiobooks (the dump).")
    p.add_argument(
        "--dest",
        help="Clean library folder. Omit to reorganize the source folder in place.",
    )
    p.add_argument(
        "--apply",
        action="store_true",
        help="Actually move files. Without this flag, Bindery only prints a plan.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Force a plan-only run (default unless --apply is set).",
    )
    p.add_argument("--yes", "-y", action="store_true", help="Do not ask for confirmation.")
    p.add_argument(
        "--copy",
        action="store_true",
        help="Copy files to --dest instead of moving them. Source dump is left alone (archives still extract in source).",
    )
    p.add_argument(
        "--keep-names",
        action="store_true",
        help='Name tracks "01 - Chapter title.mp3" instead of "01.mp3".',
    )
    p.add_argument(
        "--keep-images",
        action="store_true",
        help="Keep every image in the book folder, not just cover art.",
    )
    p.add_argument(
        "--format",
        choices=("title-year", "year-title", "title"),
        default="title-year",
        help='Book folder pattern. title-year → "Dune (1965)"; year-title → "1965 - Dune".',
    )
    p.add_argument(
        "--trash-name",
        default="trash",
        help='Trash folder name inside the source (default: "trash").',
    )
    p.add_argument("--trash", help="Full path for junk. Defaults to <source>/<trash-name>.")
    return p


# ---------------------------------------------------------------------------
# Self-test (used in this workspace; also runnable as: python main.py --self-test)
# ---------------------------------------------------------------------------


def _touch(path: Path, text: str = "x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.encode() if isinstance(text, str) else text)


def self_test() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="main-test-"))
    dump = tmp / "dump"
    dest = tmp / "library"
    dump.mkdir()
    dest.mkdir()

    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "CD1" / "Track 01.mp3")
    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "CD1" / "Track 02.mp3")
    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "CD2" / "Track 01.mp3")
    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "cover.jpg")
    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "book.nfo")
    _touch(dump / "Brandon Sanderson - The Way of Kings (2010) [Unabridged]" / "sample.mp3")

    _touch(dump / "Andy Weir" / "The Martian (2014)" / "The Martian.m4b")
    _touch(dump / "Andy Weir" / "The Martian (2014)" / "desc.txt", "A book.")

    _touch(dump / "1984 - George Orwell.m4b")

    _touch(dump / "Dune.Part.1.2021.Frank.Herbert.64kbps" / "01_chapter_one.mp3")
    _touch(dump / "Dune.Part.1.2021.Frank.Herbert.64kbps" / "02_chapter_two.mp3")
    _touch(dump / "Dune.Part.1.2021.Frank.Herbert.64kbps" / "Thumbs.db")

    hobbit_dir = dump / "zip-src" / "JRR Tolkien" / "The Hobbit (1937)"
    _touch(hobbit_dir / "The Hobbit.m4b")
    zip_path = dump / "the-hobbit.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        rel = hobbit_dir / "The Hobbit.m4b"
        zf.write(rel, arcname="JRR Tolkien/The Hobbit (1937)/The Hobbit.m4b")
    shutil.rmtree(dump / "zip-src")

    # extract then plan
    extract_archive(zip_path)
    zip_path.unlink()

    plan = build_plan(
        source=dump,
        dest=dest,
        trash=dump / "trash",
        folder_format="title-year",
        keep_names=False,
        include_non_cover_images=False,
    )

    authors = sorted({b.meta.author for b in plan.books})
    titles = sorted({b.meta.title for b in plan.books})
    print("authors:", authors)
    print("titles:", titles)
    for b in plan.books:
        print(
            f"- {b.meta.author} | {b.meta.title} | {b.meta.year} | tracks={len(b.tracks)} | {b.dest_dir.name}"
        )
        for t in b.tracks:
            print(f"    {t.src.name} -> {t.dest.name}")

    way = next(b for b in plan.books if "Way of Kings" in b.meta.title)
    assert way.meta.author == "Brandon Sanderson", way.meta
    assert way.meta.year == "2010", way.meta
    assert len(way.tracks) == 3, way.tracks
    assert way.tracks[0].dest.name == "01.mp3"
    assert way.tracks[2].dest.name == "03.mp3"
    assert any(e.kind == "cover" for e in way.extras)
    assert any(e.kind == "trash" and e.src.name.endswith(".nfo") for e in way.extras)

    martian = next(b for b in plan.books if "Martian" in b.meta.title)
    assert martian.meta.author == "Andy Weir"
    assert martian.meta.year == "2014"
    assert martian.tracks[0].dest.name == "01.m4b"

    orwell = next(b for b in plan.books if "1984" in b.meta.title)
    assert "Orwell" in orwell.meta.author or "Orwell" in orwell.meta.title

    dune = next(b for b in plan.books if "Dune" in b.meta.title)
    assert dune.meta.year == "2021"
    assert len(dune.tracks) == 2

    hobbit = next((b for b in plan.books if "Hobbit" in b.meta.title), None)
    assert hobbit is not None, "zip contents should be a book"
    assert "Tolkien" in hobbit.meta.author

    apply_plan(plan, trash=dump / "trash", dry_run=False, copy=False)
    assert (dest / "Brandon Sanderson" / "The Way of Kings (2010)" / "01.mp3").exists()
    assert (dest / "Brandon Sanderson" / "The Way of Kings (2010)" / "03.mp3").exists()
    assert (dest / "Andy Weir" / "The Martian (2014)" / "01.m4b").exists()
    assert (dest / "Andy Weir" / "The Martian (2014)" / "desc.txt").exists()
    assert (dump / "trash" / "book.nfo").exists() or any(
        (dump / "trash").glob("book.nfo*")
    )
    print("self-test OK", tmp)
    shutil.rmtree(tmp, ignore_errors=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv == ["--self-test"]:
        return self_test()
    parser = build_parser()
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        eprint("\nInterrupted.")
        raise SystemExit(130)
