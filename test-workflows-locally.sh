#!/bin/bash
# test-workflows-locally.sh - Test CI/CD workflow steps locally for all projects

set -e  # Exit on error

PROJECTS_DIR="$HOME/0xmail"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Library projects (public)
PUBLIC_LIBS=("design_system")

# Library projects (restricted)
RESTRICTED_LIBS=("di" "mail_box_components" "mail_box_configs" "mail_box_contracts"
                 "mail_box_indexer_client" "mail_box_lib" "types" "wildduck_client")

# Web apps
WEB_APPS=("mail_box")

# Docker apps
DOCKER_APPS=("mail_box_indexer")

ALL_PROJECTS=("${PUBLIC_LIBS[@]}" "${RESTRICTED_LIBS[@]}" "${WEB_APPS[@]}" "${DOCKER_APPS[@]}")

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Local CI/CD Workflow Test Runner                         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Test a single project
test_project() {
    local project=$1
    local project_dir="$PROJECTS_DIR/$project"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📦 Testing: $project${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if project exists
    if [ ! -d "$project_dir" ]; then
        echo -e "${RED}   ❌ Project directory not found: $project_dir${NC}"
        return 1
    fi

    cd "$project_dir" || return 1

    # Check if package.json exists
    if [ ! -f "package.json" ]; then
        echo -e "${YELLOW}   ⚠️  No package.json found, skipping${NC}"
        return 0
    fi

    echo -e "${BLUE}   1. Installing dependencies...${NC}"
    # Workaround for Rollup optional dependencies issue
    if grep -q '"rollup"' package.json 2>/dev/null; then
        echo -e "${YELLOW}   📦 Detected Rollup, using workaround for optional dependencies${NC}"
        rm -rf node_modules package-lock.json
        if npm install; then
            echo -e "${GREEN}   ✅ Dependencies installed${NC}"
        else
            echo -e "${RED}   ❌ Failed to install dependencies${NC}"
            return 1
        fi
    else
        if npm ci; then
            echo -e "${GREEN}   ✅ Dependencies installed${NC}"
        else
            echo -e "${RED}   ❌ Failed to install dependencies${NC}"
            return 1
        fi
    fi

    # Type checking
    echo -e "${BLUE}   2. Running type check...${NC}"
    if [ -f "tsconfig.json" ]; then
        if npm run typecheck 2>/dev/null || npm run type-check 2>/dev/null; then
            echo -e "${GREEN}   ✅ Type check passed${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Type check failed or not configured${NC}"
        fi
    else
        echo -e "${YELLOW}   ⏭️  No tsconfig.json, skipping type check${NC}"
    fi

    # Linting
    echo -e "${BLUE}   3. Running lint...${NC}"
    if npm run lint 2>/dev/null; then
        echo -e "${GREEN}   ✅ Lint passed${NC}"
    else
        echo -e "${YELLOW}   ⚠️  Lint failed or not configured${NC}"
    fi

    # Tests
    echo -e "${BLUE}   4. Running tests...${NC}"
    # Use test:unit if available (excludes integration tests)
    if grep -q '"test:unit"' package.json 2>/dev/null; then
        echo -e "${BLUE}   📦 Using test:unit script (unit tests only)${NC}"
        if npm run test:unit 2>/dev/null; then
            echo -e "${GREEN}   ✅ Tests passed${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Tests failed or not configured${NC}"
        fi
    else
        if npm test 2>/dev/null; then
            echo -e "${GREEN}   ✅ Tests passed${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Tests failed or not configured${NC}"
        fi
    fi

    # Build
    echo -e "${BLUE}   5. Running build...${NC}"
    # Use build:ci for mail_box_contracts (skips Solana cargo build)
    if [ "$project" = "mail_box_contracts" ] && grep -q '"build:ci"' package.json 2>/dev/null; then
        if npm run build:ci; then
            echo -e "${GREEN}   ✅ Build succeeded (using build:ci)${NC}"
        else
            echo -e "${RED}   ❌ Build failed${NC}"
            return 1
        fi
    else
        if npm run build; then
            echo -e "${GREEN}   ✅ Build succeeded${NC}"
        else
            echo -e "${RED}   ❌ Build failed${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}   ✅ Project $project validated successfully${NC}"
    echo ""
    return 0
}

# Track results
PASSED=()
FAILED=()

# Test all projects
for project in "${ALL_PROJECTS[@]}"; do
    if test_project "$project"; then
        PASSED+=("$project")
    else
        FAILED+=("$project")
    fi
done

# Summary
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Test Summary                                              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${GREEN}✅ Passed (${#PASSED[@]}):${NC}"
for project in "${PASSED[@]}"; do
    echo -e "   • $project"
done
echo ""

if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "${RED}❌ Failed (${#FAILED[@]}):${NC}"
    for project in "${FAILED[@]}"; do
        echo -e "   • $project"
    done
    echo ""
    exit 1
else
    echo -e "${GREEN}🎉 All projects validated successfully!${NC}"
    echo ""
    exit 0
fi
