#!/usr/bin/env bash
# Publish ONE package to npm locally, mirroring the `release_npm` job in
# unified-cicd.yml. Intended for BOOTSTRAPPING a brand-new package (npm requires a
# package to exist before a trusted publisher can be attached); once published and
# trusted, all future releases go through CI/OIDC and you never run this again.
#
# Mirrors CI by:
#   - reading npm-access and skip-npm-publish from the package's
#     .github/workflows/ci-cd.yml  (defaults: restricted / false)
#   - auto-detecting bun vs npm (bun.lock), installing deps
#   - building with build:ci if present, else build
#   - skipping if this exact version is already on npm
#   - publishing with `npm publish --access <access>`
#
# Differences from CI (by necessity): it does NOT create a GitHub release/tag, and
# it authenticates as YOU (npm login, 2FA) instead of OIDC — you'll get an OTP
# prompt. The read-only CI token cannot publish.
#
# POSIX sh compatible: run with `bash`, `./script`, or `sh script`.
#
# Usage:
#   scripts/publish-local.sh [package_dir]     # default: current directory
#   DRY_RUN=1 scripts/publish-local.sh [dir]   # print the plan, change nothing
#   OTP=123456 scripts/publish-local.sh [dir]  # pass the 2FA code non-interactively
set -eu

PKG_DIR="${1:-$PWD}"
cd "$PKG_DIR"

[ -f package.json ] || { echo "No package.json in $PKG_DIR" >&2; exit 1; }
command -v npm  >/dev/null 2>&1 || { echo "npm not found"  >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node not found" >&2; exit 1; }

# ── Read the settings from the package's CI workflow ──────────────────────────
WF=".github/workflows/ci-cd.yml"
NPM_ACCESS="restricted"
SKIP="false"
if [ -f "$WF" ]; then
  v=$(grep -E '^[[:space:]]*npm-access:' "$WF" | head -1 | sed -E 's/.*npm-access:[[:space:]]*"?([A-Za-z]+)"?.*/\1/' || true)
  [ -n "${v:-}" ] && NPM_ACCESS="$v"
  v=$(grep -E '^[[:space:]]*skip-npm-publish:' "$WF" | head -1 | sed -E 's/.*skip-npm-publish:[[:space:]]*"?([A-Za-z]+)"?.*/\1/' || true)
  [ -n "${v:-}" ] && SKIP="$v"
else
  echo "warning: no $WF found; using defaults (npm-access=$NPM_ACCESS, skip-npm-publish=$SKIP)" >&2
fi
case "$NPM_ACCESS" in public) ACCESS=public ;; *) ACCESS=restricted ;; esac

NAME=$(node -p "require('./package.json').name || ''")
VER=$(node -p "require('./package.json').version || ''")
PRIV=$(node -p "require('./package.json').private === true")
[ -n "$NAME" ] && [ -n "$VER" ] || { echo "package.json is missing name/version" >&2; exit 1; }

echo "Package  : $NAME@$VER"
echo "Access   : $ACCESS   (from ${WF})"
echo "Manager  : $([ -f bun.lock ] || [ -f bun.lockb ] && echo bun || echo npm)"

if [ "$SKIP" = "true" ]; then
  echo "skip-npm-publish is true for this repo (it's an app, not a library). Aborting." >&2
  exit 1
fi
if [ "$PRIV" = "true" ]; then
  echo "$NAME has \"private\": true — not publishable. Aborting." >&2
  exit 1
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would install deps, build (build:ci||build), then:"
  echo "         npm publish --access $ACCESS"
  exit 0
fi

# ── Must be logged in as a publisher (2FA session, not the read-only token) ───
WHO=$(npm whoami 2>/dev/null || true)
[ -n "$WHO" ] || { echo "Not logged in. Run 'npm login' (2FA account); the read-only CI token cannot publish." >&2; exit 1; }
echo "Publisher: $WHO"

# ── Idempotent: skip if this version is already on npm (same as CI) ───────────
PUBLISHED=$(npm view "$NAME@$VER" version 2>/dev/null || true)
if [ "$PUBLISHED" = "$VER" ]; then
  echo "$NAME@$VER is already on npm — nothing to do."
  exit 0
fi

# ── Install + build (build:ci preferred, like CI) ─────────────────────────────
if [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun; else PM=npm; fi
echo "Installing dependencies ($PM)..."
if [ "$PM" = bun ]; then
  bun install
elif [ -f package-lock.json ]; then
  npm ci
else
  npm install
fi

has_script() { node -e "process.exit(((require('./package.json').scripts||{})['$1'])?0:1)"; }
BUILD=""
if has_script "build:ci"; then BUILD="build:ci"; elif has_script "build"; then BUILD="build"; fi
if [ -n "$BUILD" ]; then
  echo "Building ($PM run $BUILD)..."
  "$PM" run "$BUILD"
else
  echo "No build script; skipping build."
fi

# ── Publish (attached to the terminal so the 2FA OTP prompt works) ────────────
echo "Publishing $NAME@$VER as $ACCESS ..."
if [ -n "${OTP:-}" ]; then
  npm publish --access "$ACCESS" --otp="$OTP"
else
  npm publish --access "$ACCESS"
fi

echo ""
echo "✅ Published $NAME@$VER"
echo "Next (one-time, so CI/OIDC owns future releases):"
echo "  cd ~/projects/workflows && sh scripts/setup-trusted-publishers.sh"
