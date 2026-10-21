#!/usr/bin/env bash
# Rotate the NPM_TOKEN GitHub Actions secret on every johnqh/* repo in the
# monorepo to the token currently in ~/.npmrc.
#
# POSIX sh compatible: run with `bash`, `./script`, or `sh script`.
# The token is read from ~/.npmrc at runtime and piped straight into `gh` — never
# echoed. Idempotent (overwrite). Requires: gh authenticated with repo scope.
#
# Usage: scripts/rotate-npm-token-github.sh [projects_dir]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="${1:-$(cd "$REPO_ROOT/.." && pwd)}"

command -v gh >/dev/null 2>&1 || { echo "gh not found" >&2; exit 1; }

# Print the npm token from ~/.npmrc (never stored/echoed elsewhere).
get_npm_token() {
  t="$(sed -nE 's#.*_authToken=(.*)$#\1#p' "$HOME/.npmrc" | head -1 | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  [ -n "$t" ] || { echo "No _authToken found in ~/.npmrc" >&2; return 1; }
  printf '%s' "$t"
}

# Fail fast if the token is missing (don't 403 across every repo).
get_npm_token >/dev/null || exit 1

TMP="$(mktemp "${TMPDIR:-/tmp}/npmrotate.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

for d in "$PROJECTS_DIR"/*/; do
  d="${d%/}"
  [ -d "$d/.git" ] || continue
  u="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
  case "$u" in
    *github.com*) echo "$u" | sed -E 's#.*github.com[:/]+##; s#\.git$##' >> "$TMP" ;;
  esac
done
sort -u -o "$TMP" "$TMP"

ok=0; fail=0; failed=""
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if get_npm_token | gh secret set NPM_TOKEN --repo "$slug" --app actions >/dev/null 2>&1; then
    echo "ok    $slug"; ok=$((ok + 1))
  else
    echo "FAIL  $slug"; fail=$((fail + 1)); failed="$failed $slug"
  fi
done < "$TMP"

echo ""
echo "GitHub NPM_TOKEN rotation: $ok ok, $fail failed"
[ -n "$failed" ] && { echo "FAILED:"; for s in $failed; do echo "  $s"; done; }
exit 0
