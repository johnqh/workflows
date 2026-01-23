#!/bin/bash

# push_projects.sh - Reusable script to update, validate, version bump, and push projects
#
# This script is meant to be sourced by a project-specific script that defines:
#   PROJECTS - Array of "path:wait_after_seconds" entries
#
# Usage in your project's push_all.sh:
#   #!/bin/bash
#   PROJECTS=(
#       "../types:0"
#       "../design_system:0"
#       "../mail_box:0"
#   )
#   source /path/to/workflows/scripts/push_projects.sh
#
# Or call directly with --projects-file:
#   ./push_projects.sh --projects-file ./projects.txt
#
# Command line options:
#   --force, -f         Force version bump on all projects even without changes
#   --subpackages, -s   Also process sub-packages in /packages directories
#   --projects-file     Read projects from a file (one per line, format: path:delay)
#   --help, -h          Show help message
#   --starting-project  Skip projects until reaching the specified project name

set -e  # Exit on error
set -u  # Exit on undefined variable

# Disable interactive pager for git commands
export GIT_PAGER=cat

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[38;5;208m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global flags
FORCE_MODE=false
SUBPACKAGES_MODE=false
PROJECTS_FILE=""
STARTING_PROJECT=""

# Package manager for current project (detected per-project)
PKG_MANAGER=""
PKG_LOCKFILE=""

# Detect package manager based on lockfile
detect_package_manager() {
    local project_dir="$1"

    if [ -f "$project_dir/bun.lock" ] || [ -f "$project_dir/bun.lockb" ]; then
        PKG_MANAGER="bun"
        PKG_LOCKFILE="bun.lock"
    elif [ -f "$project_dir/pnpm-lock.yaml" ]; then
        PKG_MANAGER="pnpm"
        PKG_LOCKFILE="pnpm-lock.yaml"
    elif [ -f "$project_dir/yarn.lock" ]; then
        PKG_MANAGER="yarn"
        PKG_LOCKFILE="yarn.lock"
    elif [ -f "$project_dir/package-lock.json" ]; then
        PKG_MANAGER="npm"
        PKG_LOCKFILE="package-lock.json"
    else
        # Default to npm if no lockfile found
        PKG_MANAGER="npm"
        PKG_LOCKFILE="package-lock.json"
    fi

    log_info "Detected package manager: $PKG_MANAGER (lockfile: $PKG_LOCKFILE)"
}

# Run package manager install command
pm_install() {
    local packages=("$@")

    case "$PKG_MANAGER" in
        bun)
            if [ ${#packages[@]} -eq 0 ]; then
                bun install
            else
                bun add "${packages[@]}"
            fi
            ;;
        pnpm)
            if [ ${#packages[@]} -eq 0 ]; then
                pnpm install
            else
                pnpm add "${packages[@]}"
            fi
            ;;
        yarn)
            if [ ${#packages[@]} -eq 0 ]; then
                yarn install
            else
                yarn add "${packages[@]}"
            fi
            ;;
        npm|*)
            if [ ${#packages[@]} -eq 0 ]; then
                npm install --legacy-peer-deps
            else
                npm install "${packages[@]}" --save-exact=false --legacy-peer-deps
            fi
            ;;
    esac
}

# Run package manager script
pm_run() {
    local script="$1"
    shift

    case "$PKG_MANAGER" in
        bun)
            if [ $# -gt 0 ]; then
                bun run "$script" "$@"
            else
                bun run "$script"
            fi
            ;;
        pnpm)
            if [ $# -gt 0 ]; then
                pnpm run "$script" "$@"
            else
                pnpm run "$script"
            fi
            ;;
        yarn)
            if [ $# -gt 0 ]; then
                yarn run "$script" "$@"
            else
                yarn run "$script"
            fi
            ;;
        npm|*)
            if [ $# -gt 0 ]; then
                npm run "$script" -- "$@"
            else
                npm run "$script"
            fi
            ;;
    esac
}

# Run package manager exec (npx equivalent)
pm_exec() {
    local cmd="$1"
    shift

    case "$PKG_MANAGER" in
        bun)
            if [ $# -gt 0 ]; then
                bunx "$cmd" "$@"
            else
                bunx "$cmd"
            fi
            ;;
        pnpm)
            if [ $# -gt 0 ]; then
                pnpm exec "$cmd" "$@"
            else
                pnpm exec "$cmd"
            fi
            ;;
        yarn)
            if [ $# -gt 0 ]; then
                yarn exec "$cmd" "$@"
            else
                yarn exec "$cmd"
            fi
            ;;
        npm|*)
            if [ $# -gt 0 ]; then
                npx "$cmd" "$@"
            else
                npx "$cmd"
            fi
            ;;
    esac
}

# Bump version using package manager
pm_version_bump() {
    case "$PKG_MANAGER" in
        bun)
            # Bun doesn't have version command, use npm
            npm version patch --no-git-tag-version
            ;;
        pnpm)
            # pnpm uses npm version under the hood
            npm version patch --no-git-tag-version
            ;;
        yarn)
            yarn version --patch --no-git-tag-version
            ;;
        npm|*)
            npm version patch --no-git-tag-version
            ;;
    esac
}

# Ensure NPM_TOKEN is set for private package access
if [ -z "${NPM_TOKEN:-}" ]; then
    if [ -f "$HOME/.npmrc" ]; then
        EXTRACTED_TOKEN=$(grep '_authToken=' "$HOME/.npmrc" 2>/dev/null | sed 's/.*_authToken=//' | head -1)
        if [ -n "$EXTRACTED_TOKEN" ]; then
            export NPM_TOKEN="$EXTRACTED_TOKEN"
        fi
    fi
fi

# Log functions (using printf for portability)
log_info() {
    printf '%b[INFO]%b %s\n' "${BLUE}" "${NC}" "$1"
}

log_success() {
    printf '%b[SUCCESS] %s%b\n' "${GREEN}" "$1" "${NC}"
}

log_warning() {
    printf '%b[WARNING] %s%b\n' "${ORANGE}" "$1" "${NC}"
}

log_error() {
    printf '%b[ERROR] %s%b\n' "${RED}" "$1" "${NC}"
}

log_section() {
    printf '\n%b========================================%b\n' "${BLUE}" "${NC}"
    printf '%b%s%b\n' "${BLUE}" "$1" "${NC}"
    printf '%b========================================%b\n\n' "${BLUE}" "${NC}"
}

# Show help message
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Update, validate, version bump, and push all projects defined in PROJECTS array.

This script should be sourced by a project-specific script that defines:
  PROJECTS - Array of "path:wait_after_seconds" entries

LOGIC:
    1. Detect package manager (bun, pnpm, yarn, npm) based on lockfile
    2. Always update @sudobility dependencies to latest
    3. Check if there are any changed files (including package.json)
    4. If changes exist (or --force): validate, bump version, update lock, commit, push
    5. If no changes: skip to next package

SUPPORTED PACKAGE MANAGERS:
    - bun   (detected via bun.lock or bun.lockb)
    - pnpm  (detected via pnpm-lock.yaml)
    - yarn  (detected via yarn.lock)
    - npm   (detected via package-lock.json, or as default)

OPTIONS:
    --force, -f           Force version bump on all projects even without changes
    --subpackages, -s     Also process sub-packages in /packages directories
    --projects-file       Read projects from a file (one per line, format: path:delay)
    --starting-project    Skip projects until reaching the specified project name
    --help, -h            Show this help message

EXAMPLES:
    # In your push_all.sh:
    PROJECTS=("../types:0" "../lib:0" "../app:0")
    source /path/to/push_projects.sh

    # Or with a projects file:
    ./push_projects.sh --projects-file ./projects.txt

    # Skip projects until reaching a specific one:
    ./push_projects.sh --projects-file ./projects.txt --starting-project lib
    # If projects are [types, lib, app], this skips types and starts from lib

EOF
    exit 0
}

# Get all @sudobility packages from package.json (dependencies and devDependencies)
get_sudobility_packages() {
    local pkg_json="$1"
    if [ ! -f "$pkg_json" ]; then
        echo ""
        return
    fi

    node -e "
        const pkg = require('$pkg_json');
        const deps = { ...pkg.dependencies, ...pkg.devDependencies };
        const sudobility = Object.keys(deps).filter(k => k.startsWith('@sudobility/'));
        console.log(sudobility.join(' '));
    " 2>/dev/null || echo ""
}

# Get all @sudobility packages from peerDependencies
get_sudobility_peer_packages() {
    local pkg_json="$1"
    if [ ! -f "$pkg_json" ]; then
        echo ""
        return
    fi

    node -e "
        const pkg = require('$pkg_json');
        const peers = pkg.peerDependencies || {};
        const sudobility = Object.keys(peers).filter(k => k.startsWith('@sudobility/'));
        console.log(sudobility.join(' '));
    " 2>/dev/null || echo ""
}

# Update peerDependencies in package.json directly
update_peer_dependency() {
    local pkg_json="$1"
    local package_name="$2"
    local new_version="$3"

    node -e "
        const fs = require('fs');
        const pkg = require('$pkg_json');
        if (pkg.peerDependencies && pkg.peerDependencies['$package_name']) {
            pkg.peerDependencies['$package_name'] = '$new_version';
            fs.writeFileSync('$pkg_json', JSON.stringify(pkg, null, 2) + '\n');
            console.log('updated');
        }
    " 2>/dev/null
}

# Get latest version of a package from npm (bypass cache)
get_latest_version() {
    local package_name="$1"
    npm view "${package_name}@latest" version --prefer-online 2>/dev/null || echo ""
}

# Update @sudobility dependencies to latest versions
update_sudobility_deps() {
    local project_dir="$1"
    local pkg_json="$project_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_warning "No package.json found in $project_dir"
        return 0
    fi

    local has_updates=false

    # === Update dependencies and devDependencies ===
    local packages=$(get_sudobility_packages "$pkg_json")

    if [ -n "$packages" ]; then
        log_info "Found @sudobility packages in deps: $packages"

        local packages_to_update=()

        for package in $packages; do
            local current_version=$(node -e "
                const pkg = require('$pkg_json');
                const deps = { ...pkg.dependencies, ...pkg.devDependencies };
                console.log(deps['$package'] || '');
            " 2>/dev/null)

            local latest_version=$(get_latest_version "$package")

            if [ -z "$latest_version" ]; then
                log_error "Failed to fetch latest version for $package from npm"
                return 2
            fi

            local current_clean=$(echo "$current_version" | sed 's/^[\^~]//')

            if [ "$current_clean" != "$latest_version" ]; then
                log_info "Will update $package: $current_version -> ^$latest_version"
                packages_to_update+=("$package@^$latest_version")
                has_updates=true
            else
                log_info "$package is already at latest version ($latest_version)"
            fi
        done

        if [ ${#packages_to_update[@]} -gt 0 ]; then
            log_info "Installing all updates together using $PKG_MANAGER..."
            if pm_install "${packages_to_update[@]}" 2>&1 | grep -v "WARN" || true; then
                log_success "Updated @sudobility dependencies"
            else
                log_error "Failed to update dependencies"
            fi
        fi
    else
        log_info "No @sudobility dependencies found"
    fi

    # === Update peerDependencies (directly in package.json) ===
    local peer_packages=$(get_sudobility_peer_packages "$pkg_json")

    if [ -n "$peer_packages" ]; then
        log_info "Found @sudobility packages in peerDeps: $peer_packages"

        for package in $peer_packages; do
            local current_version=$(node -e "
                const pkg = require('$pkg_json');
                const peers = pkg.peerDependencies || {};
                console.log(peers['$package'] || '');
            " 2>/dev/null)

            local latest_version=$(get_latest_version "$package")

            if [ -z "$latest_version" ]; then
                log_error "Failed to fetch latest version for $package (peer) from npm"
                return 2
            fi

            local current_clean=$(echo "$current_version" | sed 's/^[\^~]//')

            if [ "$current_clean" != "$latest_version" ]; then
                log_info "Will update peerDep $package: $current_version -> ^$latest_version"
                update_peer_dependency "$pkg_json" "$package" "^$latest_version"
                has_updates=true
                log_success "Updated peerDep $package to ^$latest_version"
            else
                log_info "peerDep $package is already at latest version ($latest_version)"
            fi
        done
    fi

    if [ "$has_updates" = true ]; then
        return 1
    else
        log_info "No updates needed"
        return 0
    fi
}

# Check if project has build script
has_build_script() {
    local pkg_json="$1"
    node -e "
        const pkg = require('$pkg_json');
        console.log(pkg.scripts && pkg.scripts.build ? 'yes' : 'no');
    " 2>/dev/null
}

# Check if project has test script
has_test_script() {
    local pkg_json="$1"
    node -e "
        const pkg = require('$pkg_json');
        console.log(pkg.scripts && (pkg.scripts['test:unit'] || pkg.scripts.test || pkg.scripts['test:run']) ? 'yes' : 'no');
    " 2>/dev/null
}

# Check if project has unit test script
has_unit_test_script() {
    local pkg_json="$1"
    node -e "
        const pkg = require('$pkg_json');
        console.log(pkg.scripts && pkg.scripts['test:unit'] ? 'yes' : 'no');
    " 2>/dev/null
}

# Check if project has lint script
has_lint_script() {
    local pkg_json="$1"
    node -e "
        const pkg = require('$pkg_json');
        console.log(pkg.scripts && pkg.scripts.lint ? 'yes' : 'no');
    " 2>/dev/null
}

# Check if project has typecheck script
has_typecheck_script() {
    local pkg_json="$1"
    node -e "
        const pkg = require('$pkg_json');
        console.log(pkg.scripts && pkg.scripts.typecheck ? 'yes' : 'no');
    " 2>/dev/null
}

# Run validation checks
validate_project() {
    local project_dir="$1"
    local pkg_json="$project_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_error "No package.json found"
        return 1
    fi

    # Typecheck
    if [ "$(has_typecheck_script "$pkg_json")" = "yes" ]; then
        log_info "Running typecheck..."
        if ! pm_run typecheck 2>&1 | tee /tmp/typecheck.log; then
            log_error "Typecheck failed"
            cat /tmp/typecheck.log
            return 1
        fi
        log_success "Typecheck passed"
    else
        if [ -f "$project_dir/tsconfig.json" ]; then
            log_info "Running tsc --noEmit..."
            if ! pm_exec tsc --noEmit 2>&1 | tee /tmp/tsc.log; then
                log_error "TypeScript compilation failed"
                cat /tmp/tsc.log
                return 1
            fi
            log_success "TypeScript check passed"
        fi
    fi

    # Lint
    if [ "$(has_lint_script "$pkg_json")" = "yes" ]; then
        log_info "Running lint..."
        if ! pm_run lint 2>&1 | tee /tmp/lint.log; then
            log_error "Lint failed"
            cat /tmp/lint.log
            return 1
        fi
        log_success "Lint passed"
    fi

    # Tests
    if [ "$(has_test_script "$pkg_json")" = "yes" ]; then
        if [ "$(has_unit_test_script "$pkg_json")" = "yes" ]; then
            log_info "Running unit tests (test:unit)..."
            if pm_run test:unit >/dev/null 2>&1; then
                log_success "Unit tests passed"
            else
                log_error "Unit tests failed"
                return 1
            fi
        else
            log_info "Running tests..."
            # Try various test runners:
            # - test:run: explicit single-run script
            # - test -- --run: vitest single-run flag
            # - test -- --ci --forceExit: jest CI mode with force exit (for open handles)
            if pm_run test:run >/dev/null 2>&1; then
                log_success "Tests passed"
            elif pm_run test --run >/dev/null 2>&1; then
                log_success "Tests passed"
            elif pm_run test --ci --forceExit >/dev/null 2>&1; then
                log_success "Tests passed"
            else
                log_error "Tests failed"
                return 1
            fi
        fi
    fi

    # Build
    if [ "$(has_build_script "$pkg_json")" = "yes" ]; then
        log_info "Running build..."
        if pm_run build >/dev/null 2>&1; then
            log_success "Build passed"
        else
            log_error "Build failed"
            pm_run build 2>&1 | tail -50
            return 1
        fi
    fi

    return 0
}

# Run validation for sub-packages (tests only, no lint)
validate_subpackage() {
    local package_dir="$1"
    local package_name=$(basename "$package_dir")
    local pkg_json="$package_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_warning "No package.json found in $package_name"
        return 0
    fi

    log_info "  Validating sub-package: $package_name"

    if [ "$(has_test_script "$pkg_json")" = "yes" ]; then
        if [ "$(has_unit_test_script "$pkg_json")" = "yes" ]; then
            log_info "    Running unit tests (test:unit)..."
            if pm_run test:unit >/dev/null 2>&1; then
                log_success "    Unit tests passed"
            else
                log_error "    Unit tests failed for $package_name"
                return 1
            fi
        else
            log_info "    Running tests..."
            if pm_run test:run >/dev/null 2>&1; then
                log_success "    Tests passed"
            elif pm_run test --run >/dev/null 2>&1; then
                log_success "    Tests passed"
            elif pm_run test --ci --forceExit >/dev/null 2>&1; then
                log_success "    Tests passed"
            else
                log_error "    Tests failed for $package_name"
                return 1
            fi
        fi
    else
        log_info "    No test script found, skipping tests"
    fi

    if [ "$(has_build_script "$pkg_json")" = "yes" ]; then
        log_info "    Running build..."
        if pm_run build >/dev/null 2>&1; then
            log_success "    Build passed"
        else
            log_error "    Build failed for $package_name"
            pm_run build 2>&1 | tail -30
            return 1
        fi
    fi

    return 0
}

# Process all sub-packages in /packages directory
process_subpackages() {
    local project_dir="$1"
    local packages_dir="$project_dir/packages"

    if [ ! -d "$packages_dir" ]; then
        return 0
    fi

    log_info "Found /packages directory, processing sub-packages..."

    local subpackages=()
    for dir in "$packages_dir"/*/; do
        if [ -d "$dir" ] && [ -f "$dir/package.json" ]; then
            subpackages+=("$dir")
        fi
    done

    if [ ${#subpackages[@]} -eq 0 ]; then
        log_info "No sub-packages found in /packages"
        return 0
    fi

    log_info "Found ${#subpackages[@]} sub-packages"

    for subpackage_dir in "${subpackages[@]}"; do
        local subpackage_name=$(basename "$subpackage_dir")
        log_info "Processing sub-package: $subpackage_name"

        cd "$subpackage_dir" || {
            log_error "Failed to navigate to $subpackage_dir"
            return 1
        }

        log_info "  Updating @sudobility dependencies..."
        local subpkg_update_result=0
        update_sudobility_deps "$subpackage_dir" || subpkg_update_result=$?
        if [ "$subpkg_update_result" -eq 2 ]; then
            log_error "Failed to fetch @sudobility package from npm for sub-package $subpackage_name, stopping"
            return 1
        fi

        if ! validate_subpackage "$subpackage_dir"; then
            log_error "Validation failed for sub-package: $subpackage_name"
            return 1
        fi

        log_success "Sub-package $subpackage_name processed"
    done

    cd "$project_dir" || return 1

    return 0
}

# Bump version in package.json
bump_version() {
    local project_dir="$1"
    local pkg_json="$project_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_error "No package.json found"
        return 1
    fi

    log_info "Bumping patch version..."

    if pm_version_bump >/dev/null 2>&1; then
        local new_version=$(node -e "console.log(require('$pkg_json').version)")
        log_success "Version bumped to $new_version"
        return 0
    else
        log_error "Failed to bump version"
        return 1
    fi
}

# Analyze changed files and generate meaningful commit message
analyze_changes() {
    local version="$1"
    local force_mode="$2"

    # Get all changed files (staged and unstaged)
    local all_changes=$(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null)
    all_changes=$(echo "$all_changes" | sort -u)

    # Filter out package.json and lock files to find "real" changes
    local code_changes=$(echo "$all_changes" | grep -v -E '^(package\.json|package-lock\.json|bun\.lock|bun\.lockb|yarn\.lock|pnpm-lock\.yaml)$' || true)

    # Categorize changes
    local src_changes=$(echo "$code_changes" | grep -E '^src/' || true)
    local test_changes=$(echo "$code_changes" | grep -E '(\.test\.|\.spec\.|__tests__|/test/)' || true)
    local config_changes=$(echo "$code_changes" | grep -E '^(\.eslint|\.prettier|tsconfig|vite\.config|vitest\.config|jest\.config|tailwind\.config|postcss\.config)' || true)
    local doc_changes=$(echo "$code_changes" | grep -E '\.(md|txt|rst)$' || true)
    local ci_changes=$(echo "$code_changes" | grep -E '^(\.github/|\.gitlab-ci|Dockerfile|docker-compose)' || true)

    # Count changes by category (grep -c always outputs a number, use fallback for empty)
    local src_count=$(echo "$src_changes" | grep -c . 2>/dev/null); src_count=${src_count:-0}
    local test_count=$(echo "$test_changes" | grep -c . 2>/dev/null); test_count=${test_count:-0}
    local config_count=$(echo "$config_changes" | grep -c . 2>/dev/null); config_count=${config_count:-0}
    local doc_count=$(echo "$doc_changes" | grep -c . 2>/dev/null); doc_count=${doc_count:-0}
    local ci_count=$(echo "$ci_changes" | grep -c . 2>/dev/null); ci_count=${ci_count:-0}
    local total_code_changes=$(echo "$code_changes" | grep -c . 2>/dev/null); total_code_changes=${total_code_changes:-0}

    # Build commit message
    local commit_type="chore"
    local commit_title=""
    local commit_body=""

    if [ "$force_mode" = "true" ]; then
        commit_title="chore: force bump version to $version"
        commit_body="- Force version bump to re-trigger CI/CD publish"
    elif [ "$total_code_changes" -eq 0 ]; then
        # Only dependency/version updates
        commit_title="chore: update @sudobility dependencies and bump version to $version"
        commit_body="- Update @sudobility dependencies to latest versions from npm"
    else
        # Determine the primary type of change for the commit title
        if [ "$src_count" -gt 0 ]; then
            # Check if it's a fix, feature, or refactor based on file patterns
            local has_new_files=$(git diff --cached --name-status | grep -E '^A.*src/' || true)
            if [ -n "$has_new_files" ]; then
                commit_type="feat"
                commit_title="feat: add new functionality and bump version to $version"
            else
                commit_type="refactor"
                commit_title="refactor: update source code and bump version to $version"
            fi
        elif [ "$test_count" -gt 0 ] && [ "$src_count" -eq 0 ]; then
            commit_type="test"
            commit_title="test: update tests and bump version to $version"
        elif [ "$config_count" -gt 0 ]; then
            commit_title="chore: update configuration and bump version to $version"
        elif [ "$doc_count" -gt 0 ]; then
            commit_type="docs"
            commit_title="docs: update documentation and bump version to $version"
        elif [ "$ci_count" -gt 0 ]; then
            commit_type="ci"
            commit_title="ci: update CI/CD configuration and bump version to $version"
        else
            commit_title="chore: update files and bump version to $version"
        fi

        # Build detailed body with changed file summaries
        commit_body="- Update @sudobility dependencies to latest versions from npm"

        if [ "$src_count" -gt 0 ]; then
            # List specific source files changed (up to 5)
            local src_file_list=$(echo "$src_changes" | head -5 | sed 's/^/    - /')
            if [ "$src_count" -gt 5 ]; then
                src_file_list="$src_file_list
    - ... and $((src_count - 5)) more"
            fi
            commit_body="$commit_body
- Source code changes ($src_count files):
$src_file_list"
        fi

        if [ "$test_count" -gt 0 ]; then
            commit_body="$commit_body
- Test updates ($test_count files)"
        fi

        if [ "$config_count" -gt 0 ]; then
            local config_list=$(echo "$config_changes" | head -3 | tr '\n' ', ' | sed 's/,$//')
            commit_body="$commit_body
- Configuration changes: $config_list"
        fi

        if [ "$doc_count" -gt 0 ]; then
            commit_body="$commit_body
- Documentation updates ($doc_count files)"
        fi

        if [ "$ci_count" -gt 0 ]; then
            commit_body="$commit_body
- CI/CD updates ($ci_count files)"
        fi
    fi

    # Append common footer
    commit_body="$commit_body
- All validation checks passed (lint, typecheck, tests, build)
- Version bumped to $version

Generated with push_projects.sh"

    echo "$commit_title

$commit_body"
}

# Commit and push changes
commit_and_push() {
    local project_dir="$1"
    local project_name="$2"

    if git diff --quiet && git diff --cached --quiet; then
        log_info "No changes to commit"
        return 0
    fi

    log_info "Committing changes..."

    git add -A

    local version=$(node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")

    local commit_msg
    commit_msg=$(analyze_changes "$version" "$FORCE_MODE")

    if git commit -m "$commit_msg" >/dev/null 2>&1; then
        log_success "Changes committed"
    else
        log_error "Failed to commit changes"
        return 1
    fi

    log_info "Pushing to remote..."
    local push_output
    push_output=$(git push 2>&1)
    local push_exit_code=$?

    # Show output (filter out "Everything up-to-date" noise)
    echo "$push_output" | grep -v "Everything up-to-date" || true

    if [ "$push_exit_code" -ne 0 ]; then
        log_error "Failed to push changes (exit code: $push_exit_code)"
        return 1
    fi

    log_success "Changes pushed to remote"
    return 0
}

# Process a single project
process_project() {
    local project_path="$1"
    local project_name=$(basename "$project_path")

    log_section "Processing: $project_name"

    if [ ! -d "$project_path" ]; then
        log_error "Directory not found: $project_path"
        return 1
    fi

    cd "$project_path" || {
        log_error "Failed to navigate to $project_path"
        return 1
    }

    log_info "Working directory: $(pwd)"

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_warning "Not a git repository, skipping"
        return 0
    fi

    # Detect package manager for this project
    detect_package_manager "$project_path"

    log_info "Updating @sudobility dependencies to latest..."
    local update_result=0
    update_sudobility_deps "$project_path" || update_result=$?
    if [ "$update_result" -eq 2 ]; then
        log_error "Failed to fetch @sudobility package from npm, stopping"
        return 1
    fi

    if [ "$SUBPACKAGES_MODE" = true ]; then
        if ! process_subpackages "$project_path"; then
            log_error "Failed to process sub-packages for $(basename "$project_path")"
            return 1
        fi
    fi

    local has_changes=false
    if ! git diff --quiet || ! git diff --cached --quiet; then
        has_changes=true
    fi

    if [ "$has_changes" = true ]; then
        log_info "Changed files:"
        git diff --name-only
        git diff --cached --name-only
    fi

    if [ "$has_changes" = false ] && [ "$FORCE_MODE" = false ]; then
        log_info "No changes detected in $project_name, skipping"
        return 2  # Return 2 to indicate "skipped, no changes"
    fi

    if [ "$FORCE_MODE" = true ] && [ "$has_changes" = false ]; then
        log_warning "FORCE MODE: Proceeding with version bump despite no changes"
    else
        log_info "Changes detected, proceeding with validation and version bump"
    fi

    log_info "Running validation checks..."
    if ! validate_project "$project_path"; then
        log_error "Validation failed for $project_name"
        return 1
    fi

    log_success "All validation checks passed"

    if ! bump_version "$project_path"; then
        log_error "Failed to bump version for $project_name"
        return 1
    fi

    log_info "Updating $PKG_LOCKFILE..."
    if ! pm_install >/dev/null 2>&1; then
        log_error "Failed to update $PKG_LOCKFILE"
        return 1
    fi
    log_success "$PKG_LOCKFILE updated"

    if ! commit_and_push "$project_path" "$project_name"; then
        log_error "Failed to commit and push for $project_name"
        return 1
    fi

    log_success "Successfully processed $project_name"
    return 0
}

# Main execution function
run_push_projects() {
    local base_dir="$1"
    shift
    local projects=("$@")

    log_section "Starting Multi-Project Update and Release Process"
    if [ "$FORCE_MODE" = true ]; then
        log_warning "FORCE MODE: Will bump version on ALL projects regardless of changes"
    else
        log_info "Logic: Update deps -> Check changes -> If changes: validate, bump, commit, push"
    fi
    if [ "$SUBPACKAGES_MODE" = true ]; then
        log_info "SUBPACKAGES MODE: Will also process /packages sub-directories"
    fi
    if [ -n "$STARTING_PROJECT" ]; then
        log_info "STARTING PROJECT: Will skip projects until reaching '$STARTING_PROJECT'"
    fi

    local start_time=$(date +%s)
    local total_projects=${#projects[@]}
    local current_project=0
    local found_starting_project=false
    local changes_counter=0  # Counter for projects with changes

    # If no starting project specified, consider it "found" immediately
    if [ -z "$STARTING_PROJECT" ]; then
        found_starting_project=true
    fi

    for project_spec in "${projects[@]}"; do
        current_project=$((current_project + 1))

        IFS=':' read -r project_path wait_time <<< "$project_spec"

        # Get project name from path for comparison
        local project_name=$(basename "$project_path")

        # Check if this is the starting project
        if [ "$found_starting_project" = false ]; then
            if [ "$project_name" = "$STARTING_PROJECT" ]; then
                found_starting_project=true
                log_info "Found starting project: $STARTING_PROJECT"
            else
                log_info "Skipping $project_name (before starting project '$STARTING_PROJECT')"
                continue
            fi
        fi

        log_info "Progress: $current_project/$total_projects"

        local abs_path="$(cd "$base_dir" && cd "$project_path" 2>/dev/null && pwd)"

        if [ -z "$abs_path" ]; then
            log_error "Failed to resolve path: $project_path"
            exit 1
        fi

        local process_result=0
        process_project "$abs_path" || process_result=$?

        if [ "$process_result" -eq 1 ]; then
            log_error "Failed to process $(basename "$abs_path")"
            log_error "Stopping execution"
            exit 1
        elif [ "$process_result" -eq 0 ]; then
            # Project had changes and was committed
            changes_counter=$((changes_counter + 1))
        fi
        # process_result=2 means skipped (no changes), counter stays the same

        if [ "$wait_time" -gt 0 ]; then
            if [ "$changes_counter" -gt 0 ]; then
                log_info "Waiting $wait_time seconds for npm registry to update ($changes_counter project(s) published)..."
                sleep "$wait_time"
                changes_counter=0  # Reset counter after waiting
            else
                log_info "No changes published, skipping wait"
            fi
        fi
    done

    # Check if starting project was found (if specified)
    if [ -n "$STARTING_PROJECT" ] && [ "$found_starting_project" = false ]; then
        log_error "Starting project '$STARTING_PROJECT' was not found in the projects list"
        exit 1
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    log_section "All Projects Processed Successfully!"
    log_success "Total time: ${minutes}m ${seconds}s"
    log_success "All projects updated, validated, versioned, and pushed"
}

# Parse command-line arguments when run directly
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                ;;
            --force|-f)
                FORCE_MODE=true
                shift
                ;;
            --subpackages|-s)
                SUBPACKAGES_MODE=true
                shift
                ;;
            --projects-file)
                PROJECTS_FILE="$2"
                shift 2
                ;;
            --starting-project)
                STARTING_PROJECT="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Entry point when script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"

    if [ -n "$PROJECTS_FILE" ]; then
        # Read projects from file
        if [ ! -f "$PROJECTS_FILE" ]; then
            log_error "Projects file not found: $PROJECTS_FILE"
            exit 1
        fi

        PROJECTS=()
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            PROJECTS+=("$line")
        done < "$PROJECTS_FILE"

        BASE_DIR="$(dirname "$PROJECTS_FILE")"
        run_push_projects "$BASE_DIR" "${PROJECTS[@]}"
    elif [ ${#PROJECTS[@]} -gt 0 ]; then
        # PROJECTS array was defined before sourcing
        run_push_projects "$(pwd)" "${PROJECTS[@]}"
    else
        log_error "No projects defined. Either define PROJECTS array or use --projects-file"
        show_help
    fi
fi
