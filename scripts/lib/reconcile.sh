#!/usr/bin/env bash
# Pure, side-effect-free helpers for the review lifecycle. No network, no
# GitHub API calls — only deterministic bash/jq transforms so they can be unit
# tested with bats. The workflows `source` this file (single source of truth);
# CI runs tests/reconcile.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.

# Force-push can make the previously reviewed SHA unreachable; an incremental
# review would then diff against nothing. Decide the effective mode/baseline,
# falling back to a full review with a blank baseline when the commit is gone.
#
# Usage: reconcile_effective_baseline <mode> <last_sha>
# Prints two lines: "mode=<full|incremental>" and "last_sha=<sha-or-empty>".
# Requires git (uses `git cat-file` reachability check against the cwd repo).
reconcile_effective_baseline() {
  local mode="$1" last_sha="$2"
  local eff_mode="$mode" eff_sha="$last_sha"
  if [ "$mode" = "incremental" ] && [ -n "$last_sha" ]; then
    if ! git cat-file -e "${last_sha}^{commit}" 2>/dev/null; then
      eff_mode=full
      eff_sha=""
    fi
  fi
  printf 'mode=%s\n' "$eff_mode"
  printf 'last_sha=%s\n' "$eff_sha"
}

# Extract the latest trusted state-marker JSON from a comments array on stdin.
# Only markers authored by the github-actions bot are trusted; any user could
# otherwise plant a forged marker. Prints the inner JSON (or "{}" if none).
#
# Usage: reconcile_state_from_comments < comments.json
reconcile_state_from_comments() {
  jq -rs 'add
    | [.[] | select(.user.type == "Bot"
        and (.user.login | startswith("github-actions"))
        and (.body | contains("<!-- ai-review:state")))]
    | last
    | ((.body // "") | capture("<!-- ai-review:state (?<j>.*?) -->"; "s") | .j) // "{}"'
}

# Print the non-null threadIds of still-open findings from a state JSON on
# stdin, one per line.
#
# Usage: reconcile_open_thread_ids < state.json
reconcile_open_thread_ids() {
  jq -r '(try .findings catch []) // [] | .[].threadId // empty'
}

# Decide whether thread resolution may proceed. Reads the state JSON on stdin.
# Consolidates every safety condition:
#   - APPROVED verdict -> always proceed (intent: resolve all bot threads).
#   - Non-APPROVED verdicts require a state that is:
#       fresh      (.lastSha == head_sha — the LLM updated the marker this run),
#       well-formed (.findings absent/null or an array),
#       non-empty  (CHANGES_REQUESTED implies >=1 open finding),
#       fully mapped (no finding with a null threadId).
# Prints "proceed" or "skip:<reason>" (stale-state | malformed-findings |
# empty-findings-on-cr | unmapped-findings). Always returns 0; callers branch
# on the printed value so an unexpected jq failure cannot be mistaken for a
# pass.
#
# Usage: reconcile_resolution_gate <latest_state> <head_sha> < state.json
reconcile_resolution_gate() {
  local latest_state="$1" head_sha="$2"
  local state
  state="$(cat)"
  if [ "$latest_state" = "APPROVED" ]; then
    printf 'proceed\n'
    return 0
  fi
  if ! jq -e '(.findings // []) | type == "array"' <<<"$state" >/dev/null 2>&1; then
    printf 'skip:malformed-findings\n'
    return 0
  fi
  local last_sha
  last_sha="$(jq -r '.lastSha // ""' <<<"$state")"
  if [ "$last_sha" != "$head_sha" ]; then
    printf 'skip:stale-state\n'
    return 0
  fi
  local count null_count
  count="$(jq -r '(.findings // []) | length' <<<"$state")"
  null_count="$(jq -r '(.findings // []) | [.[] | select(.threadId == null)] | length' <<<"$state")"
  if [ "$latest_state" = "CHANGES_REQUESTED" ] && [ "$count" -eq 0 ]; then
    printf 'skip:empty-findings-on-cr\n'
    return 0
  fi
  if [ "$null_count" -gt 0 ]; then
    printf 'skip:unmapped-findings\n'
    return 0
  fi
  printf 'proceed\n'
}

# Compute the set of thread ids to RESOLVE: live unresolved bot-authored thread
# ids that are ABSENT from the state's still-open id list. Both inputs are
# files with one id per line. Prints ids to resolve, one per line.
#
# Usage: reconcile_resolve_set <live_ids_file> <state_ids_file>
reconcile_resolve_set() {
  local live_file="$1" state_file="$2"
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if grep -qxF "$id" "$state_file"; then
      continue
    fi
    printf '%s\n' "$id"
  done < "$live_file"
}
