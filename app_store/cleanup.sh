#!/bin/bash
# Stop Metro bundler and clean up any running simulators/emulators.
#
# Usage:
#   cleanup.sh [options]
#
# Options:
#   --metro-only    Only stop Metro, don't touch simulators/emulators.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"

METRO_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --metro-only)  METRO_ONLY=true; shift ;;
    -*)            echo "Unknown option: $1"; exit 1 ;;
    *)             echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

# ── Stop Metro ───────────────────────────────────────────────────────────────

stop_metro

# ── Clean up log file ────────────────────────────────────────────────────────

if [ -f "$APP_STORE_DIR/.metro.log" ]; then
  rm -f "$APP_STORE_DIR/.metro.log"
  echo "Removed Metro log file."
fi

echo "Cleanup complete."
