# Unified CI/CD Workflows

This repository contains reusable GitHub Actions workflows for the 0xmail.box ecosystem.

## Overview

The unified CI/CD workflow provides:
- ✅ **Automated testing** with Node.js 22.x
- 📦 **NPM publishing** for library projects
- 🐳 **Docker deployment** for containerized applications
- ☁️ **Cloudflare Pages deployment** for web applications
- 🔒 **Security checks** and linting
- 🏷️ **Automated GitHub releases**

## Usage

### For Library Projects

Create `.github/workflows/ci-cd.yml` in your project:

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      project-type: "library"
      npm-access: "restricted"  # or "public"
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### For Web Applications (Cloudflare Pages)

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      project-type: "webapp"
      cloudflare-project-name: "0xmail-box"  # optional, defaults to repo name
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
      VITE_REVENUECAT_API_KEY: ${{ secrets.VITE_REVENUECAT_API_KEY }}
      VITE_WILDDUCK_API_TOKEN: ${{ secrets.VITE_WILDDUCK_API_TOKEN }}
```

### For Docker Applications

```yaml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      project-type: "docker-app"
      docker-image-name: "mail_box_indexer"  # optional, defaults to repo name
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      DOCKER_USERNAME: ${{ secrets.DOCKER_USERNAME }}
      DOCKER_TOKEN: ${{ secrets.DOCKER_TOKEN }}
```

## Configuration Options

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `project-type` | string | ✅ Yes | - | Project type: `library`, `webapp`, or `docker-app` |
| `npm-access` | string | No | `restricted` | NPM package access: `public` or `restricted` |
| `node-version` | string | No | `22.x` | Node.js version to use |
| `cloudflare-project-name` | string | No | repo name | Cloudflare Pages project name |
| `docker-image-name` | string | No | repo name | Docker image name |

### Secrets

| Secret | Required For | Description |
|--------|--------------|-------------|
| `NPM_TOKEN` | All projects with npm dependencies | NPM authentication token |
| `DOCKER_USERNAME` | Docker apps | Docker Hub username |
| `DOCKER_TOKEN` | Docker apps | Docker Hub access token |
| `CLOUDFLARE_API_TOKEN` | Web apps | Cloudflare API token |
| `CLOUDFLARE_ACCOUNT_ID` | Web apps | Cloudflare account ID |
| `VITE_REVENUECAT_API_KEY` | Web apps (optional) | RevenueCat API key for build |
| `VITE_WILDDUCK_API_TOKEN` | Web apps (optional) | WildDuck API token for build |

## Project Types

### Library (`project-type: "library"`)

Behavior:
- ✅ Runs tests, linting, type checking
- ✅ Builds the project
- 📦 Publishes to NPM (if version changed)
- 🏷️ Creates GitHub release (if version changed)
- 🐳 **Optional**: Deploys to Docker (if secrets provided)

### Web App (`project-type: "webapp"`)

Behavior:
- ✅ Runs tests, linting, type checking
- ✅ Builds the project
- ☁️ Deploys to Cloudflare Pages (main branch only)
- 🐳 **Optional**: Deploys to Docker (if secrets provided)

### Docker App (`project-type: "docker-app"`)

Behavior:
- ✅ Runs tests, linting, type checking
- ✅ Builds the project
- 🐳 Deploys to Docker Hub (if secrets provided)

## NPM Package Access

### Public Packages

Use `npm-access: "public"` for open-source libraries:

```yaml
with:
  project-type: "library"
  npm-access: "public"
```

### Restricted Packages (Default)

Use `npm-access: "restricted"` for private @sudobility packages:

```yaml
with:
  project-type: "library"
  npm-access: "restricted"
```

## Release Behavior

### When does it release?

- ✅ On push to `main` branch
- ✅ When PR is merged to `main`
- ✅ When version in `package.json` changes
- ❌ Skipped if commit contains `[skip ci]` or `[skip-ci]`

### Version Management

The workflow automatically:
1. Checks current version in `package.json`
2. Compares with published version on NPM
3. Only publishes if version has changed
4. Creates GitHub release with tag `vX.Y.Z`

## Docker Deployment

Docker deployment is **conditional** and only runs when:
- `DOCKER_USERNAME` and `DOCKER_TOKEN` secrets are set
- Project has a `Dockerfile`

Features:
- Multi-architecture builds (arm64, amd64)
- Tags: `latest` and version tag (e.g., `v1.2.3`)
- Passes `NPM_TOKEN` as build arg for private dependencies

## Cloudflare Pages Deployment

Cloudflare deployment is **conditional** and only runs when:
- `project-type` is `webapp`
- `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` secrets are set
- Push is to `main` branch

Features:
- Deploys `dist/` directory
- Supports custom project names
- Passes build environment variables
- Non-blocking linting (continues on lint failures)

## Required Scripts in package.json

Your project should have these npm scripts:

```json
{
  "scripts": {
    "build": "...",           // Required: Build the project
    "test": "...",            // Recommended: Run tests
    "lint": "...",            // Recommended: Run linting
    "typecheck": "..."        // Recommended: Type checking (if TypeScript)
  }
}
```

## Examples by Project

### design_system
```yaml
with:
  project-type: "library"
  npm-access: "public"
```

### di, types
```yaml
with:
  project-type: "library"
  npm-access: "restricted"
```

### mail_box (Web App)
```yaml
with:
  project-type: "webapp"
  cloudflare-project-name: "0xmail-box"
secrets:
  CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
  CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

### mail_box_indexer (Docker App)
```yaml
with:
  project-type: "docker-app"
secrets:
  DOCKER_USERNAME: ${{ secrets.DOCKER_USERNAME }}
  DOCKER_TOKEN: ${{ secrets.DOCKER_TOKEN }}
```

## Troubleshooting

### NPM publish fails with 403

- Ensure `NPM_TOKEN` is set in repository secrets
- Check that token has publish permissions
- Verify package name matches @sudobility scope

### Docker build fails

- Ensure `Dockerfile` exists in repository root
- Check that `DOCKER_USERNAME` and `DOCKER_TOKEN` are set
- Verify Docker Hub credentials are valid

### Cloudflare deployment fails

- Ensure `CLOUDFLARE_API_TOKEN` has Pages edit permissions
- Verify `CLOUDFLARE_ACCOUNT_ID` is correct
- Check that build outputs to `dist/` directory

### Tests/linting/typecheck skipped

- The workflow gracefully handles missing scripts
- Warning messages are shown but don't fail the build
- Add the scripts to `package.json` to enable checks

## Updating the Workflow

To update all projects to use the latest workflow version:

1. Make changes to `.github/workflows/unified-cicd.yml` in this repo
2. Commit and push to `main` branch
3. All projects using `@main` will automatically use the new version

To use a specific version:
```yaml
uses: johnqh/workflows/.github/workflows/unified-cicd.yml@v1.0.0
```

## Migration Guide

### From existing CI/CD to unified workflow

1. **Backup existing workflow:**
   ```bash
   mv .github/workflows/ci-cd.yml .github/workflows/ci-cd.yml.backup
   ```

2. **Create new workflow file:**
   ```bash
   # Use examples above based on project type
   ```

3. **Test the workflow:**
   - Create a test branch
   - Open a PR to trigger workflow
   - Verify all jobs pass

4. **Remove backup:**
   ```bash
   rm .github/workflows/ci-cd.yml.backup
   ```

## License

MIT License - See individual project licenses for details.
