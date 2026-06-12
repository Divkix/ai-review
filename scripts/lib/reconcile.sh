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

# Print the count of findings with a null threadId in a state JSON on stdin.
#
# Usage: reconcile_null_count < state.json
reconcile_null_count() {
  jq -r '(try .findings catch []) // [] | [.[] | select(.threadId == null)] | length'
}

# Safety gate: should thread resolution be SKIPPED?
# When the verdict is NOT approve and the agent failed to map some open
# findings to thread ids (threadId null), absence of an id from the state list
# is meaningless — resolving on it could wrongly resolve the threads just
# posted. Only proceed (return 1) if approved, or if mapping is complete.
#
# Usage: reconcile_should_skip <latest_state> <null_count>
# Returns 0 (true, skip) when it is unsafe to resolve; 1 otherwise.
reconcile_should_skip() {
  local latest_state="$1" null_count="$2"
  if [ "$latest_state" != "APPROVED" ] && [ "${null_count:-0}" -gt 0 ]; then
    return 0
  fi
  return 1
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
