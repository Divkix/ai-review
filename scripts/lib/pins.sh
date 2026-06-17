#!/usr/bin/env bash
# Single source of truth for every pinned tool/binary the workflows install.
# Pure, side-effect-free descriptor table + accessors so BOTH the pin checker
# (scripts/check-pins.sh) and the pin bumper (scripts/bump-pins.sh) read the
# same data — no copy drift. CI runs tests/pins.bats against it.
#
# Conventions:
# - Functions read inputs from args and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - No network. Most accessors are pure string transforms over the descriptor
#   table; pins_grep_assignments additionally reads the workflow file(s) to
#   extract currently-pinned values (shared by the checker and the bumper).
#
# Descriptor row format (one per tool), `|`-delimited (URLs/files contain no `|`):
#   TOOL|REPO|VERSION_RULE|TAG_SELECT|URL_TEMPLATE|FILES|KIND
#
#   TOOL          pin prefix, matches the `${TOOL}_VERSION`/`${TOOL}_SHA256`
#                 shell vars in the workflows (e.g. OSV_SCANNER, GOLANGCI).
#   REPO          GitHub owner/name the releases come from.
#   VERSION_RULE  how to turn a release tag into the stored VERSION string:
#                   strip-v   -> drop a leading "v" (tag v1.2.3 -> 1.2.3)
#                   verbatim  -> keep the tag exactly (v0.11.0, apps_v1.69.0,
#                               or a bare 0.43.0 stay as-is)
#   TAG_SELECT    when non-empty, only release tags starting with this prefix
#                 are considered (oxc publishes many crate tags; we want apps_v).
#                 Empty -> use the repo's "latest" release.
#   URL_TEMPLATE  asset download URL; `${ver}` is substituted with the stored
#                 VERSION string. Copied verbatim from the workflow install steps.
#   FILES         space-separated workflow files (repo-root relative) that hold
#                 the pin. opencode lives in two files (3 copies total).
#   KIND          scanner | opencode | rules
#                   scanner -> a sha256-pinned binary checked in the TOOLS loop
#                   opencode-> sha256-pinned binary spanning 2 files (special-cased)
#                   rules   -> a git commit ref (no sha256, no release asset)

# Emit the raw descriptor table, one row per tool. Internal helper.
_pins_data() {
  cat <<'PINS_EOF'
OPENGREP|opengrep/opengrep|strip-v||https://github.com/opengrep/opengrep/releases/download/v${ver}/opengrep_manylinux_x86|.github/workflows/review.yml|scanner
GITLEAKS|gitleaks/gitleaks|strip-v||https://github.com/gitleaks/gitleaks/releases/download/v${ver}/gitleaks_${ver}_linux_x64.tar.gz|.github/workflows/review.yml|scanner
OSV_SCANNER|google/osv-scanner|strip-v||https://github.com/google/osv-scanner/releases/download/v${ver}/osv-scanner_linux_amd64|.github/workflows/review.yml|scanner
RIPGREP|BurntSushi/ripgrep|verbatim||https://github.com/BurntSushi/ripgrep/releases/download/${ver}/ripgrep-${ver}-x86_64-unknown-linux-musl.tar.gz|.github/workflows/review.yml|scanner
RUFF|astral-sh/ruff|verbatim||https://github.com/astral-sh/ruff/releases/download/${ver}/ruff-x86_64-unknown-linux-gnu.tar.gz|.github/workflows/review.yml|scanner
GOLANGCI|golangci/golangci-lint|strip-v||https://github.com/golangci/golangci-lint/releases/download/v${ver}/golangci-lint-${ver}-linux-amd64.tar.gz|.github/workflows/review.yml|scanner
OXLINT|oxc-project/oxc|verbatim|apps_v|https://github.com/oxc-project/oxc/releases/download/${ver}/oxlint-x86_64-unknown-linux-gnu.tar.gz|.github/workflows/review.yml|scanner
SHELLCHECK|koalaman/shellcheck|verbatim||https://github.com/koalaman/shellcheck/releases/download/${ver}/shellcheck-${ver}.linux.x86_64.tar.xz|.github/workflows/review.yml|scanner
HADOLINT|hadolint/hadolint|verbatim||https://github.com/hadolint/hadolint/releases/download/${ver}/hadolint-linux-x86_64|.github/workflows/review.yml|scanner
ACTIONLINT|rhysd/actionlint|strip-v||https://github.com/rhysd/actionlint/releases/download/v${ver}/actionlint_${ver}_linux_amd64.tar.gz|.github/workflows/review.yml|scanner
ZIZMOR|zizmorcore/zizmor|verbatim||https://github.com/zizmorcore/zizmor/releases/download/${ver}/zizmor-x86_64-unknown-linux-gnu.tar.gz|.github/workflows/review.yml|scanner
TRIVY|aquasecurity/trivy|strip-v||https://github.com/aquasecurity/trivy/releases/download/v${ver}/trivy_${ver}_Linux-64bit.tar.gz|.github/workflows/review.yml|scanner
TYPOS|crate-ci/typos|verbatim||https://github.com/crate-ci/typos/releases/download/${ver}/typos-${ver}-x86_64-unknown-linux-musl.tar.gz|.github/workflows/review.yml|scanner
ASTGREP|ast-grep/ast-grep|verbatim||https://github.com/ast-grep/ast-grep/releases/download/${ver}/app-x86_64-unknown-linux-gnu.zip|.github/workflows/review.yml|scanner
OPENCODE|anomalyco/opencode|strip-v||https://github.com/anomalyco/opencode/releases/download/v${ver}/opencode-linux-x64.tar.gz|.github/workflows/review.yml .github/workflows/commands.yml|opencode
OPENGREP_RULES|opengrep/opengrep-rules|verbatim|||.github/workflows/review.yml|rules
PINS_EOF
}

# Print the descriptor row for a tool (or nothing if unknown).
# Usage: _pins_row <tool>
_pins_row() {
  local tool="$1"
  _pins_data | awk -F'|' -v t="$tool" '$1 == t { print; exit }'
}

# Print one field of a tool's descriptor row by 1-based index.
# Usage: _pins_field <tool> <index>
_pins_field() {
  local tool="$1" idx="$2"
  _pins_row "$tool" | awk -F'|' -v i="$idx" '{ print $i }'
}

# --- Public accessors -------------------------------------------------------

# All tool keys (scanners + opencode + rules), one per line, table order.
# Usage: pins_all
pins_all() { _pins_data | awk -F'|' '{ print $1 }'; }

# Just the sha256-pinned scanner binaries (KIND==scanner), one per line.
# This matches the set check-pins.sh iterates in its TOOLS loop.
# Usage: pins_scanners
pins_scanners() { _pins_data | awk -F'|' '$7 == "scanner" { print $1 }'; }

# Every bumpable target (scanners + opencode + rules), one per line.
# The bump workflow builds its matrix from this.
# Usage: pins_bump_targets
pins_bump_targets() { pins_all; }

# Accessors for individual descriptor fields.
pins_repo()         { _pins_field "$1" 2; }
pins_version_rule() { _pins_field "$1" 3; }
pins_tag_select()   { _pins_field "$1" 4; }
pins_files()        { _pins_field "$1" 6; }
pins_kind()         { _pins_field "$1" 7; }

# Build the asset download URL for a tool at a given VERSION string.
# Substitutes the literal `${ver}` placeholder in the URL template.
# Usage: pins_url <tool> <ver>
pins_url() {
  local tool="$1" ver="$2" tmpl
  tmpl="$(_pins_field "$tool" 5)"
  # Replace the literal placeholder ${ver} in the template with the value.
  # shellcheck disable=SC2016  # '${ver}' is an intentional literal match target
  printf '%s\n' "${tmpl//'${ver}'/$ver}"
}

# Convert a GitHub release tag into the VERSION string the workflow stores,
# per the tool's VERSION_RULE. Unknown tool -> echoes the tag unchanged.
# Usage: pins_tag_to_version <tool> <tag>
pins_tag_to_version() {
  local tool="$1" tag="$2" rule
  rule="$(pins_version_rule "$tool")"
  case "$rule" in
    strip-v) printf '%s\n' "${tag#v}" ;;
    *)       printf '%s\n' "$tag" ;;
  esac
}

# Extract the value(s) of a pinned `NAME="value"` assignment from one or more
# files. This is the one place that knows the pin line format, so the checker
# (which asserts distinct-value counts via sort -u) and the bumper (which takes
# head -1) share it. Emits every match, one per line, in file order; empty if
# none. Usage: pins_grep_assignments <name> <file> [file...]
pins_grep_assignments() {
  local name="$1"; shift
  # `|| true`: a no-match is a legitimate empty result, not an error — keep the
  # helper composable under callers' `set -o pipefail` (per AGENTS.md).
  grep -hoE "${name}=\"[^\"]+\"" "$@" 2>/dev/null \
    | sed -E 's/.*="([^"]+)"/\1/' || true
}

# Emit a JSON array of every bump target (for a workflow matrix).
# Usage: pins_bump_matrix_json
pins_bump_matrix_json() {
  pins_bump_targets \
    | awk 'BEGIN { printf "[" }
           { printf "%s\"%s\"", (NR>1 ? "," : ""), $0 }
           END { print "]" }'
}
