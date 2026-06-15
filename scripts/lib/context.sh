#!/usr/bin/env bash
# Pure helpers for the cross-file impact map builder. No network, no GitHub
# API calls — only deterministic bash/rg/ast-grep/git transforms so they can
# be unit tested with bats. The context job `source`s this file (single source
# of truth); CI runs tests/context.bats against it.
#
# Conventions:
# - Functions read inputs from args or stdin and write results to stdout.
# - No `set` changes here; callers own their shell options.
# - Requires: git, rg (ripgrep), python3, grep, awk, sort, uniq, sed, head,
#   printf.
#   Optional: ast-grep (0.43.0+) — if absent, rg path is used for all files.
#
# Dependency note: this file does NOT source scripts/lib/scope.sh. When the
# workflow needs path filtering (context_build_map's optional patterns-file
# argument), it sources scope.sh independently before calling context_build_map.
# scope_match and scope_rg_globs are called only when patterns_file is set.
#
# ──────────────────────────────────────────────────────────────────────────────
# VALIDATED AST-GREP LANGUAGE TABLE (prototyped 2026-06-15 with ast-grep 0.43.0)
# ──────────────────────────────────────────────────────────────────────────────
# Each entry was tested with `ast-grep scan --inline-rules` against real fixture
# files. EVERY kind name here was observed to match at least once in prototype.
#
# ext(s)     | lang       | def kinds                                          | ref kinds
# -----------|------------|----------------------------------------------------|-----------
# .py        | python     | function_definition, class_definition              | call
# .js        | javascript | function_declaration, method_definition,           | call_expression, new_expression
#            |            | class_declaration, lexical_declaration             |
# .ts        | typescript | function_declaration, method_definition,           | call_expression, new_expression
#            |            | class_declaration, interface_declaration,          |
#            |            | lexical_declaration                                |
# .tsx       | tsx        | function_declaration, method_definition,           | call_expression, new_expression,
#            |            | class_declaration                                  | jsx_opening_element,
#            |            |                                                    | jsx_self_closing_element
# .go        | go         | function_declaration, method_declaration,          | call_expression
#            |            | type_declaration                                   |
# .rs        | rust       | function_item, struct_item, enum_item,             | call_expression, macro_invocation
#            |            | trait_item, impl_item                              |
# .sh/.bash  | bash       | function_definition (name field: word kind)        | command_name (inside: command)
# ──────────────────────────────────────────────────────────────────────────────

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

# Map a file path to its ast-grep language id and kind lists.
# Outputs: "<lang>|<def-kinds-comma-separated>|<ref-kinds-comma-separated>"
# Outputs empty string for unmapped extensions (caller uses rg fallback).
#
# Usage: context_ast_lang <file>
context_ast_lang() {
  local file="$1"
  case "$file" in
    *.py)
      echo "python|function_definition,class_definition|call"
      ;;
    *.js)
      echo "javascript|function_declaration,method_definition,class_declaration,lexical_declaration|call_expression,new_expression"
      ;;
    *.ts)
      echo "typescript|function_declaration,method_definition,class_declaration,interface_declaration,lexical_declaration|call_expression,new_expression"
      ;;
    *.tsx)
      echo "tsx|function_declaration,method_definition,class_declaration|call_expression,new_expression,jsx_opening_element,jsx_self_closing_element"
      ;;
    *.go)
      echo "go|function_declaration,method_declaration,type_declaration|call_expression"
      ;;
    *.rs)
      echo "rust|function_item,struct_item,enum_item,trait_item,impl_item|call_expression,macro_invocation"
      ;;
    *.sh|*.bash)
      echo "bash|function_definition|command_name"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Emit inline YAML rules for ast-grep scan (one def rule + one ref rule per
# symbol, separated by ---). Multiple rule blocks are concatenated for a
# single batched invocation.
#
# Bash is special: function name node kind is 'word'; refs use command_name.
# Rust is special: function names are 'identifier', type names 'type_identifier'.
#
# Usage: context_sg_rules <lang> <def-kinds-csv> <ref-kinds-csv> <sym...>
context_sg_rules() {
  local lang="$1"
  local def_kinds_csv="$2"
  local ref_kinds_csv="$3"
  shift 3
  local syms=("$@")

  # Convert comma-separated kind lists to YAML any: block lines (indented 6sp)
  local def_any ref_any
  def_any="$(echo "$def_kinds_csv" | tr ',' '\n' | sed 's/^/      - kind: /')"
  ref_any="$(echo "$ref_kinds_csv" | tr ',' '\n' | sed 's/^/      - kind: /')"

  local first_rule=1
  for sym in "${syms[@]}"; do
    # Regex-escape the symbol defensively (mined symbols are [A-Za-z0-9_]+)
    local escaped_sym
    escaped_sym="$(printf '%s' "$sym" | sed 's/[.^$*+?{}[\]\\|()]/\\&/g')"

    # YAML document separator: emit between rules (not before the first one).
    # ast-grep --inline-rules rejects a leading "---" as an unexpected argument.
    if [ "$lang" = "bash" ]; then
      # Bash: function name node kind is 'word'; ref kind is 'command_name'
      [ "$first_rule" -eq 0 ] && printf -- '---\n'
      printf 'id: def--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  kind: word\n'
      printf '  inside:\n'
      printf '    kind: function_definition\n'
      printf '    field: name\n'
      printf '    stopBy: neighbor\n'
      printf -- '---\n'
      printf 'id: ref--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  kind: command_name\n'
      printf '  inside:\n'
      printf '    kind: command\n'
      printf '    stopBy: end\n'
    elif [ "$lang" = "rust" ]; then
      # Rust: use any:[identifier, type_identifier] to cover both fns and types
      [ "$first_rule" -eq 0 ] && printf -- '---\n'
      printf 'id: def--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  any:\n'
      printf '    - kind: identifier\n'
      printf '    - kind: type_identifier\n'
      printf '  inside:\n'
      printf '    any:\n'
      printf '%s\n' "$def_any"
      printf '    field: name\n'
      printf '    stopBy: neighbor\n'
      printf -- '---\n'
      printf 'id: ref--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  any:\n'
      printf '    - kind: identifier\n'
      printf '    - kind: type_identifier\n'
      printf '  inside:\n'
      printf '    any:\n'
      printf '%s\n' "$ref_any"
      printf '    stopBy: end\n'
    else
      # Standard: identifier kind for both defs (field: name) and refs
      [ "$first_rule" -eq 0 ] && printf -- '---\n'
      printf 'id: def--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  kind: identifier\n'
      printf '  inside:\n'
      printf '    any:\n'
      printf '%s\n' "$def_any"
      printf '    field: name\n'
      printf '    stopBy: neighbor\n'
      printf -- '---\n'
      printf 'id: ref--%s\n' "$sym"
      printf 'language: %s\n' "$lang"
      printf 'rule:\n'
      printf "  regex: '^%s\$'\n" "$escaped_sym"
      printf '  kind: identifier\n'
      printf '  inside:\n'
      printf '    any:\n'
      printf '%s\n' "$ref_any"
      printf '    stopBy: end\n'
    fi
    first_rule=0
  done
}

# Demux ast-grep --json=stream output into impact-map markdown for one file.
# Args: <json-file> <self-file> <newline-separated-symbols>
# Reads NDJSON from <json-file>; writes markdown to stdout.
# json-file is a temp file path (not stdin) because python3 here-doc needs stdin.
#
# Usage: _context_sg_demux <json-file> <self-file> <syms-newline-sep>
_context_sg_demux() {
  local json_file="$1"
  local self_file="$2"
  local syms_str="$3"
  # Write the demux script to a temp file to avoid stdin conflicts with heredoc.
  local py_script
  py_script="$(mktemp /tmp/context-demux.XXXXXX.py)"
  cat > "$py_script" << 'PYEOF'
import json, sys, collections, os

json_file = sys.argv[1]
self_file = sys.argv[2]
syms_str = sys.argv[3] if len(sys.argv) > 3 else ""
syms = [s for s in syms_str.split('\n') if s]

# Normalize self_file to absolute path so we can compare with ast-grep output
# (ast-grep scan . returns relative paths from cwd).
cwd = os.getcwd()
self_abs = os.path.abspath(os.path.join(cwd, self_file))

defs = collections.defaultdict(list)   # sym -> [loc, ...]
refs = collections.defaultdict(list)   # sym -> [loc, ...]

with open(json_file) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue
        rule_id = m.get('ruleId', '')
        file_path = m.get('file', '')
        start = m.get('range', {}).get('start', {})
        lineno = start.get('line', 0) + 1  # convert 0-based to 1-based
        # Normalize file_path to absolute for comparison
        file_abs = os.path.abspath(file_path) if file_path else ''
        # Exclude matches in the changed file itself (source of symbols)
        if file_abs == self_abs:
            continue
        # Present as relative path from cwd for cleaner output
        try:
            display_path = os.path.relpath(file_abs, cwd)
        except ValueError:
            display_path = file_path
        loc = f"{display_path}:{lineno}"
        if rule_id.startswith('def--'):
            sym = rule_id[5:]
            defs[sym].append(loc)
        elif rule_id.startswith('ref--'):
            sym = rule_id[5:]
            refs[sym].append(loc)

for sym in syms:
    def_hits = sorted(set(defs.get(sym, [])))
    ref_hits = sorted(set(refs.get(sym, [])))[:5]
    if def_hits or ref_hits:
        print(f'- `{sym}` (AST):')
        for loc in def_hits[:1]:
            print(f'    defined at: {loc}')
        for loc in ref_hits:
            print(f'    referenced at: {loc}')
PYEOF
  python3 "$py_script" "$json_file" "$self_file" "$syms_str"
  rm -f "$py_script"
}

# Build the full cross-file impact map markdown document to stdout.
# Truncation (head -c 60000) is intentionally left to the caller so the
# workflow step can also emit the byte count.
#
# Usage: context_build_map <range> [<patterns-file>]
# <range> is a git range expression (e.g. "origin/main...HEAD").
# <patterns-file> is an optional file with one path pattern per line (same
#   format as scope.sh produces). When provided:
#   (a) changed files matching scope_match are skipped (in addition to the
#       built-in lockfile/generated case filter below), and
#   (b) the rg call gains scope_rg_globs exclusions so symbol references
#       inside ignored paths are also suppressed.
#   Requires scope_match and scope_rg_globs to be defined (source scope.sh
#   before calling this function when passing a patterns-file argument).
context_build_map() {
  local range="$1"
  local patterns_file="${2:-}"
  local f s syms hits
  local changed_list
  changed_list="$(mktemp /tmp/context-changed.XXXXXX)"

  # Decide once whether ast-grep is available.
  local has_astgrep=0
  command -v ast-grep >/dev/null 2>&1 && has_astgrep=1

  git diff --name-only -z "$range" > "$changed_list"
  {
    echo "# Impact map (auto-generated, heuristic)"
    echo
    echo "For each changed file: identifiers touched by the diff and where they are defined and referenced elsewhere in the repo. Leads, not proof — open the files to verify."
    echo
    # Use fd 3 so rg inside the loop doesn't inherit the list file as stdin
    # (rg without explicit paths reads stdin when it is not a terminal).
    while IFS= read -r -d '' f <&3; do
      [ -f "$f" ] || continue
      # Built-in lockfile/generated filter (always applied).
      case "$f" in
        *.lock|*.sum|*-lock.json|*.min.*|*.svg|*.map) continue ;;
      esac
      # Optional config-patterns filter: skip changed files matching patterns.
      if [ -n "$patterns_file" ] && scope_match "$f" "$patterns_file"; then
        continue
      fi
      echo "## $f"
      syms=$(git diff "$range" -- "$f" \
        | context_mine_symbols)

      # Build rg exclusion args from the patterns file when provided.
      local rg_pat_args=()
      if [ -n "$patterns_file" ]; then
        while IFS= read -r _rg_arg; do
          rg_pat_args+=("$_rg_arg")
        done < <(scope_rg_globs "$patterns_file")
      fi

      # Determine if this file's language is in the ast-grep curated set.
      local lang_info
      lang_info="$(context_ast_lang "$f")"

      if [ "$has_astgrep" -eq 1 ] && [ -n "$lang_info" ] && [ -n "$syms" ]; then
        # ── ast-grep path: symbol-aware def/ref ──────────────────────────────
        local lang def_kinds ref_kinds
        lang="$(echo "$lang_info" | cut -d'|' -f1)"
        def_kinds="$(echo "$lang_info" | cut -d'|' -f2)"
        ref_kinds="$(echo "$lang_info" | cut -d'|' -f3)"

        # Build one set of inline rules for all mined symbols (batched).
        local all_rules
        # shellcheck disable=SC2086
        all_rules="$(context_sg_rules "$lang" "$def_kinds" "$ref_kinds" $syms)"

        # Convert scope_rg_globs (--glob=PAT) to --globs PAT for ast-grep.
        local sg_glob_args=()
        sg_glob_args+=("--globs" "!.git")
        sg_glob_args+=("--globs" "!*.lock")
        sg_glob_args+=("--globs" "!*-lock.json")
        sg_glob_args+=("--globs" "!*.min.*")
        sg_glob_args+=("--globs" "!.ai-review-tooling")
        if [ "${#rg_pat_args[@]}" -gt 0 ]; then
          for _rg_arg in "${rg_pat_args[@]}"; do
            # rg_pat_args contains lines like "--glob=!dist/**" — strip prefix
            local _pat="${_rg_arg#--glob=}"
            sg_glob_args+=("--globs" "$_pat")
          done
        fi

        # Run ONE batched ast-grep invocation; store NDJSON in a temp file.
        # (demux uses a temp file not stdin to avoid heredoc stdin conflict)
        local sg_tmp
        sg_tmp="$(mktemp /tmp/context-sg.XXXXXX)"
        ast-grep scan --inline-rules "$all_rules" \
          --json=stream "${sg_glob_args[@]}" . >"$sg_tmp" 2>/dev/null || true
        _context_sg_demux "$sg_tmp" "$f" "$syms"
        rm -f "$sg_tmp"
      else
        # ── ripgrep fallback: unmapped language or ast-grep not on PATH ───────
        for s in $syms; do
          # </dev/null: rg with no path searches stdin when it's a file/pipe
          # (e.g. under bats on CI); force tree search.
          hits=$(rg -n --no-heading -w -F "$s" \
                  --glob '!.git' --glob '!*.lock' --glob '!*-lock.json' --glob '!*.min.*' \
                  --glob '!.ai-review-tooling' \
                  "${rg_pat_args[@]}" \
                  </dev/null 2>/dev/null | grep -v -F "$f:" | head -5 || true)
          if [ -n "$hits" ]; then
            # shellcheck disable=SC2016
            printf -- '- `%s` referenced in:\n' "$s"
            printf '%s\n' "$hits" | sed 's/^/    /'
          fi
        done
      fi
      echo
    done 3< "$changed_list"
  }
  rm -f "$changed_list"
}
