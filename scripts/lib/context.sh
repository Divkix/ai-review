#!/usr/bin/env bash
# Pure helpers for the cross-file impact map builder. No network, no GitHub
# API calls — only deterministic bash/rg/git transforms so they can be unit
# tested with bats. The context job `source`s this file (single source of
# truth); CI runs tests/context.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - Requires: git, rg (ripgrep), grep, awk, sort, uniq, sed, head, printf.

# Common keywords/types across mainstream languages; mining them as "symbols"
# would grep half the repo for nothing.
# shellcheck disable=SC2034
_CONTEXT_STOPWORDS='^(if|else|elif|for|while|do|switch|case|break|continue|return|function|func|def|class|struct|enum|interface|type|import|export|from|package|module|const|let|var|val|public|private|protected|static|final|async|await|yield|new|delete|this|self|super|null|nil|none|true|false|try|catch|except|finally|throw|throws|raise|with|use|using|namespace|void|int|float|double|bool|boolean|string|char|byte|long|short|unsigned|signed|auto|template|typename|require|include|pragma|define|undef|error|warning|default|extends|implements|abstract|override|virtual|inline|extern|register|volatile|sizeof|typeof|instanceof|and|or|not|in|is|as|where|when|match|loop|impl|trait|crate|mod|pub|ref|mut|dyn|move|unsafe|defer|chan|select|range|map|print|println|printf|console|log|test|describe|expect|assert|main|init|len|cap|err|ctx|args|kwargs)$'

# Mine symbol names from a unified diff on stdin.
# Outputs up to 30 symbol names, one per line, ranked by frequency.
# Never fails on no matches (|| true semantics).
#
# Usage: <diff text> | context_mine_symbols
context_mine_symbols() {
  grep -E '^[+-][^+-]' \
    | grep -oE '\b[A-Za-z_][A-Za-z0-9_]{2,}\b' \
    | grep -ivE "$_CONTEXT_STOPWORDS" \
    | sort | uniq -c | sort -rn | awk '{print $2}' | head -30 || true
}

# Build the full cross-file impact map markdown document to stdout.
# Truncation (head -c 60000) is intentionally left to the caller so the
# workflow step can also emit the byte count.
#
# Usage: context_build_map <range>
# <range> is a git range expression (e.g. "origin/main...HEAD").
context_build_map() {
  local range="$1"
  local f s syms hits
  local changed_list
  changed_list="$(mktemp /tmp/context-changed.XXXXXX)"

  git diff --name-only -z "$range" > "$changed_list"
  {
    echo "# Impact map (auto-generated, heuristic)"
    echo
    echo "For each changed file: identifiers touched by the diff and where they are referenced elsewhere in the repo. Leads, not proof — open the files to verify."
    echo
    # Use fd 3 so rg inside the loop doesn't inherit the list file as stdin
    # (rg without explicit paths reads stdin when it is not a terminal).
    while IFS= read -r -d '' f <&3; do
      [ -f "$f" ] || continue
      case "$f" in
        *.lock|*.sum|*-lock.json|*.min.*|*.svg|*.map) continue ;;
      esac
      echo "## $f"
      syms=$(git diff "$range" -- "$f" \
        | context_mine_symbols)
      for s in $syms; do
        # </dev/null: rg with no path searches stdin when it's a file/pipe (e.g. under bats on CI); force tree search.
        hits=$(rg -n --no-heading -w -F "$s" \
                --glob '!.git' --glob '!*.lock' --glob '!*-lock.json' --glob '!*.min.*' \
                --glob '!.ai-review-tooling' \
                </dev/null 2>/dev/null | grep -v -F "$f:" | head -5 || true)
        if [ -n "$hits" ]; then
          # shellcheck disable=SC2016
          printf -- '- `%s` referenced in:\n' "$s"
          printf '%s\n' "$hits" | sed 's/^/    /'
        fi
      done
      echo
    done 3< "$changed_list"
  }
  rm -f "$changed_list"
}
