#!/usr/bin/env bats
# Unit tests for scripts/lib/scope.sh — per-repo path filter + size guard lib.
# No network, no GitHub API calls.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/scope.sh"
  TMPD="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# scope_parse_config
# ---------------------------------------------------------------------------

@test "parse: happy path — all keys present" {
  config="$(printf 'version: 1\nmax_changed_files: 300\nmax_diff_lines: 15000\nignore:\n  - dist/**\n  - vendor/**\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -qx 'max_changed_files=300'
  echo "$output" | grep -qx 'max_diff_lines=15000'
  echo "$output" | grep -Fxq 'ignore=dist/**'
  echo "$output" | grep -Fxq 'ignore=vendor/**'
}

@test "parse: minimal valid config — version only" {
  run scope_parse_config <<< "version: 1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  # No max_changed_files or max_diff_lines emitted
  ! echo "$output" | grep -q 'max_changed_files'
  ! echo "$output" | grep -q 'max_diff_lines'
}

@test "parse: empty stdin -> valid=true with no extra keys" {
  run scope_parse_config <<< ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  ! echo "$output" | grep -q 'max_changed_files'
  ! echo "$output" | grep -q 'max_diff_lines'
  ! echo "$output" | grep -q 'ignore='
}

@test "parse: blank lines and comments only -> valid=true" {
  run scope_parse_config <<< "# comment only
"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
}

@test "parse: wrong version -> valid=false" {
  run scope_parse_config <<< "version: 2
ignore:
  - dist/**"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=false'
}

@test "parse: missing version in non-empty file -> valid=false" {
  run scope_parse_config <<< "ignore:
  - dist/**"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=false'
}

@test "parse: non-numeric max_changed_files -> valid=false" {
  run scope_parse_config <<< "version: 1
max_changed_files: lots"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=false'
}

@test "parse: non-numeric max_diff_lines -> valid=false" {
  run scope_parse_config <<< "version: 1
max_diff_lines: 'big'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=false'
}

@test "parse: quoted ignore pattern stripped of quotes" {
  run scope_parse_config <<< 'version: 1
ignore:
  - "docs/generated/**"
  - '"'"'vendor/**'"'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -Fxq 'ignore=docs/generated/**'
  echo "$output" | grep -Fxq 'ignore=vendor/**'
}

@test "parse: instructions with glob delimiter emitted as-is" {
  config="$(printf 'version: 1\ninstructions:\n  - "api/** :: Flag handlers missing input validation."\n  - "Prefer explicit error wrapping."\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -Fxq 'instructions=api/** :: Flag handlers missing input validation.'
  echo "$output" | grep -Fxq 'instructions=Prefer explicit error wrapping.'
}

@test "parse: instructions without delimiter -> repo-wide (still emitted)" {
  config="$(printf 'version: 1\ninstructions:\n  - "Always check for nil before dereferencing."\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fxq 'instructions=Always check for nil before dereferencing.'
}

@test "parse: instructions item truncated to 500 chars" {
  # Build a 600-char string
  long="$(printf '%0.s-' {1..600})"
  config="$(printf 'version: 1\ninstructions:\n  - "%s"\n' "$long")"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  # The emitted instructions= value should be at most 500 chars
  # wc -c counts the newline too, so expect <= 501
  item_len="$(echo "$output" | grep '^instructions=' | sed 's/^instructions=//' | wc -c | tr -d ' ')"
  [ "$item_len" -le 501 ]
}

@test "parse: malformed instruction item does NOT set valid=false" {
  # An instruction that looks weird but is just a string — should not invalidate
  config="$(printf 'version: 1\ninstructions:\n  - "::: bad ::: item"\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  ! echo "$output" | grep -qx 'valid=false'
}

@test "parse: instructions interleaved with other keys" {
  config="$(printf 'version: 1\nmax_changed_files: 200\ninstructions:\n  - "api/** :: validate inputs"\nignore:\n  - dist/**\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -qx 'max_changed_files=200'
  echo "$output" | grep -Fxq 'instructions=api/** :: validate inputs'
  echo "$output" | grep -Fxq 'ignore=dist/**'
}

@test "parse: guidelines present and safe -> emitted" {
  config="$(printf 'version: 1\nguidelines: docs/review-guidelines.md\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -Fxq 'guidelines=docs/review-guidelines.md'
}

@test "parse: guidelines absent -> not emitted" {
  config="$(printf 'version: 1\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '^guidelines='
}

@test "parse: guidelines with leading slash -> skipped (not valid=false)" {
  config="$(printf 'version: 1\nguidelines: /etc/passwd\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  ! echo "$output" | grep -q '^guidelines='
}

@test "parse: guidelines with .. segment -> skipped (not valid=false)" {
  config="$(printf 'version: 1\nguidelines: ../secrets/token\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  ! echo "$output" | grep -q '^guidelines='
}

@test "parse: guidelines with embedded .. segment -> skipped" {
  config="$(printf 'version: 1\nguidelines: docs/../../../etc/passwd\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  ! echo "$output" | grep -q '^guidelines='
}

@test "parse: ignore regression via scope_parse_list helper — still works" {
  config="$(printf 'version: 1\nignore:\n  - dist/**\n  - vendor/**\n  - "docs/generated/**"\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -Fxq 'ignore=dist/**'
  echo "$output" | grep -Fxq 'ignore=vendor/**'
  echo "$output" | grep -Fxq 'ignore=docs/generated/**'
}

@test "parse: unknown key forward-compat — instructions/guidelines present alongside unknown key" {
  config="$(printf 'version: 1\nunknown_future_key: somevalue\ninstructions:\n  - "api/** :: check auth"\nguidelines: docs/guide.md\n')"
  run scope_parse_config <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'valid=true'
  echo "$output" | grep -Fxq 'instructions=api/** :: check auth'
  echo "$output" | grep -Fxq 'guidelines=docs/guide.md'
}

# ---------------------------------------------------------------------------
# scope_parse_list (direct)
# ---------------------------------------------------------------------------

@test "parse_list: extracts items for a named key" {
  config="$(printf 'version: 1\nignore:\n  - dist/**\n  - vendor/**\n')"
  run scope_parse_list "ignore" <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fxq 'dist/**'
  echo "$output" | grep -Fxq 'vendor/**'
}

@test "parse_list: stops at next top-level key" {
  config="$(printf 'version: 1\nignore:\n  - dist/**\nmax_changed_files: 300\n')"
  run scope_parse_list "ignore" <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fxq 'dist/**'
  ! echo "$output" | grep -q 'max_changed_files'
}

@test "parse_list: blank line resets block (items after blank not included)" {
  config="$(printf 'version: 1\nignore:\n  - dist/**\n\n  - vendor/**\n')"
  run scope_parse_list "ignore" <<< "$config"
  [ "$status" -eq 0 ]
  # blank line resets in_block; vendor/** line appears as a stray list item
  # that is no longer under the key — it should NOT be emitted
  echo "$output" | grep -Fxq 'dist/**'
  ! echo "$output" | grep -Fxq 'vendor/**'
}

@test "parse_list: strips double quotes" {
  config="$(printf 'version: 1\nignore:\n  - "docs/generated/**"\n')"
  run scope_parse_list "ignore" <<< "$config"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fxq 'docs/generated/**'
}

@test "parse_list: key absent -> empty output" {
  config="$(printf 'version: 1\n')"
  run scope_parse_list "instructions" <<< "$config"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# scope_builtin_ignores
# ---------------------------------------------------------------------------

@test "builtin_ignores: emits exactly 6 patterns" {
  run scope_builtin_ignores
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 6 ]
  echo "$output" | grep -qx '*.lock'
  echo "$output" | grep -qx '*.sum'
  echo "$output" | grep -qx '*-lock.json'
  echo "$output" | grep -qx '*.min.*'
  echo "$output" | grep -qx '*.svg'
  echo "$output" | grep -qx '*.map'
}

# ---------------------------------------------------------------------------
# scope_match
# ---------------------------------------------------------------------------

@test "match: dist/** matches dist/a/b.js" {
  printf 'dist/**\n' > "$TMPD/pats"
  run scope_match "dist/a/b.js" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: dist/** does NOT match src/dist.js" {
  printf 'dist/**\n' > "$TMPD/pats"
  run scope_match "src/dist.js" "$TMPD/pats"
  [ "$status" -eq 1 ]
}

@test "match: dist/** matches dist/index.js (single depth)" {
  printf 'dist/**\n' > "$TMPD/pats"
  run scope_match "dist/index.js" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: *.lock matches at any depth via basename" {
  printf '*.lock\n' > "$TMPD/pats"
  run scope_match "packages/foo/yarn.lock" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: *.lock matches top-level lockfile" {
  printf '*.lock\n' > "$TMPD/pats"
  run scope_match "yarn.lock" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: *.lock does NOT match a .go file" {
  printf '*.lock\n' > "$TMPD/pats"
  run scope_match "cmd/main.go" "$TMPD/pats"
  [ "$status" -eq 1 ]
}

@test "match: *-lock.json matches package-lock.json at depth" {
  printf '*-lock.json\n' > "$TMPD/pats"
  run scope_match "ui/package-lock.json" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: vendor/** matches vendor/github.com/pkg/foo.go" {
  printf 'vendor/**\n' > "$TMPD/pats"
  run scope_match "vendor/github.com/pkg/foo.go" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: vendor/** does NOT match src/vendor_util.go" {
  printf 'vendor/**\n' > "$TMPD/pats"
  run scope_match "src/vendor_util.go" "$TMPD/pats"
  [ "$status" -eq 1 ]
}

@test "match: no patterns file -> no match (empty file)" {
  : > "$TMPD/empty_pats"
  run scope_match "any/file.go" "$TMPD/empty_pats"
  [ "$status" -eq 1 ]
}

@test "match: multiple patterns, first matches" {
  printf 'dist/**\nvendor/**\n' > "$TMPD/pats"
  run scope_match "dist/bundle.js" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

@test "match: multiple patterns, second matches" {
  printf 'dist/**\nvendor/**\n' > "$TMPD/pats"
  run scope_match "vendor/lib/x.go" "$TMPD/pats"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# scope_filtered_counts
# ---------------------------------------------------------------------------

@test "filtered_counts: ignored files excluded from counts" {
  printf 'dist/**\n' > "$TMPD/pats"
  # 3 files: 2 match dist/**, 1 does not
  json='[
    {"filename":"dist/bundle.js","additions":100,"deletions":50},
    {"filename":"dist/app.js","additions":200,"deletions":100},
    {"filename":"src/main.go","additions":10,"deletions":5}
  ]'
  run scope_filtered_counts "$TMPD/pats" <<< "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'files=1'
  echo "$output" | grep -qx 'lines=15'
}

@test "filtered_counts: no patterns -> all files counted" {
  : > "$TMPD/empty_pats"
  json='[
    {"filename":"src/a.go","additions":10,"deletions":5},
    {"filename":"src/b.go","additions":20,"deletions":10}
  ]'
  run scope_filtered_counts "$TMPD/empty_pats" <<< "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'files=2'
  echo "$output" | grep -qx 'lines=45'
}

@test "filtered_counts: lockfile builtin matches at depth" {
  scope_builtin_ignores > "$TMPD/builtins"
  json='[
    {"filename":"ui/package-lock.json","additions":500,"deletions":200},
    {"filename":"cmd/main.go","additions":10,"deletions":3}
  ]'
  run scope_filtered_counts "$TMPD/builtins" <<< "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'files=1'
  echo "$output" | grep -qx 'lines=13'
}

@test "filtered_counts: empty array -> files=0 lines=0" {
  : > "$TMPD/pats"
  run scope_filtered_counts "$TMPD/pats" <<< '[]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'files=0'
  echo "$output" | grep -qx 'lines=0'
}

# ---------------------------------------------------------------------------
# scope_rg_globs
# ---------------------------------------------------------------------------

@test "rg_globs: formats --glob !pattern pairs" {
  printf 'dist/**\nvendor/**\n' > "$TMPD/pats"
  run scope_rg_globs "$TMPD/pats"
  [ "$status" -eq 0 ]
  # Should produce alternating --glob / !pattern lines
  lines=("$output")
  echo "$output" | grep -qx -- '--glob'
  echo "$output" | grep -Fxq '!dist/**'
  echo "$output" | grep -Fxq '!vendor/**'
}

@test "rg_globs: empty patterns -> empty output" {
  : > "$TMPD/empty"
  run scope_rg_globs "$TMPD/empty"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# scope_exclude_pathspecs
# ---------------------------------------------------------------------------

@test "pathspecs: formats :(exclude)pattern lines" {
  printf 'dist/**\nvendor/**\n' > "$TMPD/pats"
  run scope_exclude_pathspecs "$TMPD/pats"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fxq ':(exclude)dist/**'
  echo "$output" | grep -Fxq ':(exclude)vendor/**'
}

@test "pathspecs: empty patterns -> empty output" {
  : > "$TMPD/empty"
  run scope_exclude_pathspecs "$TMPD/empty"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# scope_filter_findings
# ---------------------------------------------------------------------------

@test "filter_findings: MEDIUM in ignored path is dropped" {
  printf 'dist/**\n' > "$TMPD/pats"
  findings='[{"file":"dist/bundle.js","severity":"MEDIUM","ruleId":"sec/001","message":"test"}]'
  run scope_filter_findings "$TMPD/pats" <<< "$findings"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "filter_findings: HIGH in ignored path is kept with ignoredPath=true" {
  printf 'dist/**\n' > "$TMPD/pats"
  findings='[{"file":"dist/bundle.js","severity":"HIGH","ruleId":"sec/001","message":"secret"}]'
  run scope_filter_findings "$TMPD/pats" <<< "$findings"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  echo "$output" | jq -e '.[0].ignoredPath == true'
  echo "$output" | jq -e '.[0].severity == "HIGH"'
}

@test "filter_findings: finding outside ignored path is kept unchanged" {
  printf 'dist/**\n' > "$TMPD/pats"
  findings='[{"file":"src/main.go","severity":"MEDIUM","ruleId":"sec/002","message":"other"}]'
  run scope_filter_findings "$TMPD/pats" <<< "$findings"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 1 ]
  # No ignoredPath key added
  [ "$(echo "$output" | jq '.[0].ignoredPath')" = "null" ]
}

@test "filter_findings: mixed findings — drop MEDIUM ignored, annotate HIGH ignored, keep non-ignored" {
  printf 'dist/**\n' > "$TMPD/pats"
  findings='[
    {"file":"dist/a.js","severity":"MEDIUM","ruleId":"r1","message":"m1"},
    {"file":"dist/b.js","severity":"HIGH","ruleId":"r2","message":"m2"},
    {"file":"src/main.go","severity":"LOW","ruleId":"r3","message":"m3"}
  ]'
  run scope_filter_findings "$TMPD/pats" <<< "$findings"
  [ "$status" -eq 0 ]
  # 2 kept: HIGH in dist + non-ignored
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # The HIGH in dist has ignoredPath=true
  echo "$output" | jq -e '[.[] | select(.ruleId == "r2")] | .[0].ignoredPath == true'
  # The non-ignored has no ignoredPath
  echo "$output" | jq -e '[.[] | select(.ruleId == "r3")] | .[0].ignoredPath == null'
}

@test "filter_findings: empty array -> empty array" {
  : > "$TMPD/pats"
  run scope_filter_findings "$TMPD/pats" <<< '[]'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# workflow consumption smoke test
# ---------------------------------------------------------------------------

@test "parse: workflow consumption of absent keys is safe under set -euo pipefail" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    config_out=\"\$(scope_parse_config </dev/null)\"
    max_files=\"\$(grep '^max_changed_files=' <<< \"\$config_out\" | cut -d= -f2- || true)\"
    max_lines=\"\$(grep '^max_diff_lines=' <<< \"\$config_out\" | cut -d= -f2- || true)\"
    : \"\${max_files:=400}\"
    : \"\${max_lines:=20000}\"
    echo \"max_files=\$max_files\"
    echo \"max_lines=\$max_lines\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'max_files=400'
  echo "$output" | grep -qx 'max_lines=20000'
}

@test "parse: workflow consumption of instructions and guidelines under set -euo pipefail" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    config_out=\"\$(scope_parse_config <<< 'version: 1
instructions:
  - \"api/** :: check auth\"
  - \"Be strict.\"
guidelines: docs/guide.md')\"
    instructions_count=\"\$(grep -c '^instructions=' <<< \"\$config_out\" || true)\"
    guidelines=\"\$(grep '^guidelines=' <<< \"\$config_out\" | cut -d= -f2- || true)\"
    echo \"instructions_count=\$instructions_count\"
    echo \"guidelines=\$guidelines\"
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'instructions_count=2'
  echo "$output" | grep -qx 'guidelines=docs/guide.md'
}

# ---------------------------------------------------------------------------
# scope_detect_stacks
# ---------------------------------------------------------------------------

@test "detect_stacks: python file -> python token" {
  run scope_detect_stacks <<< '[{"filename":"src/app.py"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'python'
}

@test "detect_stacks: .pyi file -> python token" {
  run scope_detect_stacks <<< '[{"filename":"types/schema.pyi"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'python'
}

@test "detect_stacks: .go file -> go token" {
  run scope_detect_stacks <<< '[{"filename":"cmd/main.go"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'go'
}

@test "detect_stacks: go.mod alone -> empty output (NOT go)" {
  run scope_detect_stacks <<< '[{"filename":"go.mod"}]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_stacks: .ts file -> jsts token" {
  run scope_detect_stacks <<< '[{"filename":"src/index.ts"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'jsts'
}

@test "detect_stacks: .tsx file -> jsts token" {
  run scope_detect_stacks <<< '[{"filename":"components/Button.tsx"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'jsts'
}

@test "detect_stacks: .mjs file -> jsts token" {
  run scope_detect_stacks <<< '[{"filename":"lib/util.mjs"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'jsts'
}

@test "detect_stacks: .sh file -> shell token" {
  run scope_detect_stacks <<< '[{"filename":"scripts/deploy.sh"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'shell'
}

@test "detect_stacks: .bats file -> shell token" {
  run scope_detect_stacks <<< '[{"filename":"tests/scope.bats"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'shell'
}

@test "detect_stacks: Dockerfile -> docker token" {
  run scope_detect_stacks <<< '[{"filename":"Dockerfile"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'docker'
}

@test "detect_stacks: Dockerfile.prod -> docker token" {
  run scope_detect_stacks <<< '[{"filename":"Dockerfile.prod"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'docker'
}

@test "detect_stacks: .dockerfile extension -> docker token" {
  run scope_detect_stacks <<< '[{"filename":"build/app.dockerfile"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'docker'
}

@test "detect_stacks: Containerfile -> docker token" {
  run scope_detect_stacks <<< '[{"filename":"Containerfile"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'docker'
}

@test "detect_stacks: .github/workflows/x.yml -> actions (NOT iac)" {
  run scope_detect_stacks <<< '[{"filename":".github/workflows/ci.yml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'actions'
  ! echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: action.yml -> actions token" {
  run scope_detect_stacks <<< '[{"filename":"action.yml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'actions'
}

@test "detect_stacks: action.yaml -> actions token" {
  run scope_detect_stacks <<< '[{"filename":"action.yaml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'actions'
}

@test "detect_stacks: .tf file -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"infra/main.tf"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: .tfvars file -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"prod.tfvars"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: .tf.json file -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"generated.tf.json"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: Chart.yaml -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"helm/Chart.yaml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: kustomization.yaml -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"overlays/kustomization.yaml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: docker-compose.yml -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"docker-compose.yml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: docker-compose.override.yaml -> iac token" {
  run scope_detect_stacks <<< '[{"filename":"docker-compose.override.yaml"}]'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iac'
}

@test "detect_stacks: multiple stacks in one PR -> all tokens sorted" {
  json='[
    {"filename":"src/main.go"},
    {"filename":"src/app.py"},
    {"filename":"scripts/deploy.sh"},
    {"filename":".github/workflows/ci.yml"}
  ]'
  run scope_detect_stacks <<< "$json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'go'
  echo "$output" | grep -qx 'python'
  echo "$output" | grep -qx 'shell'
  echo "$output" | grep -qx 'actions'
  # Verify sorted order: actions < go < python < shell
  first="$(echo "$output" | head -1)"
  [ "$first" = "actions" ]
}

@test "detect_stacks: only .md files -> empty output" {
  json='[
    {"filename":"README.md"},
    {"filename":"docs/guide.md"}
  ]'
  run scope_detect_stacks <<< "$json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_stacks: empty array -> empty output" {
  run scope_detect_stacks <<< '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_stacks: duplicate filenames -> each token emitted once" {
  json='[
    {"filename":"src/a.py"},
    {"filename":"src/b.py"},
    {"filename":"lib/c.py"}
  ]'
  run scope_detect_stacks <<< "$json"
  [ "$status" -eq 0 ]
  count="$(echo "$output" | grep -c 'python' || true)"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# scope_render_instructions
# ---------------------------------------------------------------------------

@test "render_instructions: single glob item renders correctly" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< 'api/** :: Flag handlers missing input validation.'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '## Per-repo review instructions'
  echo "$output" | grep -qF -- '- `api/**` — Flag handlers missing input validation.'
}

@test "render_instructions: no-glob item renders as repo-wide" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< 'Always check for nil before dereferencing.'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- (all files) — Always check for nil before dereferencing.'
}

@test "render_instructions: leading dash in text does NOT error (regression guard)" {
  # This is the production bug: bash builtin printf '- ...' treats the leading
  # dash as a flag and exits 2 under set -euo pipefail. The fix uses
  # printf '%s\n' "$line" instead. This test MUST run under bash (not /usr/bin/printf).
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< '- leading dash text'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- (all files) — - leading dash text'
}

@test "render_instructions: colon-in-glob splits on first :: only" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< 'a:b/* :: check colon glob'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- `a:b/*` — check colon glob'
}

@test "render_instructions: two :: splits on FIRST only" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< 'path/** :: text :: extra colon'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- `path/**` — text :: extra colon'
}

@test "render_instructions: empty stdin -> empty output" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< ''
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render_instructions: multiple items all rendered" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    printf '%s\n%s\n' 'api/** :: validate inputs' 'Be strict.' | scope_render_instructions
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- `api/**` — validate inputs'
  echo "$output" | grep -qF -- '- (all files) — Be strict.'
  # Header emitted exactly once
  count="$(echo "$output" | grep -c '## Per-repo review instructions' || true)"
  [ "$count" -eq 1 ]
}

@test "render_instructions: blank lines in input are skipped" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    printf '%s\n%s\n%s\n' 'api/** :: first' '' 'second'  | scope_render_instructions
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF -- '- `api/**` — first'
  echo "$output" | grep -qF -- '- (all files) — second'
}

@test "render_instructions: lead sentence present in output" {
  SCOPE_SH="$REPO_ROOT/scripts/lib/scope.sh"
  run bash -c "
    set -euo pipefail
    source \"$SCOPE_SH\"
    scope_render_instructions <<< 'api/** :: check auth'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'These instructions come from the repository maintainers'
}
