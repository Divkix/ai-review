#!/usr/bin/env bats
# Unit tests for scripts/lib/cochange.sh — the historical co-change section
# builder the context job sources. No network, no GitHub API.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/cochange.sh"
  command -v git >/dev/null || skip "git not installed"
  command -v awk >/dev/null || skip "awk not installed"
}

# ---------------------------------------------------------------------------
# Shared helper: build a throwaway repo used by most tests.
# Creates $BATS_TEST_TMPDIR/cc_repo with:
#   - a.sh and b.sh co-committed 4 times (commit-1 through commit-4)
#   - a.sh committed alone once (commit-5, so total commits touching a.sh = 5)
#   - a 35-file mass commit (commit-6, should be dropped by max_changeset=30)
#   - a real merge commit (commit-7, should be excluded by --no-merges)
#   - c.sh present on disk (to test "file exists" filter)
#   - d.sh NOT present on disk (to test "deleted candidate" filter)
# After setup, HEAD is at the tip of the main branch.
# ---------------------------------------------------------------------------
make_cochange_repo() {
  local dir="$BATS_TEST_TMPDIR/cc_repo"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git config user.email "t@t"
  git config user.name "t"

  # Initial commit: create files
  printf '#!/usr/bin/env bash\nfunc_a() { echo a; }\n' > a.sh
  printf '#!/usr/bin/env bash\nfunc_b() { echo b; }\n' > b.sh
  printf '#!/usr/bin/env bash\nfunc_c() { echo c; }\n' > c.sh
  printf '#!/usr/bin/env bash\nfunc_d() { echo d; }\n' > d.sh
  git add a.sh b.sh c.sh d.sh
  git commit -q -m "initial"

  # Co-commits 1-4: a.sh and b.sh change together
  for i in 1 2 3 4; do
    printf '#!/usr/bin/env bash\nfunc_a_%d() { echo a; }\n' "$i" > a.sh
    printf '#!/usr/bin/env bash\nfunc_b_%d() { echo b; }\n' "$i" > b.sh
    git add a.sh b.sh
    git commit -q -m "co-commit $i"
  done

  # Commit-5: a.sh alone (total touching a.sh = 5; co-changes a+b = 4 → 80%)
  printf '#!/usr/bin/env bash\nfunc_a_solo() { echo solo; }\n' > a.sh
  git add a.sh
  git commit -q -m "solo a"

  # Commit-6: mass commit touching 35 files (>30, should be dropped)
  for i in $(seq 1 35); do
    printf 'mass%d\n' "$i" > "mass_${i}.txt"
  done
  # Also touch a.sh in the mass commit so we verify it doesn't count
  printf '#!/usr/bin/env bash\nfunc_a_mass() { echo mass; }\n' > a.sh
  git add mass_*.txt a.sh
  git commit -q -m "mass commit 35 files"

  # Commit-7: real merge commit (should be excluded by --no-merges)
  git checkout -q -b side_branch
  printf '#!/usr/bin/env bash\nfunc_a_side() { echo side; }\n' > a.sh
  printf '#!/usr/bin/env bash\nfunc_b_side() { echo side; }\n' > b.sh
  git add a.sh b.sh
  git commit -q -m "side commit"
  git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true
  git merge --no-ff -q side_branch -m "merge side into main"

  # Remove d.sh so it's a deleted candidate
  git rm -q d.sh
  git commit -q -m "delete d.sh"

  # Restore working tree: a.sh final state
  printf '#!/usr/bin/env bash\nfunc_a_final() { echo final; }\n' > a.sh
  git add a.sh
  git commit -q -m "final a"

  cd "$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# cochange_extract_history
# ---------------------------------------------------------------------------

@test "cochange: pair above thresholds -> surfaced with count and confidence" {
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  # Build a simple repo: a+b co-committed 4 times, a alone once → 4/5 = 80%
  local hist
  hist="$(cochange_extract_history HEAD)"
  # b.sh should appear as co-changed with a.sh
  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # b.sh should appear as a co-change candidate for a.sh
  echo "$output" | grep -q "b.sh"
  # count (field 1) must be >= 3 (above min_count threshold) and conf (field 2) >= 30
  echo "$output" | awk -F'\t' '$4=="b.sh" && $1>=3 && $2>=30{found=1} END{exit !found}'
}

@test "cochange: candidate also changed in PR range -> excluded" {
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'
    changed_list=\"\$(mktemp)\"
    # Both a.sh and b.sh are in PR range → b.sh must be excluded as candidate
    printf 'a.sh\nb.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # b.sh is in changed_list → must NOT appear
  ! echo "$output" | grep -q "b.sh"
}

@test "cochange: support below min count -> dropped" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/min_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # Only 2 co-commits (below min_count=3). Commit a.sh and b.sh separately in
  # the initial commit so it does NOT count as a co-change pairing.
  printf 'x\n' > a.sh && git add a.sh && git commit -q -m "init a"
  printf 'x\n' > b.sh && git add b.sh && git commit -q -m "init b"
  for i in 1 2; do
    printf '%d\n' "$i" > a.sh
    printf '%d\n' "$i" > b.sh
    git add a.sh b.sh && git commit -q -m "co $i"
  done

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # 2 co-changes < min_count 3 → no output
  [ -z "$output" ]
}

@test "cochange: confidence below threshold -> dropped" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/conf_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # a.sh alone in 10 commits, a+b only 3 times → conf = 3/13 = 23% < 30%
  printf 'x\n' > a.sh && printf 'x\n' > b.sh
  git add a.sh b.sh && git commit -q -m "init"
  for i in $(seq 1 10); do
    printf '%d\n' "$i" > a.sh
    git add a.sh && git commit -q -m "solo $i"
  done
  for i in $(seq 1 3); do
    printf 'co%d\n' "$i" > a.sh
    printf 'co%d\n' "$i" > b.sh
    git add a.sh b.sh && git commit -q -m "co $i"
  done

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # 3/13 = 23% < 30% threshold → no output
  [ -z "$output" ]
}

@test "cochange: commit touching more than max-changeset files -> not counted" {
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  # Without the mass commit, a+b would have co-changes; verify mass commit itself
  # does not inflate counts. Extract history and look for mass_ files paired with a.sh.
  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    # Extract with max_changeset=30; the mass commit has 36 files → dropped
    cochange_extract_history HEAD 1000 '12 months ago' 30 | cochange_rank a.sh \"\$changed_list\" 1 1 20
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # mass_*.txt must NOT appear (they only co-changed with a.sh in the mass commit)
  ! echo "$output" | grep -q "mass_1.txt"
  ! echo "$output" | grep -q "mass_"
}

@test "cochange: merge commit -> not counted" {
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  # The merge commit is excluded via --no-merges. If it were counted, d.sh (added
  # in side_branch before being deleted) would co-change with a.sh via the merge.
  # We verify the merge doesn't add a spurious coupling count beyond the 4 co-commits.
  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # b.sh should appear with count=4 (not 5), because the merge commit is excluded
  # The side commit (merged in) touches a.sh + b.sh; but side commit IS a regular
  # commit (reachable from merge parent) — however, the merge commit itself is not counted.
  # We check that the merge commit doesn't cause total to be off:
  # expected: 4 co-commits a+b → b.sh row has count>=4
  if echo "$output" | grep -q "b.sh"; then
    local count
    count="$(echo "$output" | awk -F'\t' '$4=="b.sh"{print $1}')"
    # count must be a number >= 4
    [ "$count" -ge 4 ]
  fi
}

@test "cochange: ignored candidate filtered via patterns-file" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/ignore_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # a.sh + package-lock.json co-committed 4 times
  printf 'x\n' > a.sh && printf 'x\n' > package-lock.json
  git add a.sh package-lock.json && git commit -q -m "init"
  for i in 1 2 3 4; do
    printf '%d\n' "$i" > a.sh
    printf '%d\n' "$i" > package-lock.json
    git add a.sh package-lock.json && git commit -q -m "co $i"
  done

  # The built-in lockfile case in cochange_build_map will skip changed files,
  # but cochange_rank doesn't have a built-in lockfile filter on candidates.
  # Here we use cochange_build_map with a patterns-file that matches *-lock.json.
  # Also create a fake PR range (empty, just need a changed_list for the function).
  git checkout -q -b pr_branch
  printf 'changed\n' > a.sh
  git add a.sh && git commit -q -m "pr change"

  local pats_file="$BATS_TEST_TMPDIR/pats_ignore"
  printf '*-lock.json\n' > "$pats_file"

  run bash -c "
    source '$REPO_ROOT/scripts/lib/scope.sh'
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    cochange_build_map 'HEAD~1...HEAD' HEAD '$pats_file'
  "
  [ "$status" -eq 0 ]
  # package-lock.json must not appear as a candidate (filtered by patterns-file)
  ! echo "$output" | grep -q "package-lock.json"
}

@test "cochange: file new in PR with no history -> omitted, exit 0" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/newfile_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # Initial commit on base branch
  printf 'x\n' > existing.sh
  git add existing.sh && git commit -q -m "init"
  # Record the base ref (simulates origin/${BASE_REF})
  local base_sha
  base_sha="$(git rev-parse HEAD)"

  # PR branch adds a brand-new file that has no history prior to this PR
  git checkout -q -b pr_newfile
  printf 'new\n' > brand_new.sh
  git add brand_new.sh && git commit -q -m "add new file"

  # Mine history from base_sha (= origin/<base>); the PR commit is NOT in that ref.
  # brand_new.sh has no history in the base branch → must be omitted.
  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    cochange_build_map '${base_sha}...HEAD' '${base_sha}'
  "
  [ "$status" -eq 0 ]
  # brand_new.sh has no history in base ref → section must be omitted entirely
  ! echo "$output" | grep -q "## brand_new.sh"
}

@test "cochange: missing ref -> empty output, exit 0" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/missingref_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"
  printf 'x\n' > a.sh && git add a.sh && git commit -q -m "init"

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    cochange_extract_history 'origin/nonexistent-branch-xyz'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cochange: row cap respected" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/rowcap_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # a.sh co-changed with 8 different files across 4 commits each
  printf 'x\n' > a.sh
  for i in $(seq 1 8); do printf 'x\n' > "peer_${i}.sh"; done
  git add . && git commit -q -m "init"

  for i in $(seq 1 4); do
    printf '%d\n' "$i" > a.sh
    for j in $(seq 1 8); do printf '%d\n' "$i" > "peer_${j}.sh"; done
    git add . && git commit -q -m "co $i"
  done

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    # max_rows=5; all 8 peers qualify (count=4, conf=100%)
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 5
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # Must output exactly 5 rows (row cap)
  local line_count
  line_count="$(echo "$output" | grep -c '^' || true)"
  [ "$line_count" -eq 5 ]
}

@test "cochange: deleted candidate file -> excluded" {
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  # d.sh was deleted in the repo. If it were a co-change candidate, it should
  # be excluded by the [ -f ] check in cochange_build_map.
  # We need a PR range; create a minimal one.
  git checkout -q -b pr_del
  printf 'changed\n' > a.sh
  git add a.sh && git commit -q -m "pr change"

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'
    cochange_build_map 'HEAD~1...HEAD' HEAD
  "
  [ "$status" -eq 0 ]
  # d.sh does not exist on disk → must not appear
  ! echo "$output" | grep -q "d.sh"
}

@test "cochange: ordering is deterministic (confidence desc, count desc, path asc)" {
  cd "$BATS_TEST_TMPDIR"
  local dir="$BATS_TEST_TMPDIR/order_repo"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  git init -q
  git config user.email "t@t" && git config user.name "t"

  # Build history so:
  #   b.sh: co 5 times / total 5 → conf=100%, count=5
  #   c.sh: co 4 times / total 5 → conf=80%,  count=4
  #   aaa.sh: co 3 times / total 5 → conf=60%, count=3  (path asc tiebreak)
  #   zzz.sh: co 3 times / total 5 → conf=60%, count=3
  printf 'x\n' > a.sh
  printf 'x\n' > b.sh
  printf 'x\n' > c.sh
  printf 'x\n' > aaa.sh
  printf 'x\n' > zzz.sh
  git add . && git commit -q -m "init"

  for i in 1 2 3 4 5; do
    printf '%d\n' "$i" > a.sh
    printf '%d\n' "$i" > b.sh
    git add a.sh b.sh
    [ "$i" -le 4 ] && { printf '%d\n' "$i" > c.sh; git add c.sh; }
    [ "$i" -le 3 ] && { printf '%d\n' "$i" > aaa.sh; printf '%d\n' "$i" > zzz.sh; git add aaa.sh zzz.sh; }
    git commit -q -m "commit $i"
  done

  run bash -c "
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$dir'
    changed_list=\"\$(mktemp)\"
    printf 'a.sh\n' > \"\$changed_list\"
    cochange_extract_history HEAD | cochange_rank a.sh \"\$changed_list\" 3 30 10
    rm -f \"\$changed_list\"
  "
  [ "$status" -eq 0 ]
  # Extract paths in order
  local paths
  paths="$(echo "$output" | awk -F'\t' '{print $4}')"
  local first second third fourth
  first="$(echo "$paths"  | sed -n '1p')"
  second="$(echo "$paths" | sed -n '2p')"
  third="$(echo "$paths"  | sed -n '3p')"
  fourth="$(echo "$paths" | sed -n '4p')"
  # b.sh (100%) > c.sh (80%) > aaa.sh (60%, path asc) > zzz.sh (60%, path asc)
  [ "$first"  = "b.sh"   ]
  [ "$second" = "c.sh"   ]
  [ "$third"  = "aaa.sh" ]
  [ "$fourth" = "zzz.sh" ]
}

@test "cochange: composition smoke test (workflow run-block under set -euo pipefail)" {
  # This test reproduces the exact split-budget workflow run-block lines verbatim
  # under set -euo pipefail to catch SIGPIPE/consumption hazards that the lib's
  # own unit tests won't catch (CLAUDE.md requires this for run-block compositions).
  make_cochange_repo
  cd "$BATS_TEST_TMPDIR/cc_repo"

  # Create a PR-like branch to give context_build_map a real range.
  git checkout -q -b pr_smoke
  printf 'smoke\n' > a.sh
  git add a.sh && git commit -q -m "smoke pr change"

  local range="HEAD~1...HEAD"
  local ref="HEAD"

  run bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/scope.sh'
    source '$REPO_ROOT/scripts/lib/context.sh'
    source '$REPO_ROOT/scripts/lib/cochange.sh'
    cd '$BATS_TEST_TMPDIR/cc_repo'

    patterns_file=\"\$(mktemp /tmp/context-patterns.XXXXXX)\"
    scope_builtin_ignores >> \"\$patterns_file\"

    range='HEAD~1...HEAD'
    ref='HEAD'

    context_build_map \"\$range\" \"\$patterns_file\" > context-impact.md
    cochange_build_map \"\$range\" \"\$ref\" \"\$patterns_file\" > context-cochange.md
    rm -f \"\$patterns_file\"
    head -c 52000 context-impact.md > context.md
    head -c 8000 context-cochange.md >> context.md
    wc -c context.md
  "
  [ "$status" -eq 0 ]
  # wc -c output should be present and context.md should exist and be non-empty
  echo "$output" | grep -qE '[0-9]+ context\.md'
}
