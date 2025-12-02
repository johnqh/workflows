# Unified CI/CD Workflows

This repository contains reusable GitHub Actions workflows for the Web3 Email ecosystem.

## Overview

The unified CI/CD workflow provides:
- ✅ **Automated testing** with Node.js 22.x
- 📦 **NPM publishing** - automatically triggered when `NPM_TOKEN` is configured
- 🐳 **Docker deployment** - automatically triggered when Docker Hub secrets are configured
- ☁️ **Cloudflare Pages deployment** - automatically triggered when Cloudflare secrets are configured
- 🔒 **Security checks** and linting
- 🏷️ **Automated GitHub releases**

**Key Feature**: The workflow automatically detects which deployment targets to use based on configured secrets. No need to specify a project type!

## Usage

### For Library Projects (NPM Only)

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
      npm-access: "restricted"  # or "public"
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### For Docker Applications (Docker Only)

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
      docker-image-name: "mail_box_indexer"  # optional, defaults to repo name
    secrets:
      DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

### For NPM + Docker (e.g., wildduck)

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
      docker-image-name: "wildduck"
      npm-access: "restricted"
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
      DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
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
      cloudflare-project-name: "{project_name}"  # optional, defaults to repo name
    secrets: inherit  # Pass all repository secrets to the workflow
```

## Configuration Options

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `npm-access` | string | No | `restricted` | NPM package access: `public` or `restricted` (only used if `NPM_TOKEN` is set) |
| `skip-npm-publish` | boolean | No | `false` | Skip NPM publishing even if `NPM_TOKEN` is configured (useful for apps that need `NPM_TOKEN` only for private dependencies) |
| `notification-email` | string | No | `""` | Email address to notify on test failures (only used for `develop` branch) |
| `node-version` | string | No | `22.x` | Node.js version to use |
| `cloudflare-project-name` | string | No | repo name | Cloudflare Pages project name (only used if Cloudflare secrets are set) |
| `docker-image-name` | string | No | repo name | Docker image name (only used if Docker Hub secrets are set) |

### Secrets

The workflow automatically detects which deployment targets to use based on configured secrets:

| Secret | Triggers | Description |
|--------|----------|-------------|
| `NPM_TOKEN` | 📦 NPM publishing | NPM authentication token. When set, publishes package to NPM on version changes. |
| `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` | 🐳 Docker deployment | Docker Hub credentials. When both are set, builds and pushes Docker images. |
| `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | ☁️ Cloudflare Pages | Cloudflare credentials. When both are set, deploys to Cloudflare Pages. |
| `RAILWAY_TOKEN` + `RAILWAY_SERVICE` | 🚂 Railway deployment | Railway credentials. When both are set, deploys to Railway. |
| `VERCEL_TOKEN` + `VERCEL_ORG_ID` + `VERCEL_PROJECT_ID` | ▲ Vercel deployment | Vercel credentials. When all three are set, deploys to Vercel. |
| `SMTP_HOST` + `SMTP_USERNAME` + `SMTP_PASSWORD` | 📧 Email notifications | SMTP server credentials. When set with `notification-email` input, sends email on test failures (develop branch only). |
| `SMTP_PORT` | Email config | SMTP server port (optional, defaults to 587) |
| `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*` | 🏗️ Build env vars | Any secrets starting with these prefixes are automatically passed to build process |

## How It Works

The workflow intelligently detects what to deploy based on configured secrets:

### All Projects

Always runs:
- ✅ Tests, linting, type checking
- ✅ Build verification with automatic environment variable injection

**Build Environment Variables**: The workflow automatically passes all secrets with common build prefixes (`VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*`) to the build process. This means you can add any build-time environment variables to your repository secrets and they'll be automatically available during the build without modifying the workflow file.

### When NPM_TOKEN is set

Automatically runs:
- 📦 Publishes to NPM (if version changed)
- 🏷️ Creates GitHub release with tag

### When Docker Hub secrets are set

Automatically runs:
- 🐳 Builds multi-arch Docker images (arm64, amd64)
- 🐳 Pushes to Docker Hub with `latest` and version tags

### When Cloudflare secrets are set

Automatically runs:
- ☁️ Deploys to Cloudflare Pages
- ☁️ Supports custom project names

### Multiple Targets

You can deploy to multiple targets simultaneously! For example:
- NPM + Docker Hub (like wildduck)
- Cloudflare Pages + Docker Hub
- All three targets at once

## NPM Package Access

### Public Packages

Use `npm-access: "public"` for open-source libraries:

```yaml
with:
  npm-access: "public"
```

### Restricted Packages (Default)

Use `npm-access: "restricted"` for private packages:

```yaml
with:
  npm-access: "restricted"
```

### Skip NPM Publishing (Apps Only)

For applications (Docker apps, web apps) that need `NPM_TOKEN` only for installing private dependencies but shouldn't publish to NPM:

```yaml
with:
  skip-npm-publish: true  # This is an app, not an NPM library
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}  # Used for installing @sudobility/* packages
```

**Use cases:**
- Bun/Ponder applications like `mail_box_indexer`
- Docker applications that consume NPM packages but aren't libraries
- Web applications that use private dependencies but deploy to Cloudflare/Vercel

**Note:** If `skip-npm-publish: true` is set, the workflow will:
- Still use `NPM_TOKEN` to install private dependencies during build/test
- Skip creating GitHub releases
- Skip publishing to NPM

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

## Develop Branch Support

The workflow supports a `develop` branch for CI testing without deployments:

### Behavior on `develop` Branch

- ✅ Runs all tests (lint, type-check, unit tests, build)
- ❌ Skips all deployments (NPM, Docker, Cloudflare, Railway, Vercel)
- ❌ Skips GitHub release creation
- 📧 Sends email notification on test failure (if configured)

### Email Notifications for Test Failures

Configure email notifications for `develop` branch test failures:

```yaml
on:
  push:
    branches:
      - main
      - develop  # Add develop branch

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      notification-email: ${{ vars.NOTIFICATION_EMAIL }}  # Set this variable in repo settings
    secrets:
      SMTP_HOST: ${{ secrets.SMTP_HOST }}
      SMTP_PORT: ${{ secrets.SMTP_PORT }}  # Optional, defaults to 587
      SMTP_USERNAME: ${{ secrets.SMTP_USERNAME }}
      SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
```

**Setup:**
1. Set `NOTIFICATION_EMAIL` variable in repository settings (Settings > Secrets and variables > Actions > Variables)
2. Configure SMTP secrets in repository settings (Settings > Secrets and variables > Actions > Secrets):
   - `SMTP_HOST`: Your SMTP server (e.g., `smtp.gmail.com`)
   - `SMTP_USERNAME`: Your SMTP username/email
   - `SMTP_PASSWORD`: Your SMTP password or app-specific password
   - `SMTP_PORT`: (Optional) SMTP port, defaults to 587

**Email Content:**
When tests fail on `develop` branch, the notification includes:
- Repository name
- Branch name
- Commit SHA and author
- Direct link to the failed workflow run

## Docker Deployment

Docker deployment automatically runs when:
- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set
- Project has a `Dockerfile`

Features:
- Multi-architecture builds (arm64, amd64)
- Tags: `latest` and version tag (e.g., `v8.0.0`)
- Passes `NPM_TOKEN` as build arg for private dependencies
- Works alongside NPM publishing (no conflicts)

## Cloudflare Pages Deployment

Cloudflare deployment automatically runs when:
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

### design_system (Public Library)
```yaml
with:
  npm-access: "public"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### di, types (Restricted Library)
```yaml
with:
  npm-access: "restricted"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### wildduck (NPM + Docker)
```yaml
with:
  docker-image-name: "wildduck"
  npm-access: "restricted"
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
  DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
  DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

### mail_box (Web App)
```yaml
with:
  cloudflare-project-name: "{project_name}"
secrets:
  CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
  CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

### mail_box_indexer (Docker App)
```yaml
with:
  docker-image-name: "mail_box_indexer"
secrets:
  DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
  DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

## Troubleshooting

### NPM publish fails with 403

- Ensure `NPM_TOKEN` is set in repository secrets
- Check that token has publish permissions
- Verify package name matches @sudobility scope

### Docker build fails

- Ensure `Dockerfile` exists in repository root
- Check that `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are set
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
