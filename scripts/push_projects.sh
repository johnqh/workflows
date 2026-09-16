#!/bin/bash

PUSH_PROJECTS_VERSION="1.2.0"

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
#   --force, -f              Force version bump on all projects even without changes
#   --subpackages, -s        Also process sub-packages in /packages directories
#   --projects-file          Read projects from a file (one per line, format: path:delay)
#   --help, -h               Show help message
#   --starting-project       Skip projects until reaching the specified project name
#   --continue-on-error, -c  Log failures and continue to the next project
#
# Environment:
#   NPM_PUBLISH_POLL_MAX       Seconds to wait for a publish to appear on npm
#                              (default 600). A ceiling, not a duration.
#   NPM_PUBLISH_POLL_INTERVAL  Seconds between registry checks (default 5).
#
# Note on "wait_after_seconds": since v1.2.0 this is no longer how long the
# script sleeps. After a project publishes, the script polls npm for the exact
# version it just pushed and continues the moment it is served — usually within
# seconds. The configured number now only raises the poll's cap when it exceeds
# NPM_PUBLISH_POLL_MAX, and is still used as a plain sleep for projects that
# publish nothing to npm (private or non-npm).

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
CONTINUE_ON_ERROR=false
PROJECTS_FILE=""
STARTING_PROJECT=""
AI_COMMIT=true

# Failure tracking (used with --continue-on-error)
declare -a FAILED_PROJECTS=()
declare -a FAILED_REASONS=()

# Package manager for current project (detected per-project)
PKG_MANAGER=""
PKG_LOCKFILE=""

# Detect package manager based on lockfile
detect_package_manager() {
    local project_dir="$1"

    if [ -f "$project_dir/pyproject.toml" ] && [ ! -f "$project_dir/package.json" ]; then
        PKG_MANAGER="python"
        PKG_LOCKFILE=""
        log_info "Detected package manager: python (pyproject.toml)"
        return
    fi

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

# Run a command with a timeout (in seconds). Returns 143 on timeout.
run_with_timeout() {
    local seconds=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$seconds" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    local exit_code=0
    wait "$pid" || exit_code=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null || true
    return $exit_code
}

# True when the current branch has commits the remote does not.
#
# Working-tree cleanliness alone is NOT a safe "nothing to do" signal: a repo
# whose work is committed but never pushed looks identical to an untouched one,
# which silently strands commits and lets a published package drift ahead of
# its git history.
has_unpushed_commits() {
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || return 1
    [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" -gt 0 ]
}

# Run package manager install command
pm_install() {
    local packages=("$@")

    case "$PKG_MANAGER" in
        bun)
            if [ ${#packages[@]} -eq 0 ]; then
                bun install
            else
                if ! bun add "${packages[@]}"; then
                    # A stale bun manifest cache reports
                    #   No version matching "^X.Y.Z" found ... (but package exists)
                    # for versions that ARE published -- `npm view` confirms them.
                    # This is the dominant failure in a publish cascade: each
                    # publish immediately stales the cache for the next consumer.
                    # Waiting cannot fix it because nothing is propagating, so
                    # clear and retry before the heavier npm fallback.
                    log_warning "bun add failed; clearing bun manifest cache and retrying"
                    bun pm cache rm >/dev/null 2>&1 || true
                    if ! bun add "${packages[@]}"; then
                        log_warning "bun add still failing; retrying dependency update via npm install fallback"
                        npm install "${packages[@]}" --save-exact=false --legacy-peer-deps
                        rm -f package-lock.json
                        bun install
                    fi
                fi
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

# Ensure NPM_TOKEN is set for private package access.
# Always prefer the token from ~/.npmrc over an existing env var, because
# project-level .npmrc files reference ${NPM_TOKEN} and the env var may
# hold a stale or different token.
if [ -f "$HOME/.npmrc" ]; then
    EXTRACTED_TOKEN=$(grep '_authToken=' "$HOME/.npmrc" 2>/dev/null | grep -v '${NPM_TOKEN}' | sed 's/.*_authToken=//' | head -1)
    if [ -n "$EXTRACTED_TOKEN" ]; then
        export NPM_TOKEN="$EXTRACTED_TOKEN"
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
    --force, -f              Force version bump on all projects even without changes
    --subpackages, -s        Also process sub-packages in /packages directories
    --projects-file          Read projects from a file (one per line, format: path:delay)
    --starting-project       Skip projects until reaching the specified project name
    --continue-on-error, -c  Log failures and continue to the next project.
                             Collects all failures and prints a summary at the end.
    --no-ai                  Disable AI-generated commit messages (use heuristic only)
    --help, -h               Show this help message

EXAMPLES:
    # In your push_all.sh:
    PROJECTS=("../types:0" "../lib:0" "../app:0")
    source /path/to/push_projects.sh

    # Or with a projects file:
    ./push_projects.sh --projects-file ./projects.txt

    # Skip projects until reaching a specific one:
    ./push_projects.sh --projects-file ./projects.txt --starting-project lib
    # If projects are [types, lib, app], this skips types and starts from lib

    # Continue processing even if some projects fail:
    ./push_projects.sh --projects-file ./projects.txt --continue-on-error

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

# Fetch latest npm versions for multiple packages in parallel
fetch_latest_versions_parallel() {
    local packages=("$@")
    local pids=()
    local tmpdir
    tmpdir=$(mktemp -d)

    for package in "${packages[@]}"; do
        local safe_name="${package//\//_}"
        ( npm view "${package}@latest" version 2>/dev/null > "$tmpdir/$safe_name" ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    for package in "${packages[@]}"; do
        local safe_name="${package//\//_}"
        local version
        version=$(cat "$tmpdir/$safe_name" 2>/dev/null)
        echo "$package=$version"
    done

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Waiting for a publish to actually land
#
# Publishing happens in CI on push, not in this script, so a project that has
# just been pushed is not yet installable. Every downstream project then
# resolves its dependencies from npm, and if the publish has not landed, npm
# answers with the *previous* version and this script cheerfully reports
# "already at latest version".
#
# That failure is silent whenever the downstream project does not reference a
# newly added export: everything typechecks, tests pass, and a release ships
# built against the library it was supposed to replace. (When it *does*
# reference one, it fails typecheck instead, which is the lucky case.)
#
# This used to be a fixed `sleep`, which cannot be right: too short and it
# ships staleness, too long and every run pays for the worst case. 60s lost the
# race, and so did 150s. So the wait is now a poll — ask npm for the exact
# version we just pushed until it answers, which returns in seconds when CI is
# quick and holds on when it is slow.
# ---------------------------------------------------------------------------

# How long a poll may run before giving up, in seconds. A ceiling, not a
# duration: a fast publish returns almost immediately.
NPM_PUBLISH_POLL_MAX="${NPM_PUBLISH_POLL_MAX:-600}"
NPM_PUBLISH_POLL_INTERVAL="${NPM_PUBLISH_POLL_INTERVAL:-5}"

# "name@version" for what a project just published, or empty if it publishes
# nothing to npm — a private package (music_api), a python project, or
# anything without a package.json. Those keep the old fixed sleep, since there
# is no registry answer to wait for.
published_package_id() {
    local project_dir="$1"
    local pkg_json="$project_dir/package.json"

    [ -f "$pkg_json" ] || return 0

    node -e "
        try {
            const pkg = require('$pkg_json');
            if (pkg.private) process.exit(0);
            if (!pkg.name || !pkg.version) process.exit(0);
            console.log(pkg.name + '@' + pkg.version);
        } catch (e) {
            process.exit(0);
        }
    " 2>/dev/null
}

# Blocks until npm serves exactly "$1" (a "name@version"), or the cap expires.
# Returns 0 when the version is live, 1 on timeout.
wait_for_npm_publish() {
    local package_id="$1"
    local max_wait="$2"

    # Scoped names start with '@', so strip from the *last* '@' only:
    # "@sudobility/music_lib@1.7.49" -> name "@sudobility/music_lib", ver "1.7.49"
    local name="${package_id%@*}"
    local version="${package_id##*@}"

    local waited=0
    local checked_reachable=false

    while [ "$waited" -lt "$max_wait" ]; do
        if [ "$(npm view "${name}@${version}" version 2>/dev/null)" = "$version" ]; then
            [ "$waited" -gt 0 ] && log_info "npm served $package_id after ${waited}s"
            return 0
        fi

        # A miss means "not published yet" — or that we cannot read the
        # registry at all, which looks identical and would otherwise burn the
        # whole cap before saying so. A project-local .npmrc referencing an
        # unset ${NPM_TOKEN} is the usual cause. Checked once, on the first
        # miss, since a reachable registry stays reachable.
        if [ "$checked_reachable" = false ]; then
            checked_reachable=true
            if ! npm view "$name" version >/dev/null 2>&1; then
                log_error "Cannot read $name from npm at all — this is not publish lag"
                log_error "Check registry auth (a project .npmrc may reference an unset \${NPM_TOKEN})"
                return 1
            fi
        fi

        sleep "$NPM_PUBLISH_POLL_INTERVAL"
        waited=$((waited + NPM_PUBLISH_POLL_INTERVAL))
    done

    return 1
}

# npm serving a version is necessary but not sufficient: bun caches the
# packument, so `bun add pkg@^new` can still fail to resolve a version that
# `npm view` and curl both show. Dropping the cache is what makes the freshly
# published version resolvable to the next project in the list.
invalidate_packument_cache() {
    case "$PKG_MANAGER" in
        bun) bun pm cache rm >/dev/null 2>&1 || true ;;
        pnpm) pnpm store prune >/dev/null 2>&1 || true ;;
        npm|yarn) npm cache clean --force >/dev/null 2>&1 || true ;;
    esac
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

    # Clean up overrides/resolutions containing file: references
    # These are sometimes added during local development and should not be committed
    local cleaned_file_refs
    cleaned_file_refs=$(node -e "
        const fs = require('fs');
        const pkg = require('$pkg_json');
        let changed = false;
        for (const field of ['overrides', 'resolutions']) {
            if (!pkg[field]) continue;
            for (const [k, v] of Object.entries(pkg[field])) {
                if (typeof v === 'string' && (v.startsWith('file:') || v.startsWith('link:'))) {
                    delete pkg[field][k];
                    changed = true;
                }
            }
            if (Object.keys(pkg[field]).length === 0) {
                delete pkg[field];
            }
        }
        if (changed) {
            fs.writeFileSync('$pkg_json', JSON.stringify(pkg, null, 2) + '\n');
            console.log('cleaned');
        }
    " 2>/dev/null)
    if [ "$cleaned_file_refs" = "cleaned" ]; then
        log_warning "Removed file:/link: references from overrides/resolutions in package.json"
        has_updates=true
    fi

    # Read all @sudobility package names and current versions in one node call
    local deps_info
    deps_info=$(node -e "
        const pkg = require('$pkg_json');
        const deps = { ...pkg.dependencies, ...pkg.devDependencies };
        const peers = pkg.peerDependencies || {};
        const lines = [];
        for (const [k, v] of Object.entries(deps)) {
            if (k.startsWith('@sudobility/')) lines.push('dep ' + k + ' ' + v);
        }
        for (const [k, v] of Object.entries(peers)) {
            if (k.startsWith('@sudobility/')) lines.push('peer ' + k + ' ' + v);
        }
        console.log(lines.join('\n'));
    " 2>/dev/null)

    if [ -z "$deps_info" ]; then
        log_info "No @sudobility dependencies found"
        return 0
    fi

    # Collect all unique package names for parallel version fetch
    local all_package_names=()
    while IFS=' ' read -r _type pkg_name _ver; do
        [ -z "$pkg_name" ] && continue
        all_package_names+=("$pkg_name")
    done <<< "$deps_info"

    if [ ${#all_package_names[@]} -eq 0 ]; then
        log_info "No @sudobility dependencies found"
        return 0
    fi

    # Deduplicate (deps and peers may overlap)
    local unique_packages
    unique_packages=($(printf '%s\n' "${all_package_names[@]}" | sort -u))

    log_info "Fetching latest versions for ${#unique_packages[@]} @sudobility packages in parallel..."

    # Fetch all latest versions in parallel (stored as "pkg=ver" lines, no associative array)
    local latest_versions_data
    latest_versions_data=$(fetch_latest_versions_parallel "${unique_packages[@]}")

    # Helper: look up a version from the parallel-fetch results
    _lookup_latest() {
        local pkg="$1"
        echo "$latest_versions_data" | grep "^${pkg}=" | head -1 | cut -d'=' -f2-
    }

    # === Update dependencies and devDependencies ===
    local dep_packages=()
    while IFS=' ' read -r type pkg_name current_version; do
        [ "$type" = "dep" ] || continue
        [ -z "$pkg_name" ] && continue
        dep_packages+=("$pkg_name")
    done <<< "$deps_info"

    if [ ${#dep_packages[@]} -gt 0 ]; then
        log_info "Found @sudobility packages in deps: ${dep_packages[*]}"

        local packages_to_update=()

        while IFS=' ' read -r type pkg_name current_version; do
            [ "$type" = "dep" ] || continue
            [ -z "$pkg_name" ] && continue

            local latest_version
            latest_version=$(_lookup_latest "$pkg_name")

            if [ -z "$latest_version" ]; then
                log_error "Failed to fetch latest version for $pkg_name from npm"
                return 2
            fi

            local current_clean="${current_version#[\^~]}"

            if [ "$current_clean" != "$latest_version" ]; then
                log_info "Will update $pkg_name: $current_version -> ^$latest_version"
                packages_to_update+=("$pkg_name@^$latest_version")
                has_updates=true
            else
                log_info "$pkg_name is already at latest version ($latest_version)"
            fi
        done <<< "$deps_info"

        if [ ${#packages_to_update[@]} -gt 0 ]; then
            log_info "Installing all updates together using $PKG_MANAGER..."
            run_with_timeout 120 pm_install "${packages_to_update[@]}" 2>&1
            local install_exit_code=$?
            if [ $install_exit_code -eq 143 ]; then
                log_error "Install timed out after 120 seconds"
                return 1
            elif [ $install_exit_code -ne 0 ]; then
                log_error "Failed to update dependencies (exit code: $install_exit_code)"
                return 1
            fi
            log_success "Updated @sudobility dependencies"
        fi
    else
        log_info "No @sudobility dependencies found"
    fi

    # === Update peerDependencies (directly in package.json) ===
    local peer_list
    peer_list=$(echo "$deps_info" | grep '^peer ' | awk '{print $2}' | tr '\n' ' ')

    if [ -n "$peer_list" ]; then
        log_info "Found @sudobility packages in peerDeps: $peer_list"

        while IFS=' ' read -r type pkg_name current_version; do
            [ "$type" = "peer" ] || continue
            [ -z "$pkg_name" ] && continue

            local latest_version
            latest_version=$(_lookup_latest "$pkg_name")

            if [ -z "$latest_version" ]; then
                log_error "Failed to fetch latest version for $pkg_name (peer) from npm"
                return 2
            fi

            local current_clean="${current_version#[\^~]}"

            if [ "$current_clean" != "$latest_version" ]; then
                log_info "Will update peerDep $pkg_name: $current_version -> ^$latest_version"
                update_peer_dependency "$pkg_json" "$pkg_name" "^$latest_version"
                has_updates=true
                log_success "Updated peerDep $pkg_name to ^$latest_version"
            else
                log_info "peerDep $pkg_name is already at latest version ($latest_version)"
            fi
        done <<< "$deps_info"
    fi

    if [ "$has_updates" != true ]; then
        log_info "No updates needed"
    fi
    return 0
}

# Cached package.json script flags (set by read_package_scripts)
_PKG_HAS_BUILD="no"
_PKG_HAS_TEST="no"
_PKG_HAS_UNIT_TEST="no"
_PKG_HAS_TEST_RUN="no"
_PKG_HAS_LINT="no"
_PKG_HAS_TYPECHECK="no"

# Read all script flags from package.json in a single node call (replaces 5 separate invocations)
read_package_scripts() {
    local pkg_json="$1"
    if [ ! -f "$pkg_json" ]; then
        _PKG_HAS_BUILD="no"; _PKG_HAS_TEST="no"; _PKG_HAS_UNIT_TEST="no"
        _PKG_HAS_TEST_RUN="no"; _PKG_HAS_LINT="no"; _PKG_HAS_TYPECHECK="no"
        return
    fi
    local result
    result=$(node -e "
        const s = require('$pkg_json').scripts || {};
        const f = [
            s.build ? 'yes' : 'no',
            s['test:unit'] ? 'yes' : 'no',
            s['test:unit'] ? 'yes' : 'no',
            s['test:run'] ? 'yes' : 'no',
            s.lint ? 'yes' : 'no',
            s.typecheck ? 'yes' : 'no'
        ];
        console.log(f.join(' '));
    " 2>/dev/null) || result="no no no no no no"
    read -r _PKG_HAS_BUILD _PKG_HAS_TEST _PKG_HAS_UNIT_TEST _PKG_HAS_TEST_RUN _PKG_HAS_LINT _PKG_HAS_TYPECHECK <<< "$result"
}

# How many lines of a failed check's output to replay.
CHECK_FAIL_LINES="${CHECK_FAIL_LINES:-80}"

# Run one validation command with its output captured.  On success the output is
# dropped so the log stays readable; on failure it is replayed.
#
# Every check used to run under `>/dev/null 2>&1`, so a failure printed nothing
# but "Tests failed" and the only way to learn why was to re-run the command by
# hand.  That friction is why red builds reached GitHub Actions instead of being
# fixed here -- and CI minutes on a private repo are billed, a local run is not.
run_check() {
    local label="$1"
    shift

    local out status
    out=$(mktemp)
    status=0

    "$@" >"$out" 2>&1 || status=$?

    if [ "$status" -eq 0 ]; then
        rm -f "$out"
        log_success "$label passed"
        return 0
    fi

    log_error "$label failed (exit $status)"
    echo "--- last ${CHECK_FAIL_LINES} lines of $label output ---" >&2
    tail -n "$CHECK_FAIL_LINES" "$out" >&2
    echo "--- end of $label output ---" >&2
    rm -f "$out"
    return "$status"
}

# pm_run with CI=true set, so vitest/jest run once instead of entering watch mode.
# Needs to be a function because run_check invokes "$@" directly and an
# environment prefix cannot be passed through positional arguments.
pm_run_ci() {
    CI=true pm_run "$@"
}

# Run validation checks
validate_python_project() {
    local project_dir="$1"

    # Which directories actually hold Python. `src` was hardcoded, so a project
    # laying its package out as `app/` (FastAPI's convention) failed with
    # "E902 No such file or directory --> src" before a single rule ran — a
    # lint failure that was really a missing path.
    local py_paths=""
    local py_src=""
    for d in src app; do
        [ -d "$project_dir/$d" ] && py_paths="$py_paths $d" && py_src="$py_src $d"
    done
    [ -d "$project_dir/tests" ] && py_paths="$py_paths tests"
    py_paths="${py_paths# }"
    py_src="${py_src# }"

    # Lint
    #
    # ruff ran under `2>/dev/null`, which discarded exactly the diagnostics
    # needed to fix the failure it was reporting.
    if [ -f "$project_dir/pyproject.toml" ] && grep -q "ruff" "$project_dir/pyproject.toml" 2>/dev/null && [ -n "$py_paths" ]; then
        log_info "Running ruff check..."
        run_check "Ruff lint" bash -c "cd '$project_dir' && ruff check $py_paths" || return 1
        log_info "Running ruff format check..."
        run_check "Ruff format" bash -c "cd '$project_dir' && ruff format --check $py_paths" || return 1
    fi

    # Typecheck
    if command -v mypy &> /dev/null; then
        log_info "Running mypy..."
        run_check "Mypy" bash -c "cd '$project_dir' && mypy $py_src" || return 1
    fi

    # Tests
    if command -v pytest &> /dev/null; then
        log_info "Running pytest..."
        run_check "Tests" bash -c "cd '$project_dir' && pytest -m 'not integration' -q" || return 1
    fi

    return 0
}

validate_project() {
    local project_dir="$1"

    # Handle Python projects
    if [ "$PKG_MANAGER" = "python" ]; then
        validate_python_project "$project_dir"
        return $?
    fi

    local pkg_json="$project_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_info "No package.json found, skipping validation"
        return 0
    fi

    # Read all script flags in one node call
    read_package_scripts "$pkg_json"

    # Typecheck
    #
    # These used to run as a bare command followed by `if [ $? -ne 0 ]`.  Under
    # `set -e` that is a trap: a non-zero exit aborts the whole script before the
    # test is ever evaluated, so the "return 1" path was unreachable in any
    # context where errexit was still armed.  run_check keeps the failure local.
    if [ "$_PKG_HAS_TYPECHECK" = "yes" ]; then
        log_info "Running typecheck..."
        run_check "Typecheck" pm_run typecheck || return 1
    else
        if [ -f "$project_dir/tsconfig.json" ]; then
            log_info "Running tsc --noEmit..."
            run_check "TypeScript check" pm_exec tsc --noEmit || return 1
        fi
    fi

    # Lint
    if [ "$_PKG_HAS_LINT" = "yes" ]; then
        log_info "Running lint..."
        run_check "Lint" pm_run lint || return 1
    fi

    # Tests
    #
    # Which script to run is decided from package.json rather than by trying
    # `test:run` and treating its failure as "not present".  That old fallback
    # could not tell a missing script from a genuinely failing one, so a real
    # test failure was silently retried as `test` and could report the wrong
    # result -- and it ran the suite twice when test:run was absent.
    if [ "$_PKG_HAS_UNIT_TEST" = "yes" ]; then
        log_info "Running unit tests (test:unit)..."
        run_check "Unit tests" pm_run test:unit || return 1
    fi

    # Build
    #
    # The failure path used to re-run the entire build just to show its output,
    # doubling the cost of the slowest check in the script.
    if [ "$_PKG_HAS_BUILD" = "yes" ]; then
        log_info "Running build..."
        run_check "Build" pm_run build || return 1
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

    read_package_scripts "$pkg_json"

    if [ "$_PKG_HAS_UNIT_TEST" = "yes" ]; then
        log_info "    Running unit tests (test:unit)..."
        run_check "Unit tests ($package_name)" pm_run test:unit || return 1
    else
        log_info "    No test script found, skipping tests"
    fi

    if [ "$_PKG_HAS_BUILD" = "yes" ]; then
        log_info "    Running build..."
        run_check "Build ($package_name)" pm_run build || return 1
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
        if [ "$subpkg_update_result" -ne 0 ]; then
            if [ "$subpkg_update_result" -eq 2 ]; then
                log_error "Failed to fetch @sudobility package from npm for sub-package $subpackage_name, stopping"
            else
                log_error "Failed to update @sudobility dependencies for sub-package $subpackage_name, stopping"
            fi
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

# Sync version to React Native native platform files (iOS, Android, macOS, Windows)
sync_rn_native_versions() {
    local project_dir="$1"
    local version="$2"

    # Detect if this is a React Native project
    if [ ! -d "$project_dir/ios" ] && [ ! -d "$project_dir/android" ]; then
        return 0
    fi

    log_info "Syncing version $version to native platforms..."

    # iOS: update MARKETING_VERSION in pbxproj
    local ios_pbxproj
    ios_pbxproj=$(find "$project_dir/ios" -name "project.pbxproj" -not -path "*/Pods/*" -maxdepth 3 2>/dev/null | head -1)
    if [ -n "$ios_pbxproj" ] && [ -f "$ios_pbxproj" ]; then
        sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $version;/g" "$ios_pbxproj"
        log_info "  Updated iOS MARKETING_VERSION"
    fi

    # Android: update versionName in build.gradle
    local android_gradle="$project_dir/android/app/build.gradle"
    if [ -f "$android_gradle" ]; then
        sed -i '' "s/versionName \"[^\"]*\"/versionName \"$version\"/" "$android_gradle"
        log_info "  Updated Android versionName"
    fi

    # macOS: update MARKETING_VERSION in pbxproj
    local macos_pbxproj
    macos_pbxproj=$(find "$project_dir/macos" -name "project.pbxproj" -not -path "*/Pods/*" -maxdepth 3 2>/dev/null | head -1)
    if [ -n "$macos_pbxproj" ] && [ -f "$macos_pbxproj" ]; then
        sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $version;/g" "$macos_pbxproj"
        log_info "  Updated macOS MARKETING_VERSION"
    fi

    # macOS: update CFBundleShortVersionString in Info.plist
    local macos_plist
    macos_plist=$(find "$project_dir/macos" -name "Info.plist" -path "*-macOS/*" -maxdepth 3 2>/dev/null | head -1)
    if [ -n "$macos_plist" ] && [ -f "$macos_plist" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$macos_plist" 2>/dev/null && \
            log_info "  Updated macOS CFBundleShortVersionString"
    fi

    # Windows: update version in Package.appxmanifest (if exists)
    local windows_manifest
    windows_manifest=$(find "$project_dir/windows" -name "Package.appxmanifest" -maxdepth 3 2>/dev/null | head -1)
    if [ -n "$windows_manifest" ] && [ -f "$windows_manifest" ]; then
        sed -i '' "s/Version=\"[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\"/Version=\"$version.0\"/" "$windows_manifest"
        log_info "  Updated Windows Package.appxmanifest"
    fi
}

# Rewrite git+ssh pinned Python deps in a downstream pyproject.toml
# Usage: update_python_git_deps <pyproject-path> <dep-name> <new-version>
update_python_git_deps() {
    local pyproject="$1"
    local dep="$2"
    local new_version="$3"

    if [ ! -f "$pyproject" ]; then
        return 0
    fi

    if ! grep -q "${dep} @ git+ssh://" "$pyproject"; then
        return 0
    fi

    log_info "Updating ${dep} pin to v${new_version} in $pyproject"
    sed -i.bak -E "s|(${dep} @ git\+ssh://[^@]*@github\.com/[^@]*)@v[0-9]+\.[0-9]+\.[0-9]+|\1@v${new_version}|" "$pyproject"
    rm -f "$pyproject.bak"
    log_success "Pin updated to v${new_version}"
}

# Bump version in package.json
bump_version() {
    local project_dir="$1"

    # Handle Python projects
    if [ "$PKG_MANAGER" = "python" ]; then
        local pyproject="$project_dir/pyproject.toml"
        if [ ! -f "$pyproject" ]; then
            log_info "No pyproject.toml found, skipping version bump"
            return 0
        fi

        log_info "Bumping patch version (Python)..."
        local current_version=$(python3 -c "import tomllib; print(tomllib.load(open('$pyproject','rb'))['project']['version'])")
        local major minor patch
        IFS='.' read -r major minor patch <<< "$current_version"
        patch=$((patch + 1))
        local new_version="$major.$minor.$patch"
        # Update version in pyproject.toml
        sed -i.bak "s/^version = \"$current_version\"/version = \"$new_version\"/" "$pyproject" && rm -f "$pyproject.bak"
        log_success "Version bumped to $new_version"

        # Propagate this version into downstream git+ssh pins. push_all.sh walks
        # repos in dependency order, so consumers are processed after this one.
        if [ "$(basename "$project_dir")" = "tapayoka_pi_core" ]; then
            update_python_git_deps "$(dirname "$project_dir")/tapayoka_pi/pyproject.toml" \
                "tapayoka-pi-core" "$new_version"
        fi
        return 0
    fi

    local pkg_json="$project_dir/package.json"

    if [ ! -f "$pkg_json" ]; then
        log_info "No package.json found, skipping version bump"
        return 0
    fi

    log_info "Bumping patch version..."

    if pm_version_bump >/dev/null 2>&1; then
        local new_version=$(node -e "console.log(require('$pkg_json').version)")
        log_success "Version bumped to $new_version"
        sync_rn_native_versions "$project_dir" "$new_version"
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
    local code_changes=$(echo "$all_changes" | grep -v -E '^(package\.json|package-lock\.json|bun\.lock|bun\.lockb|yarn\.lock|pnpm-lock\.yaml|pyproject\.toml|uv\.lock)$' || true)

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

# Generate commit message using AI (claude CLI)
generate_ai_commit_message() {
    local version="$1"
    local project_name="$2"

    # Check if claude CLI is available
    if ! command -v claude &>/dev/null; then
        return 1
    fi

    local diff_stat diff_content
    diff_stat=$(git diff --cached --stat 2>/dev/null)
    # Truncate diff to ~300 lines to keep the prompt small and fast
    diff_content=$(git diff --cached 2>/dev/null | head -300)

    if [ -z "$diff_stat" ]; then
        return 1
    fi

    local prompt="Generate a git commit message for project \"$project_name\" version $version.

Rules:
- First line: conventional commit format (feat/fix/refactor/chore/docs/test/ci: description) under 72 chars
- Include \"and bump version to $version\" at the end of the first line
- Add a blank line then a brief body (2-5 bullet points) summarizing the changes
- End with a blank line and: Generated with push_projects.sh
- Be specific about WHAT changed, not generic
- Do NOT wrap in markdown code blocks

Changed files:
$diff_stat

Diff:
$diff_content"

    local ai_msg
    ai_msg=$(echo "$prompt" | claude -p --model haiku 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$ai_msg" ]; then
        return 1
    fi

    # Strip markdown code fences if present
    ai_msg=$(echo "$ai_msg" | sed '/^```/d')

    echo "$ai_msg"
    return 0
}

# Commit and push changes
commit_and_push() {
    local project_dir="$1"
    local project_name="$2"

    local needs_commit=true
    if git diff --quiet && git diff --cached --quiet; then
        needs_commit=false
        if ! has_unpushed_commits; then
            log_info "No changes to commit and nothing unpushed"
            return 0
        fi
        log_info "No changes to commit, but commits are ahead of upstream -- pushing them"
    fi

    if [ "$needs_commit" = true ]; then
        log_info "Committing changes..."

        git add -A

        local version=$(node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "unknown")

        local commit_msg

        # Try AI-generated commit message first, fall back to heuristic
        if [ "$AI_COMMIT" = true ]; then
            commit_msg=$(generate_ai_commit_message "$version" "$project_name" 2>/dev/null) || true
        fi

        if [ -z "$commit_msg" ]; then
            commit_msg=$(analyze_changes "$version" "$FORCE_MODE")
        fi

        if git commit -m "$commit_msg" >/dev/null 2>&1; then
            log_success "Changes committed"
        else
            log_error "Failed to commit changes"
            return 1
        fi
    fi

    log_info "Pushing to remote..."
    local push_output
    push_output=$(git push 2>&1)
    local push_exit_code=$?

    # If push fails due to no upstream, retry with --set-upstream
    if [ "$push_exit_code" -ne 0 ]; then
        local current_branch
        current_branch=$(git branch --show-current 2>/dev/null)
        if echo "$push_output" | grep -q "no upstream branch\|push.autoSetupRemote\|has no upstream"; then
            log_info "No upstream branch, pushing with --set-upstream origin $current_branch"
            push_output=$(git push --set-upstream origin "$current_branch" 2>&1)
            push_exit_code=$?
        fi
    fi

    # Show output (filter out "Everything up-to-date" noise)
    echo "$push_output" | grep -v "Everything up-to-date" || true

    if [ "$push_exit_code" -ne 0 ]; then
        log_error "Failed to push changes (exit code: $push_exit_code)"
        return 1
    fi

    log_success "Changes pushed to remote"
    return 0
}

# Detect and remove @sudobility symlinks created by bun link / npm link
# These cause duplicate type resolution issues and must be replaced with
# real npm-installed packages before validation.
remove_sudobility_symlinks() {
    local project_dir="$1"
    local scope_dir="$project_dir/node_modules/@sudobility"

    if [ ! -d "$scope_dir" ]; then
        return 0
    fi

    local found_symlinks=()
    for entry in "$scope_dir"/*/; do
        [ -d "$entry" ] || continue
        if [ -L "${entry%/}" ]; then
            found_symlinks+=("$(basename "${entry%/}")")
        fi
    done

    if [ ${#found_symlinks[@]} -eq 0 ]; then
        return 0
    fi

    log_warning "Found ${#found_symlinks[@]} symlinked @sudobility package(s) (from bun/npm link):"
    for pkg in "${found_symlinks[@]}"; do
        local link_target
        link_target=$(readlink "$scope_dir/$pkg" 2>/dev/null || echo "unknown")
        log_warning "  @sudobility/$pkg -> $link_target"
        rm "$scope_dir/$pkg"
    done

    log_info "Reinstalling to fetch packages from npm..."
    pm_install >/dev/null 2>&1
    log_success "Replaced symlinks with npm packages"
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

    # Detect and remove symlinks (e.g. from bun link) in node_modules/@sudobility
    remove_sudobility_symlinks "$project_path"

    log_info "Updating @sudobility dependencies to latest..."
    local update_result=0
    update_sudobility_deps "$project_path" || update_result=$?
    if [ "$update_result" -ne 0 ]; then
        if [ "$update_result" -eq 2 ]; then
            log_error "Failed to fetch @sudobility package from npm, stopping"
        else
            log_error "Failed to update @sudobility dependencies, stopping"
        fi
        return 1
    fi

    if [ "$SUBPACKAGES_MODE" = true ]; then
        if ! process_subpackages "$project_path"; then
            log_error "Failed to process sub-packages for $(basename "$project_path")"
            return 1
        fi
    fi

    # Auto-format TypeScript projects after dependency updates to fix prettier drift
    if [ "$PKG_MANAGER" != "python" ] && [ -f "$project_path/package.json" ]; then
        local has_format_script
        has_format_script=$(node -e "const s=require('$project_path/package.json').scripts||{};console.log(s.format?'yes':'no')" 2>/dev/null) || has_format_script="no"
        if [ "$has_format_script" = "yes" ]; then
            log_info "Running format..."
            (cd "$project_path" && pm_run format) 2>&1 || true
        fi
    fi

    local has_changes=false
    if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
        has_changes=true
    fi

    # Committed-but-unpushed work counts as a change. Without this the project
    # is skipped, its commits never reach the remote, and CI never publishes --
    # while the run still reports success.
    local has_unpushed=false
    if has_unpushed_commits; then
        has_unpushed=true
    fi

    if [ "$has_changes" = true ]; then
        log_info "Changed files:"
        git diff --name-only
        git diff --cached --name-only
    fi

    if [ "$has_changes" = false ] && [ "$has_unpushed" = true ]; then
        log_info "No working-tree changes, but $(git rev-list --count '@{u}..HEAD' 2>/dev/null) commit(s) ahead of upstream -- proceeding so they are pushed"
    fi

    if [ "$has_changes" = false ] && [ "$has_unpushed" = false ] && [ "$FORCE_MODE" = false ]; then
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

    if [ -f "$project_path/package.json" ]; then
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
    fi

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

    log_section "Starting Multi-Project Update and Release Process (v$PUSH_PROJECTS_VERSION)"
    if [ "$FORCE_MODE" = true ]; then
        log_warning "FORCE MODE: Will bump version on ALL projects regardless of changes"
    else
        log_info "Logic: Update deps -> Check changes -> If changes: validate, bump, commit, push"
    fi
    if [ "$SUBPACKAGES_MODE" = true ]; then
        log_info "SUBPACKAGES MODE: Will also process /packages sub-directories"
    fi
    if [ "$CONTINUE_ON_ERROR" = true ]; then
        log_info "CONTINUE ON ERROR: Will log failures and continue to next project"
    fi
    if [ -n "$STARTING_PROJECT" ]; then
        log_info "STARTING PROJECT: Will skip projects until reaching '$STARTING_PROJECT'"
    fi

    local start_time=$(date +%s)
    local total_projects=${#projects[@]}
    local current_project=0
    local found_starting_project=false
    local changes_counter=0  # Counter for projects with changes
    # "name@version" for each project that has actually published since the
    # last wait. Kept separately from changes_counter because the two answer
    # different questions: the counter says something happened, this says what
    # is in flight on npm. A wait must poll for *these*, never for the project
    # it happens to be standing on — that one may have been skipped, in which
    # case its version is already served and the poll returns instantly,
    # granting no wait at all to whichever project really did publish.
    local pending_published_ids=()

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
            if [ "$CONTINUE_ON_ERROR" = true ]; then
                log_error "Failed to resolve path: $project_path - continuing to next project"
                FAILED_PROJECTS+=("$project_path")
                FAILED_REASONS+=("Failed to resolve path")
                continue
            else
                log_error "Failed to resolve path: $project_path"
                exit 1
            fi
        fi

        local process_result=0
        process_project "$abs_path" || process_result=$?

        if [ "$process_result" -eq 1 ]; then
            if [ "$CONTINUE_ON_ERROR" = true ]; then
                log_error "Failed to process $(basename "$abs_path") - continuing to next project"
                FAILED_PROJECTS+=("$(basename "$abs_path")")
                FAILED_REASONS+=("Validation, build, or push failed")
            else
                log_error "Failed to process $(basename "$abs_path")"
                log_error "Stopping execution (push_projects.sh v$PUSH_PROJECTS_VERSION)"
                exit 1
            fi
        elif [ "$process_result" -eq 0 ]; then
            # Project had changes and was committed
            changes_counter=$((changes_counter + 1))
            # Recorded here, at the moment it publishes, rather than read back
            # at the wait — by then the loop has moved on to another project.
            local just_published
            just_published=$(published_package_id "$abs_path")
            if [ -n "$just_published" ]; then
                pending_published_ids+=("$just_published")
            fi
        fi
        # process_result=2 means skipped (no changes), counter stays the same

        if [ "$wait_time" -gt 0 ]; then
            if [ "${#pending_published_ids[@]}" -gt 0 ]; then
                # The configured wait is treated as a floor on the cap, not as
                # the duration: a project that asked for 150s clearly expects a
                # slow publish, but the poll should still be allowed to outlast
                # it rather than give up at the number somebody guessed.
                local poll_cap="$NPM_PUBLISH_POLL_MAX"
                [ "$wait_time" -gt "$poll_cap" ] && poll_cap="$wait_time"

                # Every publish still in flight, not just the most recent —
                # several projects can publish between two waits when the ones
                # in between are configured with a 0 wait. Each poll after the
                # first is usually instant, since they were published earlier.
                local published_id
                for published_id in "${pending_published_ids[@]}"; do
                    log_info "Waiting for npm to serve $published_id (cap ${poll_cap}s)..."
                    if wait_for_npm_publish "$published_id" "$poll_cap"; then
                        log_success "npm is serving $published_id"
                    else
                        # Loud, because the consequence is a downstream project
                        # silently building against the previous version.
                        log_error "npm did not serve $published_id within ${poll_cap}s"
                        log_error "Downstream projects will resolve the PREVIOUS version — check CI for the publish job"
                        log_error "Re-run with --starting-project <next project> once the publish lands"
                    fi
                done

                # Once, after the whole set: the cache only has to be dropped
                # before the next project resolves its dependencies.
                invalidate_packument_cache

                pending_published_ids=()
                changes_counter=0
            elif [ "$changes_counter" -gt 0 ]; then
                # Something was processed, but nothing reached npm — a private
                # package, or a project that publishes no package at all. There
                # is no registry answer to wait for, so waiting is pure delay.
                log_info "$changes_counter project(s) processed, none published to npm — no wait needed"
                changes_counter=0
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

    # Print failure summary if there were failures in continue-on-error mode
    if [ "$CONTINUE_ON_ERROR" = true ] && [ ${#FAILED_PROJECTS[@]} -gt 0 ]; then
        log_section "Failure Summary"
        log_error "${#FAILED_PROJECTS[@]} project(s) failed:"
        for i in "${!FAILED_PROJECTS[@]}"; do
            log_error "  - ${FAILED_PROJECTS[$i]}: ${FAILED_REASONS[$i]}"
        done
        echo ""
        log_warning "Total time: ${minutes}m ${seconds}s"
        log_warning "Completed with ${#FAILED_PROJECTS[@]} failure(s)"
        exit 1
    fi

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
            --continue-on-error|-c)
                CONTINUE_ON_ERROR=true
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
            --no-ai)
                AI_COMMIT=false
                shift
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
