#!/bin/bash
# Boot one simulator/emulator, install the debug app, and launch it.
#
# Usage:
#   prepare.sh --device <key> [options]
#
# Options:
#   --device <key>      Device key from screens.json (required). E.g. iphone_6_9, android_phone.
#   --orientation <o>   landscape (default) or portrait. Landscape only applies to tablets.
#   --skip-install      Skip app installation (already installed).
#   --dry-run           Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

DEVICE_KEY=""
ORIENTATION="landscape"
SKIP_INSTALL=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --device)        DEVICE_KEY="$2"; shift 2 ;;
    --orientation)   ORIENTATION="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -*)              echo "Unknown option: $1"; exit 1 ;;
    *)               echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

if [ -z "$DEVICE_KEY" ]; then
  echo "Error: --device is required."
  echo "Usage: prepare.sh --device <key>"
  exit 1
fi

# ── Resolve device ───────────────────────────────────────────────────────────

resolve_device_key "$DEVICE_KEY"
echo "Device:   $DEVICE_KEY"
echo "Platform: $DEVICE_PLATFORM"
echo "Type:     $DEVICE_TYPE"
echo "Name:     $DEVICE_NAME"
echo ""

# ── Ensure Metro is running ───────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Would ensure Metro bundler is running"
else
  start_metro
  wait_for_metro_ready

  # Pre-compile the bundle for this platform so captures don't show loading screens
  case "$DEVICE_TYPE" in
    simulator) wait_for_bundle_compiled "ios" ;;
    emulator)  wait_for_bundle_compiled "android" ;;
    native)    wait_for_bundle_compiled "macos" ;;
  esac
fi
echo ""

# ── iOS / iPadOS ─────────────────────────────────────────────────────────────

if [ "$DEVICE_TYPE" = "simulator" ]; then
  UDID=$(find_simulator_udid "$DEVICE_NAME")
  if [ -z "$UDID" ]; then
    echo "Error: Simulator '$DEVICE_NAME' not found."
    exit 1
  fi
  echo "Simulator UDID: $UDID"

  # Boot
  if is_simulator_booted "$UDID"; then
    echo "Simulator already booted."
  else
    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would boot simulator $DEVICE_NAME ($UDID)"
    else
      echo "Booting simulator $DEVICE_NAME..."
      xcrun simctl boot "$UDID"

      retries=0
      while ! is_simulator_booted "$UDID"; do
        retries=$((retries + 1))
        if [ $retries -ge 30 ]; then
          echo "Warning: Timed out waiting for simulator to boot."
          break
        fi
        sleep 1
      done
      echo "Simulator booted."
    fi
  fi

  # Install
  if [ "$SKIP_INSTALL" = false ]; then
    IOS_APP="$BUILDS_DIR/debug/$IOS_APP_NAME.app"

    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would install $IOS_APP on $DEVICE_NAME"
    else
      if [ ! -d "$IOS_APP" ]; then
        echo "Error: iOS debug build not found at $IOS_APP"
        echo "Run build.sh first."
        exit 1
      fi
      echo "Installing app on $DEVICE_NAME..."
      xcrun simctl install "$UDID" "$IOS_APP"
      echo "App installed."
    fi
  fi

  # Launch — use simctl launch first so the app is in the foreground,
  # then openurl delivers the deep link without a confirmation dialog.
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would launch $BUNDLE_ID on $DEVICE_NAME"
  else
    echo "Launching app..."
    xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 10
    echo "App launched."
  fi

  # Rotate to landscape if requested and device is a tablet
  if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would rotate simulator to landscape"
    else
      set_simulator_landscape
    fi
  fi

  echo ""
  echo "Device ready: $DEVICE_KEY ($DEVICE_NAME, $UDID)"
fi

# ── Android ──────────────────────────────────────────────────────────────────

if [ "$DEVICE_TYPE" = "emulator" ]; then
  if ! avd_exists "$DEVICE_NAME"; then
    echo "Error: AVD '$DEVICE_NAME' not found."
    exit 1
  fi

  # Find or boot emulator
  SERIAL=""
  if SERIAL=$(find_running_avd_serial "$DEVICE_NAME"); then
    echo "Emulator already running on $SERIAL."
  else
    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would boot emulator $DEVICE_NAME"
      SERIAL="emulator-dry-run"
    else
      echo "Booting emulator $DEVICE_NAME..."
      before_serials=$(get_emulator_serials)
      "$ANDROID_EMULATOR" -avd "$DEVICE_NAME" -no-audio -no-boot-anim -no-snapshot-load &>/dev/null &

      retries=0
      while [ -z "$SERIAL" ]; do
        retries=$((retries + 1))
        if [ $retries -ge 120 ]; then
          echo "Error: Timed out waiting for $DEVICE_NAME to appear."
          exit 1
        fi
        sleep 1
        for s in $(get_emulator_serials); do
          if ! echo "$before_serials" | grep -qx "$s"; then
            SERIAL="$s"
            break
          fi
        done
      done

      echo "Detected on $SERIAL. Waiting for boot to complete..."
      retries=0
      while [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
        retries=$((retries + 1))
        if [ $retries -ge 90 ]; then
          echo "Warning: Emulator did not finish booting within 90s."
          break
        fi
        sleep 1
      done
      echo "Emulator booted."
    fi
  fi

  # ADB reverse
  if [ "$DRY_RUN" = false ] && [ "$SERIAL" != "emulator-dry-run" ]; then
    setup_adb_reverse "$SERIAL"
  fi

  # Install
  if [ "$SKIP_INSTALL" = false ]; then
    ANDROID_APK="$BUILDS_DIR/debug/app-debug.apk"

    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would install $ANDROID_APK on $DEVICE_NAME"
    else
      if [ ! -f "$ANDROID_APK" ]; then
        echo "Error: Android debug APK not found at $ANDROID_APK"
        echo "Run build.sh first."
        exit 1
      fi
      echo "Installing app on $DEVICE_NAME ($SERIAL)..."
      "$ADB" -s "$SERIAL" push "$ANDROID_APK" /data/local/tmp/app.apk 2>&1 | tail -1

      install_ok=false
      for attempt in 1 2 3; do
        result=$("$ADB" -s "$SERIAL" shell pm install -r /data/local/tmp/app.apk 2>&1)
        if echo "$result" | grep -q "Success"; then
          install_ok=true
          break
        fi
        echo "  Install attempt $attempt failed: $result"
        sleep 5
      done

      if [ "$install_ok" = true ]; then
        "$ADB" -s "$SERIAL" shell rm /data/local/tmp/app.apk 2>/dev/null
        echo "App installed."
      else
        echo "Error: Failed to install after 3 attempts."
        exit 1
      fi
    fi
  fi

  # Launch
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would launch app on $DEVICE_NAME"
  else
    echo "Launching app..."
    "$ADB" -s "$SERIAL" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "${BUNDLE_ID}/.MainActivity" &>/dev/null || true
    sleep 10
    echo "App launched."
  fi

  # Rotate to landscape if requested and device is a tablet
  if [ "$ORIENTATION" = "landscape" ] && is_tablet_device "$DEVICE_KEY"; then
    if [ "$DRY_RUN" = true ]; then
      echo "[dry-run] Would set emulator to landscape"
    else
      set_emulator_orientation "$SERIAL" landscape
    fi
  fi

  echo ""
  echo "Device ready: $DEVICE_KEY ($DEVICE_NAME, $SERIAL)"
fi

# ── macOS ───────────────────────────────────────────────────────────────────

if [ "$DEVICE_TYPE" = "native" ]; then
  # Build if needed
  if [ "$SKIP_INSTALL" = false ]; then
    MACOS_APP=$(find_macos_app 2>/dev/null) || true

    if [ -z "$MACOS_APP" ] || [ "$SKIP_INSTALL" = false ]; then
      if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] Would build macOS app"
      else
        echo "Building macOS app..."
        xcodebuild \
          -workspace "$PROJECT_DIR/macos/$MACOS_WORKSPACE" \
          -scheme "$MACOS_SCHEME" \
          -configuration Debug \
          -quiet \
          build
        echo "macOS app built."
      fi
    fi
  fi

  # Launch
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would launch macOS app"
  else
    kill_macos_app
    sleep 1
    echo "Launching macOS app..."
    launch_macos_app
    sleep 15
    echo "macOS app launched."
  fi

  echo ""
  echo "Device ready: $DEVICE_KEY (macOS native)"
fi
