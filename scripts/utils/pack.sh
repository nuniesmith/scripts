#!/bin/bash
# pack.sh — Pack a codebase into a zip for AI review
#
# Usage: ./pack.sh <directory> [options]
#
# Options:
#   -o, --output <file>      Output zip path (default: ./<dirname>_ai_pack.zip)
#   -s, --max-size <KB>      Skip files larger than N KB (default: 200)
#   --repo-root              Whitelist mode: only grab compose, Dockerfiles,
#                            run.sh, todo.md, top-level .proto files.
#                            Also prunes docs/, scripts/, models/ entirely.
#   --include-locks          Include lock files (Cargo.lock, yarn.lock, etc.)
#   --include-env            Include .env files  ⚠ may contain secrets
#   --no-manifest            Skip the MANIFEST.md added to the zip root
#   -v, --verbose            Print each file as it is added
#   -h, --help               Show this help and exit
#
# Output zip contains:
#   MANIFEST.md              Directory tree + stats + skipped-file log
#   <original paths>         All filtered source/config/doc files

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
TARGET_DIR=""
OUTPUT_ZIP=""
MAX_FILE_KB=200
INCLUDE_LOCKS=false
INCLUDE_ENV=false
NO_MANIFEST=false
VERBOSE=false
REPO_ROOT_MODE=false          # NEW: whitelist mode for scanning repo roots

# ─── Colours (suppressed when not a tty) ─────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

die()  { echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYAN}»${RESET} $*"; }
ok()   { echo -e "${GREEN}✔${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }

usage() {
cat <<EOF
${BOLD}pack.sh${RESET} — Pack a codebase into a zip for AI review

${BOLD}Usage:${RESET}
  ./pack.sh <directory> [options]

${BOLD}Options:${RESET}
  -o, --output <file>    Output zip path  (default: ./<dirname>_ai_pack.zip)
  -s, --max-size <KB>    Skip files larger than N KB  (default: 200)
  --repo-root            Whitelist mode for repo roots — only grabs:
                           • docker-compose*.yml/yaml, compose*.yml/yaml
                           • Dockerfile, Dockerfile.*
                           • run.sh
                           • todo.md / TODO.md (case-insensitive)
                           • *.proto files within 2 levels of root
                         Also prunes: docs/, scripts/, models/
  --include-locks        Include lock files (Cargo.lock, yarn.lock, etc.)
  --include-env          Include .env files  ⚠ may contain secrets
  --no-manifest          Skip MANIFEST.md in the zip
  -v, --verbose          Print each file as it is added
  -h, --help             Show this help and exit
EOF
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { usage; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          usage; exit 0 ;;
        -v|--verbose)       VERBOSE=true; shift ;;
        --include-locks)    INCLUDE_LOCKS=true; shift ;;
        --include-env)      INCLUDE_ENV=true; shift ;;
        --no-manifest)      NO_MANIFEST=true; shift ;;
        --repo-root)        REPO_ROOT_MODE=true; shift ;;   # NEW
        -o|--output)
            [[ -z "${2-}" ]] && die "--output requires a value"
            OUTPUT_ZIP="$2"; shift 2 ;;
        -s|--max-size)
            [[ -z "${2-}" ]] && die "--max-size requires a value"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--max-size must be a positive integer"
            MAX_FILE_KB="$2"; shift 2 ;;
        -*)
            die "Unknown option: $1" ;;
        *)
            [[ -n "$TARGET_DIR" ]] && die "Only one directory argument is supported."
            [[ -d "$1" ]] || die "'$1' is not a valid directory."
            TARGET_DIR="$1"; shift ;;
    esac
done

[[ -z "$TARGET_DIR" ]] && { usage; exit 1; }

TARGET_DIR="$(realpath "$TARGET_DIR")"
DIRNAME="$(basename "$TARGET_DIR")"
[[ -z "$OUTPUT_ZIP" ]] && OUTPUT_ZIP="$(pwd)/${DIRNAME}_ai_pack.zip"

# Ensure output dir exists
OUTPUT_DIR="$(dirname "$OUTPUT_ZIP")"
mkdir -p "$OUTPUT_DIR"

# ─── Dependency check ─────────────────────────────────────────────────────────
for cmd in zip find wc du awk sed grep; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ─── Directories to prune entirely ────────────────────────────────────────────
PRUNE_DIRS=(
    # VCS / IDE
    ".git" ".svn" ".hg"
    ".idea" ".vscode" ".vs"
    # Rust
    "target"
    # Node / JS
    "node_modules" "dist" ".npm" ".yarn" ".pnp"
    # Python
    "__pycache__" ".mypy_cache" ".pytest_cache" ".ruff_cache"
    "venv" ".venv" "env" ".env_dir" ".tox" "htmlcov" ".hypothesis"
    # Java / Kotlin / Android
    "build" ".gradle" ".kotlin" "kotlin-js-store" ".cxx"
    # Misc generated
    "coverage" ".next" ".nuxt" ".svelte-kit" ".turbo"
    "out" "generated" ".cache" "tmp" ".tmp"
)

# NEW: extra dirs pruned only in --repo-root mode
REPO_ROOT_PRUNE_DIRS=(
    "docs"
    "scripts"
    "models"
)

# Merge in the extra prune dirs when --repo-root is active
if [[ "$REPO_ROOT_MODE" == true ]]; then
    PRUNE_DIRS+=("${REPO_ROOT_PRUNE_DIRS[@]}")
fi

# ─── File extensions that are always binary / generated ───────────────────────
BINARY_EXTS=(
    # Compiled / linked
    o so a dylib dll exe wasm class jar war ear
    # Images
    png jpg jpeg gif ico bmp tiff webp svg_bin avif
    # Archives
    zip tar gz bz2 xz zst 7z rar
    # Documents / media
    pdf docx xlsx pptx odt mp3 mp4 mov avi mkv wav flac
    # Fonts
    ttf otf woff woff2 eot
    # Misc
    pyc pyo rlib rmeta pdb dSYM
)

# ─── Lock files (skipped unless --include-locks) ──────────────────────────────
LOCK_FILES=(
    "Cargo.lock"
    "package-lock.json"
    "yarn.lock"
    "pnpm-lock.yaml"
    "poetry.lock"
    "Pipfile.lock"
    "Gemfile.lock"
    "composer.lock"
    "go.sum"
    "bun.lockb"
    "flake.lock"
)

# ─── Build prune args for find ────────────────────────────────────────────────
PRUNE_ARGS=()
for i in "${!PRUNE_DIRS[@]}"; do
    [[ $i -gt 0 ]] && PRUNE_ARGS+=("-o")
    PRUNE_ARGS+=("-name" "${PRUNE_DIRS[$i]}")
done

pruned_find() {
    find "$TARGET_DIR" -type d \( "${PRUNE_ARGS[@]}" \) -prune -o "$@"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
is_binary_ext() {
    local ext="${1,,}"
    for b in "${BINARY_EXTS[@]}"; do
        [[ "$ext" == "$b" ]] && return 0
    done
    return 1
}

is_lock_file() {
    local base
    base="$(basename "$1")"
    for l in "${LOCK_FILES[@]}"; do
        [[ "$base" == "$l" ]] && return 0
    done
    return 1
}

is_env_file() {
    local base
    base="$(basename "$1")"
    [[ "$base" == ".env" ]] && return 0
    [[ "$base" =~ ^\.env\.(local|prod|production|staging|development|test)$ ]] && return 0
    return 1
}

file_size_kb() {
    du -k "$1" 2>/dev/null | awk '{print $1}'
}

# NEW ── Whitelist check for --repo-root mode ──────────────────────────────────
# Returns 0 (match) if the file should be included in repo-root mode.
# We match on basename patterns; proto files are additionally depth-limited
# to within 2 levels of the target dir (i.e. root or one sub-directory).
is_whitelisted() {
    local file="$1"
    local base
    base="$(basename "$file")"
    local lower_base="${base,,}"   # lowercase for case-insensitive checks

    # ── Docker Compose ────────────────────────────────────────────────────────
    [[ "$base" == docker-compose*.yml  ]] && return 0
    [[ "$base" == docker-compose*.yaml ]] && return 0
    [[ "$base" == compose*.yml         ]] && return 0
    [[ "$base" == compose*.yaml        ]] && return 0

    # ── Dockerfiles ───────────────────────────────────────────────────────────
    # Matches: Dockerfile, Dockerfile.prod, Dockerfile.dev, etc.
    [[ "$base" == "Dockerfile"         ]] && return 0
    [[ "$base" == Dockerfile.*         ]] && return 0

    # ── run.sh ────────────────────────────────────────────────────────────────
    [[ "$base" == "run.sh"             ]] && return 0

    # ── Todo (case-insensitive) ───────────────────────────────────────────────
    [[ "$lower_base" == "todo.md"      ]] && return 0

    # ── Proto files — depth-limited to root or one sub-directory ─────────────
    # e.g. foo.proto or proto/foo.proto → yes
    #      src/api/v1/foo.proto         → no (depth 3)
    if [[ "$base" == *.proto ]]; then
        local rel="${file#"$TARGET_DIR"/}"
        # Count directory separators to determine depth
        local slashes="${rel//[^\/]/}"
        [[ ${#slashes} -le 1 ]] && return 0
    fi

    # ── src/ — all files under the top-level src/ directory ──────────────────
    # Binary/size/lock/env filters still apply after this gate.
    local rel="${file#"$TARGET_DIR"/}"
    [[ "$rel" == src/* ]] && return 0

    return 1   # not on the whitelist
}

# ─── Temp working dir ─────────────────────────────────────────────────────────
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

PACK_ROOT="$TMPDIR_WORK/pack"
mkdir -p "$PACK_ROOT"

# ─── Collect files ────────────────────────────────────────────────────────────
if [[ "$REPO_ROOT_MODE" == true ]]; then
    info "Scanning ${BOLD}$TARGET_DIR${RESET} ${YELLOW}[repo-root whitelist mode]${RESET} ..."
else
    info "Scanning ${BOLD}$TARGET_DIR${RESET} ..."
fi

INCLUDED=()
SKIPPED_BINARY=()
SKIPPED_SIZE=()
SKIPPED_LOCK=()
SKIPPED_ENV=()
SKIPPED_NOTEXT=()
SKIPPED_WHITELIST=()   # NEW: files not on the whitelist in repo-root mode

while IFS= read -r -d '' file; do
    rel="${file#"$TARGET_DIR"/}"
    ext="${file##*.}"
    base="$(basename "$file")"

    # NEW ── repo-root whitelist gate (checked first, before other filters) ───
    if [[ "$REPO_ROOT_MODE" == true ]]; then
        if ! is_whitelisted "$file"; then
            SKIPPED_WHITELIST+=("$rel")
            continue
        fi
    fi

    # --- env files ---
    if is_env_file "$file"; then
        if [[ "$INCLUDE_ENV" == false ]]; then
            SKIPPED_ENV+=("$rel")
            continue
        fi
    fi

    # --- lock files ---
    if is_lock_file "$file"; then
        if [[ "$INCLUDE_LOCKS" == false ]]; then
            SKIPPED_LOCK+=("$rel")
            continue
        fi
    fi

    # --- binary by extension ---
    if [[ "$file" == *.* ]]; then
        if is_binary_ext "$ext"; then
            SKIPPED_BINARY+=("$rel")
            continue
        fi
    fi

    # --- size check ---
    kb=$(file_size_kb "$file")
    if [[ "$kb" -gt "$MAX_FILE_KB" ]]; then
        SKIPPED_SIZE+=("${kb}K  $rel")
        continue
    fi

    # --- binary content check ---
    if ! grep -Iq . "$file" 2>/dev/null; then
        SKIPPED_NOTEXT+=("$rel")
        continue
    fi

    # --- include ---
    INCLUDED+=("$rel")
    dest="$PACK_ROOT/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"
    [[ "$VERBOSE" == true ]] && echo "  + $rel"

done < <(pruned_find -type f -print0)

# ─── Generate MANIFEST.md ─────────────────────────────────────────────────────
if [[ "$NO_MANIFEST" == false ]]; then
    MANIFEST="$PACK_ROOT/MANIFEST.md"

    {
        echo "# AI Pack Manifest"
        echo ""
        echo "**Source:** \`$TARGET_DIR\`"
        echo "**Packed:**  $(date)"
        echo "**Max file size:** ${MAX_FILE_KB} KB"
        echo "**Mode:** $([ "$REPO_ROOT_MODE" == true ] && echo "repo-root whitelist" || echo "full scan")"   # NEW
        echo "**Lock files included:** $INCLUDE_LOCKS"
        echo "**Env files included:** $INCLUDE_ENV"
        echo ""

        # ── Stats ──
        echo "## Statistics"
        echo ""
        echo "| | Count |"
        echo "|---|---|"
        echo "| Files included | ${#INCLUDED[@]} |"
        echo "| Skipped — binary ext | ${#SKIPPED_BINARY[@]} |"
        echo "| Skipped — too large | ${#SKIPPED_SIZE[@]} |"
        echo "| Skipped — lock files | ${#SKIPPED_LOCK[@]} |"
        echo "| Skipped — env files | ${#SKIPPED_ENV[@]} |"
        echo "| Skipped — binary content | ${#SKIPPED_NOTEXT[@]} |"
        # NEW: only show whitelist row when relevant
        [[ "$REPO_ROOT_MODE" == true ]] && \
        echo "| Skipped — not whitelisted | ${#SKIPPED_WHITELIST[@]} |"
        echo ""

        # ── Lines of code by extension ──
        echo "## Lines by Extension"
        echo ""
        echo "| Extension | Lines |"
        echo "|---|---|"
        for f in "${INCLUDED[@]}"; do
            ext="${f##*.}"
            lines=$(wc -l < "$PACK_ROOT/$f" 2>/dev/null || echo 0)
            echo "$ext $lines"
        done \
            | awk '{a[$1]+=$2} END {for(k in a) print a[k], k}' \
            | sort -rn \
            | head -20 \
            | while read -r lines ext; do
                printf "| .%-10s | %6d |\n" "$ext" "$lines"
            done
        echo ""

        # ── Directory tree ──
        echo "## Directory Tree"
        echo ""
        echo '```'
        if command -v tree &>/dev/null; then
            TREE_EXCLUDE=$(IFS="|"; echo "${PRUNE_DIRS[*]}")
            tree "$TARGET_DIR" -I "$TREE_EXCLUDE" --dirsfirst 2>/dev/null || \
                find "$TARGET_DIR" -maxdepth 4 | sed "s|$TARGET_DIR/||" | sort
        else
            find "$TARGET_DIR" -maxdepth 4 | sed "s|$TARGET_DIR/||" | sort
        fi
        echo '```'
        echo ""

        # ── Included file list ──
        echo "## Included Files (${#INCLUDED[@]})"
        echo ""
        echo '```'
        printf '%s\n' "${INCLUDED[@]}" | sort
        echo '```'
        echo ""

        # NEW ── Whitelist section ─────────────────────────────────────────────
        # Only shown in repo-root mode; kept brief since the list can be huge
        if [[ "$REPO_ROOT_MODE" == true ]]; then
            echo "## Repo-Root Whitelist"
            echo ""
            echo "Only the following patterns were eligible for inclusion:"
            echo ""
            echo "- \`docker-compose*.yml/yaml\`, \`compose*.yml/yaml\`"
            echo "- \`Dockerfile\`, \`Dockerfile.*\`"
            echo "- \`run.sh\`"
            echo "- \`todo.md\` / \`TODO.md\` (case-insensitive)"
            echo "- \`*.proto\` within 2 directory levels of root"
            echo "- All files under \`src/\`"
            echo ""
            echo "Pruned directories (in addition to standard list): \`${REPO_ROOT_PRUNE_DIRS[*]}\`"
            echo ""
            echo "${#SKIPPED_WHITELIST[@]} files were skipped as not whitelisted."
            echo ""
        fi

        # ── Skipped sections ──
        if [[ ${#SKIPPED_SIZE[@]} -gt 0 ]]; then
            echo "## Skipped — Too Large (>${MAX_FILE_KB} KB)"
            echo ""
            echo '```'
            printf '%s\n' "${SKIPPED_SIZE[@]}" | sort -rh
            echo '```'
            echo ""
        fi

        if [[ ${#SKIPPED_ENV[@]} -gt 0 ]]; then
            echo "## Skipped — Env Files (use --include-env to add)"
            echo ""
            echo '```'
            printf '%s\n' "${SKIPPED_ENV[@]}" | sort
            echo '```'
            echo ""
        fi

        if [[ ${#SKIPPED_LOCK[@]} -gt 0 ]]; then
            echo "## Skipped — Lock Files (use --include-locks to add)"
            echo ""
            echo '```'
            printf '%s\n' "${SKIPPED_LOCK[@]}" | sort
            echo '```'
            echo ""
        fi

    } > "$MANIFEST"
fi

# ─── Zip it ───────────────────────────────────────────────────────────────────
[[ -f "$OUTPUT_ZIP" ]] && rm -f "$OUTPUT_ZIP"

info "Creating zip..."
(
    cd "$PACK_ROOT"
    zip -r -q "$OUTPUT_ZIP" .
)

# ─── Final summary ────────────────────────────────────────────────────────────
ZIP_SIZE=$(du -sh "$OUTPUT_ZIP" 2>/dev/null | awk '{print $1}')
TOTAL_LINES=0
for f in "${INCLUDED[@]}"; do
    l=$(wc -l < "$PACK_ROOT/$f" 2>/dev/null || echo 0)
    TOTAL_LINES=$((TOTAL_LINES + l))
done

echo ""
ok "Pack complete: ${BOLD}$OUTPUT_ZIP${RESET}  (${ZIP_SIZE})"
echo ""
echo -e "  ${BOLD}Included:${RESET}  ${#INCLUDED[@]} files  /  ~${TOTAL_LINES} lines"

# NEW: show whitelist skip count in repo-root mode
[[ "$REPO_ROOT_MODE" == true ]] && \
    echo -e "  Skipped (not whitelisted): ${#SKIPPED_WHITELIST[@]} files"

[[ ${#SKIPPED_SIZE[@]}   -gt 0 ]] && warn "Skipped (too large):    ${#SKIPPED_SIZE[@]} files  — raise -s/--max-size to include"
[[ ${#SKIPPED_ENV[@]}    -gt 0 ]] && warn "Skipped (env files):    ${#SKIPPED_ENV[@]} files  — use --include-env to include  ⚠ check for secrets first"
[[ ${#SKIPPED_LOCK[@]}   -gt 0 ]] && warn "Skipped (lock files):   ${#SKIPPED_LOCK[@]} files  — use --include-locks to include"
[[ ${#SKIPPED_BINARY[@]} -gt 0 ]] && echo -e "  Skipped (binary ext):   ${#SKIPPED_BINARY[@]} files"
[[ ${#SKIPPED_NOTEXT[@]} -gt 0 ]] && echo -e "  Skipped (binary data):  ${#SKIPPED_NOTEXT[@]} files"

echo ""

ZIP_KB=$(du -k "$OUTPUT_ZIP" 2>/dev/null | awk '{print $1}')
if [[ "$ZIP_KB" -gt 25600 ]]; then
    warn "Zip is >25 MB — consider lowering --max-size or scoping to a subdirectory for upload to AI chats"
fi
