Status: implemented (v0.2.0) — see README Per-repo configuration.

# Design: PR scope configuration — diff-size guard and per-repo path filters

**Status**: spike (2026-06-12, commit `7d232b5`)
**Priority**: P3 | **Effort**: M (build follow-up) | **Depends on**: none

This document settles the design for two related knobs: a hard size guard that
prevents very large PRs from silently blowing the LLM token budget, and a
per-repo path-ignore list that lets callers scope out generated or vendored
files from LLM attention. A minimal prototype of the size guard only is
implemented in `review.yml` as part of this spike (see prototype note below).

---

## 1. Config location and trust

**Recommendation**: `.ai-review.yml` at the repo root, read from the
**base branch** (`origin/$GITHUB_BASE_REF`), never from the PR head.

### Rationale

Config-in-head means the PR author controls what gets reviewed. Consider the
threat: a PR that touches `auth/login.go` could also write an `.ai-review.yml`
with `ignore: [auth/**]`, silently removing the sensitive file from LLM
scrutiny — while the PR itself is what should be scrutinised. Reading from the
PR head is functionally equivalent to letting an untrusted actor edit the
review configuration for their own PR. The README's security model (AGENTS.md)
states: "untrusted strings (comment bodies, state JSON, branch names) are never
interpolated into `run:` scripts via `${{ }}`" — the same adversarial posture
applies to config content.

**Base-branch config** closes this: the owner must land a config change in the
default branch before it takes effect. This is the same model as branch
protection rules and CodeOwners.

**Residual acknowledged**: a config PR changes `.ai-review.yml` on the base
branch only after merge. That means the PR _adding_ the config is itself not
filtered by it. This is acceptable and expected — same behaviour as
`.coderabbit.yaml` and branch protection.

**Fetch pattern** (gate job, after the PR is resolved):
```bash
git fetch origin "+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" \
  --depth=1 --no-tags
config_content="$(git show "origin/${base_ref}:.ai-review.yml" 2>/dev/null || true)"
```

This does not require checking out the base branch; a bare `git show` is
sufficient and avoids polluting the working tree.

---

## 2. Schema v0

```yaml
version: 1                # required; reject anything != 1
ignore:                   # optional; list of gitignore-style pathspecs
  - dist/**
  - vendor/**
  - "**/*.pb.go"          # generated protobuf
  - docs/generated/**
max_changed_files: 400    # optional; overrides built-in default
max_diff_lines: 20000     # optional; overrides built-in default
```

### Field semantics

`version` (int, required): schema version sentinel. A missing or wrong version
causes fail-open (see §6).

`ignore` (list of strings, optional): paths matched here are **dropped from LLM
attention only**. Specifically:
- Excluded from the diff passed to the LLM playbook (`git diff -- . ':(exclude)…'`)
- Excluded from the context job's symbol sweep (`rg --glob '!…'`)
- Excluded from findings forwarded to the LLM via `findings.json`

**Scanners still run on everything.** gitleaks, opengrep, and osv-scanner see
the full tree regardless. The asymmetry is intentional and security-motivated:
a secret committed in `dist/` must still be caught. The `ignore` list controls
what the LLM _attends to_, not what the security scanners cover. This preserves
the scanner-as-safety-net property while allowing noise reduction for generated
code.

`max_changed_files` (int, optional, default 400): if the PR touches more files
than this limit, the auto-trigger skips the LLM review (see §4). Explicit
`/review` and `/review full` commands bypass this.

`max_diff_lines` (int, optional, default 20000): same logic applied to
`additions + deletions` from the GitHub API.

---

## 3. Pathspec mechanics

**Recommendation**: use git's native pathspec magic at `git diff` time, not a
bash glob reimplementation.

### git diff (LLM diff input)

```bash
# Build the exclude args from the ignore list
exclude_args=()
while IFS= read -r p; do
  exclude_args+=( ":(exclude)${p}" )
done < <(scope_filter_paths)   # emitted one per line by scripts/lib/scope.sh

git diff origin/"${BASE_REF}"...HEAD -- . "${exclude_args[@]}"
```

`:(exclude)` is git's pathspec magic prefix (also written `':!pattern'`). It is
natively understood by `git diff`, `git log`, and `git show`, is
cross-platform, and avoids re-implementing glob matching. Using it at the `git
diff` call site means the exclusion applies at the content level — excluded
paths produce no diff output — rather than as a post-hoc strip.

### ripgrep (context job — symbol sweep)

```bash
# Same list, translated to --glob '!pattern' for rg
glob_args=()
while IFS= read -r p; do
  glob_args+=( --glob "!${p}" )
done < <(scope_filter_paths)

rg -n --no-heading -w -F "$sym" "${glob_args[@]}" ...
```

`rg`'s `--glob '!pattern'` implements the same gitignore glob syntax, so
pattern compatibility is maintained across both tools.

### findings.json (scanner findings forwarded to LLM)

```bash
# jq filter: drop findings whose file field matches any ignored path
ignore_patterns="$(scope_filter_paths | jq -Rs 'split("\n") | map(select(length > 0))')"
jq --argjson ignore "$ignore_patterns" '
  [.[] | select(
    .file as $f |
    ($ignore | map($f | test(gsub("\\*\\*"; ".*") | gsub("\\*"; "[^/]*"))) | any) | not
  )]
' findings.json > findings.filtered.json
```

Note: the jq glob-to-regex translation is approximate (covers `**` and `*`
wildcards; advanced pathspec magic is not supported). Accuracy here is a
best-effort noise filter, not a security boundary — the scanners still ran on
everything.

---

## 4. Size-guard behaviour

### Decision matrix

| Trigger type | Size within limits | Size exceeds limits |
|---|---|---|
| `auto` (push, PR open) | run normally | **skip** + sticky comment |
| `/review` (incremental, human) | run normally | **bypass** guard, run normally |
| `/review full` | run normally | **bypass** guard, run normally |

Explicit human commands always bypass the size guard. Auto triggers respect it.
The rationale: a human who types `/review full` on a 500-file PR knows what
they are asking for and has accepted the cost.

### Sticky comment (when guard fires)

```
<!-- ai-review:too-large -->

ai-review: PR too large for auto-review.

**N** files changed, **M** lines changed (limit: **400 files / 20 000 lines**).

Comment `/review full` to force a full review of this PR.
```

The comment is upserted using the same `<!-- ai-review:too-large -->` marker
pattern as the existing draft-PR comment (review.yml:101–110), keeping a single
per-PR too-large comment that updates on re-trigger rather than stacking.

### Built-in defaults when no config exists

`max_changed_files: 400`, `max_diff_lines: 20000`.

These are generous ceilings — they are intended to catch pathological cases
(vendored-dependency bumps, generated migrations) not ordinary large PRs. A
200-file refactor that genuinely needs review will pass.

**Release-note implication**: this is a behaviour change for callers. Today,
every non-draft PR triggers a review regardless of size. After this lands, PRs
above the default ceiling get a skip on auto-triggers. This must appear in the
CHANGELOG / release notes for the first version that includes it.

---

## 5. Where parsing lives

**Recommendation**: a new `scripts/lib/scope.sh` with three functions, parsed
using bash line-by-line grep (no external YAML parser dependency).

### Parser choice: constrained schema over yq or pyyaml

Three options were weighed:

| Option | Pro | Con |
|---|---|---|
| `yq` (pinned, hash-verified) | full YAML | another pinned binary; hash must be re-checked on bump; adds ~30 MB download per job |
| `python3 + pyyaml` | already available on ubuntu runners (python3 yes; pyyaml **no** — not in the default image) | pyyaml needs `pip install pyyaml` in the job, adding untrusted network call and ~0.5 s per run; undesirable for a hot path |
| **flat grep-parseable schema** | zero new deps; faster; fewer moving parts | schema limited to flat lists and ints (sufficient for v0) |

**Decision**: constrain schema v0 to a structure parseable with bash `grep` /
`sed`. The two list fields (`ignore:`) and two integer fields
(`max_changed_files:`, `max_diff_lines:`) in the v0 schema can be reliably
extracted without a full YAML parser — no nested mappings, no anchors, no
multi-line values. If v1 adds complexity (per-branch overrides, condition
expressions) revisit yq.

### `scripts/lib/scope.sh` API

```bash
# Load and validate config from stdin (content of .ai-review.yml or empty).
# Emits KEY=VALUE pairs for the caller to eval or read.
# On malformed input: sets SCOPE_WARN and returns 0 (fail-open, see §6).
scope_load_config()          # stdin: raw config content

# Emit one path pattern per line from the loaded config's ignore list.
scope_filter_paths()         # no args; uses state set by scope_load_config

# Check PR size against configured limits.
# Arguments: $1=changed_files $2=diff_lines $3=mode (auto|full|incremental)
# Exits 0 if within limits or mode is not auto; exits 1 if should skip.
# Sets SCOPE_SKIP_REASON on skip.
scope_check_size()
```

Functions are pure (no side effects beyond shell variables) so they are
unit-testable with bats. Tests live in `tests/scope.bats`.

### Integration point

The gate job sources `scope.sh` after the `Resolve PR and draft gate` step,
before `Decide mode`. The config is fetched from the base branch using `git
show` (see §1). The gate already has `contents: read` and a configured `git`
environment (PR head is not checked out in the gate — but `git show
origin/BASE_REF:path` works via the API-authenticated fetch).

Actually: the gate job does **not** check out the repo. It uses only the GitHub
API via `gh`. This means `git show` is not available. Alternative: use the
GitHub Contents API:

```bash
config_raw="$(gh api "repos/$GITHUB_REPOSITORY/contents/.ai-review.yml" \
  --jq '.content' 2>/dev/null \
  | base64 --decode 2>/dev/null || true)"
```

This fetches the file from the **default branch** (HEAD of the repo) — not
necessarily `base_ref` if the repo has non-default base branches. To target
exactly `base_ref`:

```bash
config_raw="$(gh api \
  "repos/$GITHUB_REPOSITORY/contents/.ai-review.yml?ref=${base_ref}" \
  --jq '.content' 2>/dev/null \
  | base64 --decode 2>/dev/null || true)"
```

A 404 (no config file) returns empty string → built-in defaults apply. This
is the correct gate integration pattern.

---

## 6. Failure semantics

**Recommendation**: fail open.

If `.ai-review.yml` exists but is malformed (syntax error, wrong version, a
field with unexpected type), the review pipeline should:
1. Proceed as if no config were present (built-in defaults apply).
2. Append a warning line to the sticky status comment: `⚠️ .ai-review.yml is
   malformed or has an unrecognised version; using defaults.`

### Justification against the threat model

The config is read from the **base branch** (§1). That means it was written by
someone with merge access. A malformed config is therefore a mistake, not an
attack. Failing open (running the review anyway) is correct: silencing reviews
because of a config typo is a worse outcome than reviewing with defaults.

Contrast this with a hypothetical config-in-head design, where fail-open would
be exploitable: a PR author writes deliberately invalid YAML to trigger
fail-open, then the review runs with no ignore filters and the too-large guard
disabled. Under the base-branch model, the PR author cannot control the config,
so the fail-open path is not a privilege-escalation surface.

The one exception: if `max_changed_files` or `max_diff_lines` is set to an
absurdly large value (e.g. `999999`), it effectively disables the guard. This
is accepted — the base-branch author has merge rights and is trusted. If the
project needs to enforce a ceiling even against repo owners, that's an
organisation policy problem outside the scope of this tool.

---

## 7. Build estimate

With the design settled:

| Component | Effort | Notes |
|---|---|---|
| `scripts/lib/scope.sh` | 1–2 days | 3 functions + bats tests for ~10 scenarios |
| `tests/scope.bats` | included above | fixtures for valid config, malformed, empty, limits exceeded/ok |
| Gate: fetch config + call `scope_check_size` | 0.5 days | ~30 lines; integrate sticky too-large comment |
| Context job: apply `scope_filter_paths` to rg invocations | 0.5 days | thread exclude_args through the loop |
| LLM-review job: apply pathspec excludes to git diff | 0.5 days | modify the diff command in the playbook or prompt-compose step |
| Static job: apply ignore list to findings.json forwarding | 0.5 days | jq post-filter; scanners still run on everything |
| Templates + README update | 0.5 days | new `.ai-review.yml` schema reference |
| **Total** | **~3.5–4 days** | |

This is an M-effort build plan. The four-job plumbing (scope.sh → gate, context,
llm-review, static forwarding) represents the majority of the work; the lib
itself is small.

---

## Open questions

1. **Should `/review` (incremental, human-triggered) bypass the size guard, or
   only `/review full`?** The design above bypasses both. The alternative is
   that only `/review full` bypasses (forcing an explicit acknowledgement of the
   full diff), with plain `/review` still subject to the guard. Maintainer
   decision: the difference is minor UX, but making it explicit in the skip
   comment ("Comment `/review full` to force") already guides users correctly.

2. **Are 400 files / 20 000 lines the right default ceilings?** These were
   chosen to be generous enough that a large but legitimate PR is not blocked,
   while still catching pathological cases (vendored dep bumps, migration
   generation). Real-world calibration against the caller repos is recommended
   before finalising. Could also be 500/25000 or configurable-only with no
   built-in default.

3. **Should `ignore:` also suppress scanner SARIF *uploads* (Code Scanning
   alerts in the Security tab) or only the LLM-forwarding filter?** Today the
   plan suppresses only forwarding to the LLM; SARIF uploads go through
   regardless. The argument for suppressing uploads too: `dist/` findings in the
   Security tab are noise. The argument against: the Security tab is a separate
   concern from the PR review, and suppressing SARIF uploads based on a
   per-repo config file involves GitHub's Code Scanning API scoping, which is
   out of scope for v0. Recommend: keep suppression LLM-only in v0; revisit in
   v1 if callers ask for it.

---

## Addendum: `instructions:` and `guidelines:` (Plan 011)

**Status**: implemented (feat/plan-011-instructions branch).

Two new keys added to the schema (version stays 1; unknown keys are forward-ignored by older parsers):

```yaml
instructions:
  - "api/** :: Flag handlers missing input validation."
  - "Prefer explicit error wrapping."
guidelines: docs/review-guidelines.md
```

### `instructions:` (list of strings)

Same YAML block shape as `ignore:`. Parsed by the shared `scope_parse_list` helper in `scope.sh`. Each item:
- Delimiter ` :: ` (space-colon-colon-space) splits glob from text. Items without the delimiter are repo-wide.
- Text is truncated to 500 characters.
- Empty or missing items are skipped — NOT `valid=false`. This is intentional: instructions are guidance, not schema enforcement. Degrading individual items prevents one bad line from invalidating the whole config and silencing all review.

The gate emits them as an `instructions` heredoc output (newline-joined). The prompt-compose step renders them as a `## Per-repo review instructions` markdown section appended to both the drafter and verifier prompts.

### `guidelines:` (scalar path)

A relative path to a long-form review guidelines file in the repo. Validation:
- Must not start with `/`
- Must contain no `..` segment (neither `..` as the full path nor `/../` embedded)
- On any validation failure: silently skip (emit nothing, do NOT set `valid=false`)

Fetched from the base branch via the Contents API (`?ref=${BASE_REF}`, same pattern as `.ai-review.yml` itself). Capped at 16 384 bytes; if the raw content exceeds that, the injected text ends with `\n... [guidelines truncated]`. On fetch failure (404, network error): empty output, silent fail-open — no `config_warning` emitted.

### Base-branch trust (same as all other keys)

Both keys are read exclusively from the base branch — the same absolute rule as §1. A PR author cannot inject instructions or guidelines by modifying the PR head. The PR adding these keys to the base branch is itself reviewed under the prior (or absent) config — same as branch protection rules.

### Interaction with existing keys

`instructions:` does not change what the scanners report or what `ignore:` filters. An `instructions:` directive cannot suppress a CRITICAL/HIGH static finding. It is additional guidance injected into the LLM's context, not a gate condition.
