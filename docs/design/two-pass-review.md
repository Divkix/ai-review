Status: implemented (feat/plan-010-two-pass, merged to main) — see README and Architecture Overview in AGENTS.md.

# Design: Two-pass LLM review with deterministic posting

**Status**: implemented (2026-06-15)
**Priority**: P1 | **Effort**: L | **Depends on**: post.sh, opencode v1.17.4+

---

## Decision

Replace the single-pass LLM review (agent writes findings and posts the GitHub
review in one session) with a three-step pipeline inside the `llm-review` job:

1. **Drafter pass** — LLM writes candidate findings to a JSON file; no GitHub API access.
2. **Skeptic/verifier pass** — a second LLM session tries to refute each draft finding; drops or demotes unprovable ones; writes verified findings JSON.
3. **Deterministic posting** — workflow bash (`scripts/lib/post.sh`) reads the verified findings, applies the inline budget, validates anchors, and calls the GitHub API. The LLM never touches the API.

---

## The drafter/verifier/post split

### Drafter

- Invoked as `opencode run --agent drafter`.
- Receives: the diff, `findings.json` (static scanner output), and `context.md` (cross-file impact map).
- Config is locked down via `OPENCODE_CONFIG_CONTENT` (an environment variable injected as the opencode config) so the agent cannot be overridden by a repo-committed `opencode.json`.
- Has **no GitHub token**: it cannot call the GitHub API even if prompt-injected.
- Outputs: `drafter_findings.json` — a JSON array of candidate findings with fields `path`, `line`, `severity`, `confidence`, `title`, `body`, `fingerprint`.

### Skeptic (verifier)

- Invoked as `opencode run --agent skeptic` in a fresh session (no shared state with the drafter).
- Optionally uses a different model via `verifier_model` / `verifier_variant` workflow inputs (defaults to the same model as the drafter).
- For each draft finding, it reads the actual file content and attempts to falsify the claim. Findings it cannot support are dropped or demoted.
- Also has **no GitHub token**.
- Outputs: `verified_findings.json` — same schema as drafter output, pruned and adjusted.

### Deterministic posting (`scripts/lib/post.sh`)

- Sourced by the workflow posting step — the **only** step in `llm-review` that holds `github.token`.
- Derives the verdict (`APPROVE` / `REQUEST_CHANGES` / `COMMENT`) from finding severities.
- Applies the inline budget: at most 10 inline comments for BLOCKER/MAJOR findings; all MINOR findings collapse into one `<details>` block in the review body.
- Validates every comment anchor (file path + line number) against the actual diff; bad anchors are demoted to body mentions rather than dropped silently.
- Posts ONE review via `gh api POST /repos/.../pulls/.../reviews`.
- Writes the sticky status comment and `<!-- ai-review:state -->` marker.
- **3-rung fallback ladder**: if the review POST fails, it retries degrading inline comments to body; if the repo forbids Actions approvals it falls back from `APPROVE` to `COMMENT`.

---

## Why deterministic posting

The original design relied on the LLM to call `gh pr review` and write the
state marker. This had two failure modes:

1. **Model non-compliance**: if the model skipped posting or wrote a malformed
   state marker, `finalize` had no state to act on.
2. **Budget non-compliance**: the model might exceed the 10-comment budget or
   omit the `<details>` collapse despite instructions.

Both are now impossible: posting correctness is a property of the bash code in
`post.sh`, not of model instruction-following.

---

## OPENCODE_CONFIG_CONTENT lockdown

The drafter and skeptic steps inject the opencode agent config via
`OPENCODE_CONFIG_CONTENT`. This environment variable is read by opencode before
scanning the working directory for `opencode.json`/`.opencode`. It prevents a
PR from committing an opencode config that overrides the agent's system prompt
or tools, which would be a prompt-injection vector.

---

## Token-isolation invariant

The invariant: **no step that runs an LLM holds `github.token`**. Specifically:
- Drafter step: `GITHUB_TOKEN` is not set in the step's `env:`.
- Skeptic step: same.
- Posting step: has `github.token` but runs only deterministic bash (no opencode invocation).
- `finalize` job: has `contents:write` but runs no LLM.

This means a successful prompt-injection attack against the drafter or skeptic
can at most corrupt the findings JSON — it cannot post arbitrary comments or
approve/reject the PR.

---

## New workflow inputs

`verifier_model` (string, optional): LLM model id for the skeptic pass. Defaults to `inputs.model`.
`verifier_variant` (string, optional): reasoning-effort variant for the skeptic pass. Defaults to `inputs.variant`.

These allow running a stronger or cheaper model on the verification step
independently of the drafting step.
