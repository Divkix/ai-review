#!/usr/bin/env bash
# Pure, side-effect-free helpers for merging SARIF findings. No network, no
# GitHub API calls — only deterministic bash/jq transforms so they can be unit
# tested with bats. The workflows `source` this file (single source of truth);
# CI runs tests/sarif.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.

# Clamp a severity value to at most max_severity.
# Severity ordering: HIGH > MEDIUM > LOW.
# Returns the clamped severity on stdout.
#
# Usage: _sarif_clamp_severity <severity> <max_severity>
_sarif_clamp_severity() {
  local sev="$1" cap="$2"
  # Convert to numeric rank: HIGH=3, MEDIUM=2, LOW=1
  local sev_rank cap_rank
  case "$sev" in
    HIGH)   sev_rank=3 ;;
    MEDIUM) sev_rank=2 ;;
    *)      sev_rank=1 ;;  # LOW or unknown
  esac
  case "$cap" in
    HIGH)   cap_rank=3 ;;
    MEDIUM) cap_rank=2 ;;
    *)      cap_rank=1 ;;  # LOW or unknown
  esac
  if [ "$sev_rank" -le "$cap_rank" ]; then
    printf '%s' "$sev"
  else
    # Clamp to cap.
    printf '%s' "$cap"
  fi
}

# Merge one SARIF file into a JSON array of normalised findings.
# Returns 0 silently when $file does not exist.
#
# Usage: sarif_merge_one <tool> <file> [max_severity]
# When max_severity is set (HIGH|MEDIUM|LOW), clamp every finding's severity
# to at most that level (min(natural_severity, max_severity)).
# Prints a JSON array of finding objects to stdout.
sarif_merge_one() {
  local tool="$1" file="$2" max_severity="${3:-}"
  [ -f "$file" ] || return 0
  local raw
  raw="$(jq --arg tool "$tool" '
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
    }]' "$file")"

  if [ -z "$max_severity" ]; then
    printf '%s\n' "$raw"
    return 0
  fi

  # Apply severity cap to each finding.
  local count i clamped result='[]'
  count="$(jq 'length' <<< "$raw")"
  i=0
  while [ "$i" -lt "$count" ]; do
    local finding sev
    finding="$(jq ".[$i]" <<< "$raw")"
    sev="$(jq -r '.severity' <<< "$finding")"
    clamped="$(_sarif_clamp_severity "$sev" "$max_severity")"
    finding="$(jq --arg s "$clamped" '. + {severity: $s}' <<< "$finding")"
    result="$(jq --argjson f "$finding" '. + [$f]' <<< "$result")"
    i=$((i + 1))
  done
  printf '%s\n' "$result"
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

# Convert shellcheck --format=json1 output into the same normalised findings
# array shape as sarif_merge_one.
#
# Input json1 shape:
#   {"comments":[{"file":"...","line":1,"endLine":2,"column":1,"endColumn":5,
#                 "level":"error","code":2086,"message":"..."},...]}
#
# Output shape per finding:
#   {"tool":"shellcheck","ruleId":"SC2086","file":"...","startLine":1,
#    "endLine":2,"message":"...","severity":"HIGH"}
#
# Level->severity mapping:
#   error   -> HIGH
#   warning -> MEDIUM
#   info    -> LOW
#   style   -> LOW
#
# Usage: findings_from_shellcheck <file> [max_severity]
# If file is missing/not found -> output [] and return 0.
findings_from_shellcheck() {
  local file="$1" max_severity="${2:-}"
  if [ ! -f "$file" ]; then
    printf '[]\n'
    return 0
  fi

  local raw
  raw="$(jq '
    [.comments[]? | {
      tool: "shellcheck",
      ruleId: ("SC" + (.code | tostring)),
      file: .file,
      startLine: .line,
      endLine: .endLine,
      message: .message,
      severity: (
        if .level == "error"     then "HIGH"
        elif .level == "warning" then "MEDIUM"
        elif .level == "info"    then "LOW"
        elif .level == "style"   then "LOW"
        else "MEDIUM"
        end)
    }]' "$file")"

  if [ -z "$max_severity" ]; then
    printf '%s\n' "$raw"
    return 0
  fi

  # Apply severity cap to each finding.
  local count i clamped result='[]'
  count="$(jq 'length' <<< "$raw")"
  i=0
  while [ "$i" -lt "$count" ]; do
    local finding sev
    finding="$(jq ".[$i]" <<< "$raw")"
    sev="$(jq -r '.severity' <<< "$finding")"
    clamped="$(_sarif_clamp_severity "$sev" "$max_severity")"
    finding="$(jq --arg s "$clamped" '. + {severity: $s}' <<< "$finding")"
    result="$(jq --argjson f "$finding" '. + [$f]' <<< "$result")"
    i=$((i + 1))
  done
  printf '%s\n' "$result"
}
