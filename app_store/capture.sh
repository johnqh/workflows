#!/bin/bash
# Capture screenshots on one running device across all languages and paths.
#
# The device must already be running and the app installed (via prepare.sh).
# Iterates: languages × paths, saving screenshots to
#   app_store/screenshots/raw/<device_key>/<lang>/<seq>.png
#
# Usage:
#   capture.sh --device <key> [options]
#
# Options:
#   --device <key>      Device key from screens.json (required).
#   --orientation <o>   landscape (default) or portrait. Landscape rotates tablet screenshots.
#   --languages <list>  Comma-separated language codes to capture (default: all).
#   --delay <seconds>   Seconds to wait before capture (default: 8).
#   --dry-run           Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

DEVICE_KEY=""
ORIENTATION="landscape"
LANGUAGES_FILTER=""
DELAY=8
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --device)       DEVICE_KEY="$2"; shift 2 ;;
    --orientation)  ORIENTATION="$2"; shift 2 ;;
    --languages)    LANGUAGES_FILTER="$2"; shift 2 ;;
    --delay)        DELAY="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -*)         echo "Unknown option: $1"; exit 1 ;;
    *)          echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

if [ -z "$DEVICE_KEY" ]; then
  echo "Error: --device is required."
  echo "Usage: capture.sh --device <key>"
  exit 1
fi

# ── Resolve device ───────────────────────────────────────────────────────────

resolve_device_key "$DEVICE_KEY"

# ── Find running device ─────────────────────────────────────────────────────

UDID=""
SERIAL=""

if [ "$DRY_RUN" = true ]; then
  if [ "$DEVICE_TYPE" = "simulator" ]; then
    UDID=$(find_simulator_udid "$DEVICE_NAME" 2>/dev/null || true)
    echo "Using simulator: $DEVICE_NAME (${UDID:-dry-run})"
  elif [ "$DEVICE_TYPE" = "emulator" ]; then
    SERIAL=$(find_running_avd_serial "$DEVICE_NAME" 2>/dev/null || true)
    echo "Using emulator: $DEVICE_NAME (${SERIAL:-dry-run})"
  elif [ "$DEVICE_TYPE" = "native" ]; then
    echo "Using native macOS app (dry-run)"
  fi
elif [ "$DEVICE_TYPE" = "simulator" ]; then
  UDID=$(find_simulator_udid "$DEVICE_NAME")
  if [ -z "$UDID" ]; then
    echo "Error: Simulator '$DEVICE_NAME' not found."
    exit 1
  fi
  if ! is_simulator_booted "$UDID"; then
    echo "Error: Simulator '$DEVICE_NAME' is not booted. Run prepare.sh first."
    exit 1
  fi
  echo "Using simulator: $DEVICE_NAME ($UDID)"
elif [ "$DEVICE_TYPE" = "emulator" ]; then
  if ! SERIAL=$(find_running_avd_serial "$DEVICE_NAME"); then
    echo "Error: Emulator '$DEVICE_NAME' is not running. Run prepare.sh first."
    exit 1
  fi
  echo "Using emulator: $DEVICE_NAME ($SERIAL)"
  setup_adb_reverse "$SERIAL"
elif [ "$DEVICE_TYPE" = "native" ]; then
  if ! is_macos_app_running; then
    echo "Error: macOS app is not running. Run prepare.sh first."
    exit 1
  fi
  echo "Using native macOS app"
fi

# ── Load languages and paths ────────────────────────────────────────────────

ALL_LANGUAGES=()
while IFS= read -r line; do ALL_LANGUAGES+=("$line"); done < <(jq -r '.[]' "$LANGUAGES_JSON")

# Filter languages if --languages was specified
if [ -n "$LANGUAGES_FILTER" ]; then
  IFS=',' read -ra LANG_FILTER_ARR <<< "$LANGUAGES_FILTER"
  LANGUAGES=()
  for lang in "${LANG_FILTER_ARR[@]}"; do
    LANGUAGES+=("$lang")
  done
else
  LANGUAGES=("${ALL_LANGUAGES[@]}")
fi

PATHS=()
while IFS= read -r line; do PATHS+=("$line"); done < <(jq -r '.[]' "$PATHS_JSON")

# Read loop order from info.json (default: languages_first)
LOOP_ORDER=$(jq -r '.capture.loopOrder // "languages_first"' "$INFO_JSON")

echo "Languages: ${LANGUAGES[*]}"
echo "Paths:     ${#PATHS[@]} entries"
echo "Delay:     ${DELAY}s"
echo "Loop:      ${LOOP_ORDER}"
echo ""

# ── Capture functions ────────────────────────────────────────────────────────

capture_ios() {
  local udid="$1" url="$2" output="$3"
  # Ensure app is in foreground so openurl doesn't trigger "Open in...?" dialog
  xcrun simctl launch "$udid" "$BUNDLE_ID" 2>/dev/null || true
  sleep 2
  xcrun simctl openurl "$udid" "$url"
  sleep "$DELAY"
  xcrun simctl io "$udid" screenshot "$output"
}

capture_android() {
  local serial="$1" url="$2" output="$3"
  "$ADB" -s "$serial" shell am start -a android.intent.action.VIEW -d "'$url'" &>/dev/null
  sleep "$DELAY"
  "$ADB" -s "$serial" exec-out screencap -p > "$output"
}

capture_macos() {
  local url="$1" output="$2"
  open_macos_deeplink "$url"
  sleep "$DELAY"
  capture_macos_screenshot "$output"
}

# ── Iterate languages × paths ───────────────────────────────────────────────

total=$(( ${#LANGUAGES[@]} * ${#PATHS[@]} ))
count=0

echo "━━━ Capturing $total screenshots for $DEVICE_KEY ━━━"

# Language switching is handled entirely via deep links — no device locale change
# needed. This avoids restarting the app (which would lose iPad landscape orientation).

switch_language() {
  local lang="$1"
  local lang_url="${SCHEME}:///${lang}/"
  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] Would switch language to $lang"
  else
    echo "  Switching to $lang..."
    if [ "$DEVICE_TYPE" = "simulator" ]; then
      xcrun simctl openurl "$UDID" "$lang_url"
    elif [ "$DEVICE_TYPE" = "emulator" ]; then
      "$ADB" -s "$SERIAL" shell am start -a android.intent.action.VIEW -d "'$lang_url'" &>/dev/null
    elif [ "$DEVICE_TYPE" = "native" ]; then
      open_macos_deeplink "$lang_url"
    fi
    sleep "$DELAY"
  fi
}

capture_screenshot() {
  local lang="$1" path="$2" seq="$3"
  local url="${SCHEME}:///${lang}${path}"
  local out_dir="$APP_STORE_DIR/screenshots/raw/$DEVICE_KEY/$lang"
  mkdir -p "$out_dir"
  local output="$out_dir/${seq}.png"

  count=$((count + 1))
  if [ "$DRY_RUN" = true ]; then
    echo "  [$count/$total] [$lang] $url → $output"
  else
    echo "  [$count/$total] [$lang] ${seq}.png"
    if [ "$DEVICE_TYPE" = "simulator" ]; then
      capture_ios "$UDID" "$url" "$output"
      if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
        rotate_screenshot_landscape "$output"
      fi
    elif [ "$DEVICE_TYPE" = "native" ]; then
      capture_macos "$url" "$output"
    else
      capture_android "$SERIAL" "$url" "$output"
      if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
        img_w=$(sips -g pixelWidth "$output" 2>/dev/null | awk '/pixelWidth/{print $2}')
        img_h=$(sips -g pixelHeight "$output" 2>/dev/null | awk '/pixelHeight/{print $2}')
        if [ -n "$img_w" ] && [ -n "$img_h" ] && [ "$img_h" -gt "$img_w" ]; then
          rotate_screenshot_landscape "$output"
        fi
      fi
    fi
  fi
}

if [ "$LOOP_ORDER" = "paths_first" ]; then
  # Outer: paths, inner: languages — must switch language before each capture
  # because navigating directly to /{lang}{path} can crash the navigation tree
  # when the language changes.
  for path_idx in "${!PATHS[@]}"; do
    path="${PATHS[$path_idx]}"
    seq=$((path_idx + 1))
    for lang in "${LANGUAGES[@]}"; do
      switch_language "$lang"
      capture_screenshot "$lang" "$path" "$seq"
    done
  done
else
  # Default (languages_first): outer: languages, inner: paths — switch language
  # once, then capture all paths before moving to the next language.
  for lang in "${LANGUAGES[@]}"; do
    switch_language "$lang"
    seq=0
    for path in "${PATHS[@]}"; do
      seq=$((seq + 1))
      capture_screenshot "$lang" "$path" "$seq"
    done
  done
fi

echo ""
echo "Done. $count screenshots captured for $DEVICE_KEY."
