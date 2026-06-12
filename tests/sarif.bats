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
