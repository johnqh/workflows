#!/bin/bash
# lint-workflows.sh - Validate GitHub Actions workflow files using actionlint
#
# Usage:
#   ./scripts/lint-workflows.sh
#   make lint-workflows

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

log_info() {
    printf '%b[INFO]%b %s\n' "${BLUE}" "${NC}" "$1"
}

log_success() {
    printf '%b[SUCCESS] %s%b\n' "${GREEN}" "$1" "${NC}"
}

log_error() {
    printf '%b[ERROR] %s%b\n' "${RED}" "$1" "${NC}"
}

log_warning() {
    printf '%b[WARNING] %s%b\n' "${YELLOW}" "$1" "${NC}"
}

# Check if actionlint is installed
if ! command -v actionlint &>/dev/null; then
    log_error "actionlint is not installed."
    echo ""
    echo "Install actionlint using one of the following methods:"
    echo ""
    echo "  macOS (Homebrew):"
    echo "    brew install actionlint"
    echo ""
    echo "  Linux (Go install):"
    echo "    go install github.com/rhysd/actionlint/cmd/actionlint@latest"
    echo ""
    echo "  Download binary:"
    echo "    https://github.com/rhysd/actionlint/releases"
    echo ""
    exit 1
fi

log_info "Running actionlint on workflow files in $WORKFLOW_DIR"

if [ ! -d "$WORKFLOW_DIR" ]; then
    log_error "Workflow directory not found: $WORKFLOW_DIR"
    exit 1
fi

# Find all YAML files in the workflows directory
workflow_files=()
for f in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
    [ -f "$f" ] && workflow_files+=("$f")
done

if [ ${#workflow_files[@]} -eq 0 ]; then
    log_warning "No workflow files found in $WORKFLOW_DIR"
    exit 0
fi

log_info "Found ${#workflow_files[@]} workflow file(s):"
for f in "${workflow_files[@]}"; do
    echo "  - $(basename "$f")"
done
echo ""

# Run actionlint
exit_code=0
actionlint "${workflow_files[@]}" || exit_code=$?

if [ "$exit_code" -eq 0 ]; then
    log_success "All workflow files passed actionlint validation"
else
    log_error "actionlint found issues (exit code: $exit_code)"
fi

exit "$exit_code"
