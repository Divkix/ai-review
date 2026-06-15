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

# --- context_ast_lang ---------------------------------------------------

@test "ast_lang: python extension maps correctly" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "foo.py"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^python|"
  echo "$output" | grep -q "function_definition"
  echo "$output" | grep -q "call$"
}

@test "ast_lang: go extension maps correctly" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "path/to/service.go"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^go|"
  echo "$output" | grep -q "function_declaration"
  echo "$output" | grep -q "call_expression"
}

@test "ast_lang: rust extension maps correctly" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "src/lib.rs"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rust|"
  echo "$output" | grep -q "function_item"
  echo "$output" | grep -q "call_expression"
}

@test "ast_lang: tsx extension maps correctly" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "Button.tsx"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^tsx|"
  echo "$output" | grep -q "jsx_opening_element"
}

@test "ast_lang: bash extensions map correctly" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "deploy.sh"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bash|"
  echo "$output" | grep -q "function_definition"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "run.bash"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^bash|"
}

@test "ast_lang: unmapped extension -> empty output (rg fallback)" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "foo.java"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_ast_lang "data.xml"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- context_sg_rules ---------------------------------------------------

@test "sg_rules: python rules have no leading --- and use identifier kind" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_sg_rules python "function_definition,class_definition" "call" "my_func"'
  [ "$status" -eq 0 ]
  # Must NOT start with ---
  first_line="$(echo "$output" | head -1)"
  [ "$first_line" != "---" ]
  echo "$output" | grep -q "id: def--my_func"
  echo "$output" | grep -q "id: ref--my_func"
  echo "$output" | grep -q "kind: identifier"
  echo "$output" | grep -q "field: name"
}

@test "sg_rules: rust rules use any:[identifier,type_identifier]" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_sg_rules rust "function_item,struct_item" "call_expression" "MyStruct"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "kind: type_identifier"
  echo "$output" | grep -q "kind: identifier"
}

@test "sg_rules: bash rules use word kind for def and command_name for ref" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_sg_rules bash "function_definition" "command_name" "deploy_app"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "kind: word"
  echo "$output" | grep -q "kind: command_name"
  echo "$output" | grep -q "kind: command"
}

@test "sg_rules: multiple symbols get --- separator between rules" {
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_sg_rules python "function_definition" "call" "func_one" "func_two"'
  [ "$status" -eq 0 ]
  # 2 symbols * 2 rules each = 4 blocks; 3 separators between them
  sep_count="$(echo "$output" | grep -c "^---" || true)"
  [ "$sep_count" -eq 3 ]
}

@test "sg_rules: regex-special symbol is escaped" {
  # Symbol with a dot (unusual but defensive) should be escaped
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_sg_rules python "function_definition" "call" "my.func"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "regex: .*my\\.func"
}

# --- ast-grep integration (gated on ast-grep binary) -------------------

@test "ast: python def is found cross-file, not in changed file" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q pydef_repo && cd pydef_repo
  git config user.email "t@t" && git config user.name "t"

  # Initial: compute.py with function, caller.py referencing it
  printf 'def compute_total(items, rate):\n    return sum(items) * rate\n' > compute.py
  printf 'from compute import compute_total\nresult = compute_total([1,2,3], 0.1)\n' > caller.py
  git add compute.py caller.py
  git commit -q -m "initial"

  # Change compute.py (add optional arg)
  printf 'def compute_total(items, rate, discount=0):\n    return sum(items) * rate * (1 - discount)\n' > compute.py
  git add compute.py
  git commit -q -m "add discount"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  # Should find reference in caller.py
  echo "$output" | grep -q "caller.py"
  # The entry should use AST label
  echo "$output" | grep -q "(AST)"
  # compute.py itself should NOT appear in the refs (self-file excluded)
  ! echo "$output" | grep -q "compute.py:.*referenced at"
}

@test "ast: javascript def/ref found cross-file" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q jsref_repo && cd jsref_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'function processPayment(amount) { return amount; }\n' > payment.js
  printf 'import { processPayment } from "./payment";\nconst r = processPayment(99);\n' > app.js
  git add payment.js app.js
  git commit -q -m "initial"

  printf 'function processPayment(amount, currency) { return amount; }\n' > payment.js
  git add payment.js
  git commit -q -m "add currency"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "app.js"
  echo "$output" | grep -q "(AST)"
}

@test "ast: go precision — 'main' symbol finds only function def, not package decl" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q goprec_repo && cd goprec_repo
  git config user.email "t@t" && git config user.name "t"

  # package main + func main — lexical grep returns 2 lines; ast-grep returns 1 def
  printf 'package main\n\nfunc main() {\n    processOrder()\n}\n' > main.go
  printf 'package main\n\nfunc processOrder() {}\n' > order.go
  git add main.go order.go
  git commit -q -m "initial"

  printf 'package main\n\nfunc main() {\n    processOrder()\n    cleanup()\n}\n' > main.go
  printf 'package main\n\nfunc processOrder() {}\nfunc cleanup() {}\n' > order.go
  git add main.go order.go
  git commit -q -m "add cleanup"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  # cleanup is the new symbol changed in order.go; it should appear as referenced in main.go
  echo "$output" | grep -q "main.go"
  echo "$output" | grep -q "(AST)"
}

@test "ast: rust def/ref found" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q rsref_repo && cd rsref_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'fn calculate_hash(data: &[u8]) -> u32 { data.len() as u32 }\n' > hash.rs
  printf 'mod hash;\nfn main() { let h = hash::calculate_hash(&[1,2,3]); }\n' > main.rs
  git add hash.rs main.rs
  git commit -q -m "initial"

  printf 'fn calculate_hash(data: &[u8], seed: u32) -> u32 { data.len() as u32 + seed }\n' > hash.rs
  git add hash.rs
  git commit -q -m "add seed"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "main.rs"
  echo "$output" | grep -q "(AST)"
}

@test "ast: bash def/ref found" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q bashref_repo && cd bashref_repo
  git config user.email "t@t" && git config user.name "t"

  printf '#!/usr/bin/env bash\ndeploy_service() { echo "deploying $1"; }\n' > deploy.sh
  printf '#!/usr/bin/env bash\nsource ./deploy.sh\ndeploy_service myapp\n' > run.sh
  git add deploy.sh run.sh
  git commit -q -m "initial"

  printf '#!/usr/bin/env bash\ndeploy_service() { echo "deploying $1 v2"; }\n' > deploy.sh
  git add deploy.sh
  git commit -q -m "update"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "run.sh"
  echo "$output" | grep -q "(AST)"
}

@test "ast: unmapped extension uses rg fallback unchanged" {
  # .java is not in the curated set; rg fallback should run
  cd "$BATS_TEST_TMPDIR"
  git init -q javaref_repo && cd javaref_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'public class Service {\n    public void handleRequest() {}\n}\n' > Service.java
  printf 'public class Main {\n    Service s = new Service();\n    void run() { s.handleRequest(); }\n}\n' > Main.java
  git add Service.java Main.java
  git commit -q -m "initial"

  printf 'public class Service {\n    public void handleRequest(String ctx) {}\n}\n' > Service.java
  git add Service.java
  git commit -q -m "add ctx"

  # Even without ast-grep-mapped lang, rg fallback should find handleRequest in Main.java
  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Main.java"
  # rg path does not emit "(AST)" label
  ! echo "$output" | grep -q "(AST)"
}

@test "ast: honors patterns-file for ast-grep path" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q sgpats_repo && cd sgpats_repo
  git config user.email "t@t" && git config user.name "t"
  # Disable global gitignore so test-specific paths aren't filtered
  git config core.excludesFile /dev/null

  mkdir -p src generated keep
  printf 'def compute_value(x):\n    return x * 2\n' > src/compute.py
  printf 'from src.compute import compute_value\nresult = compute_value(5)\n' > generated/wrapper.py
  # keep/legit.py also references compute_value — must SURVIVE (not be ignored)
  printf 'from src.compute import compute_value\nresult = compute_value(10)\n' > keep/legit.py
  git add src/compute.py generated/wrapper.py keep/legit.py
  git commit -q -m "initial"

  printf 'def compute_value(x, factor=2):\n    return x * factor\n' > src/compute.py
  git add src/compute.py
  git commit -q -m "add factor"

  printf 'generated/**\n' > "$BATS_TEST_TMPDIR/pats2"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/scope.sh; source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD" "'"$BATS_TEST_TMPDIR/pats2"'"'
  [ "$status" -eq 0 ]
  # generated/wrapper.py must be excluded from refs due to patterns-file
  ! echo "$output" | grep -q "generated/wrapper.py"
  # keep/legit.py must SURVIVE — its reference to compute_value is not ignored
  echo "$output" | grep -q "keep/legit.py"
  # The ast-grep path must have run — "(AST)" label must appear in output
  echo "$output" | grep -q "(AST)"
}

@test "ast: demux determinism — same input always same output" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q det_repo && cd det_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'def transform_data(items):\n    return [x*2 for x in items]\n' > transform.py
  printf 'from transform import transform_data\nresult1 = transform_data([1])\nresult2 = transform_data([2])\nresult3 = transform_data([3])\n' > app.py
  git add transform.py app.py
  git commit -q -m "initial"

  printf 'def transform_data(items, scale=2):\n    return [x*scale for x in items]\n' > transform.py
  git add transform.py
  git commit -q -m "add scale"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  first_run="$output"

  run bash -c 'source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  [ "$output" = "$first_run" ]
}

@test "ast: composition smoke test under set -euo pipefail" {
  command -v ast-grep || skip "ast-grep not installed"
  cd "$BATS_TEST_TMPDIR"
  git init -q smoke_repo && cd smoke_repo
  git config user.email "t@t" && git config user.name "t"

  printf 'def validate_input(data):\n    return bool(data)\n' > validator.py
  printf 'from validator import validate_input\nok = validate_input("test")\n' > main.py
  git add validator.py main.py
  git commit -q -m "initial"

  printf 'def validate_input(data, strict=False):\n    return bool(data) if not strict else len(data) > 0\n' > validator.py
  git add validator.py
  git commit -q -m "add strict"

  run bash -c 'set -euo pipefail; source '"$REPO_ROOT"'/scripts/lib/context.sh; context_build_map "HEAD~1...HEAD"'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "## validator.py"
}
