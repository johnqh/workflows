# Private Python CI/CD for the Tapayoka Pi family

Date: 2026-07-08
Status: approved, not yet implemented
Supersedes: an earlier draft that assumed public PyPI publication. That approach is dead —
see "Why not PyPI".

## Problem

`tapayoka_pi/pyproject.toml:8` declares a direct-URL requirement pointing at an absolute
macOS path:

```
"tapayoka-pi-core @ file:///Users/johnhuang/projects/tapayoka_pi_core"
```

pip must resolve it, so it fails anywhere that path does not exist. This is not theoretical:

- **CI has been red on every push since 2026-06-24.** Run `28619382387`:
  `ERROR: Could not install packages due to an OSError: [Errno 2] No such file or directory:
  '/Users/johnhuang/projects/tapayoka_pi_core'`. Introduced by `f304beb`
  (`refactor: extract policy to shared core`). Three commits have since landed on `main`,
  each with a failing check.
- **`docker compose up --build` cannot work** — `tapayoka_pi/Dockerfile:12` runs `pip install .`
  inside `python:3.11-slim`.
- Any fresh clone by anyone who is not `johnhuang` fails to install.

## Goal

`tapayoka_pi` resolves `tapayoka_pi_core` from CI, from Docker, and from a fresh clone —
with both repos **private**, and with releases driven by the shared `johnqh/workflows`
reusable workflow.

## Why not PyPI

PyPI has no private packages. From <https://pypi.org/help/>:

> "PyPI does not support publishing private packages."
> "If you need to publish your private package to a package index, the recommended solution
> is to run your own deployment of the devpi project."

There is no paid or org-scoped private tier. This is the asymmetry with the existing
`@sudobility` npm setup, which works only because **npmjs.com sells private packages** as a
paid org feature.

GitHub Packages is not an escape hatch either: it supports npm, RubyGems, Maven, Gradle,
NuGet, and Docker. **Python/pip is not supported.**

## Decision

Distribute `tapayoka_pi_core` as a **git dependency against a tag**, with no package index:

```
"tapayoka-pi-core @ git+ssh://git@github.com/johnqh/tapayoka_pi_core@v0.1.0"
```

Rationale: two Python packages, one consumer, zero external users. A private index
(Cloudsmith, Gemfury, AWS CodeArtifact) or a self-hosted devpi is real infrastructure and
recurring cost for that. Git tags supply versioning; the tag *is* the release.

Consequence accepted: **there is no PyPI publishing.** The Python half of the reusable
workflow runs with `pypi-publish: false`, exercising only test/lint/typecheck plus tagging.

`tapayoka_pi_pico` is out of scope — MicroPython, manually built, vendors its own copy of the
core. Unchanged.

## Constraints discovered

- **111 repos call `johnqh/workflows/.github/workflows/unified-cicd.yml@main`** — unpinned, at
  `main`. Any change lands for all of them on their next push. Every change below must be
  additive with behavior-preserving defaults.
- **`signic_sdk_py` is a second Python caller** (`secrets: inherit`, `pypi-publish` unset →
  default `false`). A new release job gated only on `has_pyproject_toml` would begin cutting
  git tags in that repo. New behavior must be opt-in via a new input.
- **`tapayoka_pi` already has a standalone `.github/workflows/ci-cd.yml`** that does not use
  the reusable workflow. It runs `ruff check src/ tests/` and `mypy src/ --ignore-missing-imports`
  with **no `|| true`**, making it *stricter* than the shared workflow. Migrating it onto
  `unified-cicd.yml` is a rigor **downgrade** unless W3 lands first. W3 is therefore a
  prerequisite, not an enhancement.

## Part 1 — `workflows`

### W1. Tag and GitHub Release without PyPI

`release_pypi` (`:568`) is the only job that tags a Python repo and cuts a GitHub Release. It
is gated on `inputs.pypi-publish == true` (`:574`) and further, per-step, on `PYPI_TOKEN`
being present (`:581-591`). With `pypi-publish: false` no tag is ever created — and a git
dependency has nothing to pin against.

Add a `github-release` boolean input, **default `false`**. Restructure so the tag +
`softprops/action-gh-release` steps run when `github-release == true && should_release &&
has_pyproject_toml`, while the `twine` steps remain gated on `pypi-publish` + `PYPI_TOKEN`.

Default `false` keeps `signic_sdk_py` and all 111 callers on today's behavior.

**The new job needs its own tag-existence guard.** `check_for_release` (`:309-405`) sets
`should_release=true` unconditionally on every non-develop `main` push that lacks `[skip ci]` —
it never compares the version against existing tags. Its own comment at `:405` states: *"Each
deploy job will check its own registry for version existence."* `release_pypi` satisfies this
via the PyPI JSON lookup at `:610`. A git-tag job has no registry, so it must check directly:

```
if git rev-parse "refs/tags/$VERSION_TAG" >/dev/null 2>&1; then skip; fi
```

Without this, every push with an unchanged version re-tags the same version.

### W2. Private git-dependency support

The `secrets:` block (`:20-80`) carries no git credential, so `pip install` cannot fetch a
dependency from a private GitHub repo.

Add secret `GIT_DEP_TOKEN` (`required: false`) — a fine-grained PAT with read-only Contents
access to `tapayoka_pi_core`. In the "Install Python dependencies" step (`:116`), when the
secret is non-empty:

```
git config --global url."https://x-access-token:${GIT_DEP_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
```

This rewrites `git+ssh://` URLs to authenticated HTTPS, so no SSH agent is needed on the
runner. When the secret is absent the step is a no-op and behavior is unchanged.

### W3. Stop the silent skips

Three independent ways the Python path reports green having verified nothing:

1. `:127` runs `pip install -e ".[dev]"`. **Verified locally:** on a project with no `dev`
   extra, pip exits **0** emitting only `WARNING: <pkg> does not provide the extra 'dev'`.
   `:157` then finds no pytest and logs "pytest not installed, skipping tests". The job is
   green. `tapayoka_pi_core` has no `dev` extra today, so this is exactly what its CI would do.
2. `:152` is `mypy src/ --ignore-missing-imports || true`. Type errors can never fail the build.
3. `:127` installs only the `dev` extra, so `tapayoka_pi`'s `ws` extra (websockets) is never
   installed.

Add two inputs:

- `python-extras` (string, default `"dev"`) — so `tapayoka_pi` can pass `"dev,ws"`.
- `python-strict` (boolean, default `false`) — when true, fail if pytest or ruff are absent
  after install, and drop the `|| true` from the mypy step.

Both defaults preserve current behavior for the other 110 callers.

### W4. Explicitly not fixed

The private-index code path has three latent bugs. Option A never touches a private index, so
they are recorded, not fixed:

- `:621-635` — the "already published?" guard fetches `{base}/pypi/{name}/json`. That is
  Warehouse's JSON API, served only by pypi.org and test.pypi.org. Against any other index the
  request raises, the bare `except` prints `0.0.0`, and the guard concludes "not published"
  **every time**. It then always attempts an upload, which 400s on a duplicate. It fails
  silently in the unsafe direction.
- `:665` — `twine upload dist/*` has no `--skip-existing`.
- `:667` — `TWINE_USERNAME` is hardcoded to `__token__`. AWS CodeArtifact requires `aws`;
  other indexes differ. Needs a `pypi-username` input.

## Part 2 — `tapayoka_pi_core`

- Add `[project.optional-dependencies] dev = ["pytest", "ruff", "mypy"]`.
- Add `[tool.ruff]` (line-length 100, `target-version = "py39"` — `requires-python` is `>=3.9`,
  not 3.11) and `[tool.mypy]`.
- Add `.github/workflows/ci-cd.yml` calling `unified-cicd.yml@main` with
  `python-package-manager: "pip"`, `pypi-publish: false`, `github-release: true`,
  `python-strict: true`.
- Repo stays private (already is).

**Dropped from the earlier draft:** the `LICENSE` / BUSL-1.1 work. It existed because public
PyPI distribution needs stated terms. A private repo consumed over a git URL distributes to
nobody. Cheap to add later; no longer load-bearing.

## Part 3 — `tapayoka_pi`

- `pyproject.toml:8` → `"tapayoka-pi-core @ git+ssh://git@github.com/johnqh/tapayoka_pi_core@<TAG>"`,
  where `<TAG>` is the tag Part 2 actually produced (see the open question above).
- Add the missing `[build-system]` table. There is none today, so `pip install .` falls back to
  setuptools legacy auto-discovery.
- Replace the standalone `.github/workflows/ci-cd.yml` with a wrapper calling `unified-cicd.yml@main`
  using `python-extras: "dev,ws"`, `python-strict: true`, `github-release: true`,
  `pypi-publish: false`, and `GIT_DEP_TOKEN`.
- `Dockerfile`: multi-stage. Builder installs `git` + `openssh-client`, adds github.com to
  `known_hosts`, and runs `RUN --mount=type=ssh pip install ".[pi]"`. `docker-compose.yml` gains
  `build: { ssh: [default] }`. Requires BuildKit.
- The Dockerfile change also fixes a **separate pre-existing bug**: `:12` installs no extras, so
  bluezero and RPi.GPIO never land, despite `docker-compose.yml` running `privileged: true` +
  `network_mode: host` (the BLE/GPIO production path). Removing the `file://` dep alone would
  produce an image that builds and then fails at import.
- Flip repo visibility to private. **Outward-facing and confirmed separately before running.**
- Local dev unchanged: `pip install -e ../tapayoka_pi_core` still shadows the git dep.

## Part 4 — version propagation

`push_projects.sh:927-942` bumps `pyproject.toml` versions for Python projects, and
`push_all.sh:25,27,28` already walks `tapayoka_pi_core` → `tapayoka_pi` → `tapayoka_pi_pico` in
dependency order. But **nothing rewrites `tapayoka_pi`'s `@v0.1.0` pin when core releases.**
The script updates `@sudobility` npm deps to latest; there is no Python equivalent.

Add `update_python_git_deps()` to `push_projects.sh`: after a Python project's version bump and
tag, rewrite `git+ssh://...@vX.Y.Z` pins in downstream `pyproject.toml` files.

Rejected alternative: pin to `@main`. Zero script work, but Docker rebuilds silently pick up new
core. Unacceptable for firmware.

## Implementation order

1. **W1–W3** in `workflows`. Lint with `scripts/lint-workflows.sh` (actionlint) before pushing.
2. **Part 2** — `tapayoka_pi_core` gets a `dev` extra and a wrapper. Push; confirm CI is green
   *and that pytest actually ran* (the whole point of W3). Confirm tag `v0.1.0` is created.

   Resolved: `check_for_release` sets `should_release=true` on any non-develop `main` push and
   emits `version_tag=v${version}`, so core's current `0.1.0` yields `v0.1.0` on first push.
   Still verify against the real run before writing the pin.

3. **Part 3** — `tapayoka_pi` pyproject + wrapper + Dockerfile. Pin `@v0.1.0`, confirmed against
   the tag Part 2 actually produced. Confirm CI green, `docker compose build` succeeds, container
   imports bluezero.
4. **Part 4** — `push_projects.sh` propagation.
5. Visibility flip, explicitly confirmed.

Phases 2 and 3 are the checkpoints: if `tapayoka_pi_core`'s CI goes green without running tests,
W3 is wrong and must be fixed before proceeding.

## Verification

- `scripts/lint-workflows.sh` passes on the modified `unified-cicd.yml`.
- One TypeScript caller's CI still passes after the `workflows` change (additive-only claim).
- `tapayoka_pi_core` CI log shows pytest collecting and running `tests/test_policy.py`, not
  "pytest not installed, skipping tests".
- A version tag exists on `tapayoka_pi_core` after its first post-change push, and the pin in
  `tapayoka_pi/pyproject.toml` names that exact tag.
- `tapayoka_pi` CI installs `tapayoka-pi-core` from the git URL and goes green — the first green
  run since 2026-06-24.
- `docker compose build --ssh default` succeeds, and `docker run ... python -c "import bluezero"`
  succeeds.
- A scratch clone of `tapayoka_pi` with core access can `pip install -e ".[dev]"`.

## Risks

- **Blast radius.** 111 repos consume `unified-cicd.yml@main`. The user chose to develop straight
  on `main` with additive-only changes rather than proving on a branch. Mitigation: actionlint
  before push, and every new input defaults to preserving current behavior.
- **Visibility flip.** Making `tapayoka_pi` private breaks existing clones and forks, drops stars,
  and starts charging Actions minutes against the free quota (public repos are unlimited). The
  public `johnqh/workflows` reusable workflow remains callable from a private repo.
- **Access coupling.** After this, nobody without `tapayoka_pi_core` access can build
  `tapayoka_pi` — including its Docker image. That is the intent of "private", but it is a real
  change from today.
- **Docker credentials.** The image can no longer be built in an environment with no GitHub
  credentials. CI must supply `GIT_DEP_TOKEN`; humans must have SSH agent forwarding.
