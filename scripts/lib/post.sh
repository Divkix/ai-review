#!/usr/bin/env bash
# Pure, side-effect-free helpers for deterministic PR review posting.
# No network, no GitHub API calls — only deterministic bash/jq/awk transforms
# so they can be unit-tested with bats. The workflows `source` this file
# (single source of truth); CI runs tests/post.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - Requires: bash, jq, awk, sha256sum.

# ---------------------------------------------------------------------------
# post_derive_verdict
# ---------------------------------------------------------------------------
# Derive the GitHub review verdict from verified.json on stdin.
# Prints "REQUEST_CHANGES" or "APPROVE".
#
# REQUEST_CHANGES iff:
#   - Any finding with severity=="blocker" AND confidence in {high,medium}; OR
#   - Any prior entry with status=="unfixed" AND (severity=="blocker" OR
#     severity is null/missing — conservative for legacy states).
#
# Usage: post_derive_verdict < verified.json
post_derive_verdict() {
  jq -r '
    # Budget-passing blockers: severity==blocker AND confidence high|medium
    ((.findings // []) | map(
      select(
        (.severity // "") == "blocker" and
        ((.confidence // "") == "high" or (.confidence // "") == "medium")
      )
    ) | length > 0) as $has_budget_blocker |

    # Unfixed prior blockers: status==unfixed AND (severity==blocker OR severity absent/null)
    ((.prior // []) | map(
      select(
        (.status // "") == "unfixed" and
        ((.severity == "blocker") or (.severity == null) or (has("severity") | not))
      )
    ) | length > 0) as $has_prior_blocker |

    if ($has_budget_blocker or $has_prior_blocker) then "REQUEST_CHANGES"
    else "APPROVE"
    end
  '
}

# ---------------------------------------------------------------------------
# post_select_budget
# ---------------------------------------------------------------------------
# Select inline vs minor findings from verified.json on stdin.
# Prints {"inline":[...],"minors":[...]} JSON to stdout.
#
# Inline: severity in {blocker,major} AND confidence in {high,medium} AND
#         has usable path (non-null, non-empty) AND has usable line (non-null).
#         Hard cap 10; ranked blocker>major, high>medium, path asc, line asc.
#         Overflow beyond 10 and all other findings go to minors.
#
# Usage: post_select_budget < verified.json
post_select_budget() {
  jq '
    def sev_rank: if . == "blocker" then 0 elif . == "major" then 1 else 2 end;
    def conf_rank: if . == "high" then 0 elif . == "medium" then 1 else 2 end;
    def is_inline_candidate:
      ((.severity // "") == "blocker" or (.severity // "") == "major") and
      ((.confidence // "") == "high" or (.confidence // "") == "medium") and
      ((.path // "") != "") and
      (.line != null);

    (.findings // []) as $all |

    # Candidates for inline: blocker|major, high|medium, usable path+line
    ($all | map(select(is_inline_candidate))) as $candidates |

    ($candidates | sort_by([
      (.severity | sev_rank),
      (.confidence | conf_rank),
      (.path // ""),
      (.line // 0)
    ])) as $sorted |

    ($sorted[0:10]) as $inline |
    ($sorted[10:]) as $overflow |

    # Everything else: non-candidates + overflow
    ($all | map(select(is_inline_candidate | not))) as $rest |

    {
      "inline": $inline,
      "minors": ($overflow + $rest)
    }
  '
}

# ---------------------------------------------------------------------------
# post_fingerprint
# ---------------------------------------------------------------------------
# Compute fingerprint for a finding without a rule_id.
# Prints the first 12 lowercase hex chars of sha256("<path>:<body>")
# (no trailing newline in the hashed string).
#
# Usage: post_fingerprint <path> <body>
post_fingerprint() {
  local path="$1" body="$2"
  printf '%s:%s' "$path" "$body" | sha256sum | awk '{print substr($1,1,12)}'
}

# ---------------------------------------------------------------------------
# post_finding_fingerprints
# ---------------------------------------------------------------------------
# Add "fingerprint" to each finding in a JSON array on stdin.
# rule_id (non-null, non-empty) is used as the fingerprint; otherwise
# first 12 hex chars of sha256("<path>:<body>").
#
# Usage: post_finding_fingerprints < findings.json
post_finding_fingerprints() {
  local input
  input="$(cat)"
  local length
  length="$(jq 'length' <<<"$input")" || return 1
  [ "$length" -ge 0 ] 2>/dev/null || return 1
  local result='[]'
  local i=0
  while [ "$i" -lt "$length" ]; do
    local finding rule_id path body fp
    finding="$(jq ".[$i]" <<<"$input")"
    rule_id="$(jq -r '.rule_id // ""' <<<"$finding")"
    if [ -n "$rule_id" ]; then
      fp="$rule_id"
    else
      path="$(jq -r '.path // ""' <<<"$finding")"
      body="$(jq -r '.body // ""' <<<"$finding")"
      fp="$(post_fingerprint "$path" "$body")"
    fi
    finding="$(jq --arg fp "$fp" '. + {"fingerprint": $fp}' <<<"$finding")"
    result="$(jq --argjson f "$finding" '. + [$f]' <<<"$result")"
    i=$((i + 1))
  done
  printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# post_validate_anchors
# ---------------------------------------------------------------------------
# Validate inline comment anchors against the unified diff.
# Args: <diff_file>
# Stdin: JSON array of inline comments
# Stdout: {"valid":[...],"demoted":[...]}
#
# A RIGHT-side anchor is valid iff its `line` appears as an added (+) or
# context line number on the NEW side of a hunk for the exact path.
# A LEFT-side anchor is valid iff its `line` is a deleted (-) line on the
# OLD side of a hunk for the exact path.
# Multi-line comments (end_line non-null) require the full range to be valid.
# Renamed files are anchored by their NEW path.
# Comments on absent paths or out-of-hunk lines are demoted.
# Limitation: paths containing whitespace or special characters (as produced by
# quoted git paths) are unsupported and will demote to the summary block.
#
# Usage: post_validate_anchors <diff_file> < comments.json
post_validate_anchors() {
  local diff_file="$1"
  local comments_json
  comments_json="$(cat)"

  # Build a lookup map using awk: parse the unified diff and emit lines like:
  #   <path> RIGHT <new_line_number>   (for + and context lines)
  #   <path> LEFT <old_line_number>    (for - and context lines, old side)
  # Output: path TAB side TAB line_number, one per valid anchor point.
  # Uses POSIX awk (no gawk extensions).
  local anchor_map
  anchor_map="$(awk '
    /^diff --git / {
      cur_new = ""
      cur_old = ""
      saw_rename_to = 0
      in_hunk = 0
    }
    /^rename to / {
      # Renamed file: use new path; strip "rename to " prefix
      cur_new = substr($0, 11)
      saw_rename_to = 1
    }
    /^\+\+\+ / {
      if (!saw_rename_to) {
        f = $2
        if (f == "/dev/null") {
          cur_new = ""
        } else {
          # Strip leading b/ prefix added by git diff
          if (substr(f, 1, 2) == "b/") f = substr(f, 3)
          cur_new = f
        }
      }
    }
    /^--- / {
      f = $2
      if (f == "/dev/null") {
        cur_old = ""
      } else {
        if (substr(f, 1, 2) == "a/") f = substr(f, 3)
        cur_old = f
      }
    }
    /^@@ / {
      # Parse hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
      # Use field splitting: $2 = "-old_start[,count]", $3 = "+new_start[,count]"
      old_part = $2
      new_part = $3
      # Strip leading - and +
      sub(/^-/, "", old_part)
      sub(/^\+/, "", new_part)
      # Take the part before the comma (the start line)
      sub(/,.*/, "", old_part)
      sub(/,.*/, "", new_part)
      old_line = old_part + 0
      new_line = new_part + 0
      in_hunk = 1
      next
    }
    in_hunk && /^\\ / { next }
    in_hunk && /^-/ {
      if (cur_old != "") print cur_old "\tLEFT\t" old_line
      old_line++
      next
    }
    in_hunk && /^\+/ {
      if (cur_new != "") print cur_new "\tRIGHT\t" new_line
      new_line++
      next
    }
    in_hunk && /^ / {
      if (cur_new != "") print cur_new "\tRIGHT\t" new_line
      if (cur_old != "") print cur_old "\tLEFT\t" old_line
      old_line++
      new_line++
      next
    }
    /^[^@ +-]/ { in_hunk = 0 }
  ' "$diff_file")"

  # Build a bash associative array from anchor_map for O(1) lookups
  declare -A anchor_set
  while IFS=$'\t' read -r path side linenum; do
    [ -n "$path" ] || continue
    anchor_set["${path}:${side}:${linenum}"]=1
  done <<<"$anchor_map"

  # Process each comment
  local length valid='[]' demoted='[]'
  length="$(jq 'length' <<<"$comments_json")" || return 1
  [ "$length" -ge 0 ] 2>/dev/null || return 1
  local i=0
  while [ "$i" -lt "$length" ]; do
    local comment path side start_line end_line is_valid
    comment="$(jq ".[$i]" <<<"$comments_json")"
    path="$(jq -r '.path // ""' <<<"$comment")"
    side="$(jq -r '.side // "RIGHT"' <<<"$comment")"
    start_line="$(jq -r '.line // ""' <<<"$comment")"
    end_line="$(jq -r '.end_line // ""' <<<"$comment")"

    is_valid=0
    if [ -n "$path" ] && [ -n "$start_line" ]; then
      if [ -z "$end_line" ] || [ "$end_line" = "null" ]; then
        # Single-line: check start_line only
        if [ -n "${anchor_set["${path}:${side}:${start_line}"]+x}" ]; then
          is_valid=1
        fi
      else
        # Multi-line: check all lines in range [start_line, end_line]
        # start_line must be <= end_line
        if [ "$start_line" -le "$end_line" ] 2>/dev/null; then
          is_valid=1
          local ln
          ln="$start_line"
          while [ "$ln" -le "$end_line" ]; do
            if [ -z "${anchor_set["${path}:${side}:${ln}"]+x}" ]; then
              is_valid=0
              break
            fi
            ln=$((ln + 1))
          done
        fi
      fi
    fi

    if [ "$is_valid" -eq 1 ]; then
      valid="$(jq --argjson c "$comment" '. + [$c]' <<<"$valid")"
    else
      demoted="$(jq --argjson c "$comment" '. + [$c]' <<<"$demoted")"
    fi
    i=$((i + 1))
  done

  jq -n --argjson valid "$valid" --argjson demoted "$demoted" \
    '{"valid": $valid, "demoted": $demoted}'
}

# ---------------------------------------------------------------------------
# post_compose_review
# ---------------------------------------------------------------------------
# Compose the GitHub review POST payload JSON.
# Args: <verdict>  (REQUEST_CHANGES | APPROVE | COMMENT)
# Stdin: {"walkthrough":..., "inline":[...], "minors":[...],
#         "dropped_static":[...], "rejected":[...]}
# Stdout: {"event":..., "body":..., "comments":[...]}
#
# Body = walkthrough
#   + optional <details><summary>Minor suggestions (N)</summary>... block
#   + optional "Dropped static findings" section
# Body and each comment body are hard-capped at 65000 chars with a
# "\n\n…[truncated]" suffix when exceeded.
#
# Usage: post_compose_review <verdict> < payload.json
post_compose_review() {
  local verdict="$1"
  local input
  input="$(cat)"
  # Fail loudly if stdin is not valid JSON (guards all downstream jq extracts)
  jq -e . <<<"$input" >/dev/null || return 1

  local walkthrough minors_json dropped_static_json inline_json
  walkthrough="$(jq -r '.walkthrough // ""' <<<"$input")"
  minors_json="$(jq -c '.minors // []' <<<"$input")"
  dropped_static_json="$(jq -c '.dropped_static // []' <<<"$input")"
  inline_json="$(jq -c '.inline // []' <<<"$input")"

  # Build the review body
  local body="$walkthrough"

  # Append minors section if non-empty
  local minors_count
  minors_count="$(jq 'length' <<<"$minors_json")" || return 1
  [ "$minors_count" -ge 0 ] 2>/dev/null || return 1
  if [ "$minors_count" -gt 0 ]; then
    local minors_section
    minors_section="$(jq -r '
      "\n\n<details><summary>Minor suggestions (\(length))</summary>\n\n" +
      (map("- `" + (.path // "?") + ":" + ((.line // 0) | tostring) + "` — " +
           ((.body // "") | split("\n")[0])) | join("\n")) +
      "\n\n</details>"
    ' <<<"$minors_json")"
    body="${body}${minors_section}"
  fi

  # Append dropped_static section if non-empty
  local dropped_count
  dropped_count="$(jq 'length' <<<"$dropped_static_json")" || return 1
  [ "$dropped_count" -ge 0 ] 2>/dev/null || return 1
  if [ "$dropped_count" -gt 0 ]; then
    local dropped_section
    dropped_section="$(jq -r '
      "\n\n<details><summary>Dropped static findings (\(length))</summary>\n\n" +
      (map("- **" + (.tool // "?") + "** `" + (.rule_id // "?") + "` in `" +
           (.path // "?") + "`: " + (.reason // "")) | join("\n")) +
      "\n\n</details>"
    ' <<<"$dropped_static_json")"
    body="${body}${dropped_section}"
  fi

  # Truncate body at 65000 chars
  local suffix=$'\n\n…[truncated]'
  local cap=65000
  local suffix_len=${#suffix}
  if [ ${#body} -gt $cap ]; then
    body="${body:0:$((cap - suffix_len))}${suffix}"
  fi

  # Build comments array with per-comment body cap
  local comments_json='[]'
  local inline_count
  inline_count="$(jq 'length' <<<"$inline_json")" || return 1
  [ "$inline_count" -ge 0 ] 2>/dev/null || return 1
  local j=0
  while [ "$j" -lt "$inline_count" ]; do
    local item path line end_line side cbody
    item="$(jq ".[$j]" <<<"$inline_json")"
    path="$(jq -r '.path // ""' <<<"$item")"
    line="$(jq -r '.line // 0' <<<"$item")"
    end_line="$(jq -r '.end_line // ""' <<<"$item")"
    side="$(jq -r '.side // "RIGHT"' <<<"$item")"
    cbody="$(jq -r '.body // ""' <<<"$item")"

    # Truncate comment body
    if [ ${#cbody} -gt $cap ]; then
      cbody="${cbody:0:$((cap - suffix_len))}${suffix}"
    fi

    # Build comment object; include start_line/start_side only for multi-line
    local comment_obj
    if [ -n "$end_line" ] && [ "$end_line" != "null" ] && [ "$end_line" -gt "$line" ] 2>/dev/null; then
      comment_obj="$(jq -n \
        --arg path "$path" \
        --argjson line "$end_line" \
        --argjson start_line "$line" \
        --arg side "$side" \
        --arg start_side "$side" \
        --arg body "$cbody" \
        '{"path":$path,"line":$line,"start_line":$start_line,"side":$side,"start_side":$start_side,"body":$body}')"
    else
      comment_obj="$(jq -n \
        --arg path "$path" \
        --argjson line "$line" \
        --arg side "$side" \
        --arg body "$cbody" \
        '{"path":$path,"line":$line,"side":$side,"body":$body}')"
    fi
    comments_json="$(jq --argjson c "$comment_obj" '. + [$c]' <<<"$comments_json")"
    j=$((j + 1))
  done

  jq -n \
    --arg event "$verdict" \
    --arg body "$body" \
    --argjson comments "$comments_json" \
    '{"event":$event,"body":$body,"comments":$comments}'
}

# ---------------------------------------------------------------------------
# post_match_threads
# ---------------------------------------------------------------------------
# Match posted comments to review thread IDs.
# Args: <posted_comments_json_file> <threads_json_file>
# Stdout: JSON array [{"path","body","threadId"}...]
#
# threads file: JSON array of {id, isResolved, comments:{nodes:[{path,body,databaseId}]}}
# Match: first unresolved thread whose first comment has identical path+body.
# Each thread is matched at most once.
#
# Usage: post_match_threads <posted_file> <threads_file>
post_match_threads() {
  local posted_file="$1" threads_file="$2"
  jq -n \
    --slurpfile posted "$posted_file" \
    --slurpfile threads "$threads_file" \
    '
    ($posted[0]) as $comments |
    ($threads[0]) as $all_threads |

    # Build a mutable state by tracking which thread indices are consumed.
    # We do this with a reduce over comments.
    reduce range($comments | length) as $i (
      {"results": [], "used": []};
      . as $state |
      ($comments[$i]) as $c |
      # Find the first unresolved, unmatched thread whose first comment matches
      (first(
        range($all_threads | length) |
        . as $ti |
        select(
          ($state.used | index($ti)) == null and
          ($all_threads[$ti].isResolved | not) and
          ($all_threads[$ti].comments.nodes[0].path == $c.path) and
          ($all_threads[$ti].comments.nodes[0].body == $c.body)
        )
      ) // null) as $matched_ti |
      if $matched_ti != null then
        {
          "results": ($state.results + [{"path": $c.path, "body": $c.body, "threadId": $all_threads[$matched_ti].id}]),
          "used": ($state.used + [$matched_ti])
        }
      else
        {
          "results": ($state.results + [{"path": $c.path, "body": $c.body, "threadId": null}]),
          "used": $state.used
        }
      end
    ) | .results
    '
}

# ---------------------------------------------------------------------------
# post_compose_state
# ---------------------------------------------------------------------------
# Compose the state marker comment line.
# Args: <head_sha>
# Stdin: JSON array of open findings [{"threadId","file","fingerprint","severity"}...]
# Stdout: single line: <!-- ai-review:state {"lastSha":"...","findings":[...]} -->
#
# findings carry exactly threadId/file/fingerprint/severity keys.
# The output must parse with the canonical capture regex in reconcile.sh:
#   capture("<!-- ai-review:state (?<j>.*?) -->"; "s")
#
# Usage: post_compose_state <head_sha> < findings.json
post_compose_state() {
  local head_sha="$1"
  local findings
  findings="$(cat)"
  local state_json
  state_json="$(jq -c \
    --arg sha "$head_sha" \
    '{
      "lastSha": $sha,
      "findings": [.[] | {"threadId":.threadId,"file":.file,"fingerprint":.fingerprint,"severity":.severity}]
    }' <<<"$findings")" || return 1
  awk '{printf "<!-- ai-review:state %s -->\n", $0}' <<<"$state_json"
}

# ---------------------------------------------------------------------------
# post_fold_inline_to_minors
# ---------------------------------------------------------------------------
# Fold a compose payload's inline comments into its minors block (rung-2
# anchor-class degrade). Inline comments are prepended to minors (inline first)
# and .inline is emptied. Optional arrays default to [].
#
# Stdin: {"walkthrough":..., "inline":[...], "minors":[...],
#         "dropped_static":[...], "rejected":[...]}
# Stdout: same shape with inline:[] and minors:(inline ++ minors)
#
# Usage: post_fold_inline_to_minors < compose_input.json
post_fold_inline_to_minors() {
  local input
  input="$(cat)"
  jq -e . <<<"$input" >/dev/null || return 1
  jq -c '{
    walkthrough,
    inline: [],
    minors: ((.inline // []) + (.minors // [])),
    dropped_static: (.dropped_static // []),
    rejected: (.rejected // [])
  }' <<<"$input"
}

# ---------------------------------------------------------------------------
# post_prepend_approval_notice
# ---------------------------------------------------------------------------
# Prepend the "posted as a comment because…" notice to a review payload's body
# (rung-3 permission-class degrade). Event and comments are preserved.
# Trailing newlines on the result are stripped to match the original workflow's
# `$()`-capture semantics byte-for-byte (an empty body must NOT leave the
# prefix's "\n\n" dangling).
#
# Stdin: {"event":..., "body":..., "comments":[...]}
# Stdout: same object with the notice prepended to .body
#
# Usage: post_prepend_approval_notice < review.json
post_prepend_approval_notice() {
  local input
  input="$(cat)"
  jq -e . <<<"$input" >/dev/null || return 1
  jq -c '.body = (("**Verdict: APPROVE** — posted as a comment because this repository does not allow GitHub Actions to approve pull requests.\n\n" + .body) | sub("\n+$"; ""))' <<<"$input"
}

# ---------------------------------------------------------------------------
# post_build_state_findings
# ---------------------------------------------------------------------------
# Build the open-findings array carried in the state marker.
# Args: <intended_verdict>  (the DERIVED verdict, not event_used)
# Stdin: {"prior":[...], "inline":[...], "matched":[...]}
# Stdout: JSON array of {threadId,file,fingerprint,severity}
#
# Rule: intended_verdict=="APPROVE" -> [] (nothing open).
# Otherwise: prior entries with status=="unfixed" (projected to
# threadId/file/fingerprint/severity), followed by each posted inline finding
# joined to its matched threadId by exact path+body (null when unmatched).
# Emits the same field NAMES post_compose_state reads; compose_state re-projects
# by name, so the key order here is cosmetic, not load-bearing for the round-trip.
#
# Usage: post_build_state_findings <intended_verdict> < input.json
post_build_state_findings() {
  local verdict="$1"
  local input
  input="$(cat)"
  jq -e . <<<"$input" >/dev/null || return 1
  if [ "$verdict" = "APPROVE" ]; then
    printf '[]\n'
    return 0
  fi
  jq -c '
    ([ .prior[]? | select(.status == "unfixed")
       | {threadId, file: .path, fingerprint: (.fingerprint // null), severity: (.severity // null)} ]) as $prior_unfixed |
    ([ range(.inline | length) as $i | (.inline[$i]) as $f |
       ((.matched | map(select(.path == $f.path and .body == $f.body)) | first) // {"threadId": null}) as $m |
       {threadId: $m.threadId, file: $f.path, fingerprint: ($f.fingerprint // null), severity: ($f.severity // null)} ]) as $posted |
    $prior_unfixed + $posted
  ' <<<"$input"
}

# ---------------------------------------------------------------------------
# post_summarize
# ---------------------------------------------------------------------------
# Derive the deterministic one-line summary for the sticky status comment.
# Args: <review_mode>  (full | incremental)
# Stdin: {"findings":[...], "prior":[...], "minors_count":N, "new_count":N}
# Stdout: single-line summary
#   full        -> "No findings."  (when blocking+major+minor all zero) OR
#                  "<b> blocking, <m> major, <k> minor/nit findings."
#                  b,m count severity blocker/major AND confidence high|medium;
#                  k is minors_count.
#   incremental -> "Resolved <r>, remaining <u>, new <n>."
#                  r=prior status==fixed, u=prior status==unfixed, n=new_count.
#
# Usage: post_summarize <review_mode> < input.json
post_summarize() {
  local mode="$1"
  local input
  input="$(cat)"
  jq -e . <<<"$input" >/dev/null || return 1
  if [ "$mode" = "full" ]; then
    jq -r '
      ((.findings // []) | map(select(.severity == "blocker" and (.confidence == "high" or .confidence == "medium"))) | length) as $b |
      ((.findings // []) | map(select(.severity == "major" and (.confidence == "high" or .confidence == "medium"))) | length) as $m |
      (.minors_count) as $k |
      if ($b == 0 and $m == 0 and $k == 0) then "No findings."
      else "\($b) blocking, \($m) major, \($k) minor/nit findings."
      end
    ' <<<"$input"
  else
    jq -r '
      ((.prior // []) | map(select(.status == "fixed")) | length) as $r |
      ((.prior // []) | map(select(.status == "unfixed")) | length) as $u |
      "Resolved \($r), remaining \($u), new \(.new_count)."
    ' <<<"$input"
  fi
}

# ---------------------------------------------------------------------------
# post_compose_status_body
# ---------------------------------------------------------------------------
# Assemble the sticky status comment body (the impure `gh api -X PATCH` that
# consumes it stays in the workflow).
# Stdin: {"mode","last_sha","head_sha","repo_url","event_used","trigger_desc",
#         "size_warning","config_warning","summary","state_marker"}
# Stdout: the full status comment body (no trailing newline; matches the
#         workflow's printf exactly, including the ai-review:ack marker).
#
# range_link: incremental w/ last_sha -> compare link; else single-commit link.
# verdict_label: REQUEST_CHANGES/APPROVE/COMMENT pass through; anything else
# is emitted verbatim. size_warning/config_warning each append a "\n"-suffixed
# line when non-empty.
#
# Usage: post_compose_status_body < input.json
post_compose_status_body() {
  local input
  input="$(cat)"
  jq -e . <<<"$input" >/dev/null || return 1

  local mode last_sha head_sha repo_url event_used trigger_desc
  local size_warning config_warning summary state_marker
  mode="$(jq -r '.mode // ""' <<<"$input")"
  last_sha="$(jq -r '.last_sha // ""' <<<"$input")"
  head_sha="$(jq -r '.head_sha // ""' <<<"$input")"
  repo_url="$(jq -r '.repo_url // ""' <<<"$input")"
  event_used="$(jq -r '.event_used // ""' <<<"$input")"
  trigger_desc="$(jq -r '.trigger_desc // ""' <<<"$input")"
  size_warning="$(jq -r '.size_warning // ""' <<<"$input")"
  config_warning="$(jq -r '.config_warning // ""' <<<"$input")"
  summary="$(jq -r '.summary // ""' <<<"$input")"
  state_marker="$(jq -r '.state_marker // ""' <<<"$input")"

  local short_head range_link
  short_head="${head_sha:0:7}"
  if [ "$mode" = "incremental" ] && [ -n "$last_sha" ]; then
    range_link="[\`${last_sha:0:7}\`…\`${short_head}\`](${repo_url}/compare/${last_sha}...${head_sha})"
  else
    range_link="[\`${short_head}\`](${repo_url}/commit/${head_sha})"
  fi

  # Display label is the posted event verbatim (identity map today; add a case
  # here if a label ever needs to diverge from its event name).
  local verdict_label="$event_used"

  local extra_lines=""
  [ -n "$size_warning" ]   && extra_lines="${extra_lines}${size_warning}"$'\n'
  [ -n "$config_warning" ] && extra_lines="${extra_lines}${config_warning}"$'\n'

  local marker_ack="<!-- ai-review:ack -->"
  printf '%s\n\n✅ ai-review: **%s** review of %s — **%s** (triggered by %s)\n\n%s\n%s%s' \
    "$marker_ack" \
    "$mode" \
    "$range_link" \
    "$verdict_label" \
    "$trigger_desc" \
    "$summary" \
    "$extra_lines" \
    "$state_marker"
}
