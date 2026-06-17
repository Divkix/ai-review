#!/usr/bin/env bash
# Pin bumper: for ONE tool, check whether a newer version/commit exists and, if
# so, rewrite the pin (version + sha256, or the rules commit ref) in place.
# Used by .github/workflows/bump-pins.yml; the workflow opens the PR.
#
# The new sha256 is computed from the ACTUAL downloaded asset, so the edited
# pin is correct by construction — the resulting PR passes scripts/check-pins.sh
# rather than failing it the way a version-only bump would.
#
# Usage: scripts/bump-pins.sh <TOOL>
#   <TOOL> is a key from `pins_all` (e.g. GITLEAKS, OPENCODE, OPENGREP_RULES).
#
# Reads the latest release/commit via `gh api` (requires GH_TOKEN in CI).
# Emits a result block to stdout AND, when set, to $GITHUB_OUTPUT:
#   changed=true|false
#   tool=<TOOL>
#   old=<old version-or-ref>
#   new=<new version-or-ref>
#   branch=<suggested branch name>      (only when changed)
#   title=<suggested PR title>          (only when changed)
# Exit 0 on success (no-op or applied); non-zero only on hard errors.
set -euo pipefail

_BUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib/pins.sh
. "${_BUMP_DIR}/scripts/lib/pins.sh"

# --- Pure helpers (unit-tested by tests/pins.bats) --------------------------

# Read the pinned VERSION string for a tool from a workflow file (first match).
# Extraction lives in pins.sh so the checker and bumper share one pin format.
# Usage: bump_read_version <file> <tool>
bump_read_version() {
  pins_grep_assignments "${2}_VERSION" "$1" | head -1
}

# Read the pinned SHA256 string for a tool from a workflow file (first match).
# Usage: bump_read_sha <file> <tool>
bump_read_sha() {
  pins_grep_assignments "${2}_SHA256" "$1" | head -1
}

# Read the pinned OPENGREP_RULES_REF commit from a workflow file (first match).
# Usage: bump_read_rules_ref <file>
bump_read_rules_ref() {
  pins_grep_assignments OPENGREP_RULES_REF "$1" | head -1
}

# Rewrite both the VERSION and SHA256 pins for a tool in one file (portable
# sed; no in-place -i so it works on GNU and BSD sed alike).
# Usage: bump_edit_pin <file> <tool> <new_version> <new_sha>
bump_edit_pin() {
  local file="$1" tool="$2" newver="$3" newsha="$4" tmp
  tmp="$(mktemp)"
  sed -E \
    -e "s|(${tool}_VERSION=\")[^\"]*(\")|\1${newver}\2|g" \
    -e "s|(${tool}_SHA256=\")[^\"]*(\")|\1${newsha}\2|g" \
    "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Rewrite the OPENGREP_RULES_REF commit pin in one file.
# Usage: bump_edit_rules_ref <file> <new_ref>
bump_edit_rules_ref() {
  local file="$1" newref="$2" tmp
  tmp="$(mktemp)"
  sed -E "s|(OPENGREP_RULES_REF=\")[^\"]*(\")|\1${newref}\2|g" "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Sanitize a version/ref into a branch-name-safe token.
# Usage: bump_branch_token <string>
bump_branch_token() {
  printf '%s\n' "$1" | tr -c 'A-Za-z0-9._' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

# --- Network helpers (require gh + GH_TOKEN) --------------------------------

# Resolve the newest non-prerelease release tag for a tool, honoring its
# TAG_SELECT prefix. Usage: bump_latest_tag <tool>
bump_latest_tag() {
  local tool="$1" repo sel
  repo="$(pins_repo "$tool")"
  sel="$(pins_tag_select "$tool")"
  if [ -z "$sel" ]; then
    # Conventional latest release (already excludes drafts/prereleases).
    gh api "repos/${repo}/releases/latest" --jq '.tag_name'
  else
    # Filter to non-prerelease tags starting with the select prefix; the API
    # returns releases newest-first, so the first match is the latest.
    gh api "repos/${repo}/releases" --paginate \
      --jq "[.[] | select(.prerelease == false) | .tag_name | select(startswith(\"${sel}\"))][0] // empty"
  fi
}

# Resolve the latest commit sha on a repo's default branch.
# Usage: bump_latest_commit <repo>
bump_latest_commit() {
  local repo="$1"
  gh api "repos/${repo}/commits/HEAD" --jq '.sha'
}

# --- Result emission --------------------------------------------------------

emit() {
  printf '%s\n' "$@"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
  fi
}

# --- Main -------------------------------------------------------------------

main() {
  local tool="${1:-}"
  if [ -z "$tool" ]; then
    echo "usage: scripts/bump-pins.sh <TOOL>" >&2
    exit 2
  fi
  # Resolve pins_files (repo-root-relative paths) from the repo root.
  cd "$_BUMP_DIR"
  local kind
  kind="$(pins_kind "$tool")"
  if [ -z "$kind" ]; then
    echo "::error::unknown tool '$tool' (not in scripts/lib/pins.sh)" >&2
    exit 2
  fi

  # shellcheck disable=SC2207
  local files=($(pins_files "$tool"))
  local first_file="${files[0]}"

  if [ "$kind" = "rules" ]; then
    # --- Commit-ref pin (opengrep-rules) ---
    local repo old new
    repo="$(pins_repo "$tool")"
    old="$(bump_read_rules_ref "$first_file")"
    new="$(bump_latest_commit "$repo")"
    if [ -z "$new" ]; then
      echo "::error::could not resolve latest commit for $repo" >&2
      exit 1
    fi
    if [ "$new" = "$old" ]; then
      emit "changed=false" "tool=$tool" "old=$old" "new=$new"
      echo "Already up to date: $tool @ ${old:0:12}"
      return 0
    fi
    local f
    for f in "${files[@]}"; do bump_edit_rules_ref "$f" "$new"; done
    emit "changed=true" "tool=$tool" "old=$old" "new=$new" \
      "branch=chore/bump-opengrep-rules-$(bump_branch_token "${new:0:12}")" \
      "title=chore: bump opengrep-rules to ${new:0:12}"
    echo "Bumped $tool: ${old:0:12} -> ${new:0:12}"
    return 0
  fi

  # --- Version + sha256 binary pin (scanner / opencode) ---
  local old_ver tag new_ver url tmp new_sha
  old_ver="$(bump_read_version "$first_file" "$tool")"
  if [ -z "$old_ver" ]; then
    echo "::error::no ${tool}_VERSION pin found in $first_file" >&2
    exit 1
  fi
  tag="$(bump_latest_tag "$tool")"
  if [ -z "$tag" ]; then
    echo "::error::could not resolve latest release tag for $tool" >&2
    exit 1
  fi
  new_ver="$(pins_tag_to_version "$tool" "$tag")"
  if [ "$new_ver" = "$old_ver" ]; then
    emit "changed=false" "tool=$tool" "old=$old_ver" "new=$new_ver"
    echo "Already up to date: $tool @ $old_ver"
    return 0
  fi

  url="$(pins_url "$tool" "$new_ver")"
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  echo "Fetching $url"
  if ! curl -fsSL -o "$tmp" "$url"; then
    echo "::error::failed to download $tool asset for $new_ver ($url)" >&2
    exit 1
  fi
  new_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"

  local f slug
  slug="$(printf '%s' "$tool" | tr 'A-Z_' 'a-z-')"
  for f in "${files[@]}"; do bump_edit_pin "$f" "$tool" "$new_ver" "$new_sha"; done
  emit "changed=true" "tool=$tool" "old=$old_ver" "new=$new_ver" \
    "branch=chore/bump-${slug}-$(bump_branch_token "$new_ver")" \
    "title=chore: bump $slug to $new_ver"
  echo "Bumped $tool: $old_ver -> $new_ver (sha ${new_sha:0:12}…)"
}

# Only run main when executed directly; allow `source`ing for unit tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
