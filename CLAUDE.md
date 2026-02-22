# workflows - AI Development Guide

## Overview

Shared GitHub Actions CI/CD workflows, localization scripts, and utility tooling for the entire 0xmail (Web3 Email) ecosystem. The centerpiece is a single reusable GitHub Actions workflow (`unified-cicd.yml`) that auto-detects deployment targets based on which secrets are configured in consuming repositories. The repository also provides LLM-powered and batch translation scripts for i18n, a multi-project push/release orchestration script, and SVG generation utilities.

- **Package**: `@0xmail/workflows` (v1.0.0)
- **License**: MIT
- **Package Manager**: Bun (bun.lock present), npm also supported
- **Language**: YAML (GitHub Actions), Shell (Bash), CommonJS (Node.js), Python 3
- **Runtime Dependencies**: axios (^1.7.9), dotenv (^16.4.5)
- **GitHub Ref**: `johnqh/workflows` (consumed via `uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main`)

## Project Structure

```
workflows/
├── .github/workflows/
│   └── unified-cicd.yml              # The reusable CI/CD workflow (~824 lines)
├── scripts/
│   ├── localize.cjs                  # LLM-first i18n translation (LM Studio + DeepL fallback)
│   ├── localize_batch.cjs            # Batch translation via Whisperly API
│   ├── push_projects.sh              # Multi-project dependency update, validate, bump, push
│   └── svg/
│       ├── SVG.md                    # Documentation for SVG scripts
│       ├── generate_logo_svg.py      # Programmatic SVG logo generator (Sudobility S-grid)
│       ├── vectorize_logo.py         # SLIC superpixel PNG-to-SVG vectorizer
│       ├── vectorize_quantized.py    # K-means color quantization PNG-to-SVG vectorizer
│       └── vectorize_vtracer.py      # vtracer wrapper for PNG-to-SVG conversion
├── examples/
│   ├── library-public.yml            # Example: public npm library (design_system)
│   ├── library-restricted.yml        # Example: private npm library (di, types, etc.)
│   ├── docker-app.yml                # Example: Docker app (mail_box_indexer, wildduck)
│   └── webapp-cloudflare.yml         # Example: Cloudflare Pages web app (mail_box)
├── docs/
│   └── DEPLOYMENT.md                 # Step-by-step secret configuration for all providers
├── test-workflows-locally.sh         # Local CI/CD test runner for all ecosystem projects
├── package.json
├── bun.lock / package-lock.json
└── README.md
```

## Key Components

### Unified CI/CD Workflow (`.github/workflows/unified-cicd.yml`)

A single reusable `workflow_call` that every ecosystem project references. Contains seven jobs that run conditionally based on secrets and branch context.

**Jobs:**

1. **`test`** -- Always runs. Auto-detects package manager (Bun or npm). Runs type checking, linting, tests, and build. Passes `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*` secrets as build env vars. Has Rollup optional dependency workaround.

2. **`check_for_release`** -- Gates deployment jobs. Skips on `develop` branch, unmerged PRs, and `[skip ci]`/`[skip-ci]` commits. Extracts version and package name from `package.json`.

3. **`release_npm`** -- Compares `package.json` version against npm registry. Builds, creates GitHub release, publishes. Respects `npm-access` and `skip-npm-publish`.

4. **`deploy_docker`** -- Multi-arch Docker images (arm64 + amd64) via QEMU + Buildx. Checks Docker Hub API for existing tags. Tags as `latest` and `vX.Y.Z`. Passes `NPM_TOKEN` as build arg.

5. **`deploy_cloudflare`** -- Deploys `dist/` to Cloudflare Pages. Non-blocking linting.

6. **`deploy_railway`** -- Deploys via Railway CLI (`railway up --detach`).

7. **`deploy_vercel`** -- Deploys to Vercel production via CLI.

**Secret-Based Auto-Detection:**

| Secrets Present | Deployment Target |
|---|---|
| `NPM_TOKEN` | npm publish + GitHub release |
| `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` | Multi-arch Docker Hub push |
| `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | Cloudflare Pages |
| `RAILWAY_TOKEN` + `RAILWAY_SERVICE` | Railway |
| `VERCEL_TOKEN` + `VERCEL_ORG_ID` + `VERCEL_PROJECT_ID` | Vercel |
| `SMTP_HOST` + `SMTP_USERNAME` + `SMTP_PASSWORD` | Email on develop branch test failures |

**Workflow Inputs:**

| Input | Type | Default | Description |
|---|---|---|---|
| `node-version` | string | `"22.x"` | Node.js version |
| `bun-version` | string | `"latest"` | Bun version (when bun.lock detected) |
| `npm-access` | string | `"restricted"` | npm visibility (`public` or `restricted`) |
| `skip-npm-publish` | boolean | `false` | Skip npm publish (apps needing NPM_TOKEN for private deps only) |
| `cloudflare-project-name` | string | `""` | Cloudflare project name (defaults to repo name) |
| `docker-image-name` | string | `""` | Docker image name (defaults to repo name) |

**Branch Behavior:**
- `main`: Full CI/CD including deployments
- `develop`: Tests only, optional email notifications on failure
- Pull requests: Tests only

### Localization Script (`scripts/localize.cjs`)

Translates i18n JSON locale files from English (`en/`) to 15 target languages (ar, de, es, fr, it, ja, ko, pt, ru, sv, th, uk, vi, zh, zh-hant).

**Dual translation strategy:**
1. **Primary**: LM Studio local LLM (OpenAI-compatible API). Anti-hallucination safeguards: 3.0x length ratio check, max 500 tokens, temperature 0.1, 3 retries.
2. **Fallback**: DeepL API with XML tag handling for placeholders.

**Preservation**: Wraps `{placeholders}`, `{{double}}`, brand names (MetaMask, Phantom, WalletConnect, etc.), technical terms (Web3, DApp, NFT, DAO, DeFi, ENS, SNS), domain names, ISO 8601 strings, and `.box` TLD in `<xx>` tags to prevent translation.

**RTL handling**: Arabic output sanitized to remove directional control characters and validated for JSON integrity.

**Incremental**: Skips keys that already have non-empty translations.

**Required env var**: `VITE_APP_DEEPL_API_KEY` (from `.env`, `.env.local`, or `--env` flag).

### Batch Localization Script (`scripts/localize_batch.cjs`)

Alternative translation using the Whisperly batch API. Flattens JSON to dot-notation paths, identifies missing translations per language, batches strings (configurable `--batch-limit`, default 100), sends POST requests with Bearer auth, and writes output preserving source structure. Uses `fetch()` with 120s timeout and 3 retries.

**Required**: `WHISPERLY_API_KEY` via `--api-key` or env var.

### Push Projects Script (`scripts/push_projects.sh`)

Multi-project orchestration for the 0xmail ecosystem. Can be sourced or run directly.

**Auto-detects package managers** (bun, pnpm, yarn, npm) via lockfiles. Provides `pm_install`, `pm_run`, `pm_exec`, `pm_version_bump` wrappers.

**Per-project pipeline:** detect PM, update `@sudobility/*` deps to latest, optionally process sub-packages, check for changes, validate (typecheck/lint/test/build), bump patch version, update lockfile, generate descriptive commit message, commit and push.

**Flags**: `--force`/`-f`, `--subpackages`/`-s`, `--projects-file`, `--starting-project`, `--help`/`-h`. Project spec format: `path:delay_seconds`.

### SVG Utilities (`scripts/svg/`)

- **`generate_logo_svg.py`**: Generates Sudobility S-grid logo (13 gradient-colored rounded rects).
- **`vectorize_vtracer.py`**: vtracer wrapper. Best quality (PSNR ~20.6 dB). Requires `cargo install vtracer`.
- **`vectorize_quantized.py`**: K-means quantization + contour tracing. Requires cv2, numpy.
- **`vectorize_logo.py`**: SLIC superpixel segmentation with iterative refinement. Requires cv2, numpy, scipy, skimage, sklearn, rsvg-convert.

### Local Test Runner (`test-workflows-locally.sh`)

Runs CI steps locally for all ecosystem projects. Projects: `design_system` (public lib), `di`/`mail_box_components`/`mail_box_configs`/`mail_box_contracts`/`mail_box_indexer_client`/`mail_box_lib`/`types`/`wildduck_client` (restricted libs), `mail_box` (web app), `mail_box_indexer` (Docker app). Uses `build:ci` for `mail_box_contracts`. Prefers `test:unit` when available.

## Development Commands

```bash
# Localization (LM Studio + DeepL fallback)
node scripts/localize.cjs ./public/locales
node scripts/localize.cjs ./public/locales --llm-host 192.168.1.100 --llm-port 8080
node scripts/localize.cjs ./public/locales --env ./.env.local

# Batch localization (Whisperly API)
node scripts/localize_batch.cjs ./public/locales https://api.whisperly.dev/.../translate --api-key wh_xxx

# Test all ecosystem projects locally
./test-workflows-locally.sh

# Push all projects
bash scripts/push_projects.sh --projects-file ./projects.txt
bash scripts/push_projects.sh --projects-file ./projects.txt --force --subpackages

# Install dependencies for this repo
bun install   # or: npm install
```

## Architecture / Patterns

### Secret-Based Auto-Detection

Every deployment job independently checks its secrets. Adding a deployment target requires only adding secrets to GitHub repo settings -- no workflow file changes. Multiple targets coexist (e.g., npm + Docker for wildduck). Missing secrets result in a clean skip with info log.

### Package Manager Auto-Detection

The CI/CD workflow and push_projects script both detect the package manager by checking lockfiles: `bun.lock`/`bun.lockb` > `pnpm-lock.yaml` > `yarn.lock` > `package-lock.json` > default npm.

### Version-Existence Checks

Each deployment job checks its target registry before deploying, making deployments idempotent:
- **npm**: `npm view <package> version` vs `package.json`
- **Docker Hub**: HTTP GET to tags API (200 = exists, skip)

### Translation Fallback Chain

`localize.cjs`: local LLM (free, fast) -> DeepL API (reliable cloud) -> keep original English. Anti-hallucination length check (3.0x ratio) catches LLM explanatory text.

### Build Env Var Injection

Secrets matching `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*` are auto-exported during build via `jq` extraction from `${{ toJSON(secrets) }}`. No per-project configuration needed.

### Incremental Translation

Both localization scripts skip keys with existing non-empty translations.

## Common Tasks

### Adding a New Deployment Target

1. Add secret declarations under `workflow_call.secrets` in `unified-cicd.yml`
2. Add a new job: check-secrets step, guard all steps with `if: steps.check-secrets.outputs.configured == 'true'`, add version check + deploy + notification steps
3. Set `needs: [test, check_for_release]`
4. Add example in `examples/`, update README.md and docs/DEPLOYMENT.md

### Using the Workflow in a Consuming Project

Create `.github/workflows/ci-cd.yml`. See `examples/` for ready-to-copy templates:
- `library-public.yml` -- public npm (design_system)
- `library-restricted.yml` -- private npm (di, types, etc.)
- `docker-app.yml` -- Docker + develop branch notifications
- `webapp-cloudflare.yml` -- Cloudflare Pages

Minimal example (public library):
```yaml
name: CI/CD
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
permissions: { contents: write, id-token: write, deployments: write }
jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      npm-access: "public"
    secrets:
      NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Adding a New Language to Localization

1. In `localize.cjs`: add to `languages` object and `languageNames` object
2. In `localize_batch.cjs`: add to `targetLanguages` array
3. Run the script -- new language directory and translations are created automatically

### Adding Preserved Terms in Localization

In `localize.cjs` `translateWithPlaceholders()`: add to `technicalTerms` or `walletNames` arrays.

### Setting Up push_projects

Create a projects file or source the script with a PROJECTS array:
```bash
# projects.txt (path:delay_seconds)
../types:0
../di:0
../lib:60
../app:0
```
Run: `bash scripts/push_projects.sh --projects-file ./projects.txt`

### Pinning Workflow Version

Use a tag instead of `@main`: `uses: johnqh/workflows/.github/workflows/unified-cicd.yml@v1.0.0`

## Key Dependencies

### Runtime (Node.js)

| Package | Version | Purpose |
|---|---|---|
| `axios` | ^1.7.9 | HTTP client for LM Studio and DeepL APIs |
| `dotenv` | ^16.4.5 | Load `.env` files for API keys |

### CI/CD (GitHub Actions)

| Action | Version | Purpose |
|---|---|---|
| `actions/checkout` | v4 | Repository checkout |
| `actions/setup-node` | v4 | Node.js setup |
| `oven-sh/setup-bun` | v2 | Bun runtime setup |
| `docker/setup-qemu-action` | v3 | QEMU for multi-arch builds |
| `docker/setup-buildx-action` | v3 | Docker Buildx |
| `docker/login-action` | v3 | Docker Hub auth |
| `docker/metadata-action` | v5 | Image tag/label generation |
| `docker/build-push-action` | v6 | Docker build and push |
| `cloudflare/pages-action` | v1 | Cloudflare Pages deployment |
| `softprops/action-gh-release` | v2 | GitHub release creation |

### Python (SVG scripts, not in package.json)

`opencv-python`, `numpy`, `scipy`, `scikit-image`, `scikit-learn` for vectorization scripts. `vtracer` (Rust CLI, `cargo install vtracer`) and `rsvg-convert` (system CLI) for rendering.

### Ecosystem Projects

All scoped under `@sudobility/` on npm:
- Public: `design_system`
- Restricted: `di`, `mail_box_components`, `mail_box_configs`, `mail_box_contracts`, `mail_box_indexer_client`, `mail_box_lib`, `types`, `wildduck_client`
- Web apps: `mail_box`
- Docker apps: `mail_box_indexer`
