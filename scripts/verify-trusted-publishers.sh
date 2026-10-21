#!/usr/bin/env bash
# Verify npm Trusted Publisher (OIDC / GitHub Actions) configuration for every
# publishable @sudobility package in the monorepo.
#
# POSIX sh compatible: run with `bash`, `./script`, or `sh script`.
# Requires a logged-in npm account (`npm login`, npm >= 11.5.1). `npm trust list`
# is read-only (no 2FA / no publish), so this is safe to re-run.
#
# Usage: scripts/verify-trusted-publishers.sh [projects_dir]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="${1:-$(cd "$REPO_ROOT/.." && pwd)}"
EXPECT_WORKFLOW="ci-cd.yml"
EXPECT_OWNER="johnqh"
TAB="$(printf '\t')"

command -v npm >/dev/null 2>&1 || { echo "npm not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/trustverify.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

for d in "$PROJECTS_DIR"/*/; do
  d="${d%/}"
  [ -d "$d/.git" ] || continue
  pj="$(git -C "$d" show HEAD:package.json 2>/dev/null)" || continue
  [ -n "$pj" ] || continue
  name="$(printf '%s' "$pj" | python3 -c 'import sys,json
try:
    p=json.load(sys.stdin); n=p.get("name")
    print(n) if n and p.get("private") is not True else None
except Exception:
    pass')"
  [ -n "$name" ] && printf '%s\t%s\n' "$name" "$(basename "$d")" >> "$TMP"
done
sort -o "$TMP" "$TMP"

configured=0; none=0; mismatch=0; errors=0
none_list=""

while IFS="$TAB" read -r pkg dir; do
  [ -n "$pkg" ] || continue
  out="$(npm trust list "$pkg" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qiE 'no trusted|none|not configured'; then
      echo "NONE   $pkg"; none=$((none + 1)); none_list="$none_list $pkg"
    else
      echo "ERROR  $pkg :: $(printf '%s' "$out" | tail -1)"; errors=$((errors + 1))
    fi
    continue
  fi
  if printf '%s' "$out" | grep -qiE 'github'; then
    configured=$((configured + 1))
    if printf '%s' "$out" | grep -q "$EXPECT_WORKFLOW" && printf '%s' "$out" | grep -qi "${EXPECT_OWNER}/${dir}"; then
      echo "OK     $pkg"
    else
      echo "CHECK  $pkg (configured; verify repo=${EXPECT_OWNER}/${dir} workflow=${EXPECT_WORKFLOW})"
      mismatch=$((mismatch + 1))
    fi
  elif printf '%s' "$out" | grep -qiE 'no trusted|none|not configured'; then
    echo "NONE   $pkg"; none=$((none + 1)); none_list="$none_list $pkg"
  else
    echo "CHECK  $pkg :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)"
    mismatch=$((mismatch + 1))
  fi
done < "$TMP"

echo ""
echo "==== configured=$configured  none=$none  needs-check=$mismatch  errors=$errors ===="
[ -n "$none_list" ] && { echo "NOT configured:"; for p in $none_list; do echo "  $p"; done; }
exit 0
