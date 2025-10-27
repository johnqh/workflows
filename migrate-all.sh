#!/bin/bash
# migrate-all.sh - Automated migration script for unified CI/CD workflows
# This script migrates all projects from individual workflows to the centralized reusable workflow

set -e  # Exit on error

PROJECTS_DIR="$HOME/0xmail"
WORKFLOWS_REPO="$PROJECTS_DIR/workflows"

# Color codes for output
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
DOCKER_APPS=("mail_box_indexer" "wildduck")

# Projects to exclude
EXCLUDE=("wildduck-dockerized" "mail_box_oauth")

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Unified CI/CD Workflow Migration Script                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if workflows repo exists
if [ ! -d "$WORKFLOWS_REPO" ]; then
    echo -e "${RED}❌ Workflows repository not found at $WORKFLOWS_REPO${NC}"
    exit 1
fi

# Check if examples exist
if [ ! -d "$WORKFLOWS_REPO/examples" ]; then
    echo -e "${RED}❌ Examples directory not found in workflows repository${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Found workflows repository${NC}"
echo -e "${YELLOW}📁 Projects directory: $PROJECTS_DIR${NC}"
echo ""

# Function to migrate a project
migrate_project() {
    local project=$1
    local template=$2
    local type=$3

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📦 Migrating: $project ($type)${NC}"

    local project_dir="$PROJECTS_DIR/$project"

    # Check if project exists
    if [ ! -d "$project_dir" ]; then
        echo -e "${RED}   ⚠️  Project directory not found: $project_dir${NC}"
        echo -e "${RED}   ⏭️  Skipping...${NC}"
        echo ""
        return
    fi

    cd "$project_dir" || return

    # Check if .github/workflows already exists
    if [ -d ".github/workflows" ]; then
        # Backup existing workflows
        echo -e "${YELLOW}   📋 Backing up existing workflows...${NC}"
        mkdir -p .github/workflows.backup
        cp -r .github/workflows/* .github/workflows.backup/ 2>/dev/null || true
    else
        # Create workflows directory
        mkdir -p .github/workflows
    fi

    # Copy template
    echo -e "${BLUE}   📝 Copying template: $template${NC}"
    cp "$WORKFLOWS_REPO/examples/$template" .github/workflows/ci-cd.yml

    # Special customizations
    if [ "$project" = "mail_box" ]; then
        # Update Cloudflare project name for mail_box
        sed -i '' 's/cloudflare-project-name: "0xmail-box"/cloudflare-project-name: "0xmail-box"/g' .github/workflows/ci-cd.yml
    elif [ "$project" = "mail_box_indexer" ]; then
        # Update Docker image name for mail_box_indexer
        sed -i '' 's/docker-image-name: "mail_box_indexer"/docker-image-name: "mail_box_indexer"/g' .github/workflows/ci-cd.yml
    elif [ "$project" = "wildduck" ]; then
        # Update Docker image name for wildduck
        sed -i '' 's/docker-image-name: "mail_box_indexer"/docker-image-name: "wildduck"/g' .github/workflows/ci-cd.yml
    fi

    echo -e "${GREEN}   ✅ Migration complete for $project${NC}"
    echo ""
}

# Display migration plan
echo -e "${YELLOW}Migration Plan:${NC}"
echo ""
echo -e "${BLUE}Public Libraries (${#PUBLIC_LIBS[@]}):${NC}"
for project in "${PUBLIC_LIBS[@]}"; do
    echo -e "  • $project"
done
echo ""

echo -e "${BLUE}Restricted Libraries (${#RESTRICTED_LIBS[@]}):${NC}"
for project in "${RESTRICTED_LIBS[@]}"; do
    echo -e "  • $project"
done
echo ""

echo -e "${BLUE}Web Applications (${#WEB_APPS[@]}):${NC}"
for project in "${WEB_APPS[@]}"; do
    echo -e "  • $project"
done
echo ""

echo -e "${BLUE}Docker Applications (${#DOCKER_APPS[@]}):${NC}"
for project in "${DOCKER_APPS[@]}"; do
    echo -e "  • $project"
done
echo ""

echo -e "${RED}Excluded Projects:${NC}"
for project in "${EXCLUDE[@]}"; do
    echo -e "  • $project (kept unchanged)"
done
echo ""

# Ask for confirmation
read -p "$(echo -e ${YELLOW}"Proceed with migration? (y/N): "${NC})" -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}❌ Migration cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}🚀 Starting migration...${NC}"
echo ""

# Migrate public libraries
for project in "${PUBLIC_LIBS[@]}"; do
    migrate_project "$project" "library-public.yml" "Public Library"
done

# Migrate restricted libraries
for project in "${RESTRICTED_LIBS[@]}"; do
    migrate_project "$project" "library-restricted.yml" "Restricted Library"
done

# Migrate web apps
for project in "${WEB_APPS[@]}"; do
    migrate_project "$project" "webapp-cloudflare.yml" "Web Application"
done

# Migrate docker apps
for project in "${DOCKER_APPS[@]}"; do
    migrate_project "$project" "docker-app.yml" "Docker Application"
done

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Migration Complete!                                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}📋 Next Steps:${NC}"
echo ""
echo -e "${BLUE}1.${NC} Review changes in each project:"
echo -e "   ${BLUE}cd ~/0xmail/<project> && git diff .github/workflows/${NC}"
echo ""
echo -e "${BLUE}2.${NC} Commit and push changes for each project:"
echo -e "   ${BLUE}cd ~/0xmail/<project>${NC}"
echo -e "   ${BLUE}git add .github/workflows/ci-cd.yml${NC}"
echo -e "   ${BLUE}git commit -m 'Migrate to unified CI/CD workflow'${NC}"
echo -e "   ${BLUE}git push origin main${NC}"
echo ""
echo -e "${BLUE}3.${NC} Verify workflows run successfully:"
echo -e "   • Check GitHub Actions tab for each project"
echo -e "   • Create test PRs to verify behavior"
echo ""
echo -e "${YELLOW}💡 Tip:${NC} Old workflows have been backed up to ${BLUE}.github/workflows.backup/${NC}"
echo ""
echo -e "${GREEN}🎉 Happy deploying!${NC}"
echo ""
