#!/usr/bin/env bash
# Pure helpers for the historical co-change section of the impact map.
# No network, no GitHub API calls — only deterministic bash/git/awk/sort/sed
# transforms so they can be unit-tested with bats. The context job `source`s
# this file (single source of truth); CI runs tests/cochange.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - Requires: git, awk, sort, sed.
#
# Dependency note: this file does NOT source scripts/lib/scope.sh. When the
# workflow needs path filtering (cochange_build_map's optional patterns-file
# argument), it sources scope.sh independently before calling cochange_build_map.
# scope_match is called only when patterns_file is set.
#
# Rename tracking: --no-renames is used deliberately. --follow only works for a
# single pathspec and would cost O(changed-files × history) git invocations.
# --no-renames makes output deterministic and cheap; a rename appears once as
# old-path + new-path in the renaming commit (harmless noise). Pre-rename
# coupling history is lost — acceptable for a 12-month recency-weighted heuristic.

# Emit "hash<TAB>path" lines for the co-change mining window.
# One git log pass; awk drops commits touching >max_changeset files.
# Missing or invalid ref → empty output + exit 0 (fail-open; also covers
# shallow-history graft boundaries and future fetch-depth changes gracefully).
#
# Usage: cochange_extract_history <ref> [<max_commits>] [<since>] [<max_changeset>]
cochange_extract_history() {
  local ref="$1"
  local max_commits="${2:-1000}"
  local since="${3:-12 months ago}"
  local max_changeset="${4:-30}"

  # Verify ref exists; fail-open on missing ref (e.g. shallow clone, bad name).
  git rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || return 0

  # Single git log pass. $'\x01' (SOH) is used as a commit delimiter because it
  # cannot appear in a file path. --no-merges excludes merge commits; --no-renames
  # avoids per-file rename-detection CPU. awk buffers each commit and only emits
  # "hash<TAB>path" pairs when the commit touches <= max_changeset files.
  #
  # SIGPIPE note: awk is the SOLE consumer of the git log stream. Only the small
  # ranked tail (<=5 rows) ever passes through sed/head with || true, so git log
  # cannot receive a SIGPIPE from a downstream head call here.
  git log --no-merges --no-renames --since="$since" -n "$max_commits" \
      --pretty=format:$'\x01%H' --name-only "$ref" -- 2>/dev/null \
    | awk -v max="$max_changeset" '
        /^\x01/ { flush(); hash=substr($0,2); n=0; delete files; next }
        /^$/    { next }
        { files[++n]=$0 }
        function flush(  i) {
          if (hash != "" && n > 0 && n <= max)
            for (i=1; i<=n; i++) printf "%s\t%s\n", hash, files[i]
          n=0; delete files
        }
        END { flush() }
      ' || true
}

# Read "hash<TAB>path" lines from stdin (output of cochange_extract_history).
# Emit "count<TAB>conf_pct<TAB>total<TAB>path" rows for <target>:
# files that co-change with <target>, filtered by support and confidence,
# excluding paths listed in <changed-list-file> (one path per line).
# Output is sorted: confidence desc, count desc, path asc; capped at max_rows.
#
# Usage: <history-lines> | cochange_rank <target> <changed-list-file> \
#            [<min_count>] [<min_conf_pct>] [<max_rows>]
cochange_rank() {
  local target="$1"
  local changed_list="$2"
  local min_count="${3:-3}"
  local min_conf="${4:-30}"
  local max_rows="${5:-5}"

  # awk is the SOLE consumer of stdin (the history stream). Only the small
  # ranked tail is piped through sort + sed with || true (SIGPIPE-safe).
  awk -F'\t' -v target="$target" -v changed_list="$changed_list" \
      -v min_count="$min_count" -v min_conf="$min_conf" '
    BEGIN {
      # Load PR-touched files so we can exclude them from candidates.
      while ((getline line < changed_list) > 0) in_pr[line]=1
    }
    # New commit boundary when hash changes.
    $1 != hash {
      flush()
      hash=$1; n=0; has_target=0
      delete commit_files
    }
    {
      commit_files[++n]=$2
      if ($2 == target) has_target=1
    }
    function flush(  i) {
      if (has_target) {
        total++
        for (i=1; i<=n; i++)
          if (commit_files[i] != target) co[commit_files[i]]++
      }
      n=0; has_target=0
      delete commit_files
    }
    END {
      flush()
      if (total == 0) exit 0
      for (f in co) {
        conf = int(co[f] * 100 / total)
        if (co[f] >= min_count && conf >= min_conf && !(f in in_pr))
          printf "%d\t%d\t%d\t%s\n", co[f], conf, total, f
      }
    }
  ' | sort -t"$(printf '\t')" -k2,2nr -k1,1nr -k4,4 \
    | sed -n "1,${max_rows}p" || true
}

# Build the "Historical co-change" markdown section to stdout.
# Mirrors context_build_map: <range> determines which files are in the PR,
# <ref> is the history source (e.g. origin/main), optional <patterns-file>
# filters both changed files and candidate rows (source scope.sh before
# calling this function when passing a patterns-file argument).
# Caller owns truncation.
#
# Usage: cochange_build_map <range> <ref> [<patterns-file>]
cochange_build_map() {
  local range="$1"
  local ref="$2"
  local patterns_file="${3:-}"
  local f row count conf total cand

  # Temp files: NUL-delimited changed list (for the loop) and plain-text list
  # (for awk's in_pr exclusion set) and the pre-built history dump.
  local changed_nul changed_txt hist_file
  changed_nul="$(mktemp /tmp/cochange-changed-nul.XXXXXX)"
  changed_txt="$(mktemp /tmp/cochange-changed-txt.XXXXXX)"
  hist_file="$(mktemp /tmp/cochange-hist.XXXXXX)"

  # Populate changed file lists.
  git diff --name-only -z "$range" > "$changed_nul"
  git diff --name-only "$range" > "$changed_txt"

  # ONE git log call for the entire run.
  cochange_extract_history "$ref" > "$hist_file"

  # Emit header.
  {
    echo "# Historical co-change (auto-generated, heuristic)"
    echo
    echo "Files that historically change in the same commits as this PR's changed files"
    echo "but are NOT touched by this PR. If this PR's change logically requires updates"
    echo "elsewhere, these are the most likely places. Leads, not proof — open the files"
    echo "to verify. Mined from the last 12 months of \`${ref}\` (max 1000 commits;"
    echo "merges and commits touching >30 files excluded)."
    echo

    # Use fd 3 for the NUL-delimited list so awk/sort inside the loop don't
    # compete with the list file as stdin (same pattern as context_build_map).
    while IFS= read -r -d '' f <&3; do
      # Built-in lockfile/generated filter (always applied, mirrors context.sh).
      case "$f" in
        *.lock|*.sum|*-lock.json|*.min.*|*.svg|*.map) continue ;;
      esac
      # Optional config-patterns filter: skip changed files matching patterns.
      if [ -n "$patterns_file" ] && scope_match "$f" "$patterns_file"; then
        continue
      fi

      # Rank co-change candidates for this file.
      local rows
      rows="$(cochange_rank "$f" "$changed_txt" 3 30 5 < "$hist_file")"

      # If no rows above threshold, skip the file header entirely when the file
      # has no history at all (total == 0); when it has history but no candidates
      # above threshold, emit the "(no co-change history above thresholds)" line.
      if [ -z "$rows" ]; then
        # Check if the file appears in the history at all.
        if awk -F'\t' -v t="$f" '$2==t{found=1;exit} END{exit !found}' "$hist_file"; then
          echo "## $f"
          echo "- (no co-change history above thresholds)"
          echo
        fi
        # If no history for this file (brand-new), skip entirely.
        continue
      fi

      echo "## $f"
      # Render each candidate row.
      while IFS= read -r row; do
        count="$(printf '%s' "$row" | cut -f1)"
        conf="$(printf '%s' "$row"  | cut -f2)"
        total="$(printf '%s' "$row" | cut -f3)"
        cand="$(printf '%s' "$row"  | cut -f4)"

        # Drop candidates that no longer exist on disk.
        [ -f "$cand" ] || continue

        # Optional config-patterns filter on the candidate path.
        if [ -n "$patterns_file" ] && scope_match "$cand" "$patterns_file"; then
          continue
        fi

        # shellcheck disable=SC2016
        printf -- '- `%s` — co-changed in %s of %s commits touching this file (%s%%)\n' \
          "$cand" "$count" "$total" "$conf"
      done <<< "$rows"
      echo
    done 3< "$changed_nul"
  }

  rm -f "$changed_nul" "$changed_txt" "$hist_file"
}
