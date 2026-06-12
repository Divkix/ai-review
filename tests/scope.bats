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
