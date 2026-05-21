#!/bin/bash
# Build debug and release artifacts for iOS and Android.
#
# Debug builds target simulators/emulators (for screenshots).
# Release builds target real devices (for App Store / Play Store submission).
#
# Outputs are stored in app_store/builds/{debug,release}/.
#
# Usage:
#   build.sh [options]
#
# Options:
#   --platform <name>   Filter platforms (ios, android). Repeatable.
#   --debug-only        Only build debug artifacts.
#   --release-only      Only build release artifacts.
#   --force             Rebuild even if artifacts already exist.
#   --dry-run           Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

declare -a PLATFORMS=()
DEBUG=true
RELEASE=true
FORCE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)      PLATFORMS+=("$2"); shift 2 ;;
    --debug-only)    RELEASE=false; shift ;;
    --release-only)  DEBUG=false; shift ;;
    --force)         FORCE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -*)              echo "Unknown option: $1"; exit 1 ;;
    *)               echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

want_platform() {
  local p="$1"
  if [ ${#PLATFORMS[@]} -eq 0 ]; then return 0; fi
  for pp in "${PLATFORMS[@]}"; do [ "$pp" = "$p" ] && return 0; done
  return 1
}

# ── Prepare ──────────────────────────────────────────────────────────────────

mkdir -p "$BUILDS_DIR/debug" "$BUILDS_DIR/release"

echo "Merging environment files..."
if [ "$DRY_RUN" = true ]; then
  echo "  [dry-run] Would run: node scripts/merge-env.js"
else
  (cd "$PROJECT_DIR" && node scripts/merge-env.js 2>/dev/null || true)
fi
echo ""

# ── Sync app version from package.json ──────────────────────────────────────

FULL_VERSION=$(jq -r '.version' "$PROJECT_DIR/package.json")
APP_VERSION=$(echo "$FULL_VERSION" | cut -d. -f1-2)
echo "Syncing app version: $APP_VERSION (from $FULL_VERSION)"

if [ "$DRY_RUN" = true ]; then
  echo "  [dry-run] Would update platform version strings to $APP_VERSION"
else
  # iOS: update MARKETING_VERSION in pbxproj
  IOS_PBXPROJ="$PROJECT_DIR/ios/$IOS_APP_NAME.xcodeproj/project.pbxproj"
  if [ -f "$IOS_PBXPROJ" ]; then
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $APP_VERSION;/g" "$IOS_PBXPROJ"
    echo "  Updated iOS MARKETING_VERSION"
  fi

  # Android: update versionName in build.gradle
  ANDROID_GRADLE="$PROJECT_DIR/android/app/build.gradle"
  if [ -f "$ANDROID_GRADLE" ]; then
    sed -i '' "s/versionName \"[^\"]*\"/versionName \"$APP_VERSION\"/" "$ANDROID_GRADLE"
    echo "  Updated Android versionName"
  fi

  # macOS: update MARKETING_VERSION in pbxproj
  MACOS_PBXPROJ="$PROJECT_DIR/macos/$IOS_APP_NAME.xcodeproj/project.pbxproj"
  if [ -f "$MACOS_PBXPROJ" ]; then
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $APP_VERSION;/g" "$MACOS_PBXPROJ"
    echo "  Updated macOS MARKETING_VERSION"
  fi
fi
echo ""

# ── iOS debug build ─────────────────────────────────────────────────────────

IOS_DEBUG_APP="$BUILDS_DIR/debug/$IOS_APP_NAME.app"

if want_platform ios && [ "$DEBUG" = true ]; then
  if [ -d "$IOS_DEBUG_APP" ] && [ "$FORCE" = false ]; then
    echo "iOS debug build already exists: $IOS_DEBUG_APP"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building iOS debug (simulator)..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run xcodebuild build for iphonesimulator"
    else
      IOS_BUILD_DIR="$PROJECT_DIR/ios/build"
      xcodebuild \
        -workspace "$PROJECT_DIR/ios/$IOS_WORKSPACE" \
        -scheme "$IOS_SCHEME" \
        -configuration Debug \
        -sdk iphonesimulator \
        -derivedDataPath "$IOS_BUILD_DIR" \
        -quiet \
        build

      # Find and copy the .app
      BUILT_APP=$(find "$IOS_BUILD_DIR" -name "$IOS_APP_NAME.app" -path "*/Debug-iphonesimulator/*" -maxdepth 6 2>/dev/null | head -1)
      if [ -z "$BUILT_APP" ]; then
        echo "Error: iOS debug build succeeded but could not find $IOS_APP_NAME.app"
        exit 1
      fi
      rm -rf "$IOS_DEBUG_APP"
      cp -R "$BUILT_APP" "$IOS_DEBUG_APP"
      echo "iOS debug build: $IOS_DEBUG_APP"
    fi
  fi
  echo ""
fi

# ── iOS release build ───────────────────────────────────────────────────────

IOS_ARCHIVE="$BUILDS_DIR/release/$IOS_APP_NAME.xcarchive"
IOS_IPA_DIR="$BUILDS_DIR/release/ipa"
EXPORT_OPTIONS="$APP_STORE_DIR/ExportOptions.plist"

if want_platform ios && [ "$RELEASE" = true ]; then
  if [ -d "$IOS_ARCHIVE" ] && [ "$FORCE" = false ]; then
    echo "iOS archive already exists: $IOS_ARCHIVE"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building iOS release archive..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run xcodebuild archive for iphoneos"
      echo "  [dry-run] Would run xcodebuild -exportArchive"
    else
      rm -rf "$IOS_ARCHIVE"

      xcodebuild archive \
        -workspace "$PROJECT_DIR/ios/$IOS_WORKSPACE" \
        -scheme "$IOS_SCHEME" \
        -configuration Release \
        -sdk iphoneos \
        -archivePath "$IOS_ARCHIVE" \
        -quiet

      if [ ! -d "$IOS_ARCHIVE" ]; then
        echo "Error: iOS archive failed."
        exit 1
      fi
      echo "iOS archive: $IOS_ARCHIVE"

      echo "Exporting iOS archive to .ipa..."
      rm -rf "$IOS_IPA_DIR"
      mkdir -p "$IOS_IPA_DIR"

      if xcodebuild -exportArchive \
        -archivePath "$IOS_ARCHIVE" \
        -exportPath "$IOS_IPA_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -quiet; then
        IPA_FILE=$(find "$IOS_IPA_DIR" -name "*.ipa" -maxdepth 1 2>/dev/null | head -1)
        if [ -n "$IPA_FILE" ]; then
          cp "$IPA_FILE" "$BUILDS_DIR/release/$IOS_APP_NAME.ipa"
          echo "iOS .ipa: $BUILDS_DIR/release/$IOS_APP_NAME.ipa"
        else
          echo "Warning: Archive export completed but no .ipa found in $IOS_IPA_DIR"
        fi
      else
        echo "Warning: .ipa export failed (missing distribution certificate/profile?)."
        echo "  The .xcarchive is still available at: $IOS_ARCHIVE"
        echo "  You can export manually from Xcode: open $IOS_ARCHIVE"
      fi
    fi
  fi
  echo ""
fi

# ── Android debug build ─────────────────────────────────────────────────────

ANDROID_DEBUG_APK="$BUILDS_DIR/debug/app-debug.apk"

if want_platform android && [ "$DEBUG" = true ]; then
  if [ -f "$ANDROID_DEBUG_APK" ] && [ "$FORCE" = false ]; then
    echo "Android debug APK already exists: $ANDROID_DEBUG_APK"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building Android debug APK..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run ./gradlew app:assembleDebug"
    else
      (cd "$PROJECT_DIR/android" && ./gradlew app:assembleDebug -q)

      BUILT_APK="$PROJECT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
      if [ ! -f "$BUILT_APK" ]; then
        echo "Error: Android debug build succeeded but could not find APK"
        exit 1
      fi
      cp "$BUILT_APK" "$ANDROID_DEBUG_APK"
      echo "Android debug APK: $ANDROID_DEBUG_APK"
    fi
  fi
  echo ""
fi

# ── Android release build ───────────────────────────────────────────────────

ANDROID_RELEASE_AAB="$BUILDS_DIR/release/app-release.aab"

if want_platform android && [ "$RELEASE" = true ]; then
  if [ -f "$ANDROID_RELEASE_AAB" ] && [ "$FORCE" = false ]; then
    echo "Android release AAB already exists: $ANDROID_RELEASE_AAB"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building Android release AAB..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run ./gradlew app:bundleRelease"
    else
      (cd "$PROJECT_DIR/android" && ./gradlew app:bundleRelease -q)

      BUILT_AAB="$PROJECT_DIR/android/app/build/outputs/bundle/release/app-release.aab"
      if [ ! -f "$BUILT_AAB" ]; then
        echo "Error: Android release build succeeded but could not find AAB"
        exit 1
      fi
      cp "$BUILT_AAB" "$ANDROID_RELEASE_AAB"
      echo "Android release AAB: $ANDROID_RELEASE_AAB"
    fi
  fi
  echo ""
fi

# ── macOS debug build ──────────────────────────────────────────────────────

MACOS_DEBUG_APP="$BUILDS_DIR/debug/${MACOS_APP_NAME:-$IOS_APP_NAME}-macOS.app"

if want_platform macos && [ -n "$MACOS_SCHEME" ] && [ "$DEBUG" = true ]; then
  if [ -d "$MACOS_DEBUG_APP/Contents/MacOS" ] && [ "$FORCE" = false ]; then
    echo "macOS debug build already exists: $MACOS_DEBUG_APP"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building macOS debug..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run xcodebuild build for macOS debug"
    else
      # Use default Xcode DerivedData to avoid conflicts with iOS build paths
      xcodebuild \
        -workspace "$PROJECT_DIR/macos/$MACOS_WORKSPACE" \
        -scheme "$MACOS_SCHEME" \
        -configuration Debug \
        -quiet \
        build

      # Find the .app in Xcode's default DerivedData (macOS bundles have Contents/MacOS)
      BUILT_APP=""
      while IFS= read -r candidate; do
        if [ -d "$candidate/Contents/MacOS" ]; then
          BUILT_APP="$candidate"
          break
        fi
      done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -name "${MACOS_APP_NAME:-$IOS_APP_NAME}.app" -path "*/Debug/*" -not -path "*/Index.noindex/*" -maxdepth 6 2>/dev/null)

      if [ -z "$BUILT_APP" ]; then
        echo "Error: macOS debug build succeeded but could not find .app"
        exit 1
      fi
      rm -rf "$MACOS_DEBUG_APP"
      cp -R "$BUILT_APP" "$MACOS_DEBUG_APP"
      echo "macOS debug build: $MACOS_DEBUG_APP"
    fi
  fi
  echo ""
fi

# ── macOS release build ────────────────────────────────────────────────────

MACOS_ARCHIVE="$BUILDS_DIR/release/$IOS_APP_NAME-macOS.xcarchive"
MACOS_EXPORT_DIR="$BUILDS_DIR/release/macos-export"
MACOS_EXPORT_OPTIONS="$APP_STORE_DIR/ExportOptions-macOS.plist"

if want_platform macos && [ -n "$MACOS_SCHEME" ] && [ "$RELEASE" = true ]; then
  if [ -d "$MACOS_ARCHIVE" ] && [ "$FORCE" = false ]; then
    echo "macOS archive already exists: $MACOS_ARCHIVE"
    echo "  (Use --force to rebuild.)"
  else
    echo "Building macOS release archive..."
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would run xcodebuild archive for macosx"
      echo "  [dry-run] Would run xcodebuild -exportArchive"
    else
      rm -rf "$MACOS_ARCHIVE"

      xcodebuild archive \
        -workspace "$PROJECT_DIR/macos/$MACOS_WORKSPACE" \
        -scheme "$MACOS_SCHEME" \
        -configuration Release \
        -archivePath "$MACOS_ARCHIVE" \
        -quiet

      if [ ! -d "$MACOS_ARCHIVE" ]; then
        echo "Error: macOS archive failed."
        exit 1
      fi
      echo "macOS archive: $MACOS_ARCHIVE"

      if [ -f "$MACOS_EXPORT_OPTIONS" ]; then
        echo "Exporting macOS archive..."
        rm -rf "$MACOS_EXPORT_DIR"
        mkdir -p "$MACOS_EXPORT_DIR"

        if xcodebuild -exportArchive \
          -archivePath "$MACOS_ARCHIVE" \
          -exportPath "$MACOS_EXPORT_DIR" \
          -exportOptionsPlist "$MACOS_EXPORT_OPTIONS" \
          -quiet; then
          echo "macOS export: $MACOS_EXPORT_DIR"
        else
          echo "Warning: macOS export failed (missing distribution certificate/profile?)."
          echo "  The .xcarchive is still available at: $MACOS_ARCHIVE"
          echo "  You can export manually from Xcode: open $MACOS_ARCHIVE"
        fi
      else
        echo "No ExportOptions-macOS.plist found — skipping export."
        echo "  The .xcarchive is available at: $MACOS_ARCHIVE"
        echo "  You can export manually from Xcode: open $MACOS_ARCHIVE"
      fi
    fi
  fi
  echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo "Build complete. Artifacts in $BUILDS_DIR/"
ls -lh "$BUILDS_DIR/debug/" 2>/dev/null | tail -n +2
ls -lh "$BUILDS_DIR/release/" 2>/dev/null | tail -n +2
