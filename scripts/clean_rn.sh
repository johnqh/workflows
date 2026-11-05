#!/bin/bash

CLEAN_RN_VERSION="1.0.0"

# clean_rn.sh - Reclaim disk space by deleting native build artifacts (Xcode /
# iOS and Android / Gradle) from React Native and native projects under a base
# directory (default: ~/projects).
#
# A project is a target when it has an ios/ or android/ directory. For each one
# the following regenerable native artifacts are removed (when they exist and
# are NOT git-tracked):
#
#   iOS / Xcode:
#     ios/build            Xcode build output
#     ios/Pods             CocoaPods install (restore with `pod install`)
#     ios/DerivedData      in-project derived data, if configured
#
#   Android / Gradle:
#     android/**/build     module build output (app/build, etc.)
#     android/**/.gradle   Gradle caches/state
#     android/**/.cxx      native C/C++ (NDK) build output
#
# What is kept:
#   - Source and project files (*.xcodeproj, *.xcworkspace, Podfile, *.gradle,
#     gradle/ wrapper, AndroidManifest, etc.)
#   - Lockfiles (Podfile.lock, gradle.lockfile) -- not build output
#   - Anything git tracks (so a repo that commits a build path is untouched and
#     no git diff is produced)
#   - node_modules (that is clean.sh's concern; it is never descended into here)
#
# NOT touched (outside any repo): the global Xcode DerivedData
# (~/Library/Developer/Xcode/DerivedData) and the global Gradle cache
# (~/.gradle/caches). See --help for how to clear those by hand.
#
# Usage:
#   scripts/clean_rn.sh                 # clean ~/projects
#   scripts/clean_rn.sh /path/to/base   # a different base directory
#   scripts/clean_rn.sh --dry-run       # show what WOULD be freed, delete nothing
#   scripts/clean_rn.sh -n /path        # dry-run a specific base
#
# Options:
#   --dry-run, -n   Report the plan and the space it would free; delete nothing.
#   --quiet, -q     Only print cleaned projects and the final summary.
#   --help, -h      Show this help.
#
# To also clear the global caches (all projects at once), by hand:
#   rm -rf ~/Library/Developer/Xcode/DerivedData/*
#   rm -rf ~/.gradle/caches/*

set -u

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
DRY_RUN=false
QUIET=false
BASE_DIR=""

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
    sed -n '5,48p' "$0" | sed 's/^# \{0,1\}//'
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
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

TOTAL_KB=0

# ---------------------------------------------------------------------------
# Helpers (shared shape with clean.sh)
# ---------------------------------------------------------------------------

# True if git tracks anything at the given relative path in the project.
path_is_tracked() {
    local dir="$1" rel="$2"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
    git -C "$dir" ls-files --error-unmatch "$rel" >/dev/null 2>&1 && return 0
    git -C "$dir" ls-files -- "$rel/**" 2>/dev/null | grep -q . && return 0
    return 1
}

size_kb() {
    local p="$1"
    [ -e "$p" ] || { echo 0; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1; exit}'
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

# ---------------------------------------------------------------------------
# Native cleaning
# ---------------------------------------------------------------------------
clean_native() {
    local dir="$1"

    # --- iOS / Xcode -------------------------------------------------------
    if [ -d "$dir/ios" ]; then
        local rel
        for rel in ios/build ios/Pods ios/DerivedData; do
            remove_path "$dir" "$rel"
        done
        # Any other `build` dir nested in ios/ (e.g. per-scheme), but never
        # inside Pods or node_modules.
        local p
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            remove_path "$dir" "${p#"$dir"/}"
        done < <(find "$dir/ios" -type d \( -name node_modules -o -name Pods \) -prune -o \
                      -type d -name build -prune -print 2>/dev/null | grep -v "^$dir/ios/build$")
    fi

    # --- Android / Gradle --------------------------------------------------
    if [ -d "$dir/android" ]; then
        # All build / .gradle / .cxx directories under android/, pruning
        # node_modules and not descending into a matched directory.
        local p
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            remove_path "$dir" "${p#"$dir"/}"
        done < <(find "$dir/android" -type d -name node_modules -prune -o \
                      -type d \( -name build -o -name .gradle -o -name .cxx \) -prune -print 2>/dev/null)
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "clean_rn.sh v$CLEAN_RN_VERSION"
if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN -- nothing will be deleted"
fi
log_info "Base: $BASE_DIR"
log ""

cleaned=0
skipped=0

for dir in "$BASE_DIR"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"

    if [ -d "$dir/ios" ] || [ -d "$dir/android" ]; then
        local_kinds=""
        [ -d "$dir/ios" ] && local_kinds="iOS"
        [ -d "$dir/android" ] && local_kinds="${local_kinds:+$local_kinds+}Android"
        log_info "${name}  ${DIM}(${local_kinds} native)${NC}"
        clean_native "$dir"
        cleaned=$((cleaned + 1))
    else
        log_skip "$name — no ios/ or android/ directory"
        skipped=$((skipped + 1))
    fi
done

log ""
log_info "=============================================="
if [ "$DRY_RUN" = true ]; then
    log_info "Would clean $cleaned native project(s); skipped $skipped."
    log_info "Would free: $(human_kb "$TOTAL_KB")"
else
    log_info "Cleaned $cleaned native project(s); skipped $skipped."
    log_info "Freed: $(human_kb "$TOTAL_KB")"
fi
