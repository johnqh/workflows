# Migration Guide: Unified CI/CD Workflows

This guide will help you migrate all projects from individual CI/CD workflows to the centralized reusable workflow.

## Quick Reference: Which Workflow for Each Project?

| Project | Workflow Template | NPM Access | Notes |
|---------|------------------|------------|-------|
| **design_system** | `library-public.yml` | public | Public npm package |
| **di** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box** | `webapp-cloudflare.yml` | - | Web app with Cloudflare deployment |
| **mail_box_components** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box_configs** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box_contracts** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box_indexer** | `docker-app.yml` | - | Docker application |
| **mail_box_indexer_client** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box_lib** | `library-restricted.yml` | restricted | Private @sudobility package |
| **mail_box_oauth** | `library-restricted.yml` | restricted | Private @sudobility package (if has workflow) |
| **types** | `library-restricted.yml` | restricted | Private @sudobility package |
| **wildduck** | `docker-app.yml` | - | Docker application |
| **wildduck-dockerized** | ❌ EXCLUDE | - | Keep existing multi-build setup |
| **wildduck_client** | `library-restricted.yml` | restricted | Private @sudobility package |

## Step-by-Step Migration

### Prerequisites

1. Ensure the `workflows` repository is set up:
   ```bash
   cd ~/0xmail/workflows
   git remote -v  # Should show johnqh/workflows
   ```

2. Push the unified workflow to the repository:
   ```bash
   cd ~/0xmail/workflows
   git add .github/workflows/unified-cicd.yml README.md MIGRATION.md examples/
   git commit -m "Add unified CI/CD reusable workflow"
   git push origin main
   ```

### For Each Project

#### 1. Library Projects (Public - design_system)

```bash
cd ~/0xmail/design_system

# Backup existing workflow
mv .github/workflows/ci-cd.yml .github/workflows/ci-cd.yml.backup

# Copy template
cp ~/0xmail/workflows/examples/library-public.yml .github/workflows/ci-cd.yml

# Commit changes
git add .github/workflows/ci-cd.yml
git commit -m "Migrate to unified CI/CD workflow"
git push origin main
```

#### 2. Library Projects (Restricted - di, types, etc.)

```bash
# Example for 'di' project
cd ~/0xmail/di

# Backup existing workflow
mv .github/workflows/ci-cd.yml .github/workflows/ci-cd.yml.backup

# Copy template
cp ~/0xmail/workflows/examples/library-restricted.yml .github/workflows/ci-cd.yml

# Commit changes
git add .github/workflows/ci-cd.yml
git commit -m "Migrate to unified CI/CD workflow"
git push origin main
```

**Repeat for:** mail_box_components, mail_box_configs, mail_box_contracts, mail_box_indexer_client, mail_box_lib, types, wildduck_client

#### 3. Web Application (mail_box)

```bash
cd ~/0xmail/mail_box

# Backup existing workflow
mv .github/workflows/deploy.yml .github/workflows/deploy.yml.backup
# (Also backup preview.yml if you want to keep it)

# Copy template
cp ~/0xmail/workflows/examples/webapp-cloudflare.yml .github/workflows/ci-cd.yml

# Edit cloudflare-project-name if needed
# nano .github/workflows/ci-cd.yml

# Commit changes
git add .github/workflows/ci-cd.yml
git commit -m "Migrate to unified CI/CD workflow with Cloudflare deployment"
git push origin main
```

#### 4. Docker Applications (mail_box_indexer, wildduck)

```bash
# Example for mail_box_indexer
cd ~/0xmail/mail_box_indexer

# Backup existing workflows
mv .github/workflows/test.yml .github/workflows/test.yml.backup
mv .github/workflows/docker-latest.yml .github/workflows/docker-latest.yml.backup

# Copy template
cp ~/0xmail/workflows/examples/docker-app.yml .github/workflows/ci-cd.yml

# Edit docker-image-name
sed -i '' 's/mail_box_indexer/mail_box_indexer/g' .github/workflows/ci-cd.yml

# Commit changes
git add .github/workflows/ci-cd.yml
git commit -m "Migrate to unified CI/CD workflow with Docker deployment"
git push origin main
```

**Repeat for:** wildduck (adjust docker-image-name accordingly)

## Automated Migration Script

You can use this script to migrate all projects at once:

```bash
#!/bin/bash
# migrate-all.sh

PROJECTS_DIR="$HOME/0xmail"
WORKFLOWS_REPO="$PROJECTS_DIR/workflows"

# Library projects (public)
PUBLIC_LIBS=("design_system")

# Library projects (restricted)
RESTRICTED_LIBS=("di" "mail_box_components" "mail_box_configs" "mail_box_contracts"
                 "mail_box_indexer_client" "mail_box_lib" "types" "wildduck_client")

# Web apps
WEB_APPS=("mail_box")

# Docker apps
DOCKER_APPS=("mail_box_indexer" "wildduck")

# Function to migrate a project
migrate_project() {
    local project=$1
    local template=$2

    echo "Migrating $project..."
    cd "$PROJECTS_DIR/$project" || return

    # Backup existing workflows
    if [ -d ".github/workflows" ]; then
        mkdir -p .github/workflows.backup
        cp -r .github/workflows/* .github/workflows.backup/ 2>/dev/null || true
    fi

    # Create workflows directory if not exists
    mkdir -p .github/workflows

    # Copy template
    cp "$WORKFLOWS_REPO/examples/$template" .github/workflows/ci-cd.yml

    echo "✅ Migrated $project"
}

# Migrate public libraries
for project in "${PUBLIC_LIBS[@]}"; do
    migrate_project "$project" "library-public.yml"
done

# Migrate restricted libraries
for project in "${RESTRICTED_LIBS[@]}"; do
    migrate_project "$project" "library-restricted.yml"
done

# Migrate web apps
for project in "${WEB_APPS[@]}"; do
    migrate_project "$project" "webapp-cloudflare.yml"
done

# Migrate docker apps
for project in "${DOCKER_APPS[@]}"; do
    migrate_project "$project" "docker-app.yml"
done

echo ""
echo "✅ Migration complete!"
echo ""
echo "Next steps:"
echo "1. Review changes in each project"
echo "2. Commit and push: git add .github/workflows/ci-cd.yml && git commit -m 'Migrate to unified CI/CD' && git push"
echo "3. Verify workflows run successfully on GitHub Actions"
```

Save this as `migrate-all.sh` and run:
```bash
chmod +x migrate-all.sh
./migrate-all.sh
```

## Post-Migration Checklist

For each migrated project:

- [ ] Workflow file copied to `.github/workflows/ci-cd.yml`
- [ ] Old workflow files backed up
- [ ] Changes committed and pushed to GitHub
- [ ] GitHub Actions tab shows new workflow
- [ ] Test workflow runs successfully (create a test PR)
- [ ] NPM publish works (for libraries)
- [ ] Docker push works (for Docker apps)
- [ ] Cloudflare deployment works (for web apps)

## Verifying Migration

### 1. Check Workflow Syntax
```bash
cd ~/0xmail/design_system
cat .github/workflows/ci-cd.yml
# Verify it references johnqh/workflows/.github/workflows/unified-cicd.yml@main
```

### 2. Test the Workflow

Create a test branch and PR:
```bash
git checkout -b test-unified-cicd
git push origin test-unified-cicd
# Create PR on GitHub and verify workflow runs
```

### 3. Monitor First Run

- Go to GitHub Actions tab
- Watch the workflow execution
- Verify all jobs complete successfully

## Troubleshooting

### Issue: Workflow not found
**Error:** `Unable to resolve action johnqh/workflows/.github/workflows/unified-cicd.yml@main`

**Solution:** Ensure the workflows repository is pushed and accessible
```bash
cd ~/0xmail/workflows
git push origin main
```

### Issue: Secrets not available
**Error:** Publish fails with authentication error

**Solution:** Verify secrets are set in repository settings:
- Go to Settings → Secrets and variables → Actions
- Ensure `NPM_TOKEN`, `DOCKER_USERNAME`, etc. are set

### Issue: NPM publish fails
**Error:** 403 Forbidden or 404 Not Found

**Solution:**
1. Check npm access setting matches package scope
2. Verify `NPM_TOKEN` has publish permissions
3. For first publish, may need to publish manually once

### Issue: Docker build fails
**Error:** Cannot find Dockerfile

**Solution:** Ensure `Dockerfile` exists in repository root

## Rollback Plan

If you need to rollback to the old workflow:

```bash
cd ~/0xmail/PROJECT_NAME

# Restore backup
mv .github/workflows/ci-cd.yml.backup .github/workflows/ci-cd.yml

# Commit and push
git add .github/workflows/ci-cd.yml
git commit -m "Rollback to previous CI/CD workflow"
git push origin main
```

## Benefits After Migration

✅ **Single source of truth** - Update workflow once, applies to all projects
✅ **Consistent behavior** - All projects follow same patterns
✅ **Easy maintenance** - No need to update 12+ workflow files
✅ **Faster updates** - Change workflow logic in one place
✅ **Better testing** - Standardized test/build/deploy process
✅ **Clear documentation** - Central README for all CI/CD

## Support

If you encounter issues:
1. Check the [main README](README.md) for configuration options
2. Review the [example workflows](examples/)
3. Look at the [unified workflow source](.github/workflows/unified-cicd.yml)
4. Test with a PR before merging to main
