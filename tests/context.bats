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
  # Feed a.sh as stdin to exercise the hostile-stdin (non-tty) case on every platform
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD" < a.sh'
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

@test "map: ignored changed file skipped via patterns-file" {
  cd "$BATS_TEST_TMPDIR"
  git init -q ignore_repo && cd ignore_repo
  git config user.email "t@t" && git config user.name "t"

  mkdir -p dist src
  printf '#!/usr/bin/env bash\nold_gen_func() { echo gen; }\n' > dist/gen.sh
  printf '#!/usr/bin/env bash\nreal_func() { echo real; }\n' > src/real.sh
  git add dist/gen.sh src/real.sh
  git commit -q -m "initial"

  printf '#!/usr/bin/env bash\nnew_gen_func() { echo gen2; }\n' > dist/gen.sh
  printf '#!/usr/bin/env bash\nreal_func_updated() { echo real2; }\n' > src/real.sh
  git add dist/gen.sh src/real.sh
  git commit -q -m "update"

  # Patterns file ignores dist/**
  printf 'dist/**\n' > "$BATS_TEST_TMPDIR/pats"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/scope.sh; source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD" "'"$BATS_TEST_TMPDIR/pats"'"'
  [ "$status" -eq 0 ]
  # dist/gen.sh must NOT appear as a changed file section
  ! echo "$output" | grep -q "## dist/gen.sh"
  # src/real.sh should appear
  echo "$output" | grep -q "## src/real.sh"
}

@test "map: no second arg -> existing tests unaffected" {
  cd "$BATS_TEST_TMPDIR"
  git init -q noarg_repo && cd noarg_repo
  git config user.email "t@t" && git config user.name "t"

  printf '#!/usr/bin/env bash\nnoarg_symbol_abc() { echo hi; }\n' > a.sh
  git add a.sh
  git commit -q -m "initial"

  printf '#!/usr/bin/env bash\nnoarg_symbol_xyz() { echo hi; }\n' > a.sh
  git add a.sh
  git commit -q -m "update"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "## a.sh"
}
