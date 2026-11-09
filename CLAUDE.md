# workflows — AI Development Guide

> **Git policy — never auto-commit or auto-push.** Leave your work in the working tree.
> Run `git commit`, `git push`, `gh pr create`, or `scripts/push_projects.sh` **only when the
> user explicitly asks in that turn**. Approval for an earlier change does not carry forward,
> and finishing a task is not permission to commit it. Stay on the current branch; do not
> create feature branches for code changes.

## What this is

The shared repo `johnqh/workflows` (published as the **private** package `@0xmail/workflows`,
currently v1.0.50). It is consumed by the whole Sudobility / 0xmail family — RN apps, TS
libraries, web apps, Python packages — via GitHub Actions `uses:`, raw-URL script fetches, or
checkout-alongside. Not an app; it ships reusable workflows + CLIs + scripts + RN patches.

- **Deps**: axios (~1.20.0), dotenv (~16.6.1). Package manager: Bun (`bun.lock`) or npm.
- **Languages**: YAML (Actions), Bash, CommonJS/mjs/tsx (Node), Python 3.
- Full reference lives in `README.md` and `app_store/README.md` — don't duplicate file-level
  detail here.

## Catalog (high level)

- **`.github/workflows/unified-cicd.yml`** — main reusable CI/CD, ~1500 lines, **10 jobs**:
  `test`, `check_for_release`, `release_npm`, `release_github_packages`, `release_pypi`,
  `release_python`, `deploy_docker`, `deploy_cloudflare`, `deploy_railway`, `deploy_vercel`.
  Handles Node/Bun **and** Python. Auto-detects targets from configured secrets.
- **`.github/workflows/python-cicd.yml`** — lean Python-only (test + optional tag/release,
  no publish/deploy); needs only `contents: write`.
- **`.github/workflows/app-store.yml`** — CI-able app-store submission (metadata, Android→Play,
  Windows→Microsoft Store); screenshot capture stays local.
- **`app_store/`** — the `appstore` / `store` CLI toolkit (screenshots, localize, build,
  submit across Apple/Google/Microsoft; `doctor`, `status`). See `app_store/README.md`.
- **`scripts/`** — SEO generators, i18n, token rotation, trusted-publisher setup, per-package
  publish/safety gates, Cloudflare env, cleanup, RN-patch sync, multi-repo push. See README.
- **`rn-patches/`** — canonical RN dependency patches; `manifest.json` is source of truth.

## Conventions (how consumers use it)

- Caller workflow file is **`.github/workflows/ci-cd.yml`** in each repo. This name matters:
  npm **trusted publishers** are configured against `johnqh/<repo>` + `ci-cd.yml` (NOT
  `unified-cicd.yml`).
- **Required caller permissions for `unified-cicd.yml`**: `contents: write`, `id-token: write`,
  `deployments: write` — all three, always. GitHub validates the union of all jobs' permissions
  at compile time (before `if:`), so even a Python-only/no-publish caller that grants fewer
  hits `startup_failure` with no logs. Add `packages: write` when `publish-target: github`.
  `python-cicd.yml` needs only `contents: write`.
- **`publish-target` input** (per-repo npm destination): `npm` (default) = npmjs.org via **OIDC
  trusted publishing**, no token; `github` = GitHub Packages via built-in `GITHUB_TOKEN`.
- **`NPM_TOKEN` is read-only** everywhere: installs private deps + pre-checks the published
  version. It **cannot publish** (OIDC does the npmjs publish). Apps that only need it for
  private deps pass it and set `skip-npm-publish: true`.
- **Consuming `@sudobility/*`**: this repo's `.npmrc` maps `@sudobility` →
  `https://npm.pkg.github.com` (GitHub Packages). Install auth is **`GH_PACKAGES_READ_TOKEN`**
  (read:packages PAT), falling back to `GITHUB_TOKEN`. `GIT_DEP_TOKEN` is a deprecated alias.
  Secret is named `GH_PACKAGES_READ_TOKEN` because Actions rejects `GITHUB_*` secret names.
- **Package access** comes from each package's `publishConfig.access`; the `npm-access` input
  is **deprecated and ignored** (publish runs without `--access`).
- Secret-based auto-detection: a deploy job runs only when its secrets are set. `develop` branch
  and PRs run **tests only** (no deploy, no release). Deploys happen on push to `main` only.
- Bun is pinned to **1.4.4** (not `latest`) for deterministic installs; `setup-bun` is retried
  up to 3×. Build prefers `build:ci` then `build`; tests prefer `test:unit`.
- Build env injection: secrets matching `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, `BUILD_*` are
  auto-exported into the build.
- Pin the workflow ref with `@v1` / `@v1.0.0` for stability; `@main` is latest.

## Gotchas / non-obvious

- **Bootstrap a brand-new npm package with `scripts/publish-local.sh`** — npm requires a package
  to exist before a trusted publisher can be attached; after that, CI/OIDC publishes it.
- **`scripts/check-package-entry.cjs` must run under Node, not Bun** — Bun's permissive resolver
  hides the extensionless-ESM-import bug it exists to catch.
- **rn-patches are vendored per-project** (bun `patchedDependencies`, not patch-package). The
  canonical file lives here; `scripts/sync_rn_patches.sh` copies it into each consumer's
  `patches/`, and each consumer must also declare it in its `package.json`. CI uses
  `bun install --frozen-lockfile`, so the file must be present in the consumer.
- **The old SMTP email-on-failure feature is REMOVED** from `unified-cicd.yml` (no
  `notification-email` input, no `SMTP_*` secrets, no notify job). `examples/docker-app.yml`
  still passes them — valid only against an older pinned tag, not `@main`.
- **Python is in two places with different defaults**: `unified-cicd.yml` (`python-package-manager`
  default `uv`, `github-release` default `false`, can publish to PyPI) vs `python-cicd.yml`
  (`pip`, `github-release` default `true`, no publish). Pick deliberately.
- **Trusted-publisher scripts target npmjs.com only** — `setup-/verify-trusted-publishers.sh`
  use `npm trust` (npmjs OIDC, npm ≥ 11.5.1, interactive 2FA). GitHub Packages has no
  `npm trust`, so they don't apply to packages published via `publish-target: github`. They
  hardcode `OWNER=johnqh` and workflow `ci-cd.yml`.
- **Token-rotation scripts only provision the `NPM_TOKEN` secret name** (`rotate-npm-token-github.sh`
  → Actions secret, `rotate-npm-token-cloudflare.py` → CF Pages env). They do **not** refresh
  `GH_PACKAGES_READ_TOKEN`. Rotate that separately if CI reads GitHub Packages with it.
- **`app-store.yml`'s android install hardcodes `@sudobility` → npmjs.org with `NPM_TOKEN`**
  (install-only) — inconsistent with the GitHub Packages migration path elsewhere.
- **Ecosystem-dir inconsistency**: `test-workflows-locally.sh` scans `$HOME/0xmail` (legacy);
  `push_projects.sh` / `clean*.sh` / `app_store` default to `~/projects`.
- **`scripts/svg/*` have hardcoded `/Users/johnhuang/...` input/output paths** and (except the
  vtracer one) take no CLI args — edit before reuse.

## Common dev commands

```bash
make lint-workflows          # actionlint over .github/workflows/*.yml (= ./scripts/lint-workflows.sh)
bun install                  # or: npm install
./test-workflows-locally.sh  # runs CI steps for consuming projects (expects $HOME/0xmail)
```

## Adding to the workflow

To add a deploy target to `unified-cicd.yml`: declare its secrets under
`workflow_call.secrets`, add a job with a check-secrets step (guard every step on
`steps.check-secrets.outputs.configured == 'true'`), `needs: [test, check_for_release]`, plus a
version-existence check, then add an `examples/` template and update `README.md` +
`docs/DEPLOYMENT.md`. Validate with `make lint-workflows` before pushing.
