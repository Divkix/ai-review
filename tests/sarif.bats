#!/usr/bin/env bats
# Unit tests for scripts/lib/sarif.sh — the pure SARIF merge logic
# the static job sources. No network, no GitHub API.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/sarif.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures"
}

# --- sarif_merge_one / level mapping ----------------------------------------

@test "sarif: error/warning levels map to HIGH/MEDIUM" {
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json"
  [ "$status" -eq 0 ]
  # First result is level:error -> HIGH
  echo "$output" | jq -e '.[0].severity == "HIGH"'
  # Second result is level:warning -> MEDIUM
  echo "$output" | jq -e '.[1].severity == "MEDIUM"'
}

@test "sarif: missing endLine falls back to startLine" {
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json"
  [ "$status" -eq 0 ]
  # Second result has no endLine in the fixture; endLine must equal startLine=42
  echo "$output" | jq -e '.[1].startLine == 42'
  echo "$output" | jq -e '.[1].endLine == 42'
}

@test "sarif: gitleaks default severity is HIGH" {
  run sarif_merge_one gitleaks "$FIX/sarif-gitleaks.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "HIGH"'
  echo "$output" | jq -e '.[0].tool == "gitleaks"'
}

@test "sarif: missing file -> contributes nothing" {
  run sarif_merge "opengrep:/nonexistent/path/file.sarif" "gitleaks:$FIX/sarif-gitleaks.json"
  [ "$status" -eq 0 ]
  # Only the gitleaks result is present
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].tool == "gitleaks"'
}

@test "sarif: all empty -> []" {
  run sarif_merge_one opengrep "$FIX/sarif-empty.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

# --- sarif_merge_one max_severity cap ----------------------------------------

@test "sarif: cap HIGH->MEDIUM clamps HIGH finding to MEDIUM" {
  # sarif-opengrep.json has a level:error -> HIGH finding
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json" MEDIUM
  [ "$status" -eq 0 ]
  # First finding was HIGH (error), now must be MEDIUM
  echo "$output" | jq -e '.[0].severity == "MEDIUM"'
}

@test "sarif: cap HIGH->LOW clamps HIGH finding to LOW" {
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json" LOW
  [ "$status" -eq 0 ]
  # Both findings (HIGH and MEDIUM) become LOW
  echo "$output" | jq -e '.[0].severity == "LOW"'
  echo "$output" | jq -e '.[1].severity == "LOW"'
}

@test "sarif: cap MEDIUM->LOW clamps MEDIUM finding to LOW" {
  # sarif-opengrep.json second finding is level:warning -> MEDIUM
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json" LOW
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[1].severity == "LOW"'
}

@test "sarif: cap HIGH->HIGH leaves severities unchanged (passthrough)" {
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json" HIGH
  [ "$status" -eq 0 ]
  # HIGH stays HIGH, MEDIUM stays MEDIUM
  echo "$output" | jq -e '.[0].severity == "HIGH"'
  echo "$output" | jq -e '.[1].severity == "MEDIUM"'
}

@test "sarif: no cap argument -> uncapped passthrough (regression)" {
  run sarif_merge_one opengrep "$FIX/sarif-opengrep.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "HIGH"'
  echo "$output" | jq -e '.[1].severity == "MEDIUM"'
}

@test "sarif: gitleaks HIGH with MEDIUM cap -> MEDIUM" {
  run sarif_merge_one gitleaks "$FIX/sarif-gitleaks.json" MEDIUM
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "MEDIUM"'
}

# --- findings_from_shellcheck ------------------------------------------------

@test "shellcheck: error maps to HIGH" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2086")] | .[0].severity == "HIGH"'
}

@test "shellcheck: warning maps to MEDIUM" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2034")] | .[0].severity == "MEDIUM"'
}

@test "shellcheck: info maps to LOW" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2148")] | .[0].severity == "LOW"'
}

@test "shellcheck: style maps to LOW" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2250")] | .[0].severity == "LOW"'
}

@test "shellcheck: ruleId format is SC<code> (e.g. SC2086)" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].ruleId == "SC2086"'
}

@test "shellcheck: tool field is shellcheck" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].tool == "shellcheck"'
}

@test "shellcheck: startLine and endLine populated" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].startLine == 10'
  echo "$output" | jq -e '.[0].endLine == 10'
  # Second finding spans lines 20-22
  echo "$output" | jq -e '.[1].startLine == 20'
  echo "$output" | jq -e '.[1].endLine == 22'
}

@test "shellcheck: missing file -> returns [] and exit 0" {
  run findings_from_shellcheck "/nonexistent/shellcheck-output.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "shellcheck: cap clamps error->HIGH to MEDIUM" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json" MEDIUM
  [ "$status" -eq 0 ]
  # SC2086 was error->HIGH, now must be MEDIUM
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2086")] | .[0].severity == "MEDIUM"'
  # SC2034 was warning->MEDIUM, stays MEDIUM
  echo "$output" | jq -e '[.[] | select(.ruleId == "SC2034")] | .[0].severity == "MEDIUM"'
}

@test "shellcheck: cap LOW clamps all to LOW" {
  run findings_from_shellcheck "$FIX/shellcheck-json1.json" LOW
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | .severity] | unique == ["LOW"]'
}
