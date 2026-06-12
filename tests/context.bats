#!/usr/bin/env bats
# Unit tests for scripts/lib/context.sh — the pure impact-map builder
# the context job sources. No network, no GitHub API.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/context.sh"
  command -v rg >/dev/null || skip "ripgrep not installed"
}

# --- context_mine_symbols ---------------------------------------------------

@test "mine: stopwords and short identifiers filtered" {
  diff_text="$(printf '+const for if my_function_name ab\n+  while (true) { return my_function_name; }\n-def old_impl(ctx, args):\n')"
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; printf "%s\n" "'"$diff_text"'" | context_mine_symbols'
  [ "$status" -eq 0 ]
  # my_function_name is a valid symbol and must appear
  echo "$output" | grep -qx "my_function_name"
  # stopwords must NOT appear
  ! echo "$output" | grep -qx "for"
  ! echo "$output" | grep -qx "if"
  ! echo "$output" | grep -qx "const"
  ! echo "$output" | grep -qx "while"
  ! echo "$output" | grep -qx "return"
  # short identifiers (< 3 chars) must NOT appear
  ! echo "$output" | grep -qx "ab"
}

@test "mine: cap at 30 symbols" {
  # Generate 40 distinct 3+-char identifiers on changed lines
  diff_text="$(python3 -c "
for i in range(40):
    print(f'+unique_identifier_{i:02d} = value_{i:02d}_result')
")"
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; printf "%s\n" "'"$diff_text"'" | context_mine_symbols'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 30 ]
}

@test "mine: empty diff -> empty output, exit 0" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; printf "" | context_mine_symbols'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- context_build_map (git-dependent) --------------------------------------

@test "map: cross-file reference is found" {
  # Build a throwaway repo where b.sh references a symbol changed in a.sh
  cd "$BATS_TEST_TMPDIR"
  git init -q map_repo && cd map_repo
  git config user.email "t@t" && git config user.name "t"

  # Initial commit: a.sh defines old_symbol_name, b.sh references it
  printf '#!/usr/bin/env bash\nold_symbol_name() { echo hi; }\n' > a.sh
  printf '#!/usr/bin/env bash\nold_symbol_name\n' > b.sh
  git add a.sh b.sh
  git commit -q -m "initial"

  # Change: rename symbol in a.sh (add new, remove old)
  printf '#!/usr/bin/env bash\nnew_symbol_func() { echo hi; }\n' > a.sh
  git add a.sh
  git commit -q -m "rename"

  # context_build_map with range from parent to HEAD
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  # b.sh should appear as a reference location for old_symbol_name
  echo "$output" | grep -q "b.sh"
}

@test "map: lockfiles skipped" {
  cd "$BATS_TEST_TMPDIR"
  git init -q lock_repo && cd lock_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'package-lock content\n' > package-lock.json
  git add package-lock.json
  git commit -q -m "initial"

  printf 'package-lock updated\nsome_real_symbol_xyz\n' > package-lock.json
  git add package-lock.json
  git commit -q -m "update lock"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  # The lockfile section must NOT appear
  ! echo "$output" | grep -q "## package-lock.json"
}
