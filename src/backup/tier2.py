#!/usr/bin/env python3
"""Tier-2 archival backup: chunked tar.zst with a searchable content index.

Tier 1 (backup-freddy-tier1.sh) protects the ~82MB of databases and config.
This is the other half: the 158GB of photos and files that has exactly one
copy, sized for cold storage like Glacier Deep Archive.

THE OBJECT-COUNT PROBLEM
------------------------
The naive approach -- sync 186,587 individual files to Glacier -- costs far
more than the storage does:

    186,587 objects            ~400 archives
    PUT        $11.20          $0.02
    metadata    7.1 GB/mo      ~0
    restore     $5.92          $0.80

Glacier bills 40KB of metadata per archived object (8KB at Standard rates,
32KB at Deep Archive rates). At 186k objects that is 7.1GB of permanent
overhead on 158GB of real data. So: archives, not files.

THE PROBLEM THAT CREATES
------------------------
Once data is in tarballs in cold storage, "which archive holds
IMG_4471.jpg?" becomes unanswerable without retrieving things -- and a Deep
Archive retrieval takes 12 hours. So every archive gets a MANIFEST, and every
manifest feeds a local SQLite index. The index is a few MB, lives outside
cold storage, and answers that question instantly.

The manifest is generated FROM the finished archive (`tar -t`), never from a
separate directory walk. A manifest built by listing the source can disagree
with what actually got archived; one built from the archive cannot.

USAGE
-----
    tier2.py plan    --source photos
    tier2.py archive --source photos [--dry-run]
    tier2.py find    IMG_4471
    tier2.py verify  photos-originals-2023-06
    tier2.py status
"""

from __future__ import annotations

import argparse
import fnmatch
import gzip
import hashlib
import os
import shlex
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

DEST = Path(os.environ.get("TIER2_DEST", str(Path.home() / "backups" / "tier2")))
HOST = os.environ.get("TIER2_HOST", "freddy-claude")

# A chunk over this size is split by descending one directory level. 4GiB keeps
# archives small enough to re-upload cheaply when one changes, while staying
# far above the size where per-object costs matter.
MAX_CHUNK_BYTES = 4 * 1024**3


@dataclass(frozen=True)
class Source:
    name: str
    volume: str
    root: str  # path inside the volume
    exclude: tuple[str, ...] = ()


SOURCES = {
    "photos": Source(
        name="photos",
        volume="freddy_photos_originals",
        root="originals",
        # `storage` beside it is PhotoPrism's cache and sidecars, which rebuild
        # from the originals. Only the originals are irreplaceable.
        exclude=(),
    ),
    "nextcloud": Source(
        name="nextcloud",
        volume="freddy_nextcloud_data",
        root=".",
        # appdata_* is previews and thumbnails -- 5.3GB that Nextcloud
        # regenerates on demand, and a large share of the total file count.
        # index.html and the logs are noise.
        # games/ is a 101.8GB Clone Hero library -- 43,655 community chart
        # files, 88% of Nextcloud's bytes and re-downloadable. Archiving it
        # would quadruple both the cost and the restore time to protect
        # something that is not lost when the disk dies.
        exclude=("appdata_*", "index.html", "nextcloud.log", "*.log", "games"),
    ),
}


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=False, **kw)


def remote(script: str, capture: bool = True) -> subprocess.CompletedProcess:
    return run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, script],
        capture_output=capture,
        text=capture,
    )


def in_volume(src: Source, shell: str) -> str:
    """Run a shell snippet inside a throwaway container with the volume mounted ro."""
    return (
        f"sudo docker run --rm -v {shlex.quote(src.volume)}:/s:ro alpine "
        f"sh -c {shlex.quote(shell)}"
    )


# --------------------------------------------------------------------------- db
def db() -> sqlite3.Connection:
    DEST.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DEST / "index.sqlite")
    c.executescript(
        """
        CREATE TABLE IF NOT EXISTS archives (
            name        TEXT PRIMARY KEY,
            source      TEXT NOT NULL,
            chunk_path  TEXT NOT NULL,
            fingerprint TEXT NOT NULL,   -- source state when archived
            sha256      TEXT NOT NULL,   -- of the archive itself
            bytes       INTEGER NOT NULL,
            file_count  INTEGER NOT NULL,
            created_utc TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            archive TEXT NOT NULL REFERENCES archives(name) ON DELETE CASCADE,
            path    TEXT NOT NULL,
            bytes   INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
        CREATE INDEX IF NOT EXISTS idx_files_archive ON files(archive);
        """
    )
    return c


# ------------------------------------------------------------------------ plan
def chunk_plan(src: Source) -> list[tuple[str, int]]:
    """(relative path, bytes) chunks, splitting anything over MAX_CHUNK_BYTES.

    Sizes come from one `du` pass on the remote rather than a walk per level:
    the whole tree is measured once and the splitting decided locally.
    """
    # Excludes are applied to du's OUTPUT below, not passed to du. They are
    # find predicates; busybox du accepts them as paths, matches nothing, and
    # prints nothing at all -- a silent empty plan rather than an error.
    # -d 4 reaches year/month (photos) and user/files/folder/sub (nextcloud).
    # A chunk with no children at this depth cannot be split further and is
    # emitted whole however large -- `plan` shows that so it is visible.
    shell = f"cd /s/{src.root} 2>/dev/null && du -b -d 4 . 2>/dev/null"
    r = remote(in_volume(src, shell))
    if r.returncode != 0:
        sys.exit(f"could not size {src.name}: {r.stderr.strip()[:200]}")

    sizes: dict[str, int] = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        n, p = parts
        p = p.removeprefix("./").strip()
        if p == ".":
            p = ""
        sizes[p] = int(n)

    def is_excluded(p: str) -> bool:
        return any(
            fnmatch.fnmatch(seg, pat) for pat in src.exclude for seg in p.split("/")
        )

    def depth(p: str) -> int:
        return 0 if p == "" else p.count("/") + 1

    def children(p: str) -> list[str]:
        d = depth(p) + 1
        pre = f"{p}/" if p else ""
        return sorted(k for k in sizes if depth(k) == d and k.startswith(pre))

    out: list[tuple[str, int]] = []

    def walk(p: str) -> None:
        if is_excluded(p):
            return
        size = sizes.get(p, 0)
        kids = children(p)
        # Small enough, or nothing left to split by: take it whole.
        if size <= MAX_CHUNK_BYTES or not kids:
            if size > 0:
                out.append((p, size))
            return
        # Too big: descend. Files sitting directly in this directory are not
        # covered by any child, so they need a chunk of their own or they
        # would be silently dropped.
        covered = sum(sizes.get(k, 0) for k in kids)
        if size - covered > 0:
            out.append((p + "/." if p else ".", size - covered))
        for k in kids:
            walk(k)

    for top in children(""):
        walk(top)
    # Loose files at the root, computed against EVERY top-level entry. Using
    # only the included ones would hand back the excluded bytes as a phantom
    # "root" chunk -- which is exactly what 5.3GB of Nextcloud appdata did.
    loose = sizes.get("", 0) - sum(sizes.get(k, 0) for k in children(""))
    if loose > 0:
        out.append((".", loose))
    return out


def fingerprint(src: Source, chunk: str) -> tuple[str, int]:
    """(hash of the chunk's file state, file count).

    Hashes path+size+mtime for every file so an unchanged chunk can be skipped
    without re-reading its contents. Sorted, because directory order is not
    stable across filesystems and an unstable order would make every chunk
    look changed on every run.
    """
    flat = chunk.rstrip("/.") or "."
    only_here = chunk.endswith("/.") or chunk == "."
    maxdepth = "-maxdepth 1" if only_here else ""
    shell = (
        f"cd /s/{src.root}/{flat} 2>/dev/null && "
        f"find . {maxdepth} -type f -exec stat -c '%n %s %Y' {{}} + 2>/dev/null | sort"
    )
    r = remote(in_volume(src, shell))
    data = r.stdout or ""
    n = sum(1 for line in data.splitlines() if line.strip())
    return hashlib.sha256(data.encode()).hexdigest(), n


# --------------------------------------------------------------------- archive
def archive_name(src: Source, chunk: str) -> str:
    flat = chunk.strip("/").replace("/", "-").replace(".", "root") or "root"
    return f"{src.name}-{flat}"


def archive_chunk(src: Source, chunk: str, size: int, dry: bool) -> str | None:
    name = archive_name(src, chunk)
    fp, n_files = fingerprint(src, chunk)

    # A chunk can measure non-zero and still hold no FILES: du counts each
    # directory's own inode (typically 4KB), so "loose files in this
    # directory" comes out positive for a directory that only has
    # subdirectories. tar then produces an empty archive and every downstream
    # step fails confusingly. The file count is the honest test.
    if n_files == 0:
        return None

    con = db()
    row = con.execute("SELECT fingerprint FROM archives WHERE name=?", (name,)).fetchone()
    if row and row[0] == fp:
        print(f"  = {name:44} unchanged ({n_files} files)")
        return None
    if dry:
        verb = "would update" if row else "would create"
        print(f"  + {name:44} {verb} ({n_files} files, {size/1024**3:.2f} GiB)")
        return None

    DEST.mkdir(parents=True, exist_ok=True)
    out = DEST / f"{name}.tar.zst"
    part = out.with_suffix(".part")

    flat = chunk.rstrip("/.") or "."
    only_here = chunk.endswith("/.") or chunk == "."
    # `--no-recursion` with an explicit file list is what makes a "loose files
    # in this directory" chunk possible without dragging in subdirectories
    # that have their own archives.
    if only_here:
        inner = (
            f"cd /s/{src.root}/{flat} && "
            f"find . -maxdepth 1 -type f > /tmp/l && tar -cf - -T /tmp/l"
        )
    else:
        inner = f"tar -cf - -C /s/{src.root}/{flat} ."

    # The remote emits an UNCOMPRESSED tar and zstd compresses once, locally.
    # Compressing twice (tar -czf into zstd) wastes a pass, compresses worse
    # -- zstd on raw bytes beats zstd on gzip output -- and leaves a gzip
    # stream inside the .zst that `tar -t` refuses on a pipe unless told it is
    # there ("Archive is compressed. Use -z option").
    print(f"  + {name:44} archiving {size/1024**3:.2f} GiB ...", flush=True)
    t0 = time.time()
    with open(part, "wb") as fh:
        p = subprocess.Popen(
            ["ssh", "-o", "BatchMode=yes", HOST, in_volume(src, inner)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        z = subprocess.Popen(["zstd", "-q", "-3", "-T0"], stdin=p.stdout, stdout=fh)
        p.stdout.close()
        z.communicate()
        err = p.stderr.read().decode(errors="replace")
        p.wait()

    # Check the PRODUCER's status, not the compressor's. `ssh ... | zstd`
    # reports zstd's exit code, and zstd happily succeeds on a truncated
    # stream -- which is exactly how a half-fetched archive gets kept.
    if p.returncode != 0 or z.returncode != 0:
        part.unlink(missing_ok=True)
        print(f"    FAILED (ssh={p.returncode} zstd={z.returncode}) {err.strip()[:200]}")
        return None

    h = hashlib.sha256()
    with open(part, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    sha = h.hexdigest()

    # Manifest FROM the archive, never from a separate walk of the source.
    listing = run(
        ["sh", "-c", f"zstd -dc {shlex.quote(str(part))} | tar -tvf -"],
        capture_output=True, text=True,
    )
    if listing.returncode != 0:
        part.unlink(missing_ok=True)
        print("    FAILED: archive is not readable back")
        return None

    entries: list[tuple[str, int]] = []
    man = DEST / f"{name}.manifest.tsv.gz"
    with gzip.open(man, "wt") as mf:
        mf.write("# size\tmtime\tpath\n")
        for line in listing.stdout.splitlines():
            f = line.split(None, 5)
            if len(f) < 6 or line.startswith("d"):
                continue
            try:
                nbytes = int(f[2])
            except ValueError:
                continue
            path = f[5]
            mf.write(f"{nbytes}\t{f[3]} {f[4]}\t{path}\n")
            entries.append((path, nbytes))

    part.rename(out)
    con.execute("DELETE FROM files WHERE archive=?", (name,))
    con.execute(
        "INSERT OR REPLACE INTO archives VALUES (?,?,?,?,?,?,?,?)",
        (name, src.name, chunk, fp, sha, out.stat().st_size, len(entries),
         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
    )
    con.executemany(
        "INSERT INTO files VALUES (?,?,?)", [(name, p, b) for p, b in entries]
    )
    con.commit()
    print(f"    {out.stat().st_size/1024**3:.2f} GiB, {len(entries)} files, "
          f"{time.time()-t0:.0f}s")
    return name


# ----------------------------------------------------------------------- verbs
def cmd_plan(a):
    src = SOURCES[a.source]
    plan = chunk_plan(src)
    total = sum(s for _, s in plan)
    print(f"{src.name}: {len(plan)} chunks, {total/1024**3:.1f} GiB total\n")
    for p, s in sorted(plan, key=lambda x: -x[1])[: a.limit]:
        print(f"  {s/1024**3:8.2f} GiB  {archive_name(src, p)}")
    if len(plan) > a.limit:
        print(f"  ... and {len(plan)-a.limit} more")


def cmd_archive(a):
    src = SOURCES[a.source]
    plan = chunk_plan(src)
    print(f"{src.name}: {len(plan)} chunks -> {DEST}\n")
    made = 0
    for p, s in plan:
        if archive_chunk(src, p, s, a.dry_run):
            made += 1
    print(f"\n{made} archive(s) written or updated")


def cmd_find(a):
    con = db()
    rows = con.execute(
        "SELECT f.path, f.bytes, f.archive FROM files f WHERE f.path LIKE ? "
        "ORDER BY f.path LIMIT ?",
        (f"%{a.pattern}%", a.limit),
    ).fetchall()
    if not rows:
        print("no match in the index")
        return
    print(f"{'archive':40} {'bytes':>12}  path")
    for path, b, arch in rows:
        print(f"{arch:40} {b:>12}  {path}")
    print(f"\n{len(rows)} match(es). Retrieve only the archive(s) named above.")


def cmd_verify(a):
    con = db()
    row = con.execute(
        "SELECT sha256, bytes, file_count FROM archives WHERE name=?", (a.name,)
    ).fetchone()
    if not row:
        sys.exit(f"{a.name} is not in the index")
    sha, nbytes, count = row
    f = DEST / f"{a.name}.tar.zst"
    if not f.exists():
        sys.exit(f"{f} is not here (in cold storage?)")

    h = hashlib.sha256()
    with open(f, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    ok_sha = h.hexdigest() == sha
    print(f"  sha256   {'OK' if ok_sha else 'MISMATCH'}")

    # Extracting and counting is the real test: a matching hash proves the
    # bytes are the bytes we wrote, not that they are a working archive.
    r = run(["sh", "-c", f"zstd -dc {shlex.quote(str(f))} | tar -tf - | grep -vc '/$'"],
            capture_output=True, text=True)
    got = int(r.stdout.strip() or 0)
    ok_n = got == count
    print(f"  files    {got} (index says {count}) {'OK' if ok_n else 'MISMATCH'}")
    if not (ok_sha and ok_n):
        sys.exit("VERIFY FAILED")
    print("  VERIFY PASSED")


def cmd_status(a):
    con = db()
    rows = con.execute(
        "SELECT source, count(*), sum(bytes), sum(file_count) FROM archives GROUP BY source"
    ).fetchall()
    if not rows:
        print("nothing archived yet")
        return
    print(f"{'source':14}{'archives':>10}{'size':>12}{'files':>12}")
    for s, n, b, fc in rows:
        print(f"{s:14}{n:>10}{b/1024**3:>10.2f}GiB{fc:>12,}")
    idx = (DEST / "index.sqlite").stat().st_size
    print(f"\nindex: {idx/1024**2:.1f} MiB -- keep this OUT of cold storage.")
    print("It is what turns a Glacier bucket into something you can search.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan", help="show the chunk plan without archiving")
    p.add_argument("--source", choices=sorted(SOURCES), required=True)
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("archive", help="create or update archives")
    p.add_argument("--source", choices=sorted(SOURCES), required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_archive)

    p = sub.add_parser("find", help="which archive holds a path")
    p.add_argument("pattern")
    p.add_argument("--limit", type=int, default=25)
    p.set_defaults(fn=cmd_find)

    p = sub.add_parser("verify", help="check an archive against the index")
    p.add_argument("name")
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("status", help="what is archived")
    p.set_defaults(fn=cmd_status)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
