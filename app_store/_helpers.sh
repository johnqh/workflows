#!/bin/bash
# Shared helper functions for app_store scripts.
# Requires APP_STORE_DIR to be set by the calling wrapper script.

if [ -z "$APP_STORE_DIR" ]; then
  echo "Error: APP_STORE_DIR must be set before sourcing _helpers.sh"
  exit 1
fi

WORKFLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$WORKFLOWS_DIR"
PROJECT_DIR="$(cd "$APP_STORE_DIR/.." && pwd)"

SCREENS_JSON="$APP_STORE_DIR/screens.json"
INFO_JSON="$APP_STORE_DIR/info.json"
LANGUAGES_JSON="$APP_STORE_DIR/languages.json"
PATHS_JSON="$APP_STORE_DIR/paths.json"
BUILDS_DIR="$APP_STORE_DIR/builds"

SCHEME=$(jq -r '.app.scheme' "$INFO_JSON")
BUNDLE_ID=$(jq -r '.app.bundleId' "$INFO_JSON")

# Build config from info.json (with defaults)
IOS_APP_NAME=$(jq -r '.build.ios.appName // .app.name' "$INFO_JSON")
IOS_WORKSPACE=$(jq -r '.build.ios.workspace // (.build.ios.appName // .app.name) + ".xcworkspace"' "$INFO_JSON")
IOS_SCHEME=$(jq -r '.build.ios.scheme // .build.ios.appName // .app.name' "$INFO_JSON")

ANDROID_EMULATOR="${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"

# ── Dependency check ─────────────────────────────────────────────────────────

require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
  fi
}

# ── Device resolution ────────────────────────────────────────────────────────

# Given a device key (e.g. iphone_6_9), find its platform and simulator/emulator name.
# Sets: DEVICE_PLATFORM, DEVICE_TYPE ("simulator" or "emulator"), DEVICE_NAME
resolve_device_key() {
  local key="$1"

  for platform in $(jq -r 'keys[]' "$SCREENS_JSON"); do
    local type
    case "$platform" in
      ios|ipados) type="simulator" ;;
      android)    type="emulator" ;;
      *)          continue ;;
    esac

    local name
    name=$(jq -r --arg p "$platform" --arg d "$key" '.[$p][$d].'"$type"' // empty' "$SCREENS_JSON" 2>/dev/null)

    if [ -n "$name" ] && [ "$name" != "null" ]; then
      DEVICE_PLATFORM="$platform"
      DEVICE_TYPE="$type"
      DEVICE_NAME="$name"
      return 0
    fi
  done

  echo "Error: Device key '$key' not found in screens.json (or has null simulator/emulator)."
  return 1
}

# ── iOS / iPadOS helpers ─────────────────────────────────────────────────────

find_simulator_udid() {
  local name="$1"
  xcrun simctl list devices -j 2>/dev/null | jq -r --arg name "$name" '
    .devices | to_entries[] | .value[] |
    select(.name == $name and .isAvailable == true) | .udid
  ' | head -1
}

is_simulator_booted() {
  local udid="$1"
  local state
  state=$(xcrun simctl list devices -j 2>/dev/null | jq -r --arg udid "$udid" '
    .devices | to_entries[] | .value[] |
    select(.udid == $udid) | .state
  ')
  [ "$state" = "Booted" ]
}

shutdown_simulator() {
  local udid="$1"
  echo "Shutting down simulator $udid..."
  xcrun simctl shutdown "$udid" 2>/dev/null || true
}

# ── Android helpers ──────────────────────────────────────────────────────────

avd_exists() {
  local avd="$1"
  "$ANDROID_EMULATOR" -list-avds 2>/dev/null | grep -qx "$avd"
}

get_emulator_serials() {
  "$ADB" devices 2>/dev/null | grep "^emulator-" | awk '{print $1}' || true
}

get_avd_for_serial() {
  local serial="$1"
  "$ADB" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r'
}

find_running_avd_serial() {
  local target_avd="$1"
  for serial in $(get_emulator_serials); do
    local avd
    avd=$(get_avd_for_serial "$serial")
    if [ "$avd" = "$target_avd" ]; then
      echo "$serial"
      return 0
    fi
  done
  return 1
}

shutdown_emulator() {
  local serial="$1"
  echo "Shutting down Android emulator ($serial)..."
  "$ADB" -s "$serial" emu kill 2>/dev/null || true
}

# ── Port forwarding ──────────────────────────────────────────────────────────

setup_adb_reverse() {
  local serial="$1"
  local ports=("$METRO_PORT")

  if [ -f "$PROJECT_DIR/.env" ]; then
    local api_url
    api_url=$(grep '^EXPO_PUBLIC_API_URL=' "$PROJECT_DIR/.env" | head -1 | sed 's/.*://' | tr -d '/')
    if [ -n "$api_url" ] && [[ "$api_url" =~ ^[0-9]+$ ]]; then
      ports+=("$api_url")
    fi
  fi

  for port in "${ports[@]}"; do
    "$ADB" -s "$serial" reverse tcp:"$port" tcp:"$port" &>/dev/null && \
      echo "  Forwarded port $port on $serial" || \
      echo "  Warning: Failed to forward port $port on $serial"
  done
}

# ── Metro bundler ────────────────────────────────────────────────────────────

METRO_PORT=$(jq -r '.build.metroPort // 8081' "$INFO_JSON")
METRO_PID_FILE="$APP_STORE_DIR/.metro.pid"

is_metro_running() {
  if [ -f "$METRO_PID_FILE" ]; then
    local pid
    pid=$(cat "$METRO_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Stale PID file
    rm -f "$METRO_PID_FILE"
  fi
  # Also check if something is listening on the port
  lsof -ti tcp:"$METRO_PORT" &>/dev/null
}

start_metro() {
  if is_metro_running; then
    echo "Metro bundler already running on port $METRO_PORT."
    return 0
  fi

  echo "Starting Metro bundler on port $METRO_PORT..."
  (cd "$PROJECT_DIR" && node scripts/merge-env.js 2>/dev/null || true)

  (cd "$PROJECT_DIR" && ENVFILE=.env.merged npx react-native start --port "$METRO_PORT") \
    &>"$APP_STORE_DIR/.metro.log" &
  local metro_pid=$!
  echo "$metro_pid" > "$METRO_PID_FILE"

  # Wait for Metro to be ready (check port)
  local retries=0
  while ! lsof -ti tcp:"$METRO_PORT" &>/dev/null; do
    retries=$((retries + 1))
    if [ $retries -ge 30 ]; then
      echo "Warning: Metro may not have started within 30s. Check $APP_STORE_DIR/.metro.log"
      return 1
    fi
    sleep 1
  done
  echo "Metro bundler started (PID $metro_pid)."
}

# Wait for Metro to report "packager-status:running" (port open is not enough)
wait_for_metro_ready() {
  local retries=0
  echo "Waiting for Metro status check..."
  while ! curl -sf "http://localhost:$METRO_PORT/status" 2>/dev/null | grep -q "packager-status:running"; do
    retries=$((retries + 1))
    if [ $retries -ge 60 ]; then
      echo "Warning: Metro status check timed out after 60s."
      return 1
    fi
    sleep 1
  done
  echo "Metro status: running."
}

# Pre-compile the JS bundle so the first device doesn't see "Bundling X%..."
wait_for_bundle_compiled() {
  local platform="$1"  # ios or android
  local retries=0
  local max_retries=180
  echo "Pre-compiling $platform bundle (this may take a while on first run)..."
  while ! curl -sf -o /dev/null "http://localhost:$METRO_PORT/index.bundle?platform=$platform&dev=true&minify=false" 2>/dev/null; do
    retries=$((retries + 1))
    if [ $retries -ge $max_retries ]; then
      echo "Warning: $platform bundle compilation timed out after ${max_retries}s."
      return 1
    fi
    sleep 2
  done
  echo "$platform bundle compiled and ready."
}

stop_metro() {
  if [ -f "$METRO_PID_FILE" ]; then
    local pid
    pid=$(cat "$METRO_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping Metro bundler (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$METRO_PID_FILE"
  fi
  # Kill anything else on the port
  local pids
  pids=$(lsof -ti tcp:"$METRO_PORT" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "Killing remaining processes on port $METRO_PORT..."
    echo "$pids" | xargs kill 2>/dev/null || true
  fi
  echo "Metro bundler stopped."
}

# ── Locale helpers ───────────────────────────────────────────────────────────

# Map a short language code to an Apple locale (e.g. "es" → "es_ES", "en" → "en_US")
lang_to_apple_locale() {
  local lang="$1"
  case "$lang" in
    en)      echo "en_US" ;;
    es)      echo "es_ES" ;;
    zh)      echo "zh_CN" ;;
    zh-Hant) echo "zh_TW" ;;
    ja)      echo "ja_JP" ;;
    ko)      echo "ko_KR" ;;
    fr)      echo "fr_FR" ;;
    de)      echo "de_DE" ;;
    pt)      echo "pt_BR" ;;
    it)      echo "it_IT" ;;
    ru)      echo "ru_RU" ;;
    ar)      echo "ar_SA" ;;
    sv)      echo "sv_SE" ;;
    th)      echo "th_TH" ;;
    uk)      echo "uk_UA" ;;
    vi)      echo "vi_VN" ;;
    *)       echo "${lang}_${lang^^}" ;;
  esac
}

# Map a short language code to an Android locale (e.g. "es" → "es-ES")
lang_to_android_locale() {
  local lang="$1"
  local apple
  apple=$(lang_to_apple_locale "$lang")
  echo "${apple/_/-}"
}

# Set iOS simulator locale and restart the app
set_simulator_locale() {
  local udid="$1" lang="$2"
  local locale
  locale=$(lang_to_apple_locale "$lang")
  # Handle language codes with hyphens (e.g. zh-Hant → zh-Hant)
  local apple_lang="$lang"

  echo "  Setting simulator locale to $lang ($locale)..."
  xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLanguages -array "$apple_lang"
  xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleLocale -string "$locale"

  # Restart the app to pick up the new locale
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  sleep 3
  xcrun simctl launch "$udid" "$BUNDLE_ID" 2>/dev/null || true
  sleep 10
}

# Set Android emulator locale and restart the app
set_emulator_locale() {
  local serial="$1" lang="$2"
  local locale
  locale=$(lang_to_android_locale "$lang")

  echo "  Setting emulator locale to $lang ($locale)..."
  "$ADB" -s "$serial" shell "setprop persist.sys.locale $locale; setprop persist.sys.language ${lang%%-*}; setprop persist.sys.country ${locale##*-}; settings put system system_locales $locale" 2>/dev/null
  "$ADB" -s "$serial" shell am broadcast -a android.intent.action.LOCALE_CHANGED 2>/dev/null || true

  # Restart the app to pick up the new locale
  "$ADB" -s "$serial" shell am force-stop "$BUNDLE_ID" 2>/dev/null || true
  sleep 5
  "$ADB" -s "$serial" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "${BUNDLE_ID}/.MainActivity" &>/dev/null || true
  sleep 30
}

# ── Orientation helpers ──────────────────────────────────────────────────────

# Returns 0 if the device key represents a tablet (iPad or Android tablet)
is_tablet_device() {
  local key="$1"
  case "$key" in
    ipad_*|*_tablet*) return 0 ;;
    *)                return 1 ;;
  esac
}

# Rotate iOS simulator to landscape via Cmd+Left keystroke
set_simulator_landscape() {
  echo "Rotating simulator to landscape..."
  open -a Simulator 2>/dev/null
  sleep 2
  "$SCRIPT_DIR/sim_rotate" landscape
}

# Rotate iOS simulator back to portrait via Cmd+Right keystroke
set_simulator_portrait() {
  echo "Rotating simulator to portrait..."
  "$SCRIPT_DIR/sim_rotate" portrait
}

# Set Android emulator orientation
# user_rotation: 0=portrait, 1=landscape
set_emulator_orientation() {
  local serial="$1" orientation="$2"
  local rotation=0
  [ "$orientation" = "landscape" ] && rotation=1
  echo "Setting emulator to $orientation..."
  "$ADB" -s "$serial" shell settings put system accelerometer_rotation 0 2>/dev/null
  "$ADB" -s "$serial" shell settings put system user_rotation "$rotation" 2>/dev/null
}

# Rotate a screenshot PNG 90° clockwise (for landscape screenshots from portrait framebuffer)
rotate_screenshot_landscape() {
  local file="$1"
  sips -r 270 "$file" --out "$file" &>/dev/null
}

# ── Platform filter helpers ──────────────────────────────────────────────────

platform_selected() {
  local platform="$1"
  shift
  local -a platforms=("$@")
  if [ ${#platforms[@]} -eq 0 ]; then
    return 0
  fi
  for p in "${platforms[@]}"; do
    [ "$p" = "$platform" ] && return 0
  done
  return 1
}

device_selected() {
  local key="$1"
  shift
  local -a devices=("$@")
  if [ ${#devices[@]} -eq 0 ]; then
    return 0
  fi
  for d in "${devices[@]}"; do
    [ "$d" = "$key" ] && return 0
  done
  return 1
}
