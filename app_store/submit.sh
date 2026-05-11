#!/bin/bash
# Submit app to Apple App Store.
#
# Reads version from package.json, checks against live App Store version,
# uploads build + metadata, and optionally screenshots.
#
# Usage:
#   submit.sh [options]
#
# Options:
#   --platforms <list>   Comma-separated platforms: apple (default: apple).
#   --screenshots        Upload composed store screenshots.
#   --subscriptions      Upload subscription name/description localizations.
#   --metadata-only      Skip build/upload binary, only update metadata (and screenshots if --screenshots).
#   --skip-build         Skip build step (assume IPA exists).
#   --dry-run            Print actions without executing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

# ── CLI parsing ──────────────────────────────────────────────────────────────

PLATFORMS=("apple")
UPLOAD_SCREENSHOTS=false
UPLOAD_SUBSCRIPTIONS=false
METADATA_ONLY=false
SKIP_BUILD=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --platforms)      IFS=',' read -ra PLATFORMS <<< "$2"; shift 2 ;;
    --screenshots)    UPLOAD_SCREENSHOTS=true; shift ;;
    --subscriptions)  UPLOAD_SUBSCRIPTIONS=true; shift ;;
    --metadata-only)  METADATA_ONLY=true; shift ;;
    --skip-build)     SKIP_BUILD=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -*)               echo "Unknown option: $1"; exit 1 ;;
    *)                echo "Unexpected argument: $1"; exit 1 ;;
  esac
done

# ── Load env ─────────────────────────────────────────────────────────────────

ENV_FILE="$APP_STORE_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env and fill in credentials."
  exit 1
fi
source "$ENV_FILE"

# ── Read package version ─────────────────────────────────────────────────────

PACKAGE_VERSION=$(jq -r '.version' "$PROJECT_DIR/package.json")
echo "Package version: $PACKAGE_VERSION"

# ── Process platforms ────────────────────────────────────────────────────────

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    apple)
      echo ""
      echo "══════════════════════════════════════════════════════════════"
      echo "  APPLE APP STORE"
      echo "══════════════════════════════════════════════════════════════"
      echo ""

      # Validate Apple credentials
      if [ -z "$APPLE_API_KEY_ID" ] || [ -z "$APPLE_API_ISSUER_ID" ]; then
        echo "Error: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID must be set in .env"
        exit 1
      fi
      APPLE_KEY_FILE="$APP_STORE_DIR/.keys/apple.p8"
      if [ ! -f "$APPLE_KEY_FILE" ]; then
        echo "Error: Apple API key not found at $APPLE_KEY_FILE"
        echo "Download from App Store Connect > Users and Access > Integrations > App Store Connect API"
        exit 1
      fi

      # Get bundle ID from info.json
      BUNDLE_ID=$(jq -r '.app.bundleId' "$APP_STORE_DIR/info.json")

      # Step 1: Check version against App Store
      echo "Checking App Store version..."
      LIVE_VERSION=$(python3 "$SCRIPT_DIR/submit_apple.py" \
        --action check-version \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer-id "$APPLE_API_ISSUER_ID" \
        --key-file "$APPLE_KEY_FILE" \
        --bundle-id "$BUNDLE_ID" \
        --package-version "$PACKAGE_VERSION")

      if [ "$LIVE_VERSION" = "VERSION_EXISTS" ]; then
        echo "Error: Version $PACKAGE_VERSION is already released on the App Store."
        exit 1
      elif [ "$LIVE_VERSION" = "VERSION_OLDER" ]; then
        echo "Error: Package version $PACKAGE_VERSION is older than or equal to the live version."
        exit 1
      fi
      echo "Version check passed. Proceeding with $PACKAGE_VERSION."

      if [ "$METADATA_ONLY" = false ]; then
        # Step 2: Build if needed
        IPA_DIR="$APP_STORE_DIR/builds/release/ipa"
        IPA_FILE=$(find "$IPA_DIR" -name "*.ipa" 2>/dev/null | head -1)
        IOS_APP_NAME=$(jq -r '.build.ios.appName // "App"' "$APP_STORE_DIR/info.json")
        IOS_ARCHIVE="$APP_STORE_DIR/builds/release/${IOS_APP_NAME}.xcarchive"
        EXPORT_OPTIONS="$APP_STORE_DIR/ExportOptions.plist"

        if [ -z "$IPA_FILE" ]; then
          # Try exporting from existing archive first
          if [ -d "$IOS_ARCHIVE" ] && [ -f "$EXPORT_OPTIONS" ]; then
            echo "Archive exists but no IPA. Exporting..."
            if [ "$DRY_RUN" = true ]; then
              echo "  [dry-run] Would run xcodebuild -exportArchive"
            else
              rm -rf "$IPA_DIR"
              mkdir -p "$IPA_DIR"
              xcodebuild -exportArchive \
                -archivePath "$IOS_ARCHIVE" \
                -exportPath "$IPA_DIR" \
                -exportOptionsPlist "$EXPORT_OPTIONS" \
                -quiet
              IPA_FILE=$(find "$IPA_DIR" -name "*.ipa" 2>/dev/null | head -1)
            fi
          fi

          # If still no IPA, build from scratch
          if [ -z "$IPA_FILE" ]; then
            if [ "$SKIP_BUILD" = true ]; then
              echo "Error: No IPA found in $IPA_DIR and --skip-build was specified."
              exit 1
            fi
            echo "No IPA found. Building..."
            if [ "$DRY_RUN" = true ]; then
              echo "  [dry-run] Would run build.sh --force"
            else
              "$SCRIPT_DIR/build.sh" --platform ios --force
              IPA_FILE=$(find "$IPA_DIR" -name "*.ipa" 2>/dev/null | head -1)
              if [ -z "$IPA_FILE" ]; then
                echo "Error: Build completed but no IPA found in $IPA_DIR"
                exit 1
              fi
            fi
          fi
        fi
        echo "IPA: $IPA_FILE"

        # Ensure altool can find the API key
        ALTOOL_KEY_DIR="$HOME/.private_keys"
        mkdir -p "$ALTOOL_KEY_DIR"
        ALTOOL_KEY_FILE="$ALTOOL_KEY_DIR/AuthKey_${APPLE_API_KEY_ID}.p8"
        if [ ! -f "$ALTOOL_KEY_FILE" ]; then
          ln -s "$(cd "$(dirname "$APPLE_KEY_FILE")" && pwd)/$(basename "$APPLE_KEY_FILE")" "$ALTOOL_KEY_FILE"
          echo "Linked API key for altool: $ALTOOL_KEY_FILE"
        fi

        # Step 3: Upload build
        if [ "$DRY_RUN" = true ]; then
          echo "  [dry-run] Would upload IPA via xcrun altool"
        else
          echo "Uploading build..."
          xcrun altool --upload-app \
            -f "$IPA_FILE" \
            -t ios \
            --apiKey "$APPLE_API_KEY_ID" \
            --apiIssuer "$APPLE_API_ISSUER_ID"
          echo "Build uploaded. Waiting for processing..."
        fi
      else
        echo "Skipping build/upload (--metadata-only)."
      fi

      # Step 4: Create version + upload metadata
      SCREENSHOTS_FLAG=""
      [ "$UPLOAD_SCREENSHOTS" = true ] && SCREENSHOTS_FLAG="--screenshots"
      SUBSCRIPTIONS_FLAG=""
      [ "$UPLOAD_SUBSCRIPTIONS" = true ] && SUBSCRIPTIONS_FLAG="--subscriptions"

      if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create version and upload metadata"
        [ "$UPLOAD_SCREENSHOTS" = true ] && echo "  [dry-run] Would upload screenshots"
        [ "$UPLOAD_SUBSCRIPTIONS" = true ] && echo "  [dry-run] Would upload subscription localizations"
      else
        python3 "$SCRIPT_DIR/submit_apple.py" \
          --action submit \
          --key-id "$APPLE_API_KEY_ID" \
          --issuer-id "$APPLE_API_ISSUER_ID" \
          --key-file "$APPLE_KEY_FILE" \
          --bundle-id "$BUNDLE_ID" \
          --package-version "$PACKAGE_VERSION" \
          --app-store-dir "$APP_STORE_DIR" \
          $SCREENSHOTS_FLAG \
          $SUBSCRIPTIONS_FLAG
      fi

      echo ""
      echo "Apple submission complete. Version $PACKAGE_VERSION is now a draft on App Store Connect."
      ;;

    google)
      echo ""
      echo "══════════════════════════════════════════════════════════════"
      echo "  GOOGLE PLAY STORE"
      echo "══════════════════════════════════════════════════════════════"
      echo ""

      # Validate Google Play credentials
      if [ -z "$GOOGLE_PLAY_SERVICE_ACCOUNT_KEY" ]; then
        echo "Error: GOOGLE_PLAY_SERVICE_ACCOUNT_KEY must be set in .env"
        exit 1
      fi
      GOOGLE_KEY_FILE="$APP_STORE_DIR/$GOOGLE_PLAY_SERVICE_ACCOUNT_KEY"
      if [ ! -f "$GOOGLE_KEY_FILE" ]; then
        echo "Error: Google Play service account key not found at $GOOGLE_KEY_FILE"
        echo "Download from Google Cloud Console > IAM > Service Accounts > Keys"
        exit 1
      fi

      PACKAGE_NAME=$(jq -r '.app.packageName' "$APP_STORE_DIR/info.json")

      GOOGLE_FLAGS=""
      [ "$UPLOAD_SCREENSHOTS" = true ] && GOOGLE_FLAGS="$GOOGLE_FLAGS --screenshots"
      [ "$UPLOAD_SUBSCRIPTIONS" = true ] && GOOGLE_FLAGS="$GOOGLE_FLAGS --subscriptions"
      [ "$METADATA_ONLY" = true ] && GOOGLE_FLAGS="$GOOGLE_FLAGS --metadata-only"

      if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would submit to Google Play"
        [ "$METADATA_ONLY" = true ] && echo "  [dry-run] Metadata only (no AAB upload)"
        [ "$UPLOAD_SCREENSHOTS" = true ] && echo "  [dry-run] Would upload screenshots"
        [ "$UPLOAD_SUBSCRIPTIONS" = true ] && echo "  [dry-run] Would upload subscription listings"
      else
        python3 "$SCRIPT_DIR/submit_google.py" \
          --action submit \
          --service-account-key "$GOOGLE_KEY_FILE" \
          --package-name "$PACKAGE_NAME" \
          --package-version "$PACKAGE_VERSION" \
          --app-store-dir "$APP_STORE_DIR" \
          $GOOGLE_FLAGS
      fi

      echo ""
      echo "Google Play submission complete."
      ;;

    *)
      echo "Unknown platform: $platform"
      exit 1
      ;;
  esac
done

echo ""
echo "Done."
