#!/usr/bin/env bats
# Unit tests for scripts/lib/reconcile.sh — the pure review-lifecycle logic
# the workflows source. No network, no GitHub API.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/reconcile.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures"
}

# --- reconcile_state_from_comments ------------------------------------------

@test "state: picks the LATEST bot marker, ignoring older bot + forged user" {
  run reconcile_state_from_comments < "$FIX/comments-approve-empty.json"
  [ "$status" -eq 0 ]
  # latest bot marker has lastSha bbb222 and empty findings
  echo "$output" | jq -e '.lastSha == "bbb222"'
  echo "$output" | jq -e '.findings == []'
}

@test "state: forged non-bot marker is ignored -> empty object" {
  run reconcile_state_from_comments < "$FIX/comments-none.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .)" = "{}" ]
}

# --- gate "Read state marker comment" run-block (composition smoke test) -----
# Reproduces the review.yml gate step body, templating only the comments source
# (gh api -> cat fixture) and the lib source path (env var). Asserts the
# GITHUB_OUTPUT contract the gate emits.
# The body is written to a temp script via a quoted heredoc so nothing expands
# at write time, then run with env vars supplying the inputs.

_run_gate_state_block() {
  # $1 = comments json file; writes the gate's GITHUB_OUTPUT contract.
  local script="$BATS_TEST_TMPDIR/gate_state.sh"
  cat > "$script" <<'GATE'
set -euo pipefail
# shellcheck source=/dev/null
. "$LIB"
raw="$(cat "$COMMENTS" | reconcile_state_from_comments)"
state_json=""
last_sha=""
if parsed="$(jq -ce . <<<"$raw" 2>/dev/null)" && [ "$parsed" != "{}" ]; then
  state_json="$parsed"
  last_sha="$(jq -r '.lastSha // ""' <<<"$state_json")"
fi
if ! grep -qE '^[0-9a-f]{40}$' <<<"$last_sha"; then
  last_sha=""
fi
delim="STATE_EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{
  echo "last_sha=$last_sha"
  echo "state_json<<$delim"
  echo "$state_json"
  echo "$delim"
} >> "$GITHUB_OUTPUT"
GATE
  LIB="$REPO_ROOT/scripts/lib/reconcile.sh" COMMENTS="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$script"
}

@test "gate: state run-block emits state_json + 40-hex last_sha under set -euo pipefail" {
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 40 hex
  local comments="$BATS_TEST_TMPDIR/comments.json"
  jq -n --arg sha "$sha" '[{user:{type:"Bot",login:"github-actions[bot]"},
    body:("x <!-- ai-review:state {\"lastSha\":\"" + $sha + "\",\"findings\":[]} -->")}]' > "$comments"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; : > "$GITHUB_OUTPUT"
  run _run_gate_state_block "$comments"
  [ "$status" -eq 0 ]
  grep -qx "last_sha=$sha" "$GITHUB_OUTPUT"
  # extract the heredoc payload line (the line after the state_json<<DELIM
  # opener); awk is portable across BSD/GNU, unlike sed's `{n;p}`.
  payload="$(awk '/^state_json<<STATE_EOF_/{getline; print; exit}' "$GITHUB_OUTPUT")"
  echo "$payload" | jq -e '.findings == []'
  echo "$payload" | jq -e '.lastSha == "'"$sha"'"'
}

@test "gate: state run-block ignores forged non-bot marker -> empty outputs" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; : > "$GITHUB_OUTPUT"
  run _run_gate_state_block "$FIX/comments-none.json"
  [ "$status" -eq 0 ]
  grep -qx "last_sha=" "$GITHUB_OUTPUT"
  payload="$(awk '/^state_json<<STATE_EOF_/{getline; print; exit}' "$GITHUB_OUTPUT")"
  [ -z "$payload" ]
}

@test "gate: state run-block blanks non-40-hex last_sha but keeps state_json" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; : > "$GITHUB_OUTPUT"
  run _run_gate_state_block "$FIX/comments-open-finding.json"
  [ "$status" -eq 0 ]
  grep -qx "last_sha=" "$GITHUB_OUTPUT"
  payload="$(awk '/^state_json<<STATE_EOF_/{getline; print; exit}' "$GITHUB_OUTPUT")"
  [ -n "$payload" ]
  echo "$payload" | jq -e '.lastSha == "cafe01"'
}

# --- reconcile_open_thread_ids ----------------------------------------------

@test "open ids: empty findings -> no ids" {
  state="$(reconcile_state_from_comments < "$FIX/comments-approve-empty.json")"
  run reconcile_open_thread_ids <<<"$state"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "open ids: one open finding -> its threadId" {
  state="$(reconcile_state_from_comments < "$FIX/comments-open-finding.json")"
  run reconcile_open_thread_ids <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "PRRT_keep" ]
}

@test "open ids: null threadId is omitted, mapped one kept" {
  state="$(reconcile_state_from_comments < "$FIX/comments-null-thread.json")"
  run reconcile_open_thread_ids <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "PRRT_mapped" ]
}

# --- reconcile_resolution_gate ----------------------------------------------

@test "resolution gate: APPROVED -> proceed regardless of state" {
  run reconcile_resolution_gate "APPROVED" "x" <<<"$( printf '{}' )"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "resolution gate: CR + fresh mapped non-empty state -> proceed" {
  state="$(reconcile_state_from_comments < "$FIX/comments-open-finding.json")"
  run reconcile_resolution_gate "CHANGES_REQUESTED" "cafe01" <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "resolution gate: CR + stale lastSha -> skip:stale-state" {
  state="$(reconcile_state_from_comments < "$FIX/comments-open-finding.json")"
  run reconcile_resolution_gate "CHANGES_REQUESTED" "deadbeef" <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "skip:stale-state" ]
}

@test "resolution gate: CR + findings is a string -> skip:malformed-findings" {
  state="$(reconcile_state_from_comments < "$FIX/comments-malformed-findings.json")"
  run reconcile_resolution_gate "CHANGES_REQUESTED" "bbb222" <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "skip:malformed-findings" ]
}

@test "resolution gate: CR + invalid JSON state -> skip:malformed-findings" {
  run reconcile_resolution_gate "CHANGES_REQUESTED" "abc" <<<"not-json"
  [ "$status" -eq 0 ]
  [ "$output" = "skip:malformed-findings" ]
}

@test "resolution gate: CR + empty findings -> skip:empty-findings-on-cr" {
  run reconcile_resolution_gate "CHANGES_REQUESTED" "abc" <<<'{"lastSha":"abc","findings":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "skip:empty-findings-on-cr" ]
}

@test "resolution gate: CR + null threadId -> skip:unmapped-findings" {
  state="$(reconcile_state_from_comments < "$FIX/comments-null-thread.json")"
  run reconcile_resolution_gate "CHANGES_REQUESTED" "f00d02" <<<"$state"
  [ "$status" -eq 0 ]
  [ "$output" = "skip:unmapped-findings" ]
}

@test "resolution gate: COMMENTED + empty findings -> proceed" {
  run reconcile_resolution_gate "COMMENTED" "abc" <<<'{"lastSha":"abc","findings":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

# --- reconcile_resolve_set --------------------------------------------------

@test "resolve set: live ids absent from state are resolved; state ids kept" {
  live="$BATS_TEST_TMPDIR/live"; state="$BATS_TEST_TMPDIR/state"
  printf 'PRRT_a\nPRRT_keep\nPRRT_c\n' > "$live"
  printf 'PRRT_keep\n' > "$state"
  run reconcile_resolve_set "$live" "$state"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tr '\n' ',')" = "PRRT_a,PRRT_c," ]
}

@test "resolve set: empty state -> resolve everything live (APPROVE case)" {
  live="$BATS_TEST_TMPDIR/live"; state="$BATS_TEST_TMPDIR/state"
  printf 'PRRT_a\nPRRT_b\n' > "$live"
  : > "$state"
  run reconcile_resolve_set "$live" "$state"
  [ "$(echo "$output" | tr '\n' ',')" = "PRRT_a,PRRT_b," ]
}

# --- reconcile_effective_baseline (needs a real git repo) -------------------

@test "baseline: reachable sha stays incremental" {
  cd "$BATS_TEST_TMPDIR"
  git init -q r && cd r
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  sha="$(git rev-parse HEAD)"
  run reconcile_effective_baseline "incremental" "$sha"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "mode=incremental"
  echo "$output" | grep -qx "last_sha=$sha"
}

@test "baseline: unreachable sha falls back to full with blank baseline" {
  cd "$BATS_TEST_TMPDIR"
  git init -q r2 && cd r2
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  run reconcile_effective_baseline "incremental" "0000000000000000000000000000000000000000"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "mode=full"
  echo "$output" | grep -qx "last_sha="
}

@test "baseline: full mode passes through untouched" {
  cd "$BATS_TEST_TMPDIR"
  run reconcile_effective_baseline "full" ""
  echo "$output" | grep -qx "mode=full"
  echo "$output" | grep -qx "last_sha="
}
