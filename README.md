# Unified CI/CD Workflows

This repository contains reusable GitHub Actions workflows for the Web3 Email ecosystem.

## Overview

The unified CI/CD workflow provides:
- ✅ **Automated testing** with Node.js 22.x
- 📦 **NPM publishing** - automatically triggered when `NPM_TOKEN` is configured
- 🐍 **Python package publishing** - enabled with `pypi-publish: true` and `PYPI_TOKEN`
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
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### For Python Library Projects (PyPI)

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
      python-version: "3.11"
      python-package-manager: "uv"
      pypi-publish: true
      # pypi-repository-url: "https://test.pypi.org/legacy/"  # optional
    secrets:
      PYPI_TOKEN: ${{ secrets.PYPI_TOKEN }}
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
| `npm-access` | string | No | `restricted` | **Deprecated / ignored.** Package access now comes from each package's `publishConfig.access` in `package.json`; the publish step no longer passes `--access`. Safe to delete from `ci-cd.yml`. |
| `skip-npm-publish` | boolean | No | `false` | Skip NPM publishing even if `NPM_TOKEN` is configured (useful for apps that need `NPM_TOKEN` only for private dependencies) |
| `notification-email` | string | No | `""` | Email address to notify on test failures (only used for `develop` branch) |
| `node-version` | string | No | `22.x` | Node.js version to use |
| `python-version` | string | No | `3.11` | Python version to use for Python projects |
| `python-package-manager` | string | No | `uv` | Python package manager: `uv` or `pip` |
| `pypi-publish` | boolean | No | `false` | Publish Python packages to PyPI when a `pyproject.toml` project changes version |
| `pypi-repository-url` | string | No | `""` | Optional PyPI repository URL, for example `https://test.pypi.org/legacy/` |
| `cloudflare-project-name` | string | No | repo name | Cloudflare Pages project name (only used if Cloudflare secrets are set) |
| `docker-image-name` | string | No | repo name | Docker image name (only used if Docker Hub secrets are set) |

### Secrets

The workflow automatically detects which deployment targets to use based on configured secrets:

| Secret | Triggers | Description |
|--------|----------|-------------|
| `NPM_TOKEN` | 📦 NPM publishing | NPM authentication token. When set, publishes package to NPM on version changes. |
| `PYPI_TOKEN` | 🐍 PyPI publishing | PyPI API token. When set with `pypi-publish: true`, publishes Python packages on version changes. |
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
- 📦 Publishes to NPM (if version changed) via **OIDC Trusted Publishing** — the
  publish step uses **no token**; a trusted publisher must be configured per package
  (see *Secret rotation & OIDC trusted publishing*). The `NPM_TOKEN` secret is
  **read-only** and is used only to install private `@sudobility/*` dependencies.
- 🏷️ Creates GitHub release with tag

### When PYPI_TOKEN is set

Automatically runs:
- 🐍 Publishes to PyPI when `pypi-publish: true`
- 🏷️ Creates GitHub release with tag
- 🔁 Supports alternate repository URLs such as TestPyPI via `pypi-repository-url`

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

Package visibility is controlled by each package's **`publishConfig.access`** in its
`package.json` — the single source of truth. The publish step runs `npm publish`
without `--access`, so npm honors that field.

```jsonc
// package.json
{
  "publishConfig": { "access": "public" }   // or "restricted"
}
```

> Note: npm locks a scoped package's visibility at its **first** publish — changing
> `publishConfig.access` afterward does not change an already-published package.
> The old `npm-access` workflow input is **deprecated and ignored**; you can remove
> it from your `ci-cd.yml`.

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
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### di, types (Restricted Library)
```yaml
secrets:
  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### tapayoka_lib (Python Library)
```yaml
with:
  python-version: "3.11"
  python-package-manager: "uv"
  pypi-publish: true
secrets:
  PYPI_TOKEN: ${{ secrets.PYPI_TOKEN }}
```

### wildduck (NPM + Docker)
```yaml
with:
  docker-image-name: "wildduck"
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

- Publishing uses **OIDC Trusted Publishing**: ensure a trusted publisher is
  configured for the package on npmjs.com, pointing at `johnqh/<repo>` + workflow
  `ci-cd.yml` (run `scripts/verify-trusted-publishers.sh`). The `NPM_TOKEN` secret
  is read-only and **cannot** publish.
- Confirm the publish job has `permissions: id-token: write` and runs npm ≥ 11.5.1
- Verify the package name matches the `@sudobility` scope

### Docker build fails

- Ensure `Dockerfile` exists in repository root
- Check that `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are set
- Verify Docker Hub credentials are valid

### Cloudflare deployment fails

- Ensure `CLOUDFLARE_API_TOKEN` has Pages edit permissions
- Verify `CLOUDFLARE_ACCOUNT_ID` is correct
- Check that build outputs to `dist/` directory

### PyPI publish fails or is skipped

- Ensure `pypi-publish: true` is set for Python library workflows
- Ensure `PYPI_TOKEN` is configured if you are using the reusable workflow
- Use `pypi-repository-url: "https://test.pypi.org/legacy/"` for TestPyPI
- If you want PyPI Trusted Publishing with OIDC, use a repository-local workflow with `permissions: id-token: write` and `pypa/gh-action-pypi-publish`

### Tests/linting/typecheck skipped

- The workflow gracefully handles missing scripts
- Warning messages are shown but don't fail the build
- Add the scripts to `package.json` to enable checks

## Secret rotation & OIDC trusted publishing

The ecosystem publishes with **OIDC Trusted Publishing** (no long-lived publish
token). The `NPM_TOKEN` secret is a **read-only** token used only to install private
`@sudobility/*` dependencies during builds. The `scripts/` helpers below manage this
across every repo/project. They read credentials from local files at runtime (never
committing or printing them) and are safe to re-run. Each takes an optional
`[projects_dir]` argument, defaulting to this repo's parent (the monorepo root).

**Prerequisites**
- `gh` authenticated with `repo` scope (`gh auth status`) — for GitHub secrets.
- The read-only npm token in `~/.npmrc` (`_authToken=…`) — the value pushed to CI.
- Cloudflare credentials in a key file (search order: `$CF_KEYFILE`,
  `~/.develop/.keys`, `~/.keys`, `~/.keys.txt`, `~/.private_keys`):
  `CLOUDFLARE_API_TOKEN`, or `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` (Global API Key).
- npm ≥ 11.5.1 and `npm login` with a **2FA-capable** account — for trusted publishing.

### scripts/rotate-npm-token-github.sh
Sets the `NPM_TOKEN` Actions secret on every `johnqh/*` repo to the token in
`~/.npmrc` (piped straight into `gh secret set`, never printed).
```bash
scripts/rotate-npm-token-github.sh
```

### scripts/rotate-npm-token-cloudflare.py
Rotates `NPM_TOKEN` in Cloudflare **Pages** env vars (production + preview) to the
`~/.npmrc` token, stored as an encrypted `secret_text`. It PATCHes only the single
`NPM_TOKEN` key (Cloudflare merges by key), snapshots each environment before, and
re-verifies afterwards that no other variable was removed or changed — stopping and
printing the originals if anything is off. Workers are intentionally untouched
(`NPM_TOKEN` is build-time only). `DRY_RUN=1` previews without writing.
```bash
DRY_RUN=1 python3 scripts/rotate-npm-token-cloudflare.py   # preview
python3 scripts/rotate-npm-token-cloudflare.py             # apply
```

### scripts/setup-trusted-publishers.sh
Bulk-configures npm Trusted Publishers (GitHub Actions, caller workflow `ci-cd.yml`)
for every publishable `@sudobility/*` package via `npm trust github`. npm **requires
interactive 2FA** for this and forbids bypass-2FA tokens, so run it yourself after
`npm login`; on the first package, click "skip 2FA for the next 5 minutes" on the npm
website so the rest proceed unattended (~80 per window). Re-running skips packages
already configured. `DRY_RUN=1` previews; `MAX=N` limits the count.
```bash
npm login
DRY_RUN=1 scripts/setup-trusted-publishers.sh   # preview
scripts/setup-trusted-publishers.sh             # apply
```

### scripts/verify-trusted-publishers.sh
Checks each publishable package with `npm trust list` and reports `OK` / `NONE` /
`CHECK` / `ERROR`, confirming every package has a trusted publisher pointing at
`johnqh/<repo>` + `ci-cd.yml`.
```bash
scripts/verify-trusted-publishers.sh
```

## Workflow Validation

### actionlint

Use [actionlint](https://github.com/rhysd/actionlint) to validate workflow YAML files before pushing:

```bash
# Via Makefile
make lint-workflows

# Or directly
./scripts/lint-workflows.sh
```

If `actionlint` is not installed, the script will provide installation instructions. Install it with:

```bash
# macOS
brew install actionlint

# Linux (Go)
go install github.com/rhysd/actionlint/cmd/actionlint@latest
```

## Version Pinning

Consuming projects can pin to a specific version of the workflows to avoid breaking changes from upstream updates.

### Available Versions

| Tag | Description |
|-----|-------------|
| `@v1` | Latest v1.x release (recommended for most projects) |
| `@v1.0.0` | Exact version pin |
| `@main` | Latest development (not recommended for production) |

### How to Pin

Use a version tag instead of `@main`:

```yaml
# Recommended: pin to major version (gets non-breaking updates)
uses: johnqh/workflows/.github/workflows/unified-cicd.yml@v1

# Exact pin (maximum stability)
uses: johnqh/workflows/.github/workflows/unified-cicd.yml@v1.0.0

# Latest (not recommended for production)
uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
```

### Upgrading

When a new major version is released:
1. Review the changelog for breaking changes
2. Update the version tag in your workflow file
3. Test with a PR before merging

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
