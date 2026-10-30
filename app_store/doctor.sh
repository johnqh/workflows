#!/bin/bash
# doctor — validate an app_store/ config before a capture or submit run.
#
# Checks config files, credentials, per-language listing text, and the store
# length limits that otherwise fail late (e.g. Google Play shortDescription > 80
# chars → 403 on submit). Errors exit non-zero; warnings do not.
#
# Usage:
#   appstore doctor [--fix-hints]

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"
require_jq

ERRORS=0
WARNINGS=0
err()  { echo "  ✗ ERROR:   $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  ! WARNING: $*"; WARNINGS=$((WARNINGS + 1)); }
ok()   { echo "  ✓ $*"; }

echo "Validating $APP_STORE_DIR"
echo ""

# ── Core config files ─────────────────────────────────────────────────────────
echo "Config files:"
for f in info.json screens.json paths.json languages.json; do
  if [ ! -f "$APP_STORE_DIR/$f" ]; then
    err "$f missing"
  elif ! jq empty "$APP_STORE_DIR/$f" 2>/dev/null; then
    err "$f is not valid JSON"
  else
    ok "$f"
  fi
done
[ "$ERRORS" -gt 0 ] && { echo ""; echo "Cannot continue: fix the config files above."; exit 1; }

# Which stores does this app target?
HAS_APPLE=$(jq -r 'if (.appleAppStore != null) then "yes" else "no" end' "$INFO_JSON")
HAS_GOOGLE=$(jq -r 'if (.googlePlay != null) then "yes" else "no" end' "$INFO_JSON")
HAS_MS=$(jq -r 'if (.microsoftStore != null) then "yes" else "no" end' "$INFO_JSON")
echo ""
echo "Targeted stores: apple=$HAS_APPLE google=$HAS_GOOGLE microsoft=$HAS_MS"

# ── Credentials ───────────────────────────────────────────────────────────────
echo ""
echo "Credentials:"
if [ -f "$APP_STORE_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$APP_STORE_DIR/.env"
  ok ".env present"
else
  warn ".env missing (needed for submit; not needed for screenshots)"
fi
if [ "$HAS_APPLE" = "yes" ]; then
  [ -f "$APP_STORE_DIR/.keys/apple.p8" ] && ok ".keys/apple.p8" || warn ".keys/apple.p8 missing (Apple submit will fail)"
  [ -n "${APPLE_API_KEY_ID:-}" ]   || warn "APPLE_API_KEY_ID not set in .env"
  [ -n "${APPLE_API_ISSUER_ID:-}" ] || warn "APPLE_API_ISSUER_ID not set in .env"
  [ -f "$APP_STORE_DIR/ExportOptions.plist" ] && ok "ExportOptions.plist" || warn "ExportOptions.plist missing (iOS export)"
fi
if [ "$HAS_GOOGLE" = "yes" ]; then
  KEY="${GOOGLE_PLAY_SERVICE_ACCOUNT_KEY:-.keys/google-play.json}"
  [ -f "$APP_STORE_DIR/$KEY" ] && ok "$KEY" || warn "$KEY missing (Google submit will fail)"
fi
if [ "$HAS_MS" = "yes" ]; then
  if [ -n "${MS_TENANT_ID:-}" ] && [ -n "${MS_CLIENT_ID:-}" ] && [ -n "${MS_CLIENT_SECRET:-}" ] && [ -n "${MS_SELLER_APP_ID:-}" ]; then
    ok "Microsoft Partner Center credentials"
  else
    warn "Microsoft creds incomplete (need MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MS_SELLER_APP_ID in .env)"
  fi
fi

# ── Frames referenced by screens exist ────────────────────────────────────────
echo ""
echo "Device frames:"
FRAMES_JSON="$APP_STORE_DIR/frames/frames.json"
if [ -f "$FRAMES_JSON" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$APP_STORE_DIR/frames/$f" ] && ok "$f" || err "frame file $f missing"
  done < <(jq -r '.frames[]?.file // empty' "$FRAMES_JSON")
else
  warn "frames/frames.json missing (compose will skip framing)"
fi

# ── Per-language listing text + store length limits ───────────────────────────
echo ""
echo "Localized listing text:"
INFO_DIR="$APP_STORE_DIR/screenshots/info"
NPATHS=$(jq 'length' "$APP_STORE_DIR/paths.json")

check_len() { # label value max [severity: err|warn]
  local label="$1" value="$2" max="$3" sev="${4:-err}"
  local n=${#value}
  if [ -n "$value" ] && [ "$n" -gt "$max" ]; then
    if [ "$sev" = "warn" ]; then
      warn "[$LANG] $label is $n chars (max $max)"
    else
      err "[$LANG] $label is $n chars (max $max)"
    fi
  fi
}

while IFS= read -r lang; do
  [ -z "$lang" ] && continue
  LANG="$lang"
  linfo="$INFO_DIR/$lang/info.json"
  lscreens="$INFO_DIR/$lang/screens.json"
  if [ ! -f "$linfo" ]; then
    warn "[$lang] screenshots/info/$lang/info.json missing"
    continue
  fi
  jq empty "$linfo" 2>/dev/null || { err "[$lang] info.json invalid JSON"; continue; }

  if [ "$HAS_APPLE" = "yes" ]; then
    check_len "Apple subtitle"        "$(jq -r '.appleAppStore.subtitle // ""' "$linfo")"        30
    check_len "Apple promotionalText" "$(jq -r '.appleAppStore.promotionalText // ""' "$linfo")" 170
    # Over-length keywords are auto-trimmed by submit_apple.py (last whole
    # keyword within 100 chars) — a warning (some keywords dropped), not fatal.
    check_len "Apple keywords"        "$(jq -r '.appleAppStore.keywords // ""' "$linfo")"        100 warn
    check_len "Apple description"     "$(jq -r '.appleAppStore.description // ""' "$linfo")"      4000
  fi
  if [ "$HAS_GOOGLE" = "yes" ]; then
    check_len "Play title"            "$(jq -r '.googlePlay.title // ""' "$linfo")"              30
    check_len "Play shortDescription" "$(jq -r '.googlePlay.shortDescription // ""' "$linfo")"   80
    check_len "Play fullDescription"  "$(jq -r '.googlePlay.fullDescription // ""' "$linfo")"    4000
  fi
  if [ "$HAS_MS" = "yes" ]; then
    check_len "MS shortDescription"   "$(jq -r '.microsoftStore.shortDescription // ""' "$linfo")" 1000
    check_len "MS description"        "$(jq -r '.microsoftStore.description // ""' "$linfo")"       10000
  fi

  # Caption count should match the number of screenshot paths.
  if [ -f "$lscreens" ]; then
    ncap=$(jq 'length' "$lscreens" 2>/dev/null || echo 0)
    [ "$ncap" = "$NPATHS" ] || warn "[$lang] screens.json has $ncap captions but paths.json has $NPATHS screenshots"
  else
    warn "[$lang] screens.json (captions) missing"
  fi
done < <(jq -r '.[]' "$APP_STORE_DIR/languages.json")

[ "$ERRORS" -eq 0 ] && ok "no listing-text errors"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────"
echo "Doctor: $ERRORS error(s), $WARNINGS warning(s)."
[ "$ERRORS" -gt 0 ] && exit 1 || exit 0
