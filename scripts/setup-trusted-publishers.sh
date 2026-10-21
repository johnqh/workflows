#!/usr/bin/env bash
# Bulk-configure npm Trusted Publishers (GitHub Actions, caller workflow
# ci-cd.yml) for every publishable @sudobility package in the monorepo.
#
# POSIX sh compatible: run with `bash`, `./script`, or `sh script`.
#
# npm REQUIRES interactive 2FA for `npm trust` and forbids bypass-2FA tokens — by
# design, so a stolen token cannot set up publishing. Run this yourself with a
# logged-in, 2FA-capable account (NOT the read-only CI token):
#
#   1. npm login                      # npm >= 11.5.1
#   2. scripts/setup-trusted-publishers.sh
#      On the FIRST package npm prompts for 2FA; on the npm website click
#      "skip 2FA for the next 5 minutes" so the rest run unattended.
#      ~80 packages fit per 5-min window; if it re-prompts partway, approve again.
#   3. Re-running is safe: already-configured packages report "exists (skip)".
#
# Env:
#   DRY_RUN=1   print the commands only, change nothing (no auth needed)
#   MAX=N       process at most N packages (e.g. MAX=1 for a first probe)
#
# Usage: scripts/setup-trusted-publishers.sh [projects_dir]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="${1:-$(cd "$REPO_ROOT/.." && pwd)}"
WORKFLOW="ci-cd.yml"
OWNER="johnqh"
DRY="${DRY_RUN:-0}"
MAX="${MAX:-0}"
TAB="$(printf '\t')"

command -v npm >/dev/null 2>&1 || { echo "npm not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/trustpub.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Write "<pkg_name>\t<dir>" for every sibling repo whose tracked package.json has
# a name and is not private (i.e. actually gets published).
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

# Auth precheck (skipped for dry runs) so we fail fast instead of erroring 120x.
if [ "$DRY" != "1" ]; then
  who="$(npm whoami 2>/dev/null || true)"
  if [ -z "$who" ]; then
    echo "Not logged in to npm. Run 'npm login' with a 2FA-capable account first." >&2
    echo "(The read-only CI token cannot configure trusted publishers.)" >&2
    exit 1
  fi
  echo "Logged in as: $who"
  echo ""
fi

if [ "$DRY" != "1" ]; then
  echo "On the FIRST package npm opens a browser/OTP prompt — complete 2FA and, on"
  echo "the npm website, enable 'skip 2FA for the next 5 minutes' so the rest run"
  echo "unattended. If it re-prompts partway through 120 packages, approve again."
  echo ""
fi

# Read the package list on FD 3 so `npm trust` keeps the terminal on stdin/stdout.
# Do NOT capture npm's output: capturing makes npm see a non-TTY and fail with
# EOTP ("one-time password required") instead of running the interactive 2FA flow.
n=0
while IFS="$TAB" read -r pkg dir <&3; do
  [ -n "$pkg" ] || continue
  if [ "$MAX" != "0" ] && [ "$n" -ge "$MAX" ]; then break; fi
  n=$((n + 1))
  if [ "$DRY" = "1" ]; then
    echo "DRY: npm trust github $pkg --repo ${OWNER}/${dir} --file $WORKFLOW --allow-publish --yes"
    continue
  fi
  echo "--- $pkg ---"
  if npm trust github "$pkg" --repo "${OWNER}/${dir}" --file "$WORKFLOW" --allow-publish --yes; then
    echo "ok     $pkg"
  else
    echo "FAIL   $pkg  (if npm said 'already exists', it is already configured)"
  fi
  sleep 2
done 3< "$TMP"

echo ""
echo "Done. Verify with: scripts/verify-trusted-publishers.sh"
