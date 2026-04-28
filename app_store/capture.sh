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
#   --delay <seconds>   Seconds to wait before capture (default: 8).
#   --dry-run           Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

DEVICE_KEY=""
ORIENTATION="landscape"
DELAY=8
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --device)       DEVICE_KEY="$2"; shift 2 ;;
    --orientation)  ORIENTATION="$2"; shift 2 ;;
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
fi

# ── Load languages and paths ────────────────────────────────────────────────

LANGUAGES=()
while IFS= read -r line; do LANGUAGES+=("$line"); done < <(jq -r '.[]' "$LANGUAGES_JSON")

PATHS=()
while IFS= read -r line; do PATHS+=("$line"); done < <(jq -r '.[]' "$PATHS_JSON")

echo "Languages: ${LANGUAGES[*]}"
echo "Paths:     ${#PATHS[@]} entries"
echo "Delay:     ${DELAY}s"
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
  # Android emulators are slower to render; use 2x delay
  sleep $(( DELAY * 2 ))
  "$ADB" -s "$serial" exec-out screencap -p > "$output"
}

# ── Iterate languages × paths ───────────────────────────────────────────────

total=$(( ${#LANGUAGES[@]} * ${#PATHS[@]} ))
count=0

echo "━━━ Capturing $total screenshots for $DEVICE_KEY ━━━"

# Language switching is handled entirely via deep links — no device locale change
# needed. This avoids restarting the app (which would lose iPad landscape orientation).

for lang in "${LANGUAGES[@]}"; do
  out_dir="$APP_STORE_DIR/screenshots/raw/$DEVICE_KEY/$lang"
  mkdir -p "$out_dir"
  seq=0

  # Switch app language via deep link before capturing screenshots
  lang_url="${SCHEME}:///${lang}/"
  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] Would switch language to $lang"
  else
    echo "  Switching to $lang..."
    if [ "$DEVICE_TYPE" = "simulator" ]; then
      xcrun simctl openurl "$UDID" "$lang_url"
    else
      "$ADB" -s "$SERIAL" shell am start -a android.intent.action.VIEW -d "'$lang_url'" &>/dev/null
    fi
    sleep "$DELAY"
  fi

  for path in "${PATHS[@]}"; do
    seq=$((seq + 1))
    count=$((count + 1))
    url="${SCHEME}:///${lang}${path}"
    output="$out_dir/${seq}.png"

    if [ "$DRY_RUN" = true ]; then
      echo "  [$count/$total] [$lang] $url → $output"
    else
      echo "  [$count/$total] [$lang] ${seq}.png"
      if [ "$DEVICE_TYPE" = "simulator" ]; then
        capture_ios "$UDID" "$url" "$output"
        # iOS simulator captures in native portrait buffer; rotate for landscape
        if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
          rotate_screenshot_landscape "$output"
        fi
      else
        capture_android "$SERIAL" "$url" "$output"
        # Android tablets: if orientation is landscape but screencap is portrait, rotate
        if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
          img_w=$(sips -g pixelWidth "$output" 2>/dev/null | awk '/pixelWidth/{print $2}')
          img_h=$(sips -g pixelHeight "$output" 2>/dev/null | awk '/pixelHeight/{print $2}')
          if [ -n "$img_w" ] && [ -n "$img_h" ] && [ "$img_h" -gt "$img_w" ]; then
            rotate_screenshot_landscape "$output"
          fi
        fi
      fi
    fi
  done
done

echo ""
echo "Done. $count screenshots captured for $DEVICE_KEY."
