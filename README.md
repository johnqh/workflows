# johnqh/workflows — Shared CI/CD & Tooling

The shared repository (`johnqh/workflows`, published as the private package
`@0xmail/workflows`) that the whole Sudobility / 0xmail family consumes. It holds
**reusable GitHub Actions workflows**, the **`appstore` store-submission toolkit**,
**shared build/release/i18n/SEO scripts**, and **canonical React Native dependency
patches**. Sibling repos reference the workflows with `uses:`, fetch a few scripts by
raw URL, or check this repo out alongside their own.

## What's in this repo

| Path | What it is |
|---|---|
| `.github/workflows/unified-cicd.yml` | The main reusable CI/CD workflow (~1500 lines, 10 jobs). Auto-detects deploy targets from configured secrets. Handles Node/Bun **and** Python. |
| `.github/workflows/python-cicd.yml` | Lean Python-only reusable workflow — test + optional tag/release, needs only `contents: write`. |
| `.github/workflows/app-store.yml` | Reusable workflow for the CI-able parts of app-store submission (metadata, Android→Play, Windows→Microsoft Store). |
| `app_store/` | The `appstore` / `store` CLI toolkit for screenshots, store-text localization, builds and submission to Apple / Google / Microsoft. See `app_store/README.md`. |
| `scripts/` | Shared scripts: SEO generators, i18n localization, token rotation, trusted-publisher setup, per-package publish/safety gates, Cloudflare env, cleanup, RN-patch sync, multi-repo push. See [Shared scripts](#shared-scripts). |
| `rn-patches/` | Canonical RN dependency patches (bun `patchedDependencies`) synced into consumer repos. See `rn-patches/manifest.json`. |
| `examples/` | Copy-ready caller `ci-cd.yml` templates (public/restricted npm lib, python, docker, cloudflare webapp). |
| `docs/DEPLOYMENT.md` | Per-provider secret setup guide. |

> **How `@sudobility/*` dependencies resolve:** this repo's `.npmrc` maps
> `@sudobility:registry=https://npm.pkg.github.com` (GitHub Packages). Consuming repos
> install those packages from GitHub Packages using a `GH_PACKAGES_READ_TOKEN`
> (read:packages PAT). See [NPM / GitHub Packages](#npm--github-packages--publish-target).

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

> **Required caller permissions.** GitHub validates the union of all jobs' permission
> requests at compile time, before any `if:` is evaluated. **Every** caller of
> `unified-cicd.yml` — even a Python-only or no-publish one — must declare all three or
> the run fails at startup (`startup_failure`, no logs):
>
> ```yaml
> permissions:
>   contents: write      # releases / tags
>   id-token: write      # npm OIDC provenance
>   deployments: write   # Cloudflare / Vercel
> ```
>
> For GitHub Packages publishing (`publish-target: github`) also add `packages: write`.
> The lean `python-cicd.yml` needs only `contents: write` (see
> [Other reusable workflows](#other-reusable-workflows)).

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
| `node-version` | string | No | `22.x` | Node.js version to use |
| `bun-version` | string | No | `1.4.4` | Bun version (used when `bun.lock` is detected). Pinned (not `latest`) for deterministic installs. |
| `npm-access` | string | No | `restricted` | **Deprecated / ignored.** Package access now comes from each package's `publishConfig.access` in `package.json`; the publish step no longer passes `--access`. Safe to delete from `ci-cd.yml`. |
| `skip-npm-publish` | boolean | No | `false` | Skip NPM publishing even if `NPM_TOKEN` is configured (useful for apps that need `NPM_TOKEN` only for private dependencies) |
| `publish-target` | string | No | `npm` | Where to publish the npm package: `npm` (npmjs.org via OIDC trusted publishing) or `github` (GitHub Packages via `GITHUB_TOKEN`). Set per repo to migrate it to GitHub Packages without affecting others. |
| `cloudflare-project-name` | string | No | repo name | Cloudflare Pages project name (only used if Cloudflare secrets are set) |
| `docker-image-name` | string | No | repo name | Docker image name (only used if Docker Hub secrets are set) |
| `docker-platforms` | string | No | `linux/arm64,linux/amd64` | Platforms to build. Narrow to `linux/amd64` when a dependency ships no arm64 wheel. |
| `python-version` | string | No | `3.11` | Python version to use for Python projects |
| `python-package-manager` | string | No | `uv` | Python package manager: `uv` or `pip` |
| `pypi-publish` | boolean | No | `false` | Publish Python packages to PyPI when a `pyproject.toml` project changes version |
| `pypi-repository-url` | string | No | `""` | Optional PyPI repository URL, for example `https://test.pypi.org/legacy/` |
| `github-release` | boolean | No | `false` | Create a git tag + GitHub Release for **Python** projects independent of PyPI publishing |
| `python-extras` | string | No | `dev` | Comma-separated extras to install for Python projects (pip only), e.g. `dev,ws`. Empty installs none. |
| `python-strict` | boolean | No | `false` | Fail the build when ruff/pytest are missing after install, and let mypy failures fail the build |

### Secrets

The workflow automatically detects which deployment targets to use based on configured secrets:

| Secret | Triggers | Description |
|--------|----------|-------------|
| `NPM_TOKEN` | 📦 NPM install / publish | **Read-only** npm token. Installs private `@sudobility/*` deps and pre-checks the published version. On `publish-target: npm` the actual publish uses OIDC trusted publishing, **not** this token. |
| `GH_PACKAGES_READ_TOKEN` | 📥 GitHub Packages install | GitHub PAT with `read:packages`, to install `@scope` deps from GitHub Packages across repos. Falls back to the built-in `GITHUB_TOKEN` when unset. |
| `GIT_DEP_TOKEN` | 📥 private git deps | **Deprecated** alias / PAT with read-only Contents access for private-repo git dependencies. Prefer `GH_PACKAGES_READ_TOKEN`. |
| `PYPI_TOKEN` | 🐍 PyPI publishing | PyPI API token. When set with `pypi-publish: true`, publishes Python packages on version changes. |
| `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` | 🐳 Docker deployment | Docker Hub credentials. When both are set, builds and pushes Docker images. |
| `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | ☁️ Cloudflare Pages | Cloudflare credentials. When both are set, deploys to Cloudflare Pages. |
| `RAILWAY_TOKEN` + `RAILWAY_SERVICE` | 🚂 Railway deployment | Railway credentials. When both are set, deploys to Railway. |
| `VERCEL_TOKEN` + `VERCEL_ORG_ID` + `VERCEL_PROJECT_ID` | ▲ Vercel deployment | Vercel credentials. When all three are set, deploys to Vercel. |
| `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*` | 🏗️ Build env vars | Any secrets starting with these prefixes are automatically passed to the build process |

> All secrets are `required: false`; pass only the ones your repo needs (or use
> `secrets: inherit`). The `test` job only reaches secrets you pass, so an app that
> needs `NPM_TOKEN` just for private deps still passes it and sets `skip-npm-publish: true`.

## How It Works

The workflow intelligently detects what to deploy based on configured secrets:

### All Projects

Always runs:
- ✅ Tests, linting, type checking
- ✅ Build verification with automatic environment variable injection

**Build Environment Variables**: The workflow automatically passes all secrets with common build prefixes (`VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*`) to the build process. This means you can add any build-time environment variables to your repository secrets and they'll be automatically available during the build without modifying the workflow file.

### npm package (version changed on `main`)

Automatically runs (unless `skip-npm-publish: true`):
- 📦 **`publish-target: npm` (default)** — publishes to npmjs.org via **OIDC Trusted
  Publishing** (no token; a trusted publisher must be configured per package). `NPM_TOKEN`
  is **read-only**, used only to install private `@sudobility/*` deps. Job `release_npm`.
- 📦 **`publish-target: github`** — publishes to **GitHub Packages** via `GITHUB_TOKEN`.
  Job `release_github_packages`.
- 🏷️ Either way, creates a GitHub release with tag. See
  [NPM / GitHub Packages](#npm--github-packages--publish-target).

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

## NPM / GitHub Packages & publish target

### Where packages publish (`publish-target`)

The `publish-target` input decides the npm publish destination, per repo:

- **`npm` (default)** — publishes to **npmjs.org via OIDC Trusted Publishing**. The
  publish step uses **no token**: it upgrades npm to ≥ 11.5.1, strips every token from
  the environment, and relies solely on the GitHub OIDC id-token. A **trusted publisher
  must be configured per package** on npmjs.com pointing at `johnqh/<repo>` + the caller
  workflow file **`ci-cd.yml`** (not `unified-cicd.yml`). `NPM_TOKEN` is read-only and
  cannot publish here. Job: `release_npm`.
- **`github`** — publishes to **GitHub Packages** (`npm.pkg.github.com`) using the
  built-in `GITHUB_TOKEN`. Scope is derived from the repo owner (lowercased, e.g.
  `@sudobility`). Requires the caller to grant `packages: write`. Old versions are not
  pruned. Job: `release_github_packages`.

> **Consuming** `@sudobility/*` packages (install side) is independent of where you
> publish: this repo's `.npmrc` maps `@sudobility` to GitHub Packages, and consumers
> authenticate reads with `GH_PACKAGES_READ_TOKEN` (falls back to `GITHUB_TOKEN`).

### Package access (public vs restricted)

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

## Develop Branch & Pull Requests

Add `develop` to your `on.push.branches` for CI-only testing:

- ✅ Runs all tests (lint, type-check, unit tests, build)
- ❌ Skips every deployment (npm, GitHub Packages, PyPI, Docker, Cloudflare, Railway, Vercel) and GitHub release creation

Pull requests also run tests only (no deployment). Deployments happen only on push to
`main`.

> Note: the old SMTP email-on-failure feature (`notification-email` input, `SMTP_*`
> secrets) has been **removed** from `unified-cicd.yml`. Do not pass those to `@main`.

## Docker Deployment

Docker deployment automatically runs when:
- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set
- Project has a `Dockerfile`

Features:
- Multi-architecture builds (arm64, amd64 by default; override with `docker-platforms`)
- Tags: `latest` and version tag (e.g., `v8.0.0`)
- Passes `GH_PACKAGES_TOKEN` (from `GH_PACKAGES_READ_TOKEN`, falling back to `GITHUB_TOKEN`) as a build arg for installing private dependencies
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

## Other reusable workflows

Everything above is `unified-cicd.yml`. The repo ships two more reusable workflows:

### `python-cicd.yml` — lean Python-only CI/CD

Split out from `unified-cicd.yml` so pure-Python repos grant only `contents: write`
(instead of the full `contents` + `id-token` + `deployments` union). Use it for Python
repos that do **not** publish to npm/PyPI and do **not** deploy. It runs the Python test
pipeline (ruff, mypy, pytest) and, by default, creates a git tag + GitHub Release on push
to `main`. It publishes nothing.

| Input | Default | Notes |
|---|---|---|
| `python-version` | `3.11` | |
| `python-package-manager` | `pip` | `uv` or `pip` (note: `unified-cicd.yml` defaults to `uv`) |
| `python-extras` | `dev` | comma-separated extras (pip only) |
| `python-strict` | `false` | fail on missing tooling / mypy errors |
| `github-release` | `true` | tag + GitHub Release on push to `main` (note: `unified-cicd.yml` defaults to `false`) |

Secrets (both optional): `GH_PACKAGES_READ_TOKEN`, `GIT_DEP_TOKEN` (deprecated alias) —
for cloning private git dependencies. Outputs: `released`, `version`, `tag`.

```yaml
permissions: { contents: write }
jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/python-cicd.yml@main
    secrets:
      GH_PACKAGES_READ_TOKEN: ${{ secrets.GH_PACKAGES_READ_TOKEN }}
```

### `app-store.yml` — app-store submission

Reusable workflow for the CI-able parts of store submission (screenshot **capture** stays
local — it needs simulators/emulators). It checks out `johnqh/workflows` alongside the app
repo and drives the `appstore` toolkit:

- **metadata** (ubuntu) — `appstore doctor`, optional `localize`, metadata/screenshot submit
- **android** (ubuntu) — build + submit to Google Play
- **windows** (windows) — MSIX build + submit to Microsoft Store

Inputs: `app-dir` (`.`), `platforms` (`google`; CSV of `apple,google,microsoft`), `steps`
(`submit`; CSV of `localize,submit`), `metadata-only` (`false`), `screenshots` (`false`),
`node-version` (`22.x`), `workflows-ref` (`main`). Secrets (all optional): `NPM_TOKEN`,
`WHISPERLY_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8_BASE64`,
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `MS_TENANT_ID`, `MS_CLIENT_ID`,
`MS_CLIENT_SECRET`, `MS_SELLER_APP_ID`.

```yaml
jobs:
  submit:
    uses: johnqh/workflows/.github/workflows/app-store.yml@main
    with: { platforms: "google,microsoft", steps: "localize,submit" }
    secrets: inherit
```

## App Store toolkit (`app_store/`)

The `appstore` / `store` CLI takes any app in the family through the whole store pipeline —
screenshots, store-text localization, builds, and submission to the Apple App Store, Google
Play, and Microsoft Store — from one config-driven data model. Each app keeps only its
config + credentials under `<project>/app_store/`; all logic lives here. Apps invoke it via
a repo-local `scripts/store.sh` wrapper (RN apps add a `"store"` package.json script). The
`app-store.yml` workflow above runs its CI-able steps.

See **[`app_store/README.md`](app_store/README.md)** for the flag grammar, data model
(`info.json`, `screens.json`, `languages.json`, localized `screenshots/info/<lang>/…`),
credentials, `appstore doctor` length limits, and the `appstore status` fleet dashboard.

## Shared scripts

Scripts under `scripts/` fall into three groups. Token/publisher scripts are documented
under [Secret rotation & OIDC trusted publishing](#secret-rotation--oidc-trusted-publishing).

**Fetched by consuming repos** (via `raw.githubusercontent.com/johnqh/workflows/main/...`):

| Script | Purpose |
|---|---|
| `generate-seo-assets.mjs` | Per-route, per-language `index.html` + `sitemap.xml` + `robots.txt` for multilingual static sites. Config-driven via the project's `seo.config.mjs`. `node generate-seo-assets.mjs <public\|dist>`. |
| `generate-seo-assets-v2.mjs` | Drop-in successor: sitemap **index** + per-language child sitemaps (submit English first), managed `<head>` injection, per-route `staticHtml`/`structuredData` (JSON-LD) hooks, richer robots. Same CLI/config. |

**Per-package / per-project tools** (run from a package or app root):

| Script | Purpose |
|---|---|
| `localize.cjs` | LLM-first i18n: LM Studio local LLM → DeepL fallback → keep English. 15 languages, placeholder/brand/term preservation, incremental. Needs `VITE_APP_DEEPL_API_KEY` for the fallback. |
| `localize_batch.cjs` | Alternative i18n via the Whisperly batch API (`WHISPERLY_API_KEY`). |
| `process-static-files.ts` | Generic `{{VAR}}` template processor (`index.template.html`, `public/**/*.template.*`) from `.env`/`.env.local`. |
| `generate-cloudflare-env.ts` | Build a committed `.env.production` from `.env`, baking **public** `VITE_*` config and excluding credential-looking keys. |
| `cf-pages-sync-env.sh` | Push all non-empty vars from a `.env` to a Cloudflare Pages project as secrets, via `wrangler`. (No credential filtering.) |
| `publish-local.sh` | Publish one package locally, mirroring `release_npm` — mainly to **bootstrap** a brand-new package before a trusted publisher can be attached. |
| `check-package-entry.cjs` | Post-build gate: import the package's declared entry point as a consumer would (run under **Node**, not Bun). |
| `check-publish-safety.cjs` | Refuse to publish from a dirty tree or republish an existing version (`ALLOW_DIRTY_PUBLISH=1` overrides). |
| `add-esm-extensions.cjs` | Rewrite relative TS import/export specifiers to carry explicit `.js`/`/index.js` so tsc-emitted ESM loads under Node. |

**Monorepo-wide maintenance** (iterate sibling repos, usually under `~/projects`):

| Script | Purpose |
|---|---|
| `push_projects.sh` | Update `@sudobility/*` deps, validate, bump, commit, push across many projects (CI then publishes). Registry-aware of the npmjs-vs-GitHub-Packages split; polls the registry until a publish lands. RN **apps** are never version-bumped; RN libraries are. AI commit messages via `claude -p --model haiku` (`--no-ai` to disable). |
| `sync_rn_patches.sh` | Distribute canonical RN patches from `rn-patches/` into each consumer's `patches/` (`--check` reports drift). |
| `clean.sh` / `clean_rn.sh` | Reclaim disk from TS library build output/node_modules, and from native iOS/Android build artifacts (only untracked paths). |
| `lint-workflows.sh` | Run `actionlint` over this repo's workflow YAML (`make lint-workflows`). |
| `scripts/svg/*` | PNG→SVG vectorizers + Sudobility logo generator (Python; see `scripts/svg/SVG.md`). Note: input/output paths are hardcoded and must be edited before reuse. |

## React Native patches (`rn-patches/`)

Canonical RN dependency patches for the family, applied via **bun `patchedDependencies`**
(filenames `name@version.patch`). `rn-patches/manifest.json` is the single source of truth —
it lists each patch, why it exists, and which consumer repos use it. `scripts/sync_rn_patches.sh`
copies each canonical file into its consumers' `patches/` dir so every project stays
byte-identical; each consumer must also declare the patch in its `package.json`
`patchedDependencies` (patches stay vendored per-project because CI uses
`bun install --frozen-lockfile`). No `patch-package` anywhere.

## License

MIT License - See individual project licenses for details.
