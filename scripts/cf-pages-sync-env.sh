#!/bin/bash
# Sync environment variables from a .env file to Cloudflare Pages (production + preview)
# Usage: ./cf-pages-sync-env.sh <project-name> <env-file> [--production-only | --preview-only]
#
# Examples:
#   ./cf-pages-sync-env.sh heavymath-app .env
#   ./cf-pages-sync-env.sh heavymath-app .env --preview-only
#   ./cf-pages-sync-env.sh heavymath-app .env --production-only

set -euo pipefail

show_usage() {
  cat <<'USAGE'
Usage: cf-pages-sync-env.sh <project-name> <env-file> [--production-only | --preview-only]

Reads a .env file and pushes all non-empty variables as secrets to a
Cloudflare Pages project via wrangler. By default, sets secrets for
both production and preview environments.

Arguments:
  project-name          Cloudflare Pages project name
  env-file              Path to .env file with KEY=VALUE pairs

Options:
  --production-only     Only set secrets for the production environment
  --preview-only        Only set secrets for the preview environment

Prerequisites:
  - wrangler must be installed (bun add -g wrangler)
  - You must be logged in (wrangler login)

Examples:
  cf-pages-sync-env.sh heavymath-app .env
  cf-pages-sync-env.sh heavymath-app .env.production --production-only
  cf-pages-sync-env.sh heavymath-app .env --preview-only
USAGE
}

if [[ $# -lt 2 ]]; then
  show_usage
  exit 1
fi

PROJECT="$1"
ENV_FILE="$2"
MODE="${3:-both}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: File '$ENV_FILE' not found"
  exit 1
fi

if ! command -v wrangler &>/dev/null; then
  echo "Error: wrangler is not installed. Install with: bun add -g wrangler"
  exit 1
fi

count=0

while IFS='=' read -r key value; do
  # Skip comments and empty lines
  [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

  # Remove surrounding quotes from value
  value="${value%\"}"
  value="${value#\"}"

  # Skip empty values
  [[ -z "$value" ]] && continue

  echo "Setting $key..."

  if [[ "$MODE" != "--preview-only" ]]; then
    echo "$value" | wrangler pages secret put "$key" --project-name="$PROJECT" --env=production 2>&1 | tail -1
  fi

  if [[ "$MODE" != "--production-only" ]]; then
    echo "$value" | wrangler pages secret put "$key" --project-name="$PROJECT" --env=preview 2>&1 | tail -1
  fi

  ((count++))
done < "$ENV_FILE"

echo ""
echo "Done. Set $count variables for project '$PROJECT' (mode: ${MODE/--/})."
