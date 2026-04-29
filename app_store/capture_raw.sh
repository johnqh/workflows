#!/bin/bash
# Orchestrator: build once, then for each device: prepare → capture → shutdown.
#
# Processes one device at a time to minimize RAM usage.
#
# Usage:
#   capture_raw.sh [options]
#
# Options:
#   --platform <name>   Filter platforms (ios, ipados, android). Repeatable.
#   --device <key>      Filter device keys. Repeatable.
#   --orientation <o>   landscape (default) or portrait. Landscape only applies to tablets.
#   --delay <seconds>   Seconds to wait before each capture (default: 8).
#   --skip-build        Skip build step entirely.
#   --skip-release      Build debug only (skip release builds).
#   --dry-run           Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

declare -a PLATFORMS=()
declare -a DEVICES=()
ORIENTATION="landscape"
DELAY=8
SKIP_BUILD=false
SKIP_RELEASE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)      PLATFORMS+=("$2"); shift 2 ;;
    --device)        DEVICES+=("$2"); shift 2 ;;
    --orientation)   ORIENTATION="$2"; shift 2 ;;
    --delay)         DELAY="$2"; shift 2 ;;
    --skip-build)    SKIP_BUILD=true; shift ;;
    --skip-release)  SKIP_RELEASE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -*)              echo "Unknown option: $1"; exit 1 ;;
    *)               echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

DRY_RUN_FLAG=""
[ "$DRY_RUN" = true ] && DRY_RUN_FLAG="--dry-run"

# ── Step 1: Build ────────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = true ]; then
  echo "Skipping build step (--skip-build)."
  echo ""
else
  echo "══════════════════════════════════════════════════════════════"
  echo "  BUILDING"
  echo "══════════════════════════════════════════════════════════════"
  echo ""

  build_flags=()
  [ "$SKIP_RELEASE" = true ] && build_flags+=("--debug-only")
  [ "$DRY_RUN" = true ] && build_flags+=("--dry-run")

  "$SCRIPT_DIR/build.sh" "${build_flags[@]}"
  echo ""
fi

# ── Step 2: Collect devices ──────────────────────────────────────────────────

declare -a DEVICE_KEYS=()

for platform in $(jq -r 'keys[]' "$SCREENS_JSON"); do
  case "$platform" in
    ios|ipados) device_type="simulator" ;;
    android)    device_type="emulator" ;;
    macos)      device_type="native" ;;
    *)          continue ;;
  esac

  platform_selected "$platform" "${PLATFORMS[@]}" || continue

  for device_key in $(jq -r --arg p "$platform" '.[$p] | keys[]' "$SCREENS_JSON"); do
    device_selected "$device_key" "${DEVICES[@]}" || continue

    if [ "$device_type" = "native" ]; then
      # macOS native app — just check the key exists
      device_name=$(jq -r --arg p "$platform" --arg d "$device_key" \
        '.[$p][$d].app // empty' "$SCREENS_JSON")
    else
      device_name=$(jq -r --arg p "$platform" --arg d "$device_key" \
        '.[$p][$d].'"$device_type"' // empty' "$SCREENS_JSON")
    fi

    [ -z "$device_name" ] || [ "$device_name" = "null" ] && continue

    DEVICE_KEYS+=("$device_key")
  done
done

total_devices=${#DEVICE_KEYS[@]}

if [ "$total_devices" -eq 0 ]; then
  echo "No matching devices found in screens.json."
  exit 0
fi

echo "══════════════════════════════════════════════════════════════"
echo "  SCREENSHOTS: $total_devices device(s)"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Devices: ${DEVICE_KEYS[*]}"
echo ""

# ── Step 3: Process each device ──────────────────────────────────────────────

device_num=0
failed_devices=()

for device_key in "${DEVICE_KEYS[@]}"; do
  device_num=$((device_num + 1))

  echo "┌──────────────────────────────────────────────────────────┐"
  echo "│  [$device_num/$total_devices] $device_key"
  echo "└──────────────────────────────────────────────────────────┘"
  echo ""

  # Resolve device to get platform info for shutdown later
  if ! resolve_device_key "$device_key"; then
    echo "  Skipping $device_key (could not resolve)."
    failed_devices+=("$device_key")
    echo ""
    continue
  fi

  local_platform="$DEVICE_PLATFORM"
  local_type="$DEVICE_TYPE"
  local_name="$DEVICE_NAME"

  # ── Prepare (boot + install + launch)
  echo "--- Preparing $device_key ---"
  if ! "$SCRIPT_DIR/prepare.sh" --device "$device_key" --orientation "$ORIENTATION" $DRY_RUN_FLAG; then
    echo "  Error: prepare.sh failed for $device_key. Skipping."
    failed_devices+=("$device_key")
    echo ""
    continue
  fi
  echo ""

  # ── Capture screenshots
  echo "--- Capturing screenshots for $device_key ---"
  if ! "$SCRIPT_DIR/capture.sh" --device "$device_key" --orientation "$ORIENTATION" --delay "$DELAY" $DRY_RUN_FLAG; then
    echo "  Error: capture.sh failed for $device_key."
    failed_devices+=("$device_key")
  fi
  echo ""

  # ── Shutdown
  echo "--- Shutting down $device_key ---"
  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] Would shut down $local_name"
  else
    if [ "$local_type" = "simulator" ]; then
      udid=$(find_simulator_udid "$local_name")
      if [ -n "$udid" ]; then
        shutdown_simulator "$udid"
      fi
    elif [ "$local_type" = "emulator" ]; then
      serial=$(find_running_avd_serial "$local_name" 2>/dev/null) || true
      if [ -n "$serial" ]; then
        shutdown_emulator "$serial"
        # Wait for emulator process to fully exit before booting the next one
        sleep 5
      fi
    elif [ "$local_type" = "native" ]; then
      kill_macos_app
    fi
  fi

  echo ""
  echo "Done $device_num/$total_devices."
  echo ""
done

# ── Cleanup ───────────────────────────────────────────────────────────────────

echo "--- Cleaning up ---"
if [ "$DRY_RUN" = true ]; then
  echo "  [dry-run] Would stop Metro bundler"
else
  "$SCRIPT_DIR/cleanup.sh"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

echo "══════════════════════════════════════════════════════════════"
echo "  COMPLETE"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Processed $total_devices device(s)."

if [ ${#failed_devices[@]} -gt 0 ]; then
  echo "Failed: ${failed_devices[*]}"
  exit 1
else
  echo "All devices succeeded."
fi
