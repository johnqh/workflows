#!/bin/bash
# Shared Xcode Cloud post-clone setup for the RN apps in this ecosystem.
#
# Each app keeps a tiny ios/ci_scripts/ci_post_clone.sh (and macos/…) that fetches
# and runs this, so the real logic lives in one place and cannot drift per app:
#
#   #!/bin/bash
#   set -euo pipefail
#   curl -fsSL https://raw.githubusercontent.com/johnqh/workflows/main/app_store/ci_post_clone.sh -o /tmp/ci_post_clone.sh
#   exec bash /tmp/ci_post_clone.sh ios     # or: macos
#
# Argument 1: platform ("ios" default, or "macos" — macOS deletes Podfile.lock first).
# Env: NPM_TOKEN (private registry auth), NPM_SCOPE (default @sudobility),
#      plus every variable the app's .env.example declares (valued from the
#      Xcode Cloud workflow environment).

set -euo pipefail

PLATFORM="${1:-ios}"
NPM_SCOPE="${NPM_SCOPE:-@sudobility}"

echo "=== Xcode Cloud: $PLATFORM post-clone setup ==="

cd "$CI_PRIMARY_REPOSITORY_PATH"

# --- Install tooling ---
echo "Installing Node.js..."
brew install node || brew upgrade node || true

echo "Installing Bun..."
# Prefer Homebrew: the bun.sh installer pulls from
# release-assets.githubusercontent.com, which the Xcode Cloud runner cannot
# always resolve ("curl: (6) Could not resolve host").
brew install bun || {
  echo "brew install bun failed; falling back to bun.sh installer..."
  for i in 1 2 3; do
    curl -fsSL https://bun.sh/install | bash && break
    echo "bun.sh install attempt $i failed; retrying in 5s..."
    sleep 5
  done
}
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$(brew --prefix)/bin:$PATH"
echo "Bun version: $(bun --version)"

# --- Configure npm registry for private packages ---
echo "Configuring npm registry for $NPM_SCOPE..."
cat > "$HOME/.npmrc" << EOF
${NPM_SCOPE}:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN:-}
EOF

# --- Install JS dependencies ---
echo "Installing JS dependencies..."
bun install --frozen-lockfile

# --- Write environment variables ---
# Every name .env.example declares, valued from the workflow's environment. The
# names are read from .env.example (not a hand-kept list) so this cannot fall
# behind what the app reads. A name the workflow does not set is written blank,
# which the app reads as "not configured". A store build is never a dev build
# unless the workflow says so.
export VITE_DEV_MODE="${VITE_DEV_MODE:-false}"
if [ -f .env.example ]; then
  : > .env
  for name in $(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example); do
    printf '%s=%s\n' "$name" "$(printenv "$name" || true)" >> .env
  done
  echo "Wrote .env with $(wc -l < .env | tr -d ' ') variables."
fi

# --- Install CocoaPods ---
echo "Installing CocoaPods dependencies ($PLATFORM)..."
if [ "$PLATFORM" = "macos" ]; then
  cd macos
  rm -f Podfile.lock
else
  cd ios
fi
pod install

echo "=== $PLATFORM post-clone setup complete ==="
