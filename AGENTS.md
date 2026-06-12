# Repository Guidelines

## Project Structure & Module Organization
This repo is a reusable GitHub Actions AI PR reviewer — no application runtime, all logic lives in workflows plus a small shell/Python toolkit.
- `.github/workflows/` — `review.yml` (gate→static→context→llm-review→finalize), `commands.yml` (`/review`, `/plan`, `/oc` router), `ci.yml` (this repo's own static checks).
- `prompts/` — LLM playbooks (`review-full.md`, `review-incremental.md`, `plan.md`). Their `$VAR` contract must match the workflows' `env:` blocks.
- `scripts/lib/reconcile.sh` — pure, unit-tested baseline/state/thread logic the workflows `source` (single source of truth, no copy drift).
- `scripts/check-pins.sh`, `scripts/check-contract.py` — invariant guards run in CI.
- `tests/` — `reconcile.bats` + JSON fixtures. `templates/` — caller workflows for target repos. `rules/` — extra OpenGrep rules.

## Architecture Overview
`review.yml` is a five-job pipeline: **gate** (resolve PR/SHA, skip drafts, read trusted prior state) → **static** (opengrep/gitleaks/osv → `findings.json`) and **context** (ripgrep cross-file impact map → `context.md`) in parallel → **llm-review** (read-only; runs the opencode CLI with the prompt + artifacts) → **finalize** (`contents:write`; dismisses superseded reviews, resolves threads). `commands.yml` routes `/review`, `/plan`, `/oc` comments into the same review. State lives in one sticky status comment carrying an embedded `<!-- ai-review:state … -->` marker; only the bot-authored marker is trusted, and `reconcile.sh` derives the effective baseline, prior verdict, and open threads from it.

## Build, Test, and Development Commands
Run all checks in one command: `make check` (runs lint, tests, contract, and pin checks).

Individual commands:
- `actionlint .github/workflows/*.yml` — lint workflows (bundles shellcheck on every `run:` block).
- `bats tests/reconcile.bats` — unit-test the reconcile library.
- `python3 scripts/check-contract.py` — verify prompt env vars, template permission supersets, and the gate↔lib regex drift-guard.
- `scripts/check-pins.sh` — assert opencode version/sha256 sync + live asset hash; offline with `CHECK_PINS_OFFLINE=1`.
- `shellcheck scripts/check-pins.sh scripts/release.sh scripts/lib/reconcile.sh` — lint shell.

## Coding Style & Naming Conventions
- Shell: `bash` with `set -euo pipefail`; 2-space indent; `snake_case` functions/vars. Keep `# shellcheck disable=` directives immediately above the offending line (actionlint ignores file-top directives).
- Python: 3.12, standard library + `pyyaml`; 4-space indent; type hints; `snake_case`.
- Workflows: pin third-party actions by commit SHA; pin the opencode CLI by version **and** sha256 (update all 3 copies together). Pass untrusted input via `env:`, never interpolated into `run:`.

## Testing Guidelines
Add a `bats` case for any change to `reconcile.sh`; name tests `area: scenario -> expectation`. Put new fixtures in `tests/fixtures/`. Run the full local set (`bats`, `check-contract.py`, `check-pins.sh`, `actionlint`) before pushing — CI runs the same four jobs on every push/PR.

## Commit & Pull Request Guidelines
Use Conventional Commits: `feat:`, `fix:`, `docs:`, `ci:` (see `git log`). Keep the subject imperative and scoped to one change. PRs should describe the behavior change, note any pin/version bumps, and pass CI. The project is **alpha**: callers pin an exact tag (e.g. `@v0.0.3`), not a floating major. Release by running `scripts/release.sh <tag>` (bumps every internal `ref:`/`@<tag>` pin and re-verifies), then cutting an annotated tag once `main` is green.
