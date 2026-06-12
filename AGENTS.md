# Repository Guidelines

## Project Structure & Module Organization
This repo is a reusable GitHub Actions AI PR reviewer — no application runtime, all logic lives in workflows plus a small shell/Python toolkit.
- `.github/workflows/` — `review.yml` (gate→static→context→llm-review→finalize), `commands.yml` (`/review`, `/plan`, `/oc` router), `ci.yml` (this repo's own static checks).
- `prompts/` — LLM playbooks: `review-full.md` and `review-incremental.md` (mode-specific), `review-common.md` (shared protocol appended to both at compose time), `plan.md`. Their `$VAR` contract must match the workflows' `env:` blocks (enforced by `check-contract.py`).
- `scripts/lib/` — pure, bats-tested logic the workflows `source` (single source of truth, no copy drift): `reconcile.sh` (baseline/state/thread reconciliation), `sarif.sh` (SARIF→findings merge), `context.sh` (cross-file impact map), `scope.sh` (`.ai-review.yml` parsing, path matching, size-guard counts).
- `scripts/check-pins.sh`, `scripts/check-contract.py` — invariant guards run in CI. `scripts/release.sh <tag>` — release pin bumper.
- `tests/` — one `.bats` file per lib + fixtures in `tests/fixtures/`. `templates/` — caller workflows for target repos. `rules/` — extra OpenGrep rules. `docs/design/` — settled design docs (read before reworking the areas they cover). `Makefile` — bundles the local check suite.

## Architecture Overview
`review.yml` is a five-job pipeline: **gate** (resolve PR/SHA, skip drafts, fetch `.ai-review.yml` from the **base** branch, config-driven size guard, emit `ignore_patterns`) → **static** (opengrep/gitleaks/osv → SARIF uploads → `findings.json` filtered by config ignores, HIGH severity always kept and annotated) and **context** (ripgrep cross-file impact map honoring ignores → `context.md`) in parallel → **llm-review** (read-only; runs the opencode CLI with the prompt + artifacts + `IGNORE_PATHSPECS`) → **finalize** (`contents:write`; dismisses superseded reviews, resolves threads gated on a fresh, well-formed state). `commands.yml` routes `/review`, `/plan`, `/oc` comments into the same review. State lives in one sticky status comment carrying an embedded `<!-- ai-review:state … -->` marker; only the bot-authored marker is trusted, and `reconcile.sh` derives the effective baseline, prior verdict, and open threads from it.

Caller-facing contract: model/provider are `workflow_call` inputs (`model`, `variant`, `api_key_env`) with the secret `LLM_API_KEY`; per-repo behavior comes from `.ai-review.yml` (`ignore:` scopes what the AI reviews, never what the scanners report — and it is read from the base branch only, never the PR head, so a PR cannot exclude its own files).

## Build, Test, and Development Commands
Run all checks in one command: `make check` (lint, tests, contract, offline pin check).

Individual commands:
- `actionlint .github/workflows/*.yml` — lint workflows (bundles shellcheck on every `run:` block).
- `bats tests/` — unit-test the lib scripts (reconcile, sarif, context, scope).
- `python3 scripts/check-contract.py` — verify prompt env vars, template permission supersets, and the gate↔lib regex drift-guard.
- `scripts/check-pins.sh` — assert all tool version/sha256 pins are in sync and match the live release assets; offline with `CHECK_PINS_OFFLINE=1`.
- `shellcheck scripts/*.sh scripts/lib/*.sh` — lint shell.

## Coding Style & Naming Conventions
- Shell: `bash` with `set -euo pipefail`; 2-space indent; `snake_case` functions/vars. Keep `# shellcheck disable=` directives immediately above the offending line (actionlint ignores file-top directives). In workflow `run:` blocks, guard `grep`-based extractions with `|| true` when the key may legitimately be absent — an unguarded miss kills the job under `pipefail`.
- Python: 3.12, standard library + `pyyaml`; 4-space indent; type hints; `snake_case`.
- Workflows: pin third-party actions by commit SHA; pin every fetched tool binary by version **and** sha256 (opencode has 3 copies — update them together); the OpenGrep ruleset is pinned by commit (`OPENGREP_RULES_REF`). Pass untrusted input via `env:`, never interpolated into `run:`. Never read `.ai-review.yml` from the PR head.

## Testing Guidelines
Add a `bats` case for any change to a `scripts/lib/*.sh` function; name tests `area: scenario -> expectation`. Put new fixtures in `tests/fixtures/`. When workflow `run:` blocks compose lib output (grep/cut extraction chains), pin the composition with a smoke test under `set -euo pipefail` — the libs' own tests won't catch consumption bugs. Run `make check` before pushing — CI runs the same four jobs on every PR (and on pushes to `main`).

## Commit & Pull Request Guidelines
Use Conventional Commits: `feat:`, `fix:`, `docs:`, `ci:` (see `git log`). Keep the subject imperative and scoped to one change. PRs should describe the behavior change, note any pin/version bumps, and pass CI. The project is **alpha**: callers pin an exact tag (e.g. `@v0.2.0`), not a floating major. Release by running `scripts/release.sh <tag>` (bumps every internal `ref:`/`@<tag>` pin and re-verifies — README "currently" prose and migration notes are manual), then cutting an annotated tag once `main` is green. After tagging, run the e2e acceptance protocol in the `Divkix/ai-review-e2e` sandbox (its README documents the scenarios) before announcing the release.
