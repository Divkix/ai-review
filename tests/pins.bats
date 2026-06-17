# Unit tests for scripts/lib/pins.sh (the single source of truth for pinned
# tools) and the pure helpers in scripts/bump-pins.sh. No network, no GitHub API.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/pins.sh"
  # bump-pins.sh guards main behind BASH_SOURCE so sourcing only loads helpers.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/bump-pins.sh"
}

# --- pins.sh: roster --------------------------------------------------------

@test "pins_scanners: 14 sha-pinned binaries, no opencode, no rules" {
  run pins_scanners
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "14" ]
  ! grep -qx OPENCODE <<<"$output"
  ! grep -qx OPENGREP_RULES <<<"$output"
  grep -qx GITLEAKS <<<"$output"
}

@test "pins_all: includes opencode + rules (16 total)" {
  run pins_all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "16" ]
  grep -qx OPENCODE <<<"$output"
  grep -qx OPENGREP_RULES <<<"$output"
}

@test "pins_bump_matrix_json: valid JSON array of all targets" {
  run pins_bump_matrix_json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 16'
  echo "$output" | jq -e 'index("OPENGREP_RULES") != null'
}

# --- pins.sh: field accessors ----------------------------------------------

@test "pins_repo / pins_kind: known + unknown tool" {
  [ "$(pins_repo GITLEAKS)" = "gitleaks/gitleaks" ]
  [ "$(pins_kind GITLEAKS)" = "scanner" ]
  [ "$(pins_kind OPENCODE)" = "opencode" ]
  [ "$(pins_kind OPENGREP_RULES)" = "rules" ]
  [ -z "$(pins_kind NOPE)" ]
}

@test "pins_files: opencode spans two workflow files" {
  run pins_files OPENCODE
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/review.yml .github/workflows/commands.yml" ]
}

# --- pins.sh: tag -> version rules -----------------------------------------

@test "pins_tag_to_version: strip-v drops leading v" {
  [ "$(pins_tag_to_version OPENGREP v1.22.0)" = "1.22.0" ]
  [ "$(pins_tag_to_version GITLEAKS v8.30.1)" = "8.30.1" ]
  [ "$(pins_tag_to_version OPENCODE v1.17.4)" = "1.17.4" ]
}

@test "pins_tag_to_version: verbatim keeps the tag (v-prefixed)" {
  [ "$(pins_tag_to_version SHELLCHECK v0.11.0)" = "v0.11.0" ]
  [ "$(pins_tag_to_version HADOLINT v2.14.0)" = "v2.14.0" ]
  [ "$(pins_tag_to_version TYPOS v1.47.2)" = "v1.47.2" ]
}

@test "pins_tag_to_version: verbatim keeps bare (no-v) tags" {
  [ "$(pins_tag_to_version RUFF 0.15.17)" = "0.15.17" ]
  [ "$(pins_tag_to_version RIPGREP 14.1.1)" = "14.1.1" ]
  [ "$(pins_tag_to_version ASTGREP 0.43.0)" = "0.43.0" ]
}

@test "pins_tag_to_version: oxlint keeps the apps_v prefix verbatim" {
  [ "$(pins_tag_to_version OXLINT apps_v1.69.0)" = "apps_v1.69.0" ]
  [ "$(pins_tag_select OXLINT)" = "apps_v" ]
}

# --- pins.sh: URL building (must match the workflow install steps) ---------

@test "pins_url: opengrep (v-prefix in URL, single \${ver})" {
  [ "$(pins_url OPENGREP 1.22.0)" = "https://github.com/opengrep/opengrep/releases/download/v1.22.0/opengrep_manylinux_x86" ]
}

@test "pins_url: gitleaks (repeated \${ver})" {
  [ "$(pins_url GITLEAKS 8.30.1)" = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz" ]
}

@test "pins_url: shellcheck (verbatim v-tag used directly)" {
  [ "$(pins_url SHELLCHECK v0.11.0)" = "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz" ]
}

@test "pins_url: oxlint (apps_v tag used directly)" {
  [ "$(pins_url OXLINT apps_v1.69.0)" = "https://github.com/oxc-project/oxc/releases/download/apps_v1.69.0/oxlint-x86_64-unknown-linux-gnu.tar.gz" ]
}

@test "pins_url: opencode" {
  [ "$(pins_url OPENCODE 1.17.4)" = "https://github.com/anomalyco/opencode/releases/download/v1.17.4/opencode-linux-x64.tar.gz" ]
}

# --- pins.sh: shared assignment extractor -----------------------------------

@test "pins_grep_assignments: extracts a single pin value" {
  f="$(mktemp)"
  printf '          GITLEAKS_VERSION="8.30.1"\n' > "$f"
  [ "$(pins_grep_assignments GITLEAKS_VERSION "$f")" = "8.30.1" ]
  rm -f "$f"
}

@test "pins_grep_assignments: emits one line per match across files (file order)" {
  a="$(mktemp)"; b="$(mktemp)"
  printf 'OPENCODE_VERSION="1.0.0"\nOPENCODE_VERSION="1.0.0"\n' > "$a"
  printf 'OPENCODE_VERSION="1.0.0"\n' > "$b"
  run pins_grep_assignments OPENCODE_VERSION "$a" "$b"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "3" ]
  rm -f "$a" "$b"
}

@test "pins_grep_assignments: no match -> empty (no error)" {
  f="$(mktemp)"
  printf 'NOTHING_HERE=1\n' > "$f"
  run pins_grep_assignments GITLEAKS_VERSION "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$f"
}

# --- bump-pins.sh: pure read/edit helpers -----------------------------------

@test "bump_read_version / bump_read_sha: extract pinned values" {
  f="$(mktemp)"
  printf '          GITLEAKS_VERSION="8.30.1"\n          GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"\n' > "$f"
  [ "$(bump_read_version "$f" GITLEAKS)" = "8.30.1" ]
  [ "$(bump_read_sha "$f" GITLEAKS)" = "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ]
  rm -f "$f"
}

@test "bump_read_rules_ref: extracts the commit pin" {
  f="$(mktemp)"
  printf '          OPENGREP_RULES_REF="f1d2b562b414783763fd02a6ed2736eaed622efa"\n' > "$f"
  [ "$(bump_read_rules_ref "$f")" = "f1d2b562b414783763fd02a6ed2736eaed622efa" ]
  rm -f "$f"
}

@test "bump_edit_pin: rewrites BOTH version and sha lines" {
  f="$(mktemp)"
  printf '          GITLEAKS_VERSION="8.30.1"\n          GITLEAKS_SHA256="old"\n' > "$f"
  bump_edit_pin "$f" GITLEAKS 8.99.0 newsha123
  grep -q 'GITLEAKS_VERSION="8.99.0"' "$f"
  grep -q 'GITLEAKS_SHA256="newsha123"' "$f"
  rm -f "$f"
}

@test "bump_edit_pin: rewrites all occurrences (opencode multi-copy)" {
  f="$(mktemp)"
  printf 'OPENCODE_VERSION="1.0.0"\nOPENCODE_SHA256="a"\nOPENCODE_VERSION="1.0.0"\nOPENCODE_SHA256="a"\n' > "$f"
  bump_edit_pin "$f" OPENCODE 2.0.0 bbb
  [ "$(grep -c 'OPENCODE_VERSION="2.0.0"' "$f")" = "2" ]
  [ "$(grep -c 'OPENCODE_SHA256="bbb"' "$f")" = "2" ]
  rm -f "$f"
}

@test "bump_edit_pin: does not touch a different tool's pins" {
  f="$(mktemp)"
  printf 'GITLEAKS_VERSION="8.30.1"\nTRIVY_VERSION="0.71.0"\n' > "$f"
  bump_edit_pin "$f" GITLEAKS 8.99.0 sha
  grep -q 'TRIVY_VERSION="0.71.0"' "$f"
  rm -f "$f"
}

@test "bump_edit_rules_ref: rewrites the commit pin" {
  f="$(mktemp)"
  printf '          OPENGREP_RULES_REF="aaa"\n' > "$f"
  bump_edit_rules_ref "$f" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  grep -q 'OPENGREP_RULES_REF="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$f"
  rm -f "$f"
}

@test "bump_branch_token: sanitizes to branch-safe chars" {
  [ "$(bump_branch_token apps_v1.69.0)" = "apps_v1.69.0" ]
  [ "$(bump_branch_token v0.11.0)" = "v0.11.0" ]
  [ "$(bump_branch_token 'weird/ver sion')" = "weird-ver-sion" ]
}
