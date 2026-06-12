#!/usr/bin/env bash
# Pure, side-effect-free helpers for per-repo scope configuration.
# No network, no GitHub API calls — only deterministic bash/jq transforms so
# they can be unit-tested with bats. Workflows source this file; CI runs
# tests/scope.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - Dependency note: context.sh does NOT source this file. When the context
#   job needs scope functions, the workflow sources both scope.sh and
#   context.sh independently, then calls context_build_map with an optional
#   patterns-file argument.

# Parse .ai-review.yml content from stdin.
# Emits KEY=VALUE lines to stdout:
#   valid=true|false
#   max_changed_files=N      (only when present and numeric)
#   max_diff_lines=N         (only when present and numeric)
#   ignore=<pattern>         (zero or more lines, one per list item)
#
# Rules:
# - Empty/absent file (empty stdin) -> valid=true with no other keys (use defaults).
# - Non-empty file must have "version: 1" to be valid. Missing version on a
#   non-empty file -> valid=false (fail-open happens in the caller).
# - Unknown keys are ignored (forward-compat).
# - Any key that looks syntactically wrong (value unparseable) -> valid=false.
# - Comments (#...) and blank lines are tolerated.
# - ignore: list items may be:  - "pat"  or  - pat  (with optional leading spaces)
#
# Usage: scope_parse_config < /path/to/.ai-review.yml
scope_parse_config() {
  local raw
  raw="$(cat)"

  # Empty input -> no config, use defaults.
  if ! printf '%s' "$raw" | grep -v '^[[:space:]]*#' | grep -qv '^[[:space:]]*$'; then
    printf 'valid=true\n'
    return 0
  fi

  # Check version field. It must be exactly "1".
  local version
  version="$(printf '%s\n' "$raw" | grep -E '^[[:space:]]*version[[:space:]]*:' | head -1 | sed 's/^[[:space:]]*version[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
  if [ "$version" != "1" ]; then
    printf 'valid=false\n'
    return 0
  fi

  # Parse max_changed_files (optional integer).
  local max_files
  max_files="$(printf '%s\n' "$raw" | grep -E '^[[:space:]]*max_changed_files[[:space:]]*:' | head -1 | sed 's/^[[:space:]]*max_changed_files[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
  if [ -n "$max_files" ]; then
    if ! printf '%s' "$max_files" | grep -qE '^[0-9]+$'; then
      printf 'valid=false\n'
      return 0
    fi
  fi

  # Parse max_diff_lines (optional integer).
  local max_lines
  max_lines="$(printf '%s\n' "$raw" | grep -E '^[[:space:]]*max_diff_lines[[:space:]]*:' | head -1 | sed 's/^[[:space:]]*max_diff_lines[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')"
  if [ -n "$max_lines" ]; then
    if ! printf '%s' "$max_lines" | grep -qE '^[0-9]+$'; then
      printf 'valid=false\n'
      return 0
    fi
  fi

  # Parse ignore list. Lines following "ignore:" that match list-item patterns.
  # Collect them: items are lines matching /^\s*-\s+/ after stripping quotes.
  local in_ignore=0
  local pat line
  while IFS= read -r line; do
    # Skip blank lines and comments.
    case "$line" in
      ''|'#'*) in_ignore=0; continue ;;
    esac
    # Strip trailing comments (# not inside quotes is unlikely in paths, but safe).
    # Detect the "ignore:" key.
    if printf '%s' "$line" | grep -qE '^[[:space:]]*ignore[[:space:]]*:'; then
      in_ignore=1
      continue
    fi
    # Another top-level key ends the ignore block.
    if printf '%s' "$line" | grep -qE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:'; then
      in_ignore=0
      continue
    fi
    if [ "$in_ignore" = "1" ]; then
      # List item: "  - pattern"  or  '  - "pattern"'
      if printf '%s' "$line" | grep -qE '^[[:space:]]*-[[:space:]]+'; then
        pat="$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")"
        if [ -n "$pat" ]; then
          printf 'ignore=%s\n' "$pat"
        fi
      fi
    fi
  done <<< "$raw"

  printf 'valid=true\n'
  if [ -n "$max_files" ]; then printf 'max_changed_files=%s\n' "$max_files"; fi
  if [ -n "$max_lines" ]; then printf 'max_diff_lines=%s\n' "$max_lines"; fi
  return 0
}

# Print the 6 built-in generated/lockfile patterns, one per line.
# These are the same patterns that context_build_map skips.
#
# Usage: scope_builtin_ignores
scope_builtin_ignores() {
  printf '*.lock\n'
  printf '*.sum\n'
  printf '*-lock.json\n'
  printf '*.min.*\n'
  printf '*.svg\n'
  printf '*.map\n'
}

# Test whether a file path matches any pattern in a patterns file.
# Returns 0 if a match is found, 1 if no match.
#
# Pattern semantics (bash `case` / fnmatch WITHOUT FNM_PATHNAME):
#   - `*` matches any sequence of characters INCLUDING `/`.
#   - `dist/**` is translated to `dist/*` (double-star reduced to single).
#   - `**/*.ext` is translated to `*.ext` (leading glob).
#   - A pattern without `/` (e.g. `*.lock`) is matched against both the full
#     path AND the basename, so it catches the pattern at any depth.
#   - A pattern WITH a leading component (e.g. `dist/*`) is matched against the
#     full path only.
# These semantics are documented here because they are tested in scope.bats.
#
# Usage: scope_match <path> <patterns-file>
scope_match() {
  local filepath="$1" patterns_file="$2"
  local pat translated basename_path
  basename_path="$(basename "$filepath")"

  while IFS= read -r pat || [ -n "$pat" ]; do
    [ -n "$pat" ] || continue
    # Translate gitignore-style double-stars for bash case matching:
    #   dist/**   -> dist/*
    #   **/foo    -> foo  (or */foo, but we also try basename)
    #   **/*.ext  -> *.ext
    translated="$(printf '%s' "$pat" | sed 's|\*\*|*|g')"

    # If the (translated) pattern contains a `/`, match only against full path.
    if printf '%s' "$translated" | grep -q '/'; then
      # shellcheck disable=SC2254  # intentional glob expansion in case pattern
      case "$filepath" in
        $translated) return 0 ;;
      esac
    else
      # No slash: match against both full path and basename.
      # shellcheck disable=SC2254  # intentional glob expansion in case pattern
      case "$filepath" in
        $translated) return 0 ;;
      esac
      # shellcheck disable=SC2254  # intentional glob expansion in case pattern
      case "$basename_path" in
        $translated) return 0 ;;
      esac
    fi
  done < "$patterns_file"

  return 1
}

# Compute filtered file and line counts, excluding files matching patterns.
# stdin: JSON array of GitHub API PR files objects:
#   [{"filename": "...", "additions": N, "deletions": N}, ...]
# stdout: two lines:
#   files=N
#   lines=M
#
# Usage: scope_filtered_counts <patterns-file>
scope_filtered_counts() {
  local patterns_file="$1"
  local tmpfile
  tmpfile="$(mktemp /tmp/scope-files.XXXXXX)"
  # Extract filename<TAB>adds+dels using jq.
  jq -r '.[] | "\(.filename)\t\(.additions + .deletions)"' > "$tmpfile"

  local files=0 lines=0
  local fname delta
  while IFS=$'\t' read -r fname delta; do
    if ! scope_match "$fname" "$patterns_file"; then
      files=$((files + 1))
      lines=$((lines + delta))
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"
  printf 'files=%d\n' "$files"
  printf 'lines=%d\n' "$lines"
}

# Print ripgrep --glob exclusion arguments for patterns in a patterns file.
# Prints one argument per line (suitable for safe array construction):
#   --glob
#   !<pattern>
#
# Usage: scope_rg_globs <patterns-file>
scope_rg_globs() {
  local patterns_file="$1"
  local pat
  while IFS= read -r pat || [ -n "$pat" ]; do
    [ -n "$pat" ] || continue
    printf -- '--glob\n'
    printf '!%s\n' "$pat"
  done < "$patterns_file"
}

# Print git pathspec exclusion arguments for patterns in a patterns file.
# Prints one :(exclude)<pattern> per line.
#
# Usage: scope_exclude_pathspecs <patterns-file>
scope_exclude_pathspecs() {
  local patterns_file="$1"
  local pat
  while IFS= read -r pat || [ -n "$pat" ]; do
    [ -n "$pat" ] || continue
    printf ':(exclude)%s\n' "$pat"
  done < "$patterns_file"
}

# Filter a findings.json array from stdin, applying ignore patterns.
# Drops findings whose .file matches any pattern UNLESS .severity == "HIGH",
# in which case the finding is kept and gains "ignoredPath": true.
# Findings outside ignored paths are passed through unchanged.
#
# stdin: JSON array of finding objects (as produced by sarif_merge).
# stdout: filtered JSON array.
#
# Usage: scope_filter_findings <patterns-file>
scope_filter_findings() {
  local patterns_file="$1"
  local tmpfile
  tmpfile="$(mktemp /tmp/scope-findings.XXXXXX)"

  # Read all findings into a temp file.
  cat > "$tmpfile"

  # Build a jq-consumable patterns array for the ignored-path test.
  # We use shell iteration + jq to tag each finding.
  local total
  total="$(jq 'length' "$tmpfile")"

  local output='[]'
  local i=0
  while [ "$i" -lt "$total" ]; do
    local finding file severity
    finding="$(jq ".[$i]" "$tmpfile")"
    file="$(jq -r '.file // ""' <<< "$finding")"
    severity="$(jq -r '.severity // ""' <<< "$finding")"

    if [ -n "$file" ] && scope_match "$file" "$patterns_file"; then
      # Ignored path.
      if [ "$severity" = "HIGH" ]; then
        # Keep + annotate.
        finding="$(jq '. + {"ignoredPath": true}' <<< "$finding")"
        output="$(jq --argjson f "$finding" '. + [$f]' <<< "$output")"
      fi
      # Otherwise drop.
    else
      # Not an ignored path — keep as-is.
      output="$(jq --argjson f "$finding" '. + [$f]' <<< "$output")"
    fi
    i=$((i + 1))
  done

  rm -f "$tmpfile"
  printf '%s\n' "$output"
}
