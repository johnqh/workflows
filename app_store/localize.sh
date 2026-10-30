#!/bin/bash
# Localize app store listing text and screenshot captions.
#
# Translates every file under app_store/screenshots/info/ from the hand-authored
# en/ source into all other languages, using the shared batch translation helper
# (scripts/localize_batch.cjs). Replaces the per-app scripts/localize_store.sh
# wrapper: the Whisperly project slug now comes from info.json instead of being
# hardcoded per app.
#
# Usage:
#   appstore localize [endpoint-url] [options]
#
# Options:
#   --slug <slug>       Override the Whisperly project slug (default: info.json
#                       .localize.slug, else .app.scheme).
#   --api-base <url>    Override the API base (default: info.json .localize.apiBase,
#                       else https://api.whisperly.dev/api/v1/translate/jie9cytr).
#   --no-format         Skip the prettier pass.
#   (any other flags are passed through to localize_batch.cjs, e.g. --batch-limit)
#
# A bare positional URL is treated as the full endpoint (slug already included),
# matching the old `localize:store:local` usage.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

WORKFLOWS_ROOT="$(cd "$WORKFLOWS_DIR/.." && pwd)"
LOCALIZE_BATCH="$WORKFLOWS_ROOT/scripts/localize_batch.cjs"
STORE_LOCALES="$APP_STORE_DIR/screenshots/info"

SLUG=""
API_BASE=""
FULL_URL=""
FORMAT=true
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)      SLUG="$2"; shift 2 ;;
    --api-base)  API_BASE="$2"; shift 2 ;;
    --no-format) FORMAT=false; shift ;;
    http://*|https://*) FULL_URL="$1"; shift ;;
    *)           PASSTHROUGH+=("$1"); shift ;;
  esac
done

if [ ! -f "$LOCALIZE_BATCH" ]; then
  echo "Error: localize_batch.cjs not found at $LOCALIZE_BATCH" >&2
  exit 1
fi
if [ ! -d "$STORE_LOCALES" ]; then
  echo "Error: $STORE_LOCALES not found. Author en/ first." >&2
  exit 1
fi

# Resolve the endpoint URL.
if [ -z "$FULL_URL" ]; then
  [ -z "$SLUG" ]     && SLUG=$(jq -r '.localize.slug // .app.scheme // empty' "$INFO_JSON")
  [ -z "$API_BASE" ] && API_BASE=$(jq -r '.localize.apiBase // "https://api.whisperly.dev/api/v1/translate/jie9cytr"' "$INFO_JSON")
  if [ -z "$SLUG" ]; then
    echo "Error: no translation slug. Set .localize.slug or .app.scheme in info.json, or pass --slug / a full URL." >&2
    exit 1
  fi
  FULL_URL="${API_BASE%/}/${SLUG}"
fi

echo "Translating store text in $STORE_LOCALES"
echo "  endpoint: $FULL_URL"
node "$LOCALIZE_BATCH" "$STORE_LOCALES" "$FULL_URL" "${PASSTHROUGH[@]}"

if [ "$FORMAT" = true ]; then
  echo ""
  echo "Formatting..."
  (cd "$PROJECT_DIR" && npx prettier "$STORE_LOCALES" --write 2>/dev/null) \
    || npx prettier "$STORE_LOCALES" --write 2>/dev/null \
    || echo "  (prettier not available; skipping format)"
fi

echo ""
echo "Done."
