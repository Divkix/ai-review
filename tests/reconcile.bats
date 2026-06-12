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

# --- reconcile_null_count ----------------------------------------------------

@test "null count: zero when all mapped" {
  state="$(reconcile_state_from_comments < "$FIX/comments-open-finding.json")"
  run reconcile_null_count <<<"$state"
  [ "$output" = "0" ]
}

@test "null count: one when a finding has null threadId" {
  state="$(reconcile_state_from_comments < "$FIX/comments-null-thread.json")"
  run reconcile_null_count <<<"$state"
  [ "$output" = "1" ]
}

# --- reconcile_should_skip (safety gate) ------------------------------------

@test "gate: non-approve + unmapped findings -> SKIP" {
  run reconcile_should_skip "CHANGES_REQUESTED" 1
  [ "$status" -eq 0 ]   # 0 = skip
}

@test "gate: APPROVED + unmapped findings -> proceed" {
  run reconcile_should_skip "APPROVED" 2
  [ "$status" -eq 1 ]   # 1 = proceed
}

@test "gate: non-approve + complete mapping -> proceed" {
  run reconcile_should_skip "CHANGES_REQUESTED" 0
  [ "$status" -eq 1 ]
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
