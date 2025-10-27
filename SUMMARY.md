# Unified CI/CD Workflows - Summary

## What Was Created

This repository contains a **centralized, reusable GitHub Actions workflow** for all projects in the 0xmail.box ecosystem.

### Repository Structure

```
workflows/
├── .github/
│   └── workflows/
│       └── unified-cicd.yml      # Main reusable workflow
├── examples/
│   ├── library-public.yml        # Template for public libraries
│   ├── library-restricted.yml    # Template for private libraries
│   ├── webapp-cloudflare.yml     # Template for web applications
│   └── docker-app.yml            # Template for Docker applications
├── README.md                      # Complete documentation
├── MIGRATION.md                   # Step-by-step migration guide
├── SUMMARY.md                     # This file
└── migrate-all.sh                 # Automated migration script
```

## Key Benefits

✅ **Single Source of Truth** - One workflow definition, used by all projects
✅ **Easy Maintenance** - Update once, applies everywhere
✅ **Consistent Behavior** - All projects follow the same CI/CD patterns
✅ **Conditional Deployment** - Only deploys when secrets are configured
✅ **Type-Safe Configuration** - Clear inputs for each project type

## Workflow Features

### Universal Features (All Projects)
- ✅ Node.js 22.x testing
- ✅ TypeScript type checking
- ✅ ESLint linting
- ✅ Automated tests
- ✅ Production builds

### Library Projects (`project-type: "library"`)
- 📦 NPM publishing (public or restricted)
- 🏷️ Automated GitHub releases
- 🔄 Version change detection
- 🐳 Optional Docker deployment

### Web Applications (`project-type: "webapp"`)
- ☁️ Cloudflare Pages deployment
- 🌍 Production builds with environment variables
- 🐳 Optional Docker deployment

### Docker Applications (`project-type: "docker-app"`)
- 🐳 Multi-architecture Docker builds (arm64, amd64)
- 🏷️ Version tagging (latest + semver)
- 📦 Docker Hub publishing

## How It Works

### 1. Reusable Workflow (workflows repo)

The main workflow lives at `johnqh/workflows/.github/workflows/unified-cicd.yml`

### 2. Wrapper Workflows (each project)

Each project has a minimal wrapper workflow that calls the reusable one:

```yaml
jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      project-type: "library"
      npm-access: "restricted"
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### 3. Conditional Execution

Jobs execute based on:
- **Project type** (library, webapp, docker-app)
- **Available secrets** (NPM_TOKEN, DOCKER_*, CLOUDFLARE_*)
- **Version changes** (for NPM publishing)
- **Branch** (main vs PR)

## Project Mapping

| Project | Type | NPM Access | Deployment |
|---------|------|------------|------------|
| design_system | Library | public | NPM |
| di | Library | restricted | NPM |
| mail_box | Web App | - | Cloudflare Pages |
| mail_box_components | Library | restricted | NPM |
| mail_box_configs | Library | restricted | NPM |
| mail_box_contracts | Library | restricted | NPM |
| mail_box_indexer | Docker App | - | Docker Hub |
| mail_box_indexer_client | Library | restricted | NPM |
| mail_box_lib | Library | restricted | NPM |
| types | Library | restricted | NPM |
| wildduck | Docker App | - | Docker Hub |
| wildduck_client | Library | restricted | NPM |

## Quick Start

### 1. Push Workflows Repository

```bash
cd ~/0xmail/workflows
git add .
git commit -m "Add unified CI/CD reusable workflow"
git push origin main
```

### 2. Migrate All Projects

```bash
cd ~/0xmail/workflows
./migrate-all.sh
```

### 3. Commit Each Project

```bash
# For each migrated project:
cd ~/0xmail/<project>
git add .github/workflows/ci-cd.yml
git commit -m "Migrate to unified CI/CD workflow"
git push origin main
```

## Configuration Examples

### Public Library (design_system)
```yaml
with:
  project-type: "library"
  npm-access: "public"
```

### Private Library (di, types, etc.)
```yaml
with:
  project-type: "library"
  npm-access: "restricted"
```

### Web Application (mail_box)
```yaml
with:
  project-type: "webapp"
secrets:
  CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
  CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

### Docker Application (mail_box_indexer)
```yaml
with:
  project-type: "docker-app"
secrets:
  DOCKER_USERNAME: ${{ secrets.DOCKER_USERNAME }}
  DOCKER_TOKEN: ${{ secrets.DOCKER_TOKEN }}
```

## Required Secrets

### All Projects
- `NPM_TOKEN` - For installing private @sudobility packages

### Library Projects (additionally)
- `NPM_TOKEN` - For publishing to npm

### Web Applications (additionally)
- `CLOUDFLARE_API_TOKEN` - For Cloudflare Pages deployment
- `CLOUDFLARE_ACCOUNT_ID` - Cloudflare account ID
- `VITE_REVENUECAT_API_KEY` - (optional) Build-time environment variable
- `VITE_WILDDUCK_API_TOKEN` - (optional) Build-time environment variable

### Docker Applications (additionally)
- `DOCKER_USERNAME` - Docker Hub username
- `DOCKER_TOKEN` - Docker Hub access token

## Maintenance

### Updating the Workflow

To update the workflow for all projects:

1. Edit `.github/workflows/unified-cicd.yml` in this repo
2. Commit and push changes
3. All projects using `@main` automatically use the new version

### Using Specific Versions

Projects can pin to a specific version:

```yaml
uses: johnqh/workflows/.github/workflows/unified-cicd.yml@v1.0.0
```

## Testing

### Before Deploying to All Projects

1. Test with one project first (e.g., `types`)
2. Create a PR to trigger the workflow
3. Verify all jobs execute correctly
4. Merge and verify main branch execution
5. Confirm NPM/Docker/Cloudflare deployment works

### Verification Checklist

- [ ] Workflow appears in GitHub Actions tab
- [ ] Test job runs successfully
- [ ] Type checking passes
- [ ] Linting passes
- [ ] Tests pass
- [ ] Build completes
- [ ] NPM publish works (libraries)
- [ ] Docker push works (Docker apps)
- [ ] Cloudflare deploy works (web apps)

## Troubleshooting

### Common Issues

1. **Workflow not found** - Ensure workflows repo is pushed and accessible
2. **Secrets not available** - Verify secrets are set in each repo settings
3. **NPM publish 403** - Check token permissions and package access
4. **Docker build fails** - Ensure Dockerfile exists

See [MIGRATION.md](MIGRATION.md) for detailed troubleshooting.

## Files Reference

- **[README.md](README.md)** - Complete usage documentation
- **[MIGRATION.md](MIGRATION.md)** - Step-by-step migration guide
- **[migrate-all.sh](migrate-all.sh)** - Automated migration script
- **[examples/](examples/)** - Copy-paste workflow templates

## Support

For issues or questions:
1. Check the [README](README.md) for configuration options
2. Review the [migration guide](MIGRATION.md)
3. Examine the [workflow source](.github/workflows/unified-cicd.yml)
4. Test with a PR before merging to main

---

**Version:** 1.0.0
**Last Updated:** 2025-01-27
**License:** MIT
