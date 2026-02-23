# Improvement Plans for @0xmail/workflows

## Priority 1 - High Impact

### 1. Add Workflow Testing and Validation ✅
- `unified-cicd.yml` is approximately 824 lines of YAML with complex conditional logic (7 jobs, secret-based auto-detection, branch behavior variations) but has no automated validation beyond `test-workflows-locally.sh`, which only tests consuming projects -- not the workflow itself.
- Adding `actionlint` (GitHub Actions linter) to a CI step that runs on pushes to this repository would catch YAML syntax errors, invalid action references, and expression mistakes before consuming projects are affected.
- The `test-workflows-locally.sh` script tests each ecosystem project sequentially but does not validate the workflow's conditional logic paths (e.g., skip-on-develop, version-existence checks, secret-missing skip behavior). Adding mock-based workflow tests using `act` (local GitHub Actions runner) for key scenarios would improve confidence.

### 2. Improve Localization Script Robustness ✅
- `scripts/localize.cjs` has anti-hallucination safeguards (3.0x length ratio, max 500 tokens, 3 retries) but these thresholds are hardcoded. Making them configurable via CLI flags or a config file would allow tuning per language pair (e.g., CJK languages naturally have different length ratios than Latin-script languages).
- The RTL handling for Arabic (removing directional control characters) is a post-processing step that could mask legitimate RTL formatting. Adding a validation step that checks the output renders correctly (e.g., balanced directional markers) would be more robust.
- Error handling in the DeepL fallback path should be documented: what happens when both LM Studio and DeepL fail for a key? Currently the original English text is kept, but this is not logged prominently enough for operators to notice incomplete translations.

### 3. Add Version Pinning Strategy for Reusable Workflow ✅
- Consuming projects reference `@main` (`uses: johnqh/workflows/.github/workflows/unified-cicd.yml@main`), meaning any push to `main` in this repository immediately affects all consuming projects' CI/CD. A breaking change (e.g., renaming a secret, changing a job condition) could break CI across the entire ecosystem simultaneously.
- Implementing a versioning strategy (Git tags like `v1.0.0`, `v1.1.0`) with documented migration guides and a deprecation policy would allow consuming projects to upgrade at their own pace.
- The `examples/` directory and `docs/DEPLOYMENT.md` should reference specific versions rather than `@main`.

## Priority 2 - Medium Impact

### 4. Improve push_projects.sh Error Handling ✅
- `scripts/push_projects.sh` orchestrates multi-project dependency updates, validation, version bumps, and git pushes. If any project fails validation (typecheck/lint/test/build), the script behavior depends on how it was invoked but recovery documentation is sparse.
- Adding a `--continue-on-error` flag that logs failures and continues to the next project (with a summary at the end) would be useful for large batch operations where one project's failure should not block others.
- The `--starting-project` flag implies the script is meant to be resumable after failures, but the project spec format (`path:delay_seconds`) and processing order should be more clearly documented.

### 5. Add Monitoring for Workflow Execution Times
- The unified CI/CD workflow runs across many projects but there is no tracking of execution time trends. Adding a step that records job duration to a central location (e.g., a GitHub Gist, or a simple log) would help identify when CI times are growing and which jobs are bottlenecks.
- The Docker build job uses multi-arch builds (arm64 + amd64 via QEMU), which can be slow. Documenting expected build times and providing guidance on when to enable/disable multi-arch would help consuming projects make informed decisions.

### 6. Standardize Localization Script Dependencies ✅
- `localize.cjs` uses `axios` and `dotenv` (declared in `package.json`), while `localize_batch.cjs` uses the native `fetch()` API. Standardizing on one HTTP client would reduce cognitive load. Since the project already depends on `axios`, using it consistently (or dropping it in favor of native `fetch` everywhere) would simplify maintenance.
- Python dependencies for `scripts/svg/` (opencv-python, numpy, scipy, scikit-image, scikit-learn) are not managed by any requirements file or `pyproject.toml`. Adding a `scripts/svg/requirements.txt` would make setup reproducible.

## Priority 3 - Nice to Have

### 7. Add Workflow Documentation Generator
- The README and `docs/DEPLOYMENT.md` must be manually kept in sync with `unified-cicd.yml` when inputs, secrets, or jobs change. Adding a script that extracts workflow inputs, secrets, and job descriptions from the YAML and generates a Markdown reference would prevent documentation drift.

### 8. Add Dry Run Mode to Localization Scripts
- Both `localize.cjs` and `localize_batch.cjs` write output directly. Adding a `--dry-run` flag that reports which keys would be translated, how many API calls would be made, and estimated cost (for DeepL) without actually translating would help operators plan large translation batches.

### 9. Consolidate SVG Utilities
- Four separate Python scripts for SVG generation/vectorization (`generate_logo_svg.py`, `vectorize_logo.py`, `vectorize_quantized.py`, `vectorize_vtracer.py`) serve overlapping purposes. Documenting which script to use for which scenario (with quality/size/speed comparisons) would help users choose the right tool. The `SVG.md` documentation exists but could include a comparison table with example outputs.
