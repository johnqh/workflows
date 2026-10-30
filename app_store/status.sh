#!/bin/bash
# status — generate and open the cross-app submission status dashboard.
#
# With no app_store dirs given, auto-discovers every */app_store/info.json (and
# */app_store_*/info.json) under the projects root, so one command shows the
# whole fleet. Filesystem-only; no credentials or network.
#
# Usage:
#   appstore status [--out <file.html>] [--no-open] [<app_store_dir> ...]
#   appstore status                       # whole fleet, auto-discovered
#
# Env: PROJECTS_ROOT (default: parent of the workflows repo, i.e. ~/projects).

set -eo pipefail

if [ -z "$WORKFLOWS_DIR" ]; then
  WORKFLOWS_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECTS_ROOT="${PROJECTS_ROOT:-$(cd "$WORKFLOWS_DIR/../.." && pwd)}"
OUT="${TMPDIR:-/tmp}/appstore-status.html"
OPEN=true
DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUT="$2"; shift 2 ;;
    --no-open) OPEN=false; shift ;;
    *)         DIRS+=("$1"); shift ;;
  esac
done

if [ ${#DIRS[@]} -eq 0 ]; then
  echo "Discovering app_store configs under $PROJECTS_ROOT ..."
  while IFS= read -r f; do
    DIRS+=("$(dirname "$f")")
  done < <(find "$PROJECTS_ROOT" -maxdepth 2 -type f \
             \( -path "*/app_store/info.json" -o -path "*/app_store_*/info.json" \) 2>/dev/null | sort)
fi

if [ ${#DIRS[@]} -eq 0 ]; then
  echo "No app_store configs found."
  exit 0
fi

python3 "$WORKFLOWS_DIR/status.py" --out "$OUT" "${DIRS[@]}"

if [ "$OPEN" = true ]; then
  case "$(uname -s)" in
    Darwin) open "$OUT" ;;
    Linux)  xdg-open "$OUT" 2>/dev/null || echo "Open: $OUT" ;;
    *)      echo "Open: $OUT" ;;
  esac
fi
