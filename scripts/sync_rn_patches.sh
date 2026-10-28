#!/usr/bin/env bash
#
# sync_rn_patches.sh — distribute the family's canonical React Native dependency
# patches (workflows/rn-patches) into each consuming project's patches/ dir.
#
# Why vendored + synced, rather than a shared runtime path: both bun's
# `patchedDependencies` and patch-package need the .patch file physically in the
# project, and CI runs `bun install --frozen-lockfile` with no checkout of this
# repo. So the canonical copy lives here (one source of truth) and this script
# copies it into each project. Run it whenever a canonical patch changes.
#
# It does NOT edit package.json / bun.lock: a bun consumer must already declare
# the patch in `patchedDependencies` (version-keyed), and a patch-package
# consumer applies every file in patches/ via its postinstall. This script only
# keeps the files identical.
#
# Usage:
#   scripts/sync_rn_patches.sh [--check] [--project <name>]
#     --check            report drift and exit non-zero; copy nothing
#     --project <name>   limit to one consumer (repeatable)
#
# Reads rn-patches/manifest.json. Requires: bash, node (for JSON parsing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$(cd "$WORKFLOWS_DIR/.." && pwd)"
PATCHES_DIR="$WORKFLOWS_DIR/rn-patches"
MANIFEST="$PATCHES_DIR/manifest.json"

CHECK_ONLY=0
ONLY_PROJECTS=" "   # space-delimited filter; " " means "all"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --project) ONLY_PROJECTS="$ONLY_PROJECTS$2 "; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

in_filter() {
  [ "$ONLY_PROJECTS" = " " ] && return 0
  case "$ONLY_PROJECTS" in *" $1 "*) return 0 ;; esac
  return 1
}

# Iterate "canonicalRelPath<TAB>consumerProject" rows from the manifest
# (while-read loop, not mapfile, for bash 3.2 on macOS).
copied=0 drift=0 missing=0 same=0
while IFS=$'\t' read -r rel proj; do
  [ -n "$rel" ] || continue
  in_filter "$proj" || continue

  src="$PATCHES_DIR/$rel"
  dstdir="$PROJECTS_DIR/$proj/patches"
  dst="$dstdir/$(basename "$rel")"

  if [ ! -f "$src" ]; then
    echo "MISSING CANONICAL  $rel" >&2; missing=$((missing+1)); continue
  fi
  if [ ! -d "$PROJECTS_DIR/$proj" ]; then
    echo "SKIP (no project)  $proj"; continue
  fi

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    same=$((same+1)); continue
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "DRIFT  $proj/patches/$(basename "$rel")"; drift=$((drift+1)); continue
  fi
  mkdir -p "$dstdir"
  cp "$src" "$dst"
  echo "SYNCED $proj/patches/$(basename "$rel")"; copied=$((copied+1))
done < <(node -e '
  const m = require(process.argv[1]);
  for (const p of m.patches) for (const c of p.consumers) console.log(p.file + "\t" + c);
' "$MANIFEST")

echo "---"
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "in-sync: $same   drift: $drift   missing-canonical: $missing"
  [ "$drift" -eq 0 ] && [ "$missing" -eq 0 ]
else
  echo "in-sync: $same   synced: $copied   missing-canonical: $missing"
  [ "$missing" -eq 0 ]
fi
