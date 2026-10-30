#!/bin/bash
# init — scaffold an app_store/ config in a project that does not have one yet.
#
# Creates the config files (info.json, screens.json, paths.json, languages.json),
# the English source listing (screenshots/info/en/{info,screens}.json), .env.example
# and a .gitignore. Fills identity fields from flags; leaves store metadata as
# TODO placeholders to edit, then run `appstore doctor`.
#
# Usage:
#   appstore init --name "My App" --bundle-id com.example.myapp [options]
#
# Options:
#   --name <name>          App display name (required).
#   --bundle-id <id>       iOS bundle id / Android package name (required).
#   --scheme <scheme>      URL scheme + translation slug (default: lowercased name).
#   --metro-port <port>    Metro port for RN apps (default: 8081).
#   --dir <project-dir>    Target project (default: current directory).
#   --stores <list>        Comma-separated: apple,google,microsoft (default: all).
#   --frames-from <path>   Copy frames/ from another app_store dir.
#   --force                Overwrite an existing app_store/.

set -eo pipefail

NAME="" BUNDLE_ID="" SCHEME="" METRO_PORT="8081"
TARGET_DIR="$PWD" STORES="apple,google,microsoft" FRAMES_FROM="" FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --bundle-id)   BUNDLE_ID="$2"; shift 2 ;;
    --scheme)      SCHEME="$2"; shift 2 ;;
    --metro-port)  METRO_PORT="$2"; shift 2 ;;
    --dir)         TARGET_DIR="$2"; shift 2 ;;
    --stores)      STORES="$2"; shift 2 ;;
    --frames-from) FRAMES_FROM="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    *)             echo "Unknown option: $1"; exit 1 ;;
  esac
done

[ -z "$NAME" ] && { echo "Error: --name required."; exit 1; }
[ -z "$BUNDLE_ID" ] && { echo "Error: --bundle-id required."; exit 1; }
[ -z "$SCHEME" ] && SCHEME="$(echo "$NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"

AS="$TARGET_DIR/app_store"
if [ -d "$AS" ] && [ "$FORCE" = false ]; then
  echo "Error: $AS already exists (use --force to overwrite config files)."
  exit 1
fi

want_store() { case ",$STORES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

mkdir -p "$AS/screenshots/info/en" "$AS/frames" "$AS/.keys"

# ── info.json ─────────────────────────────────────────────────────────────────
APPLE_BLOCK="" ; GOOGLE_BLOCK="" ; MS_BLOCK=""
want_store apple && APPLE_BLOCK=',
  "appleAppStore": { "primaryCategory": "TODO", "pricing": { "priceTier": 0, "availableInAllTerritories": true },
    "platforms": { "ios": { "minimumOsVersion": "15.1" } } }'
want_store google && GOOGLE_BLOCK=',
  "googlePlay": { "defaultLanguage": "en-US", "applicationCategory": "TODO",
    "pricing": { "free": true, "inAppPurchases": false } }'
want_store microsoft && MS_BLOCK=',
  "microsoftStore": { "category": "TODO",
    "properties": { "privacyPolicyUrl": "TODO", "websiteUrl": "TODO" },
    "systemRequirements": { "minimumOs": "Windows 10 version 17763.0", "architecture": ["x64", "ARM64"] } }'

cat > "$AS/info.json" <<EOF
{
  "metadata": { "version": "1.0", "lastUpdated": "$(date +%Y-%m-%d)", "whatsNew": "Initial release." },
  "capture": { "loopOrder": "languages_first" },
  "build": { "metroPort": $METRO_PORT, "ios": { "appName": "$NAME", "workspace": "$NAME.xcworkspace", "scheme": "$NAME" } },
  "localize": { "slug": "$SCHEME" },
  "app": {
    "name": "$NAME", "bundleId": "$BUNDLE_ID", "packageName": "$BUNDLE_ID",
    "scheme": "$SCHEME", "developer": "TODO", "website": "TODO",
    "supportUrl": "TODO", "privacyPolicyUrl": "TODO", "contactEmail": "TODO"
  },
  "supportedLanguages": [ { "code": "en", "name": "English", "primary": true } ]$APPLE_BLOCK$GOOGLE_BLOCK$MS_BLOCK
}
EOF

# ── screens.json (sensible RN default: one phone + one tablet per platform) ─────
cat > "$AS/screens.json" <<'EOF'
{
  "ios": {
    "iphone_6_9": { "simulator": "iPhone 16 Plus", "runtime": "iOS-18-6", "resolution": "1290x2796" }
  },
  "ipados": {
    "ipad_13": { "simulator": "iPad Air 13-inch (M3)", "runtime": "iOS-18-6", "resolution": "2048x2732", "store_resolution": "2732x2048" }
  },
  "android": {
    "android_phone": { "emulator": "Pixel_9_Pro_XL", "resolution": "1344x2992", "store_resolution": "1080x1920" }
  }
}
EOF

# ── paths.json / languages.json ────────────────────────────────────────────────
cat > "$AS/paths.json" <<'EOF'
["/"]
EOF

cat > "$AS/languages.json" <<'EOF'
["de","en","es","fr","it","ja","ko","pt","ru","sv","th","uk","vi","zh","zh-Hant"]
EOF

# ── English source listing ─────────────────────────────────────────────────────
cat > "$AS/screenshots/info/en/info.json" <<EOF
{
  "locale": "en",
  "appleAppStore": { "title": "$NAME", "subtitle": "TODO (<=30 chars)", "keywords": "TODO",
    "promotionalText": "TODO (<=170 chars)", "description": "TODO", "whatsNew": "Initial release." },
  "googlePlay": { "title": "$NAME", "shortDescription": "TODO (<=80 chars)", "fullDescription": "TODO", "tags": [] },
  "microsoftStore": { "productName": "$NAME", "description": "TODO", "shortDescription": "TODO", "searchTerms": "TODO", "whatsNew": "Initial release." }
}
EOF

cat > "$AS/screenshots/info/en/screens.json" <<'EOF'
[
  { "title": "TODO", "text": "One caption per entry in paths.json" }
]
EOF

# ── .env.example / .gitignore ──────────────────────────────────────────────────
cat > "$AS/.env.example" <<'EOF'
# Copy to .env and fill in. See workflows/app_store README for details.
APPLE_API_KEY_ID=
APPLE_API_ISSUER_ID=
GOOGLE_PLAY_SERVICE_ACCOUNT_KEY=.keys/google-play.json
# Microsoft Partner Center (Azure AD app registration)
MS_TENANT_ID=
MS_CLIENT_ID=
MS_CLIENT_SECRET=
MS_SELLER_APP_ID=
EOF

cat > "$AS/.gitignore" <<'EOF'
.env
.keys/
builds/
screenshots/raw/
screenshots/store/
.metro.pid
.metro.log
EOF

# ── project wrapper (scripts/store.sh) ────────────────────────────────────────
mkdir -p "$TARGET_DIR/scripts"
cat > "$TARGET_DIR/scripts/store.sh" <<'EOF'
#!/bin/bash
# Run the shared app_store `store` orchestrator against this project.
#   RN:     bun run store -- --screenshots:iphone:en
#   native: ./scripts/store.sh --submit:appstore
# APP_STORE_DIR may be preset (e.g. a 2nd product) and is honored if so.
set -eo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${APP_STORE_DIR:-}" ]; then
  export APP_STORE_DIR="$(cd "$APP_STORE_DIR" && pwd)"
else
  export APP_STORE_DIR="$PROJECT_DIR/app_store"
fi
export WORKFLOWS_DIR="${WORKFLOWS_DIR:-$HOME/projects/workflows/app_store}"
exec "$WORKFLOWS_DIR/store" "$@"
EOF
chmod +x "$TARGET_DIR/scripts/store.sh"
echo "Wrote $TARGET_DIR/scripts/store.sh"
if [ -f "$TARGET_DIR/package.json" ]; then
  echo "  → add to package.json scripts:  \"store\": \"bash scripts/store.sh\""
fi

# ── frames ─────────────────────────────────────────────────────────────────────
if [ -n "$FRAMES_FROM" ] && [ -d "$FRAMES_FROM" ]; then
  cp -R "$FRAMES_FROM/." "$AS/frames/"
  echo "Copied frames from $FRAMES_FROM"
else
  echo "(No frames copied — add device frame PNGs + frames/frames.json, or use --frames-from.)"
fi

echo ""
echo "Scaffolded $AS"
echo "Next:"
echo "  1. Edit app_store/info.json and screenshots/info/en/* (replace TODOs)."
echo "  2. cp app_store/.env.example app_store/.env  and add credentials to .keys/."
echo "  3. appstore doctor"
echo "  4. appstore localize && appstore screenshots && appstore submit"
