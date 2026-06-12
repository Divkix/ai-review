#!/usr/bin/env bash
# Pure, side-effect-free helpers for merging SARIF findings. No network, no
# GitHub API calls — only deterministic bash/jq transforms so they can be unit
# tested with bats. The workflows `source` this file (single source of truth);
# CI runs tests/sarif.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.

# Merge one SARIF file into a JSON array of normalised findings.
# Returns 0 silently when $file does not exist.
#
# Usage: sarif_merge_one <tool> <file>
# Prints a JSON array of finding objects to stdout.
sarif_merge_one() {
  local tool="$1" file="$2"
  [ -f "$file" ] || return 0
  jq --arg tool "$tool" '
    [.runs[]?.results[]? | {
      tool: $tool,
      ruleId: (.ruleId // "unknown"),
      file: (.locations[0].physicalLocation.artifactLocation.uri // ""),
      startLine: (.locations[0].physicalLocation.region.startLine // 0),
      endLine: (.locations[0].physicalLocation.region.endLine
                // .locations[0].physicalLocation.region.startLine // 0),
      message: (.message.text // ""),
      severity: (
        if .level == "error" then "HIGH"
        elif .level == "warning" then "MEDIUM"
        elif .level == "note" then "LOW"
        elif $tool == "osv" then "HIGH"
        elif $tool == "gitleaks" then "HIGH"
        else "MEDIUM"
        end)
    }]' "$file"
}

# Merge multiple SARIF files into a single JSON array.
# Arguments are "tool:file" pairs (colon-separated).
# Missing files contribute nothing; the result is always a valid array.
#
# Usage: sarif_merge <tool:file>...
# Prints the merged JSON array to stdout.
sarif_merge() {
  local pair tool file
  {
    for pair in "$@"; do
      tool="${pair%%:*}"
      file="${pair#*:}"
      sarif_merge_one "$tool" "$file"
    done
  } | jq -s 'add // []'
}
