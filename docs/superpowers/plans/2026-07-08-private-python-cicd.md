# Private Python CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tapayoka_pi` resolve `tapayoka_pi_core` from CI, Docker, and fresh clones with both repos private, driven by the shared `johnqh/workflows` reusable workflow.

**Architecture:** No package index. `tapayoka_pi` depends on `tapayoka_pi_core` via `git+ssh://` pinned to a tag. The shared `unified-cicd.yml` gains three opt-in inputs and one secret so it can (a) install private git dependencies, (b) actually run Python tests instead of silently skipping them, and (c) cut a git tag without publishing to PyPI.

**Tech Stack:** GitHub Actions reusable workflows, setuptools, pip, pytest, ruff, mypy, Docker BuildKit.

## Global Constraints

- **`unified-cicd.yml` has 111 callers at `@main`, unpinned.** Every new input MUST default to preserving current behavior. A YAML error breaks all 111 on their next push.
- `tapayoka_pi_core` targets `requires-python = ">=3.9"`. Ruff/mypy config must target py39, not py311.
- `tapayoka_pi_core` has **zero runtime dependencies**. Do not add any.
- `tapayoka_pi_pico` is out of scope. Do not modify it.
- Never run `git push` or change repo visibility without explicit user confirmation. Both are outward-facing.
- `mypy` strict mode is NOT enabled on core — `policy.py` has untyped defs and would fail.

## Environment Prerequisites

These must exist before starting. Verify, do not assume.

- [ ] **actionlint installed.** `command -v actionlint` currently fails on this machine.
  Install: `brew install actionlint`. Required by `workflows/scripts/lint-workflows.sh`.
- [ ] **Docker installed.** `docker` is currently **not on PATH** on this machine.
  Task 10 cannot be verified without it. Either install Docker Desktop, or accept that
  Task 10 ships unverified and say so explicitly.
- [ ] **`tapayoka_pi` working tree is clean.** It currently has uncommitted work:
  `M README.md`, `M src/command_handler.py`, `M tests/test_command_handler.py`,
  `?? docs/pins.md`, `?? src/pin_mapping.py`. Commit or stash before Task 8.

---

## Task 1: Add opt-in inputs and the git-dependency secret to `unified-cicd.yml`

Pure surface-area addition. No step reads these yet, so behavior for all 111 callers is unchanged.

**Files:**
- Modify: `~/projects/workflows/.github/workflows/unified-cicd.yml:43-80`

**Interfaces:**
- Produces: inputs `github-release` (boolean, default `false`), `python-extras` (string, default `"dev"`), `python-strict` (boolean, default `false`); secret `GIT_DEP_TOKEN` (not required). Tasks 2, 3, 4 consume these.

- [ ] **Step 1: Add the three inputs**

Insert immediately after the `pypi-repository-url` input block (which ends at `:47` with `default: ""`), before the `secrets:` key:

```yaml
      github-release:
        description: "Create a git tag and GitHub Release for Python projects, independent of PyPI publishing"
        type: boolean
        default: false
      python-extras:
        description: "Comma-separated extras to install for Python projects (pip only), e.g. 'dev,ws'. Empty installs no extras."
        type: string
        default: "dev"
      python-strict:
        description: "Fail the build when ruff or pytest are missing after install, and let mypy failures fail the build"
        type: boolean
        default: false
```

- [ ] **Step 2: Add the secret**

Append to the `secrets:` block, after the `PYPI_TOKEN` entry:

```yaml
      GIT_DEP_TOKEN:
        description: "GitHub PAT with read-only Contents access to private repos used as git dependencies"
        required: false
```

- [ ] **Step 3: Verify the YAML parses and lints**

```bash
cd ~/projects/workflows
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/unified-cicd.yml')); print('YAML OK')"
./scripts/lint-workflows.sh
```

Expected: `YAML OK`, then actionlint reports no errors.

- [ ] **Step 4: Verify defaults preserve behavior**

```bash
cd ~/projects/workflows
python3 -c "
import yaml
w = yaml.safe_load(open('.github/workflows/unified-cicd.yml'))
i = w[True]['workflow_call']['inputs']
assert i['github-release']['default'] is False, 'github-release must default false'
assert i['python-strict']['default'] is False, 'python-strict must default false'
assert i['python-extras']['default'] == 'dev', 'python-extras must default to dev'
s = w[True]['workflow_call']['secrets']
assert s['GIT_DEP_TOKEN']['required'] is False
print('defaults preserve current behavior for all 111 callers')
"
```

Note: PyYAML parses the `on:` key as boolean `True`. That is why the code says `w[True]`.

Expected: the success line prints.

- [ ] **Step 5: Commit (do not push yet)**

```bash
cd ~/projects/workflows
git add .github/workflows/unified-cicd.yml
git commit -m "feat(ci): add github-release, python-extras, python-strict inputs and GIT_DEP_TOKEN secret"
```

Do NOT push. All four `workflows` tasks push together at the end of Task 4, to minimize the window in which 111 repos see a partially-applied change.

---

## Task 2: Install private git dependencies (W2)

**Files:**
- Modify: `~/projects/workflows/.github/workflows/unified-cicd.yml` — insert a step before "Install Python dependencies" (`:116`)

**Interfaces:**
- Consumes: secret `GIT_DEP_TOKEN` from Task 1.
- Produces: a global git URL rewrite so `pip` can clone private repos over HTTPS with a token. Task 8's `git+ssh://` dependency relies on this.

- [ ] **Step 1: Add the git rewrite step**

Insert between the "Setup Python" step (ends `:114`) and the "Install Python dependencies" step (begins `:116`):

```yaml
      - name: "Configure git for private Python dependencies"
        if: steps.detect-pm.outputs.manager == 'python'
        env:
          GIT_DEP_TOKEN: ${{ secrets.GIT_DEP_TOKEN }}
        run: |
          if [ -n "$GIT_DEP_TOKEN" ]; then
            git config --global --add url."https://x-access-token:${GIT_DEP_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
            git config --global --add url."https://x-access-token:${GIT_DEP_TOKEN}@github.com/".insteadOf "git@github.com:"
            echo "✅ git URL rewrite configured for private dependencies"
          else
            echo "ℹ️  GIT_DEP_TOKEN not set, skipping git rewrite"
          fi
```

`--add` is required: two `insteadOf` values map onto the same `url.<base>` key, and plain `git config` would overwrite the first.

When the secret is unset the step logs and exits 0 — no behavior change for the other 110 callers.

- [ ] **Step 2: Verify the rewrite locally**

This step tests the git incantation itself, isolated from CI:

```bash
cd /tmp && rm -rf gitrewrite && mkdir gitrewrite && cd gitrewrite && git init -q
git config --local --add url."https://x-access-token:FAKETOKEN@github.com/".insteadOf "ssh://git@github.com/"
git config --local --add url."https://x-access-token:FAKETOKEN@github.com/".insteadOf "git@github.com:"
git config --local --get-all url."https://x-access-token:FAKETOKEN@github.com/".insteadOf
```

Expected output — both values present, proving `--add` did not clobber:

```
ssh://git@github.com/
git@github.com:
```

- [ ] **Step 3: Lint**

```bash
cd ~/projects/workflows && ./scripts/lint-workflows.sh
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/workflows
git add .github/workflows/unified-cicd.yml
git commit -m "feat(ci): rewrite git+ssh URLs to token HTTPS when GIT_DEP_TOKEN is set"
```

---

## Task 3: Stop the silent test skips (W3)

Three defects, one task — they share a test cycle (a Python CI run) and a reviewer would accept or reject them together.

**Files:**
- Modify: `~/projects/workflows/.github/workflows/unified-cicd.yml:116-160`

**Interfaces:**
- Consumes: inputs `python-extras`, `python-strict` from Task 1.
- Produces: a Python test job that fails loudly when tooling is absent. Tasks 7 and 9 set `python-strict: true`.

**Background — the bug, verified:** `pip install -e ".[dev]"` against a project with no `dev` extra exits **0**, emitting only `WARNING: <pkg> 0.0.1 does not provide the extra 'dev'`. pytest is then absent, `:157` logs "pytest not installed, skipping tests", and the job is green. `tapayoka_pi_core` has no `dev` extra, so this is exactly what its CI would do today.

- [ ] **Step 1: Write the failing test**

There is no unit-test harness for GitHub Actions YAML. The real failing test is a live CI run, and it is Task 7 Step 2 — where `tapayoka_pi_core` gets `python-strict: true` *before* it has a `dev` extra, and CI **must go red**. That is the red phase. Do not skip it.

What can be tested here in isolation is the strict-check shell logic:

```bash
cd /tmp && rm -rf strictcheck && mkdir strictcheck && cd strictcheck
cat > check.sh <<'EOF'
#!/bin/bash
STRICT="$1"
missing=0
for tool in pytest ruff; do
  if ! command -v "$tool" &>/dev/null; then
    echo "❌ $tool not installed but python-strict is enabled"
    missing=1
  fi
done
if [ "$STRICT" == "true" ] && [ "$missing" -ne 0 ]; then exit 1; fi
exit 0
EOF
chmod +x check.sh
```

- [ ] **Step 2: Run it to verify it fails when strict and tooling is missing**

```bash
cd /tmp/strictcheck
PATH=/usr/bin:/bin ./check.sh true; echo "exit=$?"
```

Expected: prints the two ❌ lines and `exit=1`.

Then confirm the permissive path still passes:

```bash
PATH=/usr/bin:/bin ./check.sh false; echo "exit=$?"
```

Expected: prints the two ❌ lines and `exit=0`.

- [ ] **Step 3: Replace the "Install Python dependencies" step**

Replace `:116-131` in full:

```yaml
      - name: "Install Python dependencies"
        if: steps.detect-pm.outputs.manager == 'python'
        run: |
          PM="${{ inputs.python-package-manager }}"
          EXTRAS="${{ inputs.python-extras }}"
          if [ "$PM" == "uv" ]; then
            echo "📦 Installing with uv"
            pip install uv
            uv sync
          else
            echo "📦 Installing with pip"
            if [ -f "pyproject.toml" ]; then
              if [ -n "$EXTRAS" ]; then
                echo "📦 Installing extras: $EXTRAS"
                pip install -e ".[$EXTRAS]"
              else
                pip install -e .
              fi
            elif [ -f "requirements.txt" ]; then
              pip install -r requirements.txt
            fi
          fi
```

- [ ] **Step 4: Add the tooling verification step**

Insert immediately after the install step:

```yaml
      - name: "Verify Python tooling (strict)"
        if: steps.detect-pm.outputs.manager == 'python' && inputs.python-strict
        run: |
          # pip exits 0 with only a WARNING when an extra does not exist,
          # so a missing dev extra otherwise produces a green run with zero tests.
          missing=0
          for tool in pytest ruff; do
            if command -v "$tool" &>/dev/null; then
              echo "✅ $tool present"
            else
              echo "❌ $tool not installed but python-strict is enabled"
              missing=1
            fi
          done
          if [ "$missing" -ne 0 ]; then
            echo "Add these to your [project.optional-dependencies] and pass them via python-extras."
            exit 1
          fi
```

- [ ] **Step 5: Make mypy able to fail under strict**

Replace the "Python type check" step (`:146-153`):

```yaml
      - name: "Python type check"
        if: steps.detect-pm.outputs.manager == 'python'
        run: |
          if command -v mypy &> /dev/null; then
            echo "📝 Running mypy"
            if [ "${{ inputs.python-strict }}" == "true" ]; then
              mypy src/ --ignore-missing-imports
            else
              mypy src/ --ignore-missing-imports || true
            fi
          else
            echo "ℹ️  mypy not installed, skipping type check"
          fi
```

With `python-strict` defaulting to `false`, the `|| true` path is what all 110 existing callers keep getting.

- [ ] **Step 6: Lint and re-verify defaults**

```bash
cd ~/projects/workflows
./scripts/lint-workflows.sh
python3 -c "
import yaml
w = yaml.safe_load(open('.github/workflows/unified-cicd.yml'))
i = w[True]['workflow_call']['inputs']
assert i['python-strict']['default'] is False
assert i['python-extras']['default'] == 'dev'
print('OK')
"
```

Expected: no lint errors, `OK`.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/workflows
git add .github/workflows/unified-cicd.yml
git commit -m "feat(ci): add python-extras and python-strict; stop silently skipping python tests"
```

---

## Task 4: Tag and GitHub Release without PyPI (W1)

**Files:**
- Modify: `~/projects/workflows/.github/workflows/unified-cicd.yml` — add a new job after `release_pypi` ends (`:682`), before `deploy_docker:` (`:684`)

**Interfaces:**
- Consumes: input `github-release` from Task 1; `check_for_release` outputs `should_release`, `version`, `version_tag`, `has_pyproject_toml`.
- Produces: a git tag `v${version}` and a GitHub Release. Task 8 pins against this tag.

**Background:** `release_pypi` (`:568`) is the only job that tags a Python repo, gated on `pypi-publish == true` (`:574`). `check_for_release` (`:309-405`) sets `should_release=true` on **every** non-develop `main` push lacking `[skip ci]` — it never compares against existing tags. Its own comment at `:405`: *"Each deploy job will check its own registry for version existence."* A git-tag job has no registry, so it needs its own guard or it re-tags the same version on every push.

- [ ] **Step 1: Add the `release_python` job**

Insert after the `release_pypi` job's final step and before `  deploy_docker:`:

```yaml
  release_python:
    name: "Tag and GitHub Release (Python)"
    needs:
      - test
      - check_for_release
    if: |
      inputs.github-release == true &&
      inputs.pypi-publish != true &&
      needs.check_for_release.outputs.should_release == 'true' &&
      needs.check_for_release.outputs.has_pyproject_toml == 'true'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: "Checkout"
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: "Check if tag already exists"
        id: check-tag
        run: |
          TAG="${{ needs.check_for_release.outputs.version_tag }}"
          git fetch --tags --quiet
          if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
            echo "exists=true" >> $GITHUB_OUTPUT
            echo "ℹ️  Tag $TAG already exists, skipping release"
          else
            echo "exists=false" >> $GITHUB_OUTPUT
            echo "✅ Tag $TAG does not exist, will create"
          fi

      - name: "Create GitHub Release"
        if: steps.check-tag.outputs.exists == 'false'
        uses: softprops/action-gh-release@v3
        with:
          tag_name: ${{ needs.check_for_release.outputs.version_tag }}
          name: "Release ${{ needs.check_for_release.outputs.version }}"
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: "Notify"
        if: success() && steps.check-tag.outputs.exists == 'false'
        run: |
          echo "🏷️  Tagged ${{ needs.check_for_release.outputs.version_tag }}"
          echo "• GitHub: https://github.com/${{ github.repository }}/releases/tag/${{ needs.check_for_release.outputs.version_tag }}"
```

`inputs.pypi-publish != true` prevents a double release when both flags are on — `release_pypi` already cuts a GitHub Release at `:654-661`.

- [ ] **Step 2: Verify the tag guard logic in isolation**

```bash
cd /tmp && rm -rf tagguard && mkdir tagguard && cd tagguard
git init -q && git commit -q --allow-empty -m init
check() { if git rev-parse -q --verify "refs/tags/$1" >/dev/null; then echo "exists=true"; else echo "exists=false"; fi; }
check v0.1.0
git tag v0.1.0
check v0.1.0
```

Expected:

```
exists=false
exists=true
```

- [ ] **Step 3: Verify no existing caller is affected**

```bash
cd ~/projects
grep -rl 'unified-cicd.yml@' */.github/workflows/ | while read -r f; do
  if grep -q 'github-release' "$f"; then echo "SETS github-release: $f"; fi
done
echo "--- callers that would newly tag: (expect none)"
```

Expected: no `SETS github-release` lines. `signic_sdk_py` and the 110 TS repos leave it unset → default `false` → `release_python` never runs for them.

- [ ] **Step 4: Lint**

```bash
cd ~/projects/workflows && ./scripts/lint-workflows.sh
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/workflows
git add .github/workflows/unified-cicd.yml
git commit -m "feat(ci): add release_python job to tag without publishing to PyPI"
```

- [ ] **Step 6: STOP — get user confirmation before pushing**

Pushing publishes this to 111 repos at `@main`. Show the user:

```bash
cd ~/projects/workflows
git log --oneline origin/main..HEAD
git diff origin/main..HEAD -- .github/workflows/unified-cicd.yml
```

Ask explicitly: *"This pushes to `workflows` main, which 111 repos consume unpinned. Push?"*
Only on a clear yes:

```bash
cd ~/projects/workflows && git push origin main
```

- [ ] **Step 7: Verify a TypeScript caller still passes**

Pick any TS repo that pushed recently and re-run its latest workflow:

```bash
cd ~/projects/di && gh run list --limit 1
gh run rerun $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```

Wait for completion, then:

```bash
cd ~/projects/di && gh run list --limit 1
```

Expected: `completed  success`. If it fails, the additive-only claim is wrong — revert `workflows` main immediately.

---

## Task 5: Create the `GIT_DEP_TOKEN` PAT and add it as a secret

This is a user action. The agent cannot create a PAT.

**Files:** none.

**Interfaces:**
- Produces: repo secret `GIT_DEP_TOKEN` on `johnqh/tapayoka_pi`. Task 9 consumes it.

- [ ] **Step 1: User creates a fine-grained PAT**

Direct the user to <https://github.com/settings/personal-access-tokens/new>:
- Resource owner: `johnqh`
- Repository access: **Only select repositories** → `tapayoka_pi_core`
- Permissions: **Repository permissions → Contents → Read-only**
- Expiration: user's choice; note that CI breaks silently-ish when it lapses.

Nothing else. No write scopes.

- [ ] **Step 2: Add it as a secret on the consumer repo**

`tapayoka_pi` needs it (it has the git dependency). `tapayoka_pi_core` does not — it has zero dependencies.

```bash
gh secret set GIT_DEP_TOKEN --repo johnqh/tapayoka_pi
```

Paste the token at the prompt. The agent must NOT echo the token into the transcript.

- [ ] **Step 3: Verify the secret exists (name only, never the value)**

```bash
gh secret list --repo johnqh/tapayoka_pi
```

Expected: a row named `GIT_DEP_TOKEN`.

---

## Task 6: Make `tapayoka_pi_core` lint-clean

`python-strict: true` runs `ruff check .` for real. Core currently has **19 ruff errors** under `select = ["E","F","I","W"]` at line-length 100 — mostly `E501` (long lines) and an unsorted `__init__.py` import block. Fix before enabling strict, or Task 7's green phase can never be reached.

**Files:**
- Modify: `~/projects/tapayoka_pi_core/src/tapayoka_pi_core/policy.py`
- Modify: `~/projects/tapayoka_pi_core/src/tapayoka_pi_core/__init__.py`
- Modify: `~/projects/tapayoka_pi_core/tests/test_policy.py`

**Interfaces:**
- Consumes: nothing.
- Produces: a lint-clean core. Task 7 depends on it.

- [ ] **Step 1: Reproduce the failures**

```bash
cd ~/projects/tapayoka_pi_core
source ~/projects/tapayoka_pi/.venv/bin/activate
python -m ruff check --select E,F,I,W --line-length 100 . 2>&1 | tail -3
```

Expected: `Found 19 errors.` (`[*] 1 fixable with the --fix option.`)

- [ ] **Step 2: Auto-fix what ruff can**

```bash
cd ~/projects/tapayoka_pi_core
python -m ruff check --select E,F,I,W --line-length 100 --fix .
```

This sorts the `__init__.py` import block. `STATUS_NOT_CONFIGURED` currently sits between `prune_seen_nonces` and `validate_signals`; ruff's isort will move it up with the other uppercase names.

- [ ] **Step 3: Hand-fix the remaining E501 long lines**

Re-run to list them:

```bash
cd ~/projects/tapayoka_pi_core
python -m ruff check --select E,F,I,W --line-length 100 . 2>&1 | grep E501
```

The known worst offender is `policy.py`'s `validate_signals` signature. Wrap it:

```python
def validate_signals(
    signals,
    max_signal_seconds=MAX_SIGNAL_SECONDS,
    min_bcm_pin=MIN_BCM_PIN,
    max_bcm_pin=MAX_BCM_PIN,
):
```

Wrap each remaining flagged line the same way. Do not change any behavior — no logic edits, only line breaks.

- [ ] **Step 4: Verify lint is clean and tests still pass**

```bash
cd ~/projects/tapayoka_pi_core
python -m ruff check --select E,F,I,W --line-length 100 .
python -m pytest tests/ -v
```

Expected: `All checks passed!` and all tests in `tests/test_policy.py` passing. If any test fails, a line-wrap changed behavior — revert and redo.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/tapayoka_pi_core
git add src/ tests/
git commit -m "style: make core lint-clean under ruff E,F,I,W at line-length 100"
```

---

## Task 7: Give `tapayoka_pi_core` a dev extra and a CI wrapper

**Files:**
- Modify: `~/projects/tapayoka_pi_core/pyproject.toml`
- Create: `~/projects/tapayoka_pi_core/.github/workflows/ci-cd.yml`

**Interfaces:**
- Consumes: inputs `python-strict`, `github-release` from Task 1; the strict check from Task 3; the `release_python` job from Task 4.
- Produces: git tag `v0.1.0` on `johnqh/tapayoka_pi_core`. Task 8 pins to it.

- [ ] **Step 1: Create the wrapper WITHOUT adding the dev extra yet**

This is the red phase for Task 3. Core has no `dev` extra, so `python-strict: true` must make CI fail.

Create `~/projects/tapayoka_pi_core/.github/workflows/ci-cd.yml`:

```yaml
---
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: write

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      python-version: "3.11"
      python-package-manager: "pip"
      python-strict: true
      pypi-publish: false
      github-release: true
```

- [ ] **Step 2: Push and verify CI goes RED**

```bash
cd ~/projects/tapayoka_pi_core
git add .github/workflows/ci-cd.yml
git commit -m "ci: adopt shared unified-cicd workflow with strict python checks"
git push origin main
gh run watch
```

Expected: **failure**, in the "Verify Python tooling (strict)" step, with:

```
❌ pytest not installed but python-strict is enabled
❌ ruff not installed but python-strict is enabled
```

If CI goes **green** here, Task 3 is broken — the silent skip still exists. Stop and fix Task 3 before continuing.

- [ ] **Step 3: Add the dev extra and tool config**

Append to `~/projects/tapayoka_pi_core/pyproject.toml`, after the `[project]` table and before `[tool.setuptools]`:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "ruff>=0.4.0",
    "mypy>=1.10",
]
```

And append at the end of the file:

```toml
[tool.ruff]
line-length = 100
target-version = "py39"

[tool.ruff.lint]
select = ["E", "F", "I", "W"]

[tool.mypy]
python_version = "3.9"
```

`target-version = "py39"` — core's `requires-python` is `>=3.9`, not 3.11. Do NOT set `strict = true` under `[tool.mypy]`: `policy.py` is entirely untyped and strict mode would fail the build.

- [ ] **Step 4: Verify locally before pushing**

```bash
cd ~/projects/tapayoka_pi_core
rm -rf .venv-check && python3 -m venv .venv-check
./.venv-check/bin/pip install -q -e ".[dev]"
./.venv-check/bin/python -c "import shutil; assert shutil.which('pytest'); assert shutil.which('ruff'); print('tooling present')"
./.venv-check/bin/ruff check .
./.venv-check/bin/pytest tests/ -v
./.venv-check/bin/mypy src/ --ignore-missing-imports
rm -rf .venv-check
```

Expected: `tooling present`, `All checks passed!`, tests pass, mypy reports success.

- [ ] **Step 5: Push and verify CI goes GREEN with tests actually running**

```bash
cd ~/projects/tapayoka_pi_core
git add pyproject.toml
git commit -m "feat: add dev extra and ruff/mypy config"
git push origin main
gh run watch
```

Then confirm pytest genuinely ran — not skipped:

```bash
cd ~/projects/tapayoka_pi_core
gh run view --log | grep -E 'test_policy|passed|✅ pytest present'
```

Expected: `✅ pytest present`, collected items from `tests/test_policy.py`, and a `passed` summary. The string "pytest not installed, skipping tests" must NOT appear.

- [ ] **Step 6: Verify the tag was created**

```bash
cd ~/projects/tapayoka_pi_core
git fetch --tags
git tag -l
gh release list
```

Expected: tag `v0.1.0` exists and a GitHub Release `Release 0.1.0` is listed. `check_for_release` emits `version_tag=v${version}` and core's version is `0.1.0`.

If no tag appears, read the `release_python` job's log before proceeding — Task 8's pin depends on this exact tag string.

---

## Task 8: Point `tapayoka_pi` at the git dependency

**Files:**
- Modify: `~/projects/tapayoka_pi/pyproject.toml:1-11`

**Interfaces:**
- Consumes: tag `v0.1.0` from Task 7.
- Produces: a `tapayoka_pi` that installs from git. Tasks 9 and 10 depend on it.

**Precondition:** `tapayoka_pi`'s working tree must be clean. It currently holds uncommitted `pin_mapping.py` work. Commit or stash first.

- [ ] **Step 1: Reproduce the current failure**

```bash
cd ~/projects/tapayoka_pi
git status --short
```

Expected: clean. If not, stop and resolve with the user.

The CI failure this fixes, for reference (run `28619382387`):

```
ERROR: Could not install packages due to an OSError: [Errno 2]
       No such file or directory: '/Users/johnhuang/projects/tapayoka_pi_core'
```

- [ ] **Step 2: Add the missing `[build-system]` table with an explicit package list**

`tapayoka_pi/pyproject.toml` has no `[build-system]`. Adding a naive one is **not safe**: with both `src/__init__.py` and `tests/__init__.py` present, setuptools auto-detects src-layout and flattens `src/` to the wheel root, producing `main.py` instead of `src/main.py` — which breaks `python -m src.main`. Verified empirically. An explicit `packages` list prevents this.

Insert at the very top of the file, before `[project]`:

```toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"
```

And add, after the `[project.optional-dependencies]` block:

```toml
[tool.setuptools]
packages = ["src"]
```

- [ ] **Step 3: Replace the `file://` dependency**

In `[project].dependencies`, replace line 8:

```toml
    "tapayoka-pi-core @ file:///Users/johnhuang/projects/tapayoka_pi_core",
```

with:

```toml
    "tapayoka-pi-core @ git+ssh://git@github.com/johnqh/tapayoka_pi_core@v0.1.0",
```

- [ ] **Step 4: Verify the wheel keeps `src.main` importable**

```bash
cd ~/projects/tapayoka_pi
rm -rf /tmp/whlcheck && mkdir -p /tmp/whlcheck
source .venv/bin/activate
rm -rf build *.egg-info
pip wheel --no-deps --no-build-isolation -w /tmp/whlcheck . 2>&1 | tail -2
python -c "
import zipfile, glob
w = glob.glob('/tmp/whlcheck/*.whl')[0]
names = zipfile.ZipFile(w).namelist()
assert 'src/main.py' in names, f'src.main missing! got: {names}'
assert 'main.py' not in names, 'src/ was flattened to root — packages list is wrong'
print('wheel layout OK: src/main.py preserved')
"
```

Expected: `wheel layout OK: src/main.py preserved`.

`--no-deps` matters — it skips resolving the git dependency, which needs SSH.

- [ ] **Step 5: Verify the git dependency resolves in a clean venv**

Requires your SSH key to have access to the private `tapayoka_pi_core`.

```bash
cd ~/projects/tapayoka_pi
rm -rf /tmp/gitdep && python3 -m venv /tmp/gitdep
/tmp/gitdep/bin/pip install -q ".[dev]"
/tmp/gitdep/bin/python -c "from tapayoka_pi_core import STATUS_NOT_CONFIGURED; print('resolved:', STATUS_NOT_CONFIGURED)"
/tmp/gitdep/bin/pip show tapayoka-pi-core | grep -i version
rm -rf /tmp/gitdep
```

Expected: `resolved: NOT_CONFIGURED` and `Version: 0.1.0`.

- [ ] **Step 6: Verify local editable dev still works**

The editable core install must still shadow the git dep — this is the documented local-dev escape hatch.

```bash
cd ~/projects/tapayoka_pi
source .venv/bin/activate
pip install -e ../tapayoka_pi_core
python -c "import tapayoka_pi_core, os; print('shadowed from:', os.path.dirname(tapayoka_pi_core.__file__))"
pytest tests/ -v
```

Expected: the path points into `~/projects/tapayoka_pi_core/src/`, and tests pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/tapayoka_pi
git add pyproject.toml
git commit -m "fix: resolve tapayoka-pi-core from a git tag instead of an absolute local path"
```

Do not push yet — CI will fail until Task 9 adds `GIT_DEP_TOKEN` handling to the wrapper.

---

## Task 9: Migrate `tapayoka_pi` onto the shared workflow

**Files:**
- Modify: `~/projects/tapayoka_pi/.github/workflows/ci-cd.yml` (replace entirely)

**Interfaces:**
- Consumes: `GIT_DEP_TOKEN` secret from Task 5; `python-extras`, `python-strict`, `github-release` from Task 1.
- Produces: green CI on `tapayoka_pi` — the first since 2026-06-24.

**Note:** the current standalone workflow runs `ruff check src/ tests/` and `mypy src/ --ignore-missing-imports` with **no `|| true`**. It is stricter than the shared workflow's default. `python-strict: true` is what preserves that rigor. Without it, this migration silently drops type checking.

- [ ] **Step 1: Replace the workflow**

Overwrite `~/projects/tapayoka_pi/.github/workflows/ci-cd.yml`:

```yaml
---
name: CI/CD

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

permissions:
  contents: write

jobs:
  cicd:
    uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main
    with:
      python-version: "3.11"
      python-package-manager: "pip"
      python-extras: "dev,ws"
      python-strict: true
      pypi-publish: false
      github-release: true
    secrets:
      GIT_DEP_TOKEN: ${{ secrets.GIT_DEP_TOKEN }}
```

`python-extras: "dev,ws"` — the `ws` extra carries `websockets`, needed by `TapayokaWsPeripheral`. The old workflow installed only `[dev]`, so any test touching the WebSocket transport was running against a missing import or being skipped.

- [ ] **Step 2: Confirm the extras claim before relying on it**

```bash
cd ~/projects/tapayoka_pi
grep -rn "websockets" src/ tests/ | head
```

If nothing in `tests/` imports `websockets`, `dev` alone would suffice — but `dev,ws` is still correct, since `src/` imports it at runtime and mypy will check `src/`.

- [ ] **Step 3: Push and verify CI goes green**

```bash
cd ~/projects/tapayoka_pi
git add .github/workflows/ci-cd.yml
git commit -m "ci: adopt shared unified-cicd workflow with private git dependency support"
git push origin main
gh run watch
```

Expected: **success**. This is the first green run since 2026-06-24.

- [ ] **Step 4: Verify the git dependency actually resolved in CI**

```bash
cd ~/projects/tapayoka_pi
gh run view --log | grep -E 'git URL rewrite|tapayoka.pi.core|✅ pytest present'
```

Expected: `✅ git URL rewrite configured for private dependencies`, a line showing pip cloning `tapayoka_pi_core`, and `✅ pytest present`.

The string `No such file or directory: '/Users/johnhuang/projects/tapayoka_pi_core'` must NOT appear.

- [ ] **Step 5: Verify a tag was cut**

```bash
cd ~/projects/tapayoka_pi
git fetch --tags && git tag -l
```

Expected: `v0.1.0` (matching `tapayoka_pi`'s own `version = "0.1.0"`).

---

## Task 10: Fix the Dockerfile

**Files:**
- Modify: `~/projects/tapayoka_pi/Dockerfile` (replace entirely)
- Modify: `~/projects/tapayoka_pi/docker-compose.yml:4-5`

**Interfaces:**
- Consumes: the git dependency from Task 8.
- Produces: a buildable image that actually contains bluezero and RPi.GPIO.

**Two bugs fixed here.** (1) The `file://` dep — already fixed in Task 8, but Docker needs SSH to fetch the replacement. (2) `Dockerfile:12` runs `pip install .` with **no extras**, so bluezero and RPi.GPIO never install, despite `docker-compose.yml` running `privileged: true` + `network_mode: host`. The image builds and dies at `import bluezero`.

**⚠️ Docker is not installed on this machine** (`docker: command not found`). Every verification step below requires it. Either install Docker Desktop first, or mark this task **shipped unverified** and tell the user plainly.

- [ ] **Step 1: Replace the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.11-slim AS builder

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git openssh-client build-essential \
    libbluetooth-dev libdbus-1-dev libglib2.0-dev && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 0700 /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml .
COPY src/ src/

RUN --mount=type=ssh pip install --no-cache-dir ".[pi]"

FROM python:3.11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bluetooth bluez libbluetooth3 libdbus-1-3 libglib2.0-0 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY src/ src/

RUN mkdir -p /root/.tapayoka

CMD ["python", "-m", "src.main"]
```

The `# syntax=` line enables `--mount=type=ssh`. `.[pi]` pulls the `ble` + `gpio` extras (see `pyproject.toml:28-30`).

- [ ] **Step 2: Add SSH forwarding to compose**

In `~/projects/tapayoka_pi/docker-compose.yml`, replace `build: .` (line 5):

```yaml
    build:
      context: .
      ssh:
        - default
```

- [ ] **Step 3: Build**

```bash
cd ~/projects/tapayoka_pi
ssh-add -l >/dev/null 2>&1 || ssh-add
DOCKER_BUILDKIT=1 docker compose build
```

Expected: build succeeds. If it fails cloning `tapayoka_pi_core`, the SSH agent has no key with access.

- [ ] **Step 4: Verify the extras actually landed**

```bash
cd ~/projects/tapayoka_pi
docker compose run --rm --entrypoint python tapayoka-pi -c "import bluezero; print('bluezero OK')"
docker compose run --rm --entrypoint pip tapayoka-pi show RPi.GPIO
docker compose run --rm --entrypoint python tapayoka-pi -c "from tapayoka_pi_core import STATUS_NOT_CONFIGURED; print('core OK:', STATUS_NOT_CONFIGURED)"
```

Expected: `bluezero OK`, an `RPi.GPIO` version line, `core OK: NOT_CONFIGURED`.

Do NOT try `import RPi.GPIO` — it raises `RuntimeError: This module can only be run on a Raspberry Pi!` off-device. Presence in `pip show` is the correct check.

- [ ] **Step 5: Update the README's Docker instructions**

`README.md:62` says `docker compose up --build`. That now needs BuildKit and an SSH agent. Change it to:

```bash
ssh-add            # once per session; needs access to johnqh/tapayoka_pi_core
DOCKER_BUILDKIT=1 docker compose up --build
```

- [ ] **Step 6: Commit**

```bash
cd ~/projects/tapayoka_pi
git add Dockerfile docker-compose.yml README.md
git commit -m "fix(docker): multi-stage build with ssh mount, install [pi] extras"
```

---

## Task 11: Teach `push_projects.sh` to propagate the git-tag pin

Without this, every core release requires a manual edit of `tapayoka_pi/pyproject.toml`. That step gets forgotten and ships stale firmware policy.

**Files:**
- Modify: `~/projects/workflows/scripts/push_projects.sh` — add a function near `bump_version()` (`:924`)

**Interfaces:**
- Consumes: `PKG_MANAGER == "python"`, the bumped version from `bump_version()`.
- Produces: rewritten `git+ssh://...@vX.Y.Z` pins in downstream `pyproject.toml` files.

- [ ] **Step 1: Write the failing test**

```bash
cd /tmp && rm -rf pindep && mkdir pindep && cd pindep
cat > pyproject.toml <<'EOF'
[project]
name = "tapayoka-pi"
version = "0.2.0"
dependencies = [
    "eth-account>=0.13.0",
    "tapayoka-pi-core @ git+ssh://git@github.com/johnqh/tapayoka_pi_core@v0.1.0",
    "python-dotenv>=1.0.0",
]
EOF
cat > rewrite.sh <<'EOF'
#!/bin/bash
# update_python_git_deps <pyproject> <dep-name> <new-version>
update_python_git_deps() {
    local pyproject="$1" dep="$2" new_version="$3"
    [ -f "$pyproject" ] || return 0
    sed -i.bak -E "s|(${dep} @ git\+ssh://[^@]*@github\.com/[^@]*)@v[0-9]+\.[0-9]+\.[0-9]+|\1@v${new_version}|" "$pyproject"
    rm -f "$pyproject.bak"
}
update_python_git_deps "$1" "$2" "$3"
EOF
chmod +x rewrite.sh
grep 'tapayoka-pi-core @' pyproject.toml
```

Expected: shows the pin at `@v0.1.0`.

- [ ] **Step 2: Run it and verify it rewrites only the pin**

```bash
cd /tmp/pindep
./rewrite.sh pyproject.toml "tapayoka-pi-core" "0.1.1"
grep 'tapayoka-pi-core @' pyproject.toml
grep 'eth-account' pyproject.toml
grep '^version' pyproject.toml
```

Expected:
- pin now reads `...tapayoka_pi_core@v0.1.1`
- `eth-account>=0.13.0` untouched
- `version = "0.2.0"` untouched (the regex must not touch the project's own version)

If `version = "0.2.0"` changed, the regex is too greedy. Fix before proceeding.

- [ ] **Step 3: Add the function to `push_projects.sh`**

Insert immediately before `bump_version()` (`:924`):

```bash
# Rewrite git+ssh pinned Python deps in a downstream pyproject.toml
# Usage: update_python_git_deps <pyproject-path> <dep-name> <new-version>
update_python_git_deps() {
    local pyproject="$1"
    local dep="$2"
    local new_version="$3"

    if [ ! -f "$pyproject" ]; then
        return 0
    fi

    if ! grep -q "${dep} @ git+ssh://" "$pyproject"; then
        return 0
    fi

    log_info "Updating ${dep} pin to v${new_version} in $pyproject"
    sed -i.bak -E "s|(${dep} @ git\+ssh://[^@]*@github\.com/[^@]*)@v[0-9]+\.[0-9]+\.[0-9]+|\1@v${new_version}|" "$pyproject"
    rm -f "$pyproject.bak"
    log_success "Pin updated to v${new_version}"
}
```

- [ ] **Step 4: Wire it into the Python branch of `bump_version()`**

In `bump_version()`, after `log_success "Version bumped to $new_version"` (`:937`) and before `return 0`, add:

```bash
        # Propagate this version into downstream git+ssh pins.
        # push_all.sh walks repos in dependency order, so consumers are
        # processed after their dependencies.
        if [ "$(basename "$project_dir")" = "tapayoka_pi_core" ]; then
            update_python_git_deps "$(dirname "$project_dir")/tapayoka_pi/pyproject.toml" \
                "tapayoka-pi-core" "$new_version"
        fi
```

- [ ] **Step 5: Verify the script still parses**

```bash
cd ~/projects/workflows
bash -n scripts/push_projects.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/workflows
git add scripts/push_projects.sh
git commit -m "feat(push): propagate python git+ssh dep pins to downstream pyproject.toml"
```

- [ ] **Step 7: Ask before pushing**

Same 111-caller blast radius as Task 4. `push_projects.sh` is not consumed by the reusable workflow, so the risk is lower — but confirm anyway.

---

## Task 12: Flip `tapayoka_pi` to private

**Outward-facing and only partly reversible. Requires explicit user confirmation immediately before running.**

**Files:** none.

- [ ] **Step 1: State the consequences to the user, then ask**

- Existing clones and forks break.
- Stars and watchers are lost and do not come back on re-publishing.
- GitHub Actions minutes begin counting against the free quota. Public repos are unlimited.
- `johnqh/workflows` is public, so the reusable workflow keeps working from a private caller.
- Nobody without `tapayoka_pi_core` access can build `tapayoka_pi` or its Docker image.

- [ ] **Step 2: Flip it, only on an explicit yes**

```bash
gh repo edit johnqh/tapayoka_pi --visibility private --accept-visibility-change-consequences
```

- [ ] **Step 3: Verify**

```bash
gh repo view johnqh/tapayoka_pi --json visibility
gh repo view johnqh/tapayoka_pi_core --json visibility
```

Expected: both `PRIVATE`.

- [ ] **Step 4: Verify CI still runs after the flip**

```bash
cd ~/projects/tapayoka_pi
git commit --allow-empty -m "ci: verify workflow after visibility change"
git push origin main
gh run watch
```

Expected: success. A private caller of a public reusable workflow is supported; if this fails, the reusable-workflow access setting needs review.

---

## Out of Scope — recorded, not implemented

- **Private-index support in `unified-cicd.yml`.** Three latent bugs remain, harmless only because nothing sets `pypi-repository-url`:
  - `:621-635` — the "already published?" guard fetches `{base}/pypi/{name}/json`, an API served **only** by pypi.org and test.pypi.org. Against any other index the request raises, the bare `except` prints `0.0.0`, and the guard concludes "not published" every time, then attempts an upload that 400s. It fails silently in the unsafe direction.
  - `:665` — `twine upload dist/*` lacks `--skip-existing`.
  - `:667` — `TWINE_USERNAME` hardcoded to `__token__`; AWS CodeArtifact requires `aws`.
- **`deploy_docker` for `tapayoka_pi`.** That job needs Docker Hub secrets, which are unset, so it never runs. If enabled later it will need `GIT_DEP_TOKEN` plumbed into the Docker build as a BuildKit secret — the SSH-agent approach in Task 10 does not exist on a runner.
- **`tapayoka_pi_pico`.** MicroPython, manual build, vendors its own copy of the core.
