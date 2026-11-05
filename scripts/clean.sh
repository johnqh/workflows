#!/bin/bash

CLEAN_VERSION="1.0.0"

# clean.sh - Reclaim disk space by deleting build output and node_modules from
# TypeScript *library* projects under a base directory (default: ~/projects).
#
# A project is cleaned ONLY when it is classified as a TS library. Everything
# else is left untouched:
#   - web apps        (a root index.html, or a `next` dependency)
#   - React Native    (an ios/ or android/ dir, or react-native in dependencies)
#   - chrome/web ext.  (a manifest.json, or @crxjs/webextension tooling)
#   - command scripts  (a `bin` entry in package.json)
#   - private packages (apps, APIs, services, bots -- `"private": true`)
#   - anything that is not a TypeScript project at all
#
# A TS library here means: a TypeScript project (tsconfig.json or a typescript
# dependency) that is published/consumable -- NOT private, with library entry
# points (main/module/exports/types) -- and none of the exclusions above.
#
# What gets deleted for a library:
#   - build output directories (dist, build, out, lib, es/esm/cjs, .vite, ...)
#   - *.tsbuildinfo incremental files
#   - node_modules
# ...but only paths git does NOT track, so a project that intentionally commits
# its dist/ (or, by accident, node_modules) is never modified and no git diff is
# produced. node_modules and build output are regenerable with `bun install` /
# `bun run build`.
#
# Usage:
#   scripts/clean.sh                 # clean ~/projects
#   scripts/clean.sh /path/to/base   # clean a different base directory
#   scripts/clean.sh --dry-run       # show what WOULD be freed, delete nothing
#   scripts/clean.sh -n /path        # dry-run a specific base
#
# Options:
#   --dry-run, -n   Report the plan and the space it would free; delete nothing.
#   --quiet, -q     Only print cleaned projects and the final summary.
#   --help, -h      Show this help.

set -u

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
DRY_RUN=false
QUIET=false
BASE_DIR=""

# Colors (disabled when stdout is not a TTY)
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; NC=''
fi

log()      { printf '%s\n' "$*"; }
log_info() { [ "$QUIET" = true ] || printf '%b%s%b\n' "$BLUE" "$*" "$NC"; }
log_skip() { [ "$QUIET" = true ] || printf '%b  skip%b %s\n' "$DIM" "$NC" "$*"; }
log_ok()   { printf '%b  clean%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b  warn%b %s\n' "$YELLOW" "$NC" "$*"; }
log_err()  { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

show_help() {
    sed -n '7,41p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) show_help ;;
        --dry-run|-n) DRY_RUN=true; shift ;;
        --quiet|-q) QUIET=true; shift ;;
        -*) log_err "Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
        *)
            if [ -n "$BASE_DIR" ]; then
                log_err "Unexpected extra argument: $1"; exit 1
            fi
            BASE_DIR="$1"; shift ;;
    esac
done

[ -n "$BASE_DIR" ] || BASE_DIR="$HOME/projects"

if [ ! -d "$BASE_DIR" ]; then
    log_err "Base directory not found: $BASE_DIR"
    exit 1
fi
# Normalize to an absolute path.
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

# ---------------------------------------------------------------------------
# Classification
#
# Returns one token on stdout:
#   LIBRARY            -> a TS library; clean it
#   SKIP_NO_PKG        -> no package.json
#   SKIP_BAD_PKG       -> package.json could not be parsed
#   SKIP_NOT_TS        -> no tsconfig.json and no typescript dependency
#   SKIP_WEB_APP       -> root index.html, or a `next` dependency
#   SKIP_EXTENSION     -> a browser-extension manifest / tooling
#   SKIP_RN            -> ios/ or android/ dir, or react-native in dependencies
#   SKIP_CLI           -> a `bin` entry (command script)
#   SKIP_PRIVATE       -> "private": true (apps, APIs, services, bots)
#   SKIP_NOT_LIBRARY   -> no library entry points (main/module/exports/types)
#
# Exclusions are tested before `private` so the printed reason is specific, but
# the governing rule is simply: clean iff the result is LIBRARY.
# ---------------------------------------------------------------------------
classify_project() {
    local dir="$1"
    bun -e '
        const fs = require("fs");
        const path = require("path");
        const d = process.argv[1];
        const pj = path.join(d, "package.json");
        if (!fs.existsSync(pj)) { console.log("SKIP_NO_PKG"); process.exit(0); }
        let p = {};
        try { p = JSON.parse(fs.readFileSync(pj, "utf8")); }
        catch (e) { console.log("SKIP_BAD_PKG"); process.exit(0); }

        const deps = { ...p.dependencies, ...p.devDependencies, ...p.peerDependencies };
        const hasDep = k => Object.prototype.hasOwnProperty.call(deps, k);
        const ex = f => fs.existsSync(path.join(d, f));

        // Must be a TypeScript project.
        if (!(ex("tsconfig.json") || hasDep("typescript"))) { console.log("SKIP_NOT_TS"); process.exit(0); }

        // Web app: a real HTML entry point, or Next.js. (Vite alone is NOT a
        // signal -- many libraries build in Vite library mode.)
        if (ex("index.html") || ex("public/index.html") || hasDep("next")) { console.log("SKIP_WEB_APP"); process.exit(0); }

        // Browser extension.
        if (ex("manifest.json") || ex("public/manifest.json") || ex("src/manifest.json") ||
            ex("src/manifest.ts") || hasDep("@crxjs/vite-plugin") || hasDep("webextension-polyfill")) {
            console.log("SKIP_EXTENSION"); process.exit(0);
        }

        // React Native: a native project directory, or react-native as a real
        // runtime dependency (an app). Libraries that only list react-native as
        // a peer dependency, with no native dir, are universal TS libraries and
        // are NOT excluded here.
        const rnRuntime = !!(p.dependencies && p.dependencies["react-native"]);
        if (ex("ios") || ex("android") || rnRuntime) { console.log("SKIP_RN"); process.exit(0); }

        // Command script / CLI.
        if (p.bin) { console.log("SKIP_CLI"); process.exit(0); }

        // Private packages: apps, backend APIs, services, bots -- not published
        // libraries.
        if (p.private === true) { console.log("SKIP_PRIVATE"); process.exit(0); }

        // A published library exposes entry points.
        if (p.main || p.module || p.exports || p.types || p.typings) { console.log("LIBRARY"); process.exit(0); }

        console.log("SKIP_NOT_LIBRARY");
    ' "$dir" 2>/dev/null || echo "SKIP_BAD_PKG"
}

# Human-readable reason for a skip token.
skip_reason() {
    case "$1" in
        SKIP_NO_PKG)      echo "no package.json" ;;
        SKIP_BAD_PKG)     echo "unreadable package.json" ;;
        SKIP_NOT_TS)      echo "not a TypeScript project" ;;
        SKIP_WEB_APP)     echo "web app" ;;
        SKIP_EXTENSION)   echo "browser extension" ;;
        SKIP_RN)          echo "React Native app" ;;
        SKIP_CLI)         echo "command script (bin)" ;;
        SKIP_PRIVATE)     echo "private package (app/api/service/bot)" ;;
        SKIP_NOT_LIBRARY) echo "no library entry points" ;;
        *)                echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------

# Build output directories to remove when untracked. `lib`/`es`/`esm`/`cjs` are
# included because tsc library builds emit them, but the git-tracked guard below
# means a source directory that happens to carry one of these names (and is
# committed) is never touched.
BUILD_DIRS=(dist build out lib es esm cjs .next .nuxt .svelte-kit .turbo .vite .rollup.cache coverage)

TOTAL_KB=0

# True if git tracks anything at the given relative path in the project.
path_is_tracked() {
    local dir="$1" rel="$2"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
    git -C "$dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1 && return 0
    git -C "$dir" ls-files -- "$rel/**" 2>/dev/null | grep -q . && return 0
    return 1
}

# Measure a path in KiB (0 if missing).
size_kb() {
    local p="$1"
    [ -e "$p" ] || { echo 0; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1; exit}'
}

# Delete one path if it exists and is untracked; otherwise report why not.
# Accumulates freed size. Honors DRY_RUN.
remove_path() {
    local dir="$1" rel="$2"
    local full="$dir/$rel"

    # Guard against an empty/space-only relative path turning this into a
    # delete of the project root.
    [ -n "$rel" ] || return 0
    [ -e "$full" ] || return 0

    if path_is_tracked "$dir" "$rel"; then
        log_warn "kept (git-tracked): $rel"
        return 0
    fi

    local kb
    kb="$(size_kb "$full")"
    TOTAL_KB=$((TOTAL_KB + kb))

    if [ "$DRY_RUN" = true ]; then
        log_ok "would remove $rel ($(human_kb "$kb"))"
        return 0
    fi

    if [ -n "$full" ] && [ -e "$full" ]; then
        rm -rf "$full"
        log_ok "removed $rel ($(human_kb "$kb"))"
    fi
}

human_kb() {
    local kb="$1"
    if [ "$kb" -ge 1048576 ]; then
        awk -v k="$kb" 'BEGIN{printf "%.1f GiB", k/1048576}'
    elif [ "$kb" -ge 1024 ]; then
        awk -v k="$kb" 'BEGIN{printf "%.1f MiB", k/1024}'
    else
        printf '%d KiB' "$kb"
    fi
}

clean_library() {
    local dir="$1"
    local rel

    for rel in "${BUILD_DIRS[@]}"; do
        remove_path "$dir" "$rel"
    done

    # tsc incremental build-info files (top level only; never inside node_modules).
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local base_rel="${f#"$dir"/}"
        remove_path "$dir" "$base_rel"
    done < <(find "$dir" -maxdepth 2 -name '*.tsbuildinfo' -not -path '*/node_modules/*' 2>/dev/null)

    # node_modules -- the big one.
    remove_path "$dir" "node_modules"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "clean.sh v$CLEAN_VERSION"
if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN -- nothing will be deleted"
fi
log_info "Base: $BASE_DIR"
log ""

cleaned=0
skipped=0
declare -a CLEANED_NAMES=()

for dir in "$BASE_DIR"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"

    label="$(classify_project "$dir")"

    if [ "$label" = "LIBRARY" ]; then
        log_info "${name}  ${DIM}(TS library)${NC}"
        clean_library "$dir"
        cleaned=$((cleaned + 1))
        CLEANED_NAMES+=("$name")
    else
        log_skip "$name — $(skip_reason "$label")"
        skipped=$((skipped + 1))
    fi
done

log ""
log_info "=============================================="
if [ "$DRY_RUN" = true ]; then
    log_info "Would clean $cleaned library project(s); skipped $skipped."
    log_info "Would free: $(human_kb "$TOTAL_KB")"
else
    log_info "Cleaned $cleaned library project(s); skipped $skipped."
    log_info "Freed: $(human_kb "$TOTAL_KB")"
fi
