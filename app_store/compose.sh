#!/bin/bash
# Compose store-ready screenshots from raw captures.
#
# Wraps compose.py with project path resolution.
# Requires Python 3 and Pillow (pip3 install Pillow).
#
# Usage:
#   compose.sh [options]
#
# Options are forwarded to compose.py:
#   --lang <code>      Process single language (default: all).
#   --device <key>     Process single device (default: all).
#   --seq <n>          Process single sequence number.
#   --color <name>     Background color (blue|red|orange|green|purple|teal|pink|slate).
#   --frames-dir <p>   Path to device frame PNGs.
#   --force            Overwrite existing output files.
#   --dry-run          Print actions without compositing.

set -eo pipefail

source "${WORKFLOWS_DIR:-$(dirname "$0")}/_helpers.sh"

# Check Python 3
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required."
  exit 1
fi

# Check Pillow
if ! python3 -c "import PIL" 2>/dev/null; then
  echo "Error: Pillow is required. Install with: pip3 install Pillow"
  exit 1
fi

echo "══════════════════════════════════════════════════════════════"
echo "  COMPOSING STORE SCREENSHOTS"
echo "══════════════════════════════════════════════════════════════"
echo ""

python3 "$SCRIPT_DIR/compose.py" \
  --app-store-dir "$APP_STORE_DIR" \
  "$@"
