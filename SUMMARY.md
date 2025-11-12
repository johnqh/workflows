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
✅ **Automatic Detection** - Detects deployment targets based on configured secrets
✅ **Multi-Target Support** - Deploy to multiple destinations simultaneously (NPM + Docker, etc.)
✅ **No Project Type Required** - Workflow intelligently adapts to your project

## Workflow Features

### Universal Features (All Projects)
- ✅ Node.js 22.x testing
- ✅ TypeScript type checking
- ✅ ESLint linting
- ✅ Automated tests
- ✅ Production builds

### NPM Publishing (when NPM_TOKEN is set)
- 📦 NPM publishing (public or restricted)
- 🏷️ Automated GitHub releases
- 🔄 Version change detection
- Works alongside Docker deployment

### Docker Deployment (when Docker Hub secrets are set)
- 🐳 Multi-architecture Docker builds (arm64, amd64)
- 🏷️ Version tagging (latest + semver)
- 📦 Docker Hub publishing
- Works alongside NPM publishing

### Cloudflare Pages (when Cloudflare secrets are set)
- ☁️ Cloudflare Pages deployment
- 🌍 Production builds with environment variables
- Can also deploy to Docker Hub simultaneously

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
      npm-access: "restricted"  # Only needed if publishing to NPM
      docker-image-name: "wildduck"  # Only needed if deploying to Docker
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

### 3. Automatic Detection

Jobs execute based on:
- **Available secrets** - Workflow detects what to deploy based on configured secrets
  - NPM_TOKEN → NPM publishing
  - DOCKERHUB_USERNAME + DOCKERHUB_TOKEN → Docker Hub deployment
  - CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID → Cloudflare Pages
- **Version changes** (for NPM publishing)
- **Branch** (main vs PR)

## Project Mapping

| Project | NPM Access | Deployment Targets |
|---------|------------|-------------------|
| design_system | public | NPM |
| di | restricted | NPM |
| mail_box | - | Cloudflare Pages |
| mail_box_components | restricted | NPM |
| mail_box_configs | restricted | NPM |
| mail_box_contracts | restricted | NPM |
| mail_box_indexer | - | Docker Hub |
| mail_box_indexer_client | restricted | NPM |
| mail_box_lib | restricted | NPM |
| types | restricted | NPM |
| **wildduck** | **restricted** | **NPM + Docker Hub** |
| wildduck_client | restricted | NPM |

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
  npm-access: "public"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Private Library (di, types, etc.)
```yaml
with:
  npm-access: "restricted"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### NPM + Docker (wildduck)
```yaml
with:
  docker-image-name: "wildduck"
  npm-access: "restricted"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
  DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
  DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

### Web Application (mail_box)
```yaml
with:
  cloudflare-project-name: "0xmail-box"
secrets:
  CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
  CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

### Docker Application (mail_box_indexer)
```yaml
with:
  docker-image-name: "mail_box_indexer"
secrets:
  DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
  DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

## Required Secrets

The workflow automatically detects what to deploy based on which secrets are configured:

### For NPM Publishing
- `NPM_TOKEN` - NPM authentication token (triggers NPM publishing when set)

### For Docker Hub Deployment
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_TOKEN` - Docker Hub access token
- Both required to trigger Docker deployment

### For Cloudflare Pages Deployment
- `CLOUDFLARE_API_TOKEN` - For Cloudflare Pages deployment
- `CLOUDFLARE_ACCOUNT_ID` - Cloudflare account ID
- Both required to trigger Cloudflare deployment

### Build Environment Variables (Automatic)

The workflow automatically detects and passes all secrets with these prefixes to the build process:
- `VITE_*` - Vite environment variables
- `REACT_APP_*` - Create React App environment variables
- `NEXT_PUBLIC_*` - Next.js public environment variables
- `BUILD_*` - Generic build environment variables

**No workflow changes needed** - just add your build-time secrets to the repository with the appropriate prefix!

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
