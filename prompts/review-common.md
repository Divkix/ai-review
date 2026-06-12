# Shared review protocol

This protocol applies to both full and incremental reviews. It is appended after the mode-specific playbook; the mode playbook's verdict policy, walkthrough format, and status-comment format govern where they are referenced below.

## Step 1.5 — Build cross-file context

If env `IGNORE_PATHSPECS` is non-empty, append it (as git pathspecs after `--`) to every `git diff` you run and do not review or report on those paths; static findings already arrive filtered, and HIGH-severity findings from ignored paths are marked `ignoredPath` — surface those in the walkthrough body only.

You have read-only repo tools (grep, read, glob). Before judging any change:

1. Read the impact map at `$CONTEXT_PATH` — pre-computed leads on where the changed symbols are referenced elsewhere in the repo. Treat it as leads, not gospel: it is heuristic identifier matching, not a call graph.
2. For any changed function, type, or exported symbol, confirm impact yourself (on incremental reviews, scope this to symbols changed in the new range):
   - grep for call sites; open the most relevant ones.
   - if a signature, return type, or behavior changed, verify each caller still holds. A caller that breaks is a BLOCKING finding (`evidence: caller-verified`).
3. Spend retrieval only on changes that plausibly affect other code. Do not explore unrelated files; cap yourself to the diff's blast radius.

## Step 4 — Classify every candidate finding

For EACH candidate finding assign:

- `severity`: `blocker` | `major` | `minor` | `nit`
  - blocker: correctness bugs, security vulnerabilities, data loss risks.
  - major: likely bug or significant defect, but survivable (e.g. unhandled edge case on a plausible input, swallowed error on a failure path).
  - minor/nit: suggestions, readability, test gaps.
- `confidence`: `high` | `medium` | `low`
  - high: scanner-confirmed (also present in `$FINDINGS_PATH`) OR caller-verified (you opened the breaking call site).
  - medium: a concrete logic/edge case you can articulate with the specific input that breaks it.
  - low: style, preference, "consider…", "might want to…" — anything without proof.
- `evidence`: `scanner-confirmed` | `caller-verified` | `logic-proof` | `opinion`

Dedup within this review: N instances of the same issue/rule → ONE comment on the clearest instance, naming the pattern and "…and N−1 other places (file:line, file:line)".

## Step 4.5 — Review your own review

Before posting, re-read your candidate findings as a skeptical senior engineer and DELETE any that are:

- not provable from the diff or a file you actually opened (speculation),
- already handled elsewhere in the changed code (you missed the guard — go check),
- style a linter would cover,
- restating what the code obviously does,
- duplicates of another finding (merge them).

Keep a finding only if you'd stake your credibility on it. When unsure, cut it.

## Posting mechanics

When Step 5 of your playbook says to post the review, post it exactly like this:

```
cat > "$RUNNER_TEMP/review.json" <<'EOF'
{
  "event": "REQUEST_CHANGES",
  "body": "<walkthrough markdown>",
  "comments": [
    { "path": "src/file.ts", "line": 42, "side": "RIGHT", "body": "..." }
  ]
}
EOF
gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" --input "$RUNNER_TEMP/review.json"
```

## Mapping inline comments to thread IDs

Where your playbook requires thread IDs (reconciliation and the state marker), fetch them like this:

```
gh api graphql -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(last: 100) {
          nodes {
            id
            isResolved
            comments(first: 1) { nodes { path body databaseId } }
          }
        }
      }
    }
  }' -f owner="<owner>" -f repo="<repo>" -F number="$PR_NUMBER"
```

Match each thread's first comment (by `path` + `body`) to the inline comments you just posted; store the matched `id` (a `PRRT_…` node ID) as `threadId` in the state findings. Threads you cannot match keep `threadId: null`.

## State marker contract

- The `ai-review:ack` and `ai-review:state` markers must both be present, exactly as shown.
- `lastSha`: value of env `HEAD_SHA`.
- `findings`: one entry per inline comment you posted, PLUS any prior finding that is still unfixed (per your playbook's prior-findings reconciliation step) — `file`, `fingerprint` (the static `ruleId`, or a short hash of the comment message for your own findings), and `threadId` if known. The state must contain ONLY still-open findings: a deterministic workflow step resolves every unresolved bot thread whose id is absent from this list, so omitting a live finding's `threadId` would wrongly resolve its thread.
- Warnings: if env `SIZE_WARNING` or `CONFIG_WARNING` is non-empty, include each one verbatim as its own line directly above the state marker. Never invent warning lines yourself.
