#!/usr/bin/env bats
# Unit tests for scripts/lib/post.sh — the deterministic posting helpers.
# No network, no GitHub API — only deterministic bash/jq transforms.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/post.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures"
}

# ---------------------------------------------------------------------------
# post_derive_verdict
# ---------------------------------------------------------------------------

@test "verdict: blocker with high confidence -> REQUEST_CHANGES" {
  run post_derive_verdict <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"high","path":"a.py","line":1,"body":"bad"}
  ],
  "prior": []
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "verdict: blocker with medium confidence -> REQUEST_CHANGES" {
  run post_derive_verdict <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"medium","path":"a.py","line":1,"body":"bad"}
  ],
  "prior": []
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "verdict: blocker with low confidence -> APPROVE (no budget-passing blocker)" {
  run post_derive_verdict <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"low","path":"a.py","line":1,"body":"bad"}
  ],
  "prior": []
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "verdict: major only -> APPROVE" {
  run post_derive_verdict <<'EOF'
{
  "findings": [
    {"severity":"major","confidence":"high","path":"a.py","line":1,"body":"bad"}
  ],
  "prior": []
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "verdict: unfixed blocker prior -> REQUEST_CHANGES" {
  run post_derive_verdict <<'EOF'
{
  "findings": [],
  "prior": [
    {"threadId":"PRRT_1","fingerprint":"abc","path":"a.py","severity":"blocker","status":"unfixed"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "verdict: unfixed prior with null severity (legacy) -> REQUEST_CHANGES (conservative)" {
  run post_derive_verdict <<'EOF'
{
  "findings": [],
  "prior": [
    {"threadId":"PRRT_1","fingerprint":"abc","path":"a.py","severity":null,"status":"unfixed"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "verdict: unfixed prior with missing severity -> REQUEST_CHANGES (conservative)" {
  run post_derive_verdict <<'EOF'
{
  "findings": [],
  "prior": [
    {"threadId":"PRRT_1","fingerprint":"abc","path":"a.py","status":"unfixed"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "REQUEST_CHANGES" ]
}

@test "verdict: unfixed prior severity=major -> APPROVE" {
  run post_derive_verdict <<'EOF'
{
  "findings": [],
  "prior": [
    {"threadId":"PRRT_1","fingerprint":"abc","path":"a.py","severity":"major","status":"unfixed"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "verdict: fixed blocker prior -> APPROVE" {
  run post_derive_verdict <<'EOF'
{
  "findings": [],
  "prior": [
    {"threadId":"PRRT_1","fingerprint":"abc","path":"a.py","severity":"blocker","status":"fixed"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "verdict: empty findings + no prior -> APPROVE" {
  run post_derive_verdict <<'EOF'
{"findings":[],"prior":[]}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "verdict: missing fields tolerated without crash" {
  run post_derive_verdict <<'EOF'
{"walkthrough":"some text"}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

# ---------------------------------------------------------------------------
# post_select_budget
# ---------------------------------------------------------------------------

@test "budget: blockers+majors (high/medium) go inline, rest to minors" {
  run post_select_budget <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"high","path":"a.py","line":1,"body":"B1"},
    {"severity":"major","confidence":"medium","path":"b.py","line":2,"body":"M1"},
    {"severity":"minor","confidence":"high","path":"c.py","line":3,"body":"n1"},
    {"severity":"nit","confidence":"high","path":"d.py","line":4,"body":"n2"},
    {"severity":"major","confidence":"low","path":"e.py","line":5,"body":"low"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline | length == 2'
  echo "$output" | jq -e '.minors | length == 3'
  # inline: blocker first
  echo "$output" | jq -e '.inline[0].severity == "blocker"'
  echo "$output" | jq -e '.inline[1].severity == "major"'
}

@test "budget: findings without usable path go to minors" {
  run post_select_budget <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"high","path":null,"line":1,"body":"no path"},
    {"severity":"blocker","confidence":"high","path":"","line":1,"body":"empty path"},
    {"severity":"blocker","confidence":"high","path":"a.py","line":null,"body":"no line"},
    {"severity":"blocker","confidence":"high","path":"a.py","line":1,"body":"ok"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline | length == 1'
  echo "$output" | jq -e '.minors | length == 3'
  echo "$output" | jq -e '.inline[0].body == "ok"'
}

@test "budget: hard cap at 10 inline, overflow to minors" {
  # Generate 12 blockers with high confidence and valid path/line
  findings='{"findings":['
  for i in $(seq 1 12); do
    findings+='{"severity":"blocker","confidence":"high","path":"f.py","line":'"$i"',"body":"b'"$i"'"},'
  done
  findings="${findings%,}]}"
  run post_select_budget <<<"$findings"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline | length == 10'
  echo "$output" | jq -e '.minors | length == 2'
}

@test "budget: stable sort: blocker>major then high>medium then path asc then line asc" {
  run post_select_budget <<'EOF'
{
  "findings": [
    {"severity":"major","confidence":"medium","path":"z.py","line":1,"body":"Z"},
    {"severity":"major","confidence":"high","path":"a.py","line":10,"body":"A10"},
    {"severity":"blocker","confidence":"medium","path":"b.py","line":5,"body":"BM"},
    {"severity":"blocker","confidence":"high","path":"b.py","line":3,"body":"BH3"},
    {"severity":"blocker","confidence":"high","path":"a.py","line":3,"body":"BHa"}
  ]
}
EOF
  [ "$status" -eq 0 ]
  # Expected order: blocker/high/a.py:3, blocker/high/b.py:3, blocker/medium/b.py:5, major/high/a.py:10, major/medium/z.py:1
  echo "$output" | jq -e '.inline[0].body == "BHa"'
  echo "$output" | jq -e '.inline[1].body == "BH3"'
  echo "$output" | jq -e '.inline[2].body == "BM"'
  echo "$output" | jq -e '.inline[3].body == "A10"'
  echo "$output" | jq -e '.inline[4].body == "Z"'
}

@test "budget: empty findings -> both arrays empty" {
  run post_select_budget <<'EOF'
{"findings":[]}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == []'
  echo "$output" | jq -e '.minors == []'
}

# ---------------------------------------------------------------------------
# post_fingerprint / post_finding_fingerprints
# ---------------------------------------------------------------------------

@test "fingerprint: known hash value (deterministic)" {
  run post_fingerprint "src/a.py" "some body text"
  [ "$status" -eq 0 ]
  # sha256('src/a.py:some body text') first 12 hex chars
  [ "$output" = "c389f8d9ab66" ]
}

@test "fingerprint: different inputs produce different hashes" {
  fp1="$(post_fingerprint "a.py" "body1")"
  fp2="$(post_fingerprint "a.py" "body2")"
  [ "$fp1" != "$fp2" ]
}

@test "fingerprint: 12 lowercase hex chars" {
  run post_fingerprint "x.py" "test"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{12}$ ]]
}

@test "finding_fingerprints: rule_id present -> uses rule_id as fingerprint" {
  run post_finding_fingerprints <<'EOF'
[
  {"path":"a.py","body":"issue","rule_id":"SEC001","severity":"blocker"}
]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].fingerprint == "SEC001"'
}

@test "finding_fingerprints: null rule_id -> hash of path:body" {
  run post_finding_fingerprints <<'EOF'
[
  {"path":"src/a.py","body":"some body text","rule_id":null,"severity":"major"}
]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].fingerprint == "c389f8d9ab66"'
}

@test "finding_fingerprints: missing rule_id -> hash of path:body" {
  run post_finding_fingerprints <<'EOF'
[
  {"path":"src/a.py","body":"some body text","severity":"major"}
]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].fingerprint == "c389f8d9ab66"'
}

@test "finding_fingerprints: empty string rule_id -> hash of path:body" {
  run post_finding_fingerprints <<'EOF'
[
  {"path":"src/a.py","body":"some body text","rule_id":"","severity":"major"}
]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].fingerprint == "c389f8d9ab66"'
}

@test "finding_fingerprints: empty array -> empty array" {
  run post_finding_fingerprints <<'EOF'
[]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

# ---------------------------------------------------------------------------
# post_validate_anchors
# ---------------------------------------------------------------------------

setup_diff_file() {
  DIFF_FILE="$BATS_TEST_TMPDIR/test.diff"
  cat > "$DIFF_FILE" <<'DIFF'
diff --git a/src/a.py b/src/a.py
index abc..def 100644
--- a/src/a.py
+++ b/src/a.py
@@ -1,4 +1,5 @@
 context line 1
+added line 2
 context line 3
-deleted line 4
 context line 5
DIFF
}

@test "anchors: added line (RIGHT) is valid" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":2,"side":"RIGHT","body":"on added line"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
  echo "$output" | jq -e '.valid[0].line == 2'
}

@test "anchors: context line (RIGHT) is valid" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":1,"side":"RIGHT","body":"on context line"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: deleted line (LEFT side) is valid" {
  setup_diff_file
  # Old side line 4 was deleted
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":4,"side":"LEFT","body":"on deleted line"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: line outside any hunk -> demoted" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":999,"side":"RIGHT","body":"outside hunk"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 0'
  echo "$output" | jq -e '.demoted | length == 1'
}

@test "anchors: path absent from diff -> demoted" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"other/file.py","line":1,"side":"RIGHT","body":"absent path"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 0'
  echo "$output" | jq -e '.demoted | length == 1'
}

@test "anchors: renamed file anchored by new path" {
  local diff_file="$BATS_TEST_TMPDIR/rename.diff"
  cat > "$diff_file" <<'DIFF'
diff --git a/old/name.py b/new/name.py
similarity index 90%
rename from old/name.py
rename to new/name.py
index abc..def 100644
--- a/old/name.py
+++ b/new/name.py
@@ -1,2 +1,3 @@
 line one
+new line two
 line three
DIFF
  run post_validate_anchors "$diff_file" <<'EOF'
[{"path":"new/name.py","line":2,"side":"RIGHT","body":"on renamed file new path"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: multiple hunks in same file, comment in second hunk" {
  local diff_file="$BATS_TEST_TMPDIR/multi.diff"
  cat > "$diff_file" <<'DIFF'
diff --git a/src/b.py b/src/b.py
index abc..def 100644
--- a/src/b.py
+++ b/src/b.py
@@ -1,3 +1,4 @@
 line 1
+added 2
 line 3
 line 4
@@ -10,3 +11,4 @@
 line 11
 line 12
+added 13
 line 14
DIFF
  run post_validate_anchors "$diff_file" <<'EOF'
[
  {"path":"src/b.py","line":2,"side":"RIGHT","body":"first hunk"},
  {"path":"src/b.py","line":13,"side":"RIGHT","body":"second hunk"}
]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 2'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: new file (/dev/null old side) - added lines valid" {
  local diff_file="$BATS_TEST_TMPDIR/newfile.diff"
  cat > "$diff_file" <<'DIFF'
diff --git a/src/new.py b/src/new.py
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/src/new.py
@@ -0,0 +1,3 @@
+line 1
+line 2
+line 3
DIFF
  run post_validate_anchors "$diff_file" <<'EOF'
[{"path":"src/new.py","line":2,"side":"RIGHT","body":"on new file"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: deleted file - old side lines valid" {
  local diff_file="$BATS_TEST_TMPDIR/delfile.diff"
  cat > "$diff_file" <<'DIFF'
diff --git a/src/old.py b/src/old.py
deleted file mode 100644
index abc1234..0000000
--- a/src/old.py
+++ /dev/null
@@ -1,3 +0,0 @@
-line 1
-line 2
-line 3
DIFF
  run post_validate_anchors "$diff_file" <<'EOF'
[{"path":"src/old.py","line":2,"side":"LEFT","body":"on deleted file"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: multi-line comment (end_line set) - full range must be valid" {
  setup_diff_file
  # Lines 1-3 on RIGHT are all context/added (valid range)
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":1,"end_line":3,"side":"RIGHT","body":"multi-line valid"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 1'
  echo "$output" | jq -e '.demoted | length == 0'
}

@test "anchors: multi-line comment - end_line outside hunk -> demoted" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[{"path":"src/a.py","line":1,"end_line":999,"side":"RIGHT","body":"multi-line invalid end"}]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid | length == 0'
  echo "$output" | jq -e '.demoted | length == 1'
}

@test "anchors: empty comment list -> both arrays empty" {
  setup_diff_file
  run post_validate_anchors "$DIFF_FILE" <<'EOF'
[]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid == []'
  echo "$output" | jq -e '.demoted == []'
}

# ---------------------------------------------------------------------------
# post_compose_review
# ---------------------------------------------------------------------------

@test "compose_review: REQUEST_CHANGES payload structure" {
  run post_compose_review "REQUEST_CHANGES" <<'EOF'
{
  "walkthrough": "## Summary\nFound issues.",
  "inline": [
    {"path":"a.py","line":1,"side":"RIGHT","body":"fix this","severity":"blocker","confidence":"high"}
  ],
  "minors": [],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "REQUEST_CHANGES"'
  echo "$output" | jq -e '.comments | length == 1'
  echo "$output" | jq -e '.comments[0].path == "a.py"'
  echo "$output" | jq -e '.comments[0].line == 1'
  echo "$output" | jq -e '.comments[0].side == "RIGHT"'
  echo "$output" | jq -e '.body | startswith("## Summary")'
}

@test "compose_review: APPROVE event" {
  run post_compose_review "APPROVE" <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [],
  "minors": [],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "APPROVE"'
  echo "$output" | jq -e '.comments == []'
}

@test "compose_review: minors section appended when non-empty" {
  run post_compose_review "APPROVE" <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [],
  "minors": [
    {"path":"x.py","line":5,"body":"Consider renaming this variable for clarity."}
  ],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.body | contains("Minor suggestions")'
  echo "$output" | jq -e '.body | contains("x.py:5")'
}

@test "compose_review: dropped_static section appended when non-empty" {
  run post_compose_review "APPROVE" <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [],
  "minors": [],
  "dropped_static": [
    {"tool":"opengrep","rule_id":"SEC001","path":"a.py","reason":"false positive"}
  ],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.body | contains("Dropped static")'
  echo "$output" | jq -e '.body | contains("opengrep")'
  echo "$output" | jq -e '.body | contains("SEC001")'
}

@test "compose_review: dropped_static section has blank line after summary so GFM renders the list" {
  run post_compose_review "APPROVE" <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [],
  "minors": [],
  "dropped_static": [
    {"tool":"gitleaks","rule_id":"generic-api-key","path":"a.py","reason":"Pre-existing finding in file not changed by this PR"},
    {"tool":"gitleaks","rule_id":"curl-auth-header","path":"README.md","reason":"Pre-existing finding in file not changed by this PR"}
  ],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  # GitHub-Flavored Markdown only renders a list inside <details> when a blank
  # line separates </summary> from the bullets (and the bullets from </details>);
  # a single newline collapses them into one paragraph.
  echo "$output" | jq -e '.body | contains("</summary>\n\n- ")'
  echo "$output" | jq -e '.body | contains("\n\n</details>")'
}

@test "compose_review: minors section has blank line after summary so GFM renders the list" {
  run post_compose_review "APPROVE" <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [],
  "minors": [
    {"path":"x.py","line":5,"body":"Rename for clarity."},
    {"path":"y.py","line":9,"body":"Extract a helper."}
  ],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.body | contains("</summary>\n\n- ")'
  echo "$output" | jq -e '.body | contains("\n\n</details>")'
}

@test "compose_review: multi-line comment uses start_line/start_side" {
  run post_compose_review "REQUEST_CHANGES" <<'EOF'
{
  "walkthrough": "issues",
  "inline": [
    {"path":"a.py","line":5,"end_line":8,"side":"RIGHT","body":"span comment","severity":"blocker","confidence":"high"}
  ],
  "minors": [],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.comments[0].line == 8'
  echo "$output" | jq -e '.comments[0].start_line == 5'
  echo "$output" | jq -e '.comments[0].start_side == "RIGHT"'
}

@test "compose_review: single-line comment has no start_line" {
  run post_compose_review "REQUEST_CHANGES" <<'EOF'
{
  "walkthrough": "issues",
  "inline": [
    {"path":"a.py","line":1,"side":"RIGHT","body":"single","severity":"blocker","confidence":"high"}
  ],
  "minors": [],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.comments[0] | has("start_line") | not'
}

@test "compose_review: body truncated at 65000 chars with suffix" {
  # Build a walkthrough just over 65000 chars
  long_text="$(python3 -c "print('x' * 65100)")"
  payload="$(jq -n --arg w "$long_text" '{"walkthrough":$w,"inline":[],"minors":[],"dropped_static":[],"rejected":[]}')"
  run post_compose_review "APPROVE" <<<"$payload"
  [ "$status" -eq 0 ]
  # wc -c counts bytes; the ellipsis in the suffix is 3 UTF-8 bytes, so allow
  # up to 65010 bytes (65000 chars + UTF-8 overhead + jq trailing newline)
  body_len="$(echo "$output" | jq -r '.body' | wc -c | tr -d ' ')"
  [ "$body_len" -le 65010 ]
  echo "$output" | jq -e '.body | endswith("[truncated]")'
}

@test "compose_review: comment body truncated at 65000 chars" {
  long_body="$(python3 -c "print('y' * 65100)")"
  payload="$(jq -n --arg b "$long_body" '{"walkthrough":"ok","inline":[{"path":"a.py","line":1,"side":"RIGHT","body":$b,"severity":"blocker","confidence":"high"}],"minors":[],"dropped_static":[],"rejected":[]}')"
  run post_compose_review "REQUEST_CHANGES" <<<"$payload"
  [ "$status" -eq 0 ]
  # wc -c counts bytes; allow UTF-8 overhead + jq trailing newline
  comment_len="$(echo "$output" | jq -r '.comments[0].body' | wc -c | tr -d ' ')"
  [ "$comment_len" -le 65010 ]
  echo "$output" | jq -e '.comments[0].body | endswith("[truncated]")'
}

# ---------------------------------------------------------------------------
# post_match_threads
# ---------------------------------------------------------------------------

@test "match_threads: exact path+body match -> threadId set" {
  posted="$BATS_TEST_TMPDIR/posted.json"
  threads="$BATS_TEST_TMPDIR/threads.json"
  cat > "$posted" <<'EOF'
[{"path":"a.py","body":"fix this","line":1}]
EOF
  cat > "$threads" <<'EOF'
[
  {
    "id": "PRRT_abc",
    "isResolved": false,
    "comments": {"nodes": [{"path":"a.py","body":"fix this","databaseId":101}]}
  }
]
EOF
  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].threadId == "PRRT_abc"'
  echo "$output" | jq -e '.[0].path == "a.py"'
}

@test "match_threads: no matching thread -> threadId null" {
  posted="$BATS_TEST_TMPDIR/posted.json"
  threads="$BATS_TEST_TMPDIR/threads.json"
  cat > "$posted" <<'EOF'
[{"path":"a.py","body":"different body","line":1}]
EOF
  cat > "$threads" <<'EOF'
[
  {
    "id": "PRRT_abc",
    "isResolved": false,
    "comments": {"nodes": [{"path":"a.py","body":"fix this","databaseId":101}]}
  }
]
EOF
  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].threadId == null'
}

@test "match_threads: resolved thread is not matched" {
  posted="$BATS_TEST_TMPDIR/posted.json"
  threads="$BATS_TEST_TMPDIR/threads.json"
  cat > "$posted" <<'EOF'
[{"path":"a.py","body":"fix this","line":1}]
EOF
  cat > "$threads" <<'EOF'
[
  {
    "id": "PRRT_resolved",
    "isResolved": true,
    "comments": {"nodes": [{"path":"a.py","body":"fix this","databaseId":101}]}
  }
]
EOF
  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].threadId == null'
}

@test "match_threads: each thread matched at most once" {
  posted="$BATS_TEST_TMPDIR/posted.json"
  threads="$BATS_TEST_TMPDIR/threads.json"
  cat > "$posted" <<'EOF'
[
  {"path":"a.py","body":"same body","line":1},
  {"path":"a.py","body":"same body","line":2}
]
EOF
  cat > "$threads" <<'EOF'
[
  {
    "id": "PRRT_one",
    "isResolved": false,
    "comments": {"nodes": [{"path":"a.py","body":"same body","databaseId":101}]}
  }
]
EOF
  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]
  # First gets matched, second doesn't (thread consumed)
  echo "$output" | jq -e '.[0].threadId == "PRRT_one"'
  echo "$output" | jq -e '.[1].threadId == null'
}

@test "match_threads: empty posted list -> empty output" {
  posted="$BATS_TEST_TMPDIR/posted.json"
  threads="$BATS_TEST_TMPDIR/threads.json"
  printf '[]' > "$posted"
  printf '[]' > "$threads"
  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "match_threads: workflow posted-comments source: valid_inline matches thread, unmatched finding gets null threadId" {
  # Regression guard for the mainline bug where the workflow read .comments from
  # the create-review REST response (which never contains an inline comments array)
  # instead of matching what was actually sent (valid_inline). That caused
  # posted-comments.json to always be [], so post_match_threads returned all-null
  # threadIds, and finalize never auto-resolved threads.
  #
  # This test mirrors the CORRECTED workflow pattern:
  #   jq -c '[.[] | {path: .path, body: .body}]' <<<"$valid_inline" > posted-comments.json
  # A regression back to reading .comments from the review response would produce
  # an empty posted-comments.json, making both threadIds null (assertion on line 1
  # would fail: threadId would be null instead of "PRRT_xyz123").

  local posted threads valid_inline

  # Fixture: valid_inline — 2 findings with path+body (as stored in the workflow variable)
  valid_inline='[
    {"path":"src/auth.py","line":5,"side":"RIGHT","body":"SQL injection risk here","severity":"blocker","confidence":"high","fingerprint":"abc123def456"},
    {"path":"src/util.py","line":12,"side":"RIGHT","body":"Unused variable leaks memory","severity":"major","confidence":"medium","fingerprint":"def456abc123"}
  ]'

  # Derive posted-comments exactly as the corrected workflow does (NOT from .comments on the response).
  posted="$BATS_TEST_TMPDIR/posted-comments.json"
  jq -c '[.[] | {path: .path, body: .body}]' <<<"$valid_inline" > "$posted"

  # Fixture: threads-post.json — one unresolved thread matching finding 1, one resolved
  # thread whose body also matches finding 1 (should not be picked — resolved), and no
  # thread matching finding 2 (threadId must be null).
  threads="$BATS_TEST_TMPDIR/threads-post.json"
  cat > "$threads" <<'EOF'
[
  {
    "id": "PRRT_xyz123",
    "isResolved": false,
    "comments": {"nodes": [{"path":"src/auth.py","body":"SQL injection risk here","databaseId":201}]}
  },
  {
    "id": "PRRT_resolved",
    "isResolved": true,
    "comments": {"nodes": [{"path":"src/auth.py","body":"SQL injection risk here","databaseId":202}]}
  },
  {
    "id": "PRRT_other",
    "isResolved": false,
    "comments": {"nodes": [{"path":"src/other.py","body":"Unrelated finding","databaseId":203}]}
  }
]
EOF

  run post_match_threads "$posted" "$threads"
  [ "$status" -eq 0 ]

  # Finding 1 (src/auth.py) must match the unresolved thread PRRT_xyz123.
  echo "$output" | jq -e 'map(select(.path == "src/auth.py")) | .[0].threadId == "PRRT_xyz123"'
  # Finding 2 (src/util.py) has no matching thread -> threadId must be null.
  echo "$output" | jq -e 'map(select(.path == "src/util.py")) | .[0].threadId == null'
  # Resolved thread PRRT_resolved must not be matched even though body matches.
  echo "$output" | jq -e '[.[] | select(.threadId == "PRRT_resolved")] | length == 0'
}

# ---------------------------------------------------------------------------
# post_compose_state + round-trip with reconcile_state_from_comments
# ---------------------------------------------------------------------------

@test "compose_state: emits correct state marker format" {
  run post_compose_state "abc123" <<'EOF'
[
  {"threadId":"PRRT_1","file":"a.py","fingerprint":"fp1","severity":"blocker"},
  {"threadId":"PRRT_2","file":"b.py","fingerprint":"fp2","severity":"major"}
]
EOF
  [ "$status" -eq 0 ]
  # Must be a single line starting with the marker
  lines="$(echo "$output" | wc -l | tr -d ' ')"
  [ "$lines" -eq 1 ]
  [[ "$output" == '<!-- ai-review:state '* ]]
  [[ "$output" == *' -->' ]]
  echo "$output" | grep -o '{.*}' | jq -e '.lastSha == "abc123"'
  echo "$output" | grep -o '{.*}' | jq -e '.findings | length == 2'
  echo "$output" | grep -o '{.*}' | jq -e '.findings[0].threadId == "PRRT_1"'
  echo "$output" | grep -o '{.*}' | jq -e '.findings[0].file == "a.py"'
  echo "$output" | grep -o '{.*}' | jq -e '.findings[0].fingerprint == "fp1"'
  echo "$output" | grep -o '{.*}' | jq -e '.findings[0].severity == "blocker"'
}

@test "compose_state: findings have exactly threadId/file/fingerprint/severity keys" {
  run post_compose_state "sha1" <<'EOF'
[{"threadId":"PRRT_x","file":"x.py","fingerprint":"abc","severity":"minor","extra":"ignored"}]
EOF
  [ "$status" -eq 0 ]
  json="$(echo "$output" | grep -o '{.*}')"
  # extra field must not appear in findings
  echo "$json" | jq -e '.findings[0] | keys == ["file","fingerprint","severity","threadId"]'
}

@test "compose_state: round-trip through reconcile_state_from_comments" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/reconcile.sh"

  marker="$(post_compose_state "roundtrip_sha" <<'EOF'
[{"threadId":"PRRT_rt","file":"c.py","fingerprint":"def456","severity":"blocker"}]
EOF
)"

  # Wrap in a bot comment array as reconcile_state_from_comments expects
  comments_json="$(jq -n --arg body "$marker" '[{"user":{"type":"Bot","login":"github-actions[bot]"},"body":$body}]')"
  recovered="$(echo "$comments_json" | reconcile_state_from_comments)"

  # Verify recovered state matches what we put in
  echo "$recovered" | jq -e '.lastSha == "roundtrip_sha"'
  echo "$recovered" | jq -e '.findings[0].threadId == "PRRT_rt"'
  echo "$recovered" | jq -e '.findings[0].file == "c.py"'
  echo "$recovered" | jq -e '.findings[0].fingerprint == "def456"'
  echo "$recovered" | jq -e '.findings[0].severity == "blocker"'
}

@test "compose_state: empty findings array" {
  run post_compose_state "emptysha" <<'EOF'
[]
EOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -o '{.*}' | jq -e '.findings == []'
  echo "$output" | grep -o '{.*}' | jq -e '.lastSha == "emptysha"'
}

# ---------------------------------------------------------------------------
# post_fold_inline_to_minors
# ---------------------------------------------------------------------------

@test "fold_inline_to_minors: inline folded into minors (inline-then-minors order), inline emptied" {
  run post_fold_inline_to_minors <<'EOF'
{
  "walkthrough": "LGTM",
  "inline": [{"path":"a.py","line":1,"side":"RIGHT","body":"I1"}],
  "minors": [{"path":"m.py","line":2,"body":"M1"}],
  "dropped_static": [],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == []'
  echo "$output" | jq -e '.minors | length == 2'
  # inline entry comes first
  echo "$output" | jq -e '.minors[0].body == "I1"'
  echo "$output" | jq -e '.minors[1].body == "M1"'
  echo "$output" | jq -e '.walkthrough == "LGTM"'
}

@test "fold_inline_to_minors: empty inline -> minors unchanged" {
  run post_fold_inline_to_minors <<'EOF'
{
  "walkthrough": "ok",
  "inline": [],
  "minors": [{"path":"m.py","line":2,"body":"M1"}],
  "dropped_static": [{"tool":"opengrep","rule_id":"R1","path":"x.py","reason":"fp"}],
  "rejected": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == []'
  echo "$output" | jq -e '.minors | length == 1'
  echo "$output" | jq -e '.minors[0].body == "M1"'
  # dropped_static preserved
  echo "$output" | jq -e '.dropped_static | length == 1'
}

# ---------------------------------------------------------------------------
# post_prepend_approval_notice
# ---------------------------------------------------------------------------

@test "prepend_approval_notice: prepends notice to .body" {
  run post_prepend_approval_notice <<'EOF'
{"event":"COMMENT","body":"## Summary\nAll good.","comments":[]}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.body | startswith("**Verdict: APPROVE** — posted as a comment because this repository does not allow GitHub Actions to approve pull requests.")'
  # Original body preserved after the notice (with blank line separator)
  echo "$output" | jq -e '.body | contains("## Summary\nAll good.")'
}

@test "prepend_approval_notice: preserves event and comments" {
  run post_prepend_approval_notice <<'EOF'
{"event":"COMMENT","body":"orig","comments":[{"path":"a.py","line":1,"side":"RIGHT","body":"c"}]}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "COMMENT"'
  echo "$output" | jq -e '.comments | length == 1'
  echo "$output" | jq -e '.comments[0].path == "a.py"'
}

@test "prepend_approval_notice: empty body -> no dangling trailing newlines (byte-exact parity with workflow \$()-capture)" {
  # Regression guard: the original rung-3 logic captured the body via
  # orig_body="$(jq -r '.body' …)", and $() strips trailing newlines. With an
  # empty body the result must be EXACTLY the notice (no trailing "\n\n").
  run post_prepend_approval_notice <<'EOF'
{"event":"COMMENT","body":"","comments":[]}
EOF
  [ "$status" -eq 0 ]
  expected="**Verdict: APPROVE** — posted as a comment because this repository does not allow GitHub Actions to approve pull requests."
  [ "$(echo "$output" | jq -r '.body')" = "$expected" ]
}

@test "prepend_approval_notice: trailing newlines in body stripped (byte-exact parity)" {
  # Body ending in newlines: $()-capture would strip them; the helper must too.
  run post_prepend_approval_notice <<'EOF'
{"event":"COMMENT","body":"line one\n\n","comments":[]}
EOF
  [ "$status" -eq 0 ]
  expected="**Verdict: APPROVE** — posted as a comment because this repository does not allow GitHub Actions to approve pull requests.\n\nline one"
  # Compare the literal escaped form (jq -c renders \n as backslash-n)
  [ "$(echo "$output" | jq -c '.body')" = "\"$expected\"" ]
}

# ---------------------------------------------------------------------------
# post_build_state_findings
# ---------------------------------------------------------------------------

@test "build_state_findings: APPROVE -> empty array" {
  run post_build_state_findings "APPROVE" <<'EOF'
{
  "prior": [{"threadId":"PRRT_1","path":"a.py","fingerprint":"fp1","severity":"blocker","status":"unfixed"}],
  "inline": [{"path":"b.py","body":"x","fingerprint":"fp2","severity":"major"}],
  "matched": [{"path":"b.py","body":"x","threadId":"PRRT_2"}]
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "build_state_findings: REQUEST_CHANGES merges prior_unfixed + posted" {
  run post_build_state_findings "REQUEST_CHANGES" <<'EOF'
{
  "prior": [
    {"threadId":"PRRT_old","path":"x.py","fingerprint":"fpx","severity":"blocker","status":"unfixed"},
    {"threadId":"PRRT_fixed","path":"y.py","fingerprint":"fpy","severity":"major","status":"fixed"}
  ],
  "inline": [{"path":"b.py","body":"new finding","fingerprint":"fp2","severity":"blocker"}],
  "matched": [{"path":"b.py","body":"new finding","threadId":"PRRT_new"}]
}
EOF
  [ "$status" -eq 0 ]
  # prior_unfixed (1) + posted (1), fixed prior excluded
  echo "$output" | jq -e 'length == 2'
  echo "$output" | jq -e '.[0].threadId == "PRRT_old"'
  echo "$output" | jq -e '.[0].file == "x.py"'
  echo "$output" | jq -e '.[1].threadId == "PRRT_new"'
  echo "$output" | jq -e '.[1].file == "b.py"'
  # key order mirrors post_compose_state
  echo "$output" | jq -e '.[0] | keys_unsorted == ["threadId","file","fingerprint","severity"]'
}

@test "build_state_findings: posted matched -> threadId carried" {
  run post_build_state_findings "REQUEST_CHANGES" <<'EOF'
{
  "prior": [],
  "inline": [{"path":"b.py","body":"x","fingerprint":"fp2","severity":"major"}],
  "matched": [{"path":"b.py","body":"x","threadId":"PRRT_match"}]
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].threadId == "PRRT_match"'
  echo "$output" | jq -e '.[0].fingerprint == "fp2"'
  echo "$output" | jq -e '.[0].severity == "major"'
}

@test "build_state_findings: posted unmatched -> threadId null" {
  run post_build_state_findings "REQUEST_CHANGES" <<'EOF'
{
  "prior": [],
  "inline": [{"path":"b.py","body":"x","fingerprint":"fp2","severity":"major"}],
  "matched": [{"path":"other.py","body":"different","threadId":"PRRT_x"}]
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  echo "$output" | jq -e '.[0].threadId == null'
  echo "$output" | jq -e '.[0].file == "b.py"'
}

@test "build_state_findings: prior status=fixed excluded" {
  run post_build_state_findings "REQUEST_CHANGES" <<'EOF'
{
  "prior": [{"threadId":"PRRT_f","path":"y.py","fingerprint":"fpy","severity":"blocker","status":"fixed"}],
  "inline": [],
  "matched": []
}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "build_state_findings: empty inline+prior -> empty array" {
  run post_build_state_findings "REQUEST_CHANGES" <<'EOF'
{"prior":[],"inline":[],"matched":[]}
EOF
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

# ---------------------------------------------------------------------------
# post_summarize
# ---------------------------------------------------------------------------

@test "summarize: full with findings -> blocking/major/minor string" {
  run post_summarize "full" <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"high"},
    {"severity":"major","confidence":"medium"}
  ],
  "prior": [],
  "minors_count": 3,
  "new_count": 0
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "1 blocking, 1 major, 3 minor/nit findings." ]
}

@test "summarize: full all-zero -> No findings." {
  run post_summarize "full" <<'EOF'
{"findings":[],"prior":[],"minors_count":0,"new_count":0}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "No findings." ]
}

@test "summarize: full counts only high/medium-confidence blockers/majors" {
  run post_summarize "full" <<'EOF'
{
  "findings": [
    {"severity":"blocker","confidence":"high"},
    {"severity":"blocker","confidence":"low"},
    {"severity":"major","confidence":"medium"},
    {"severity":"major","confidence":"low"},
    {"severity":"minor","confidence":"high"}
  ],
  "prior": [],
  "minors_count": 0,
  "new_count": 0
}
EOF
  [ "$status" -eq 0 ]
  # low-confidence blocker/major excluded; minor not counted in blocking/major
  [ "$output" = "1 blocking, 1 major, 0 minor/nit findings." ]
}

@test "summarize: incremental -> Resolved/remaining/new string" {
  run post_summarize "incremental" <<'EOF'
{
  "findings": [],
  "prior": [
    {"status":"fixed"},
    {"status":"unfixed"},
    {"status":"unfixed"}
  ],
  "minors_count": 0,
  "new_count": 5
}
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "Resolved 1, remaining 2, new 5." ]
}

# ---------------------------------------------------------------------------
# post_compose_status_body
# ---------------------------------------------------------------------------

@test "compose_status_body: full -> single-commit link, ack marker, no warnings" {
  run post_compose_status_body <<'EOF'
{
  "mode": "full",
  "last_sha": "",
  "head_sha": "deadbeef1234567890",
  "repo_url": "https://github.com/o/r",
  "event_used": "REQUEST_CHANGES",
  "trigger_desc": "push by @x",
  "size_warning": "",
  "config_warning": "",
  "summary": "1 blocking, 0 major, 0 minor/nit findings.",
  "state_marker": "<!-- ai-review:state {\"lastSha\":\"deadbeef\",\"findings\":[]} -->"
}
EOF
  [ "$status" -eq 0 ]
  # ack marker leads the body
  [[ "$output" == '<!-- ai-review:ack -->'* ]]
  # single-commit link (full mode)
  echo "$output" | grep -qF '[`deadbee`](https://github.com/o/r/commit/deadbeef1234567890)'
  echo "$output" | grep -qF '**REQUEST_CHANGES**'
  echo "$output" | grep -qF '1 blocking, 0 major, 0 minor/nit findings.'
  # state marker is the tail
  [[ "$output" == *'<!-- ai-review:state {"lastSha":"deadbeef","findings":[]} -->' ]]
}

@test "compose_status_body: incremental -> compare link with both warnings appended" {
  run post_compose_status_body <<'EOF'
{
  "mode": "incremental",
  "last_sha": "0123456789abcdef",
  "head_sha": "fedcba9876543210",
  "repo_url": "https://github.com/o/r",
  "event_used": "APPROVE",
  "trigger_desc": "/review by @y",
  "size_warning": "WARN_SIZE",
  "config_warning": "WARN_CONFIG",
  "summary": "Resolved 1, remaining 0, new 0.",
  "state_marker": "<!-- ai-review:state {\"lastSha\":\"x\",\"findings\":[]} -->"
}
EOF
  [ "$status" -eq 0 ]
  # compare link (incremental + last_sha)
  echo "$output" | grep -qF '[`0123456`…`fedcba9`](https://github.com/o/r/compare/0123456789abcdef...fedcba9876543210)'
  echo "$output" | grep -qF '**APPROVE**'
  # both warnings present between summary and state marker
  echo "$output" | grep -qF 'WARN_SIZE'
  echo "$output" | grep -qF 'WARN_CONFIG'
}

@test "compose_status_body: warnings and marker render on their own lines (newline regression)" {
  run post_compose_status_body <<'EOF'
{
  "mode": "incremental",
  "last_sha": "0123456789abcdef",
  "head_sha": "fedcba9876543210",
  "repo_url": "https://github.com/o/r",
  "event_used": "APPROVE",
  "trigger_desc": "/review by @y",
  "size_warning": "WARN_SIZE",
  "config_warning": "WARN_CONFIG",
  "summary": "SUMMARY.",
  "state_marker": "MARKER"
}
EOF
  [ "$status" -eq 0 ]
  # No literal two-char backslash-n may survive in the rendered body.
  ! printf '%s' "$output" | grep -qF '\n'
  # Each warning and the marker occupy their own physical line
  # (bats splits $output into $lines on real newlines; grep -x = whole-line match).
  [ "$(printf '%s\n' "${lines[@]}" | grep -cx 'WARN_SIZE')" -eq 1 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -cx 'WARN_CONFIG')" -eq 1 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -cx 'MARKER')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# I2: malformed stdin failure-mode tests
# Each stdin-consuming function must exit non-zero on non-JSON input.
# ---------------------------------------------------------------------------

@test "post: derive_verdict malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_derive_verdict <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: select_budget malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_select_budget <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: finding_fingerprints malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_finding_fingerprints <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: validate_anchors malformed stdin -> non-zero exit" {
  local diff_file
  diff_file="$BATS_TEST_TMPDIR/empty.diff"
  printf '' > "$diff_file"
  run bash -c 'source "$1/scripts/lib/post.sh"; post_validate_anchors "$2" <<<"not json"' _ "$REPO_ROOT" "$diff_file"
  [ "$status" -ne 0 ]
}

@test "post: compose_review malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_compose_review REQUEST_CHANGES <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: compose_state malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_compose_state abc123 <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: fold_inline_to_minors malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_fold_inline_to_minors <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: prepend_approval_notice malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_prepend_approval_notice <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: build_state_findings malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_build_state_findings REQUEST_CHANGES <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: summarize malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_summarize full <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: compose_status_body malformed stdin -> non-zero exit" {
  run bash -c 'source "$1/scripts/lib/post.sh"; post_compose_status_body <<<"not json"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "post: match_threads missing posted file -> non-zero exit" {
  local threads_file
  threads_file="$BATS_TEST_TMPDIR/threads.json"
  printf '[]' > "$threads_file"
  run bash -c 'source "$1/scripts/lib/post.sh"; post_match_threads /nonexistent/path.json "$2"' _ "$REPO_ROOT" "$threads_file"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regression guard: workflow must extract .findings before calling
# post_finding_fingerprints. Previously the workflow piped the whole verified.json
# object (not .findings array) — jq 'length' counts keys, then .[$i] on an
# object with an integer index returns null, so the loop ran N times over nulls,
# producing N phantom fingerprinted-null entries (silent data corruption, not crash).
# This test guards the correct workflow pattern: extract then merge back.
# ---------------------------------------------------------------------------

@test "finding_fingerprints: correct workflow pattern fingerprints .findings correctly" {
  # This is the exact pattern used in review.yml (verbatim variable names preserved).
  # Must produce exactly 1 fingerprinted entry with correct path/body.
  verified_json='{
    "mode": "full",
    "walkthrough": "text",
    "findings": [{"path":"a.py","body":"b","severity":"blocker","line":1}],
    "prior": [],
    "dropped_static": [],
    "rejected": []
  }'
  # Correct pattern: extract array, fingerprint, merge back.
  fp_findings="$(jq -c '.findings // []' <<<"$verified_json" | post_finding_fingerprints)"
  verified_fp="$(jq --argjson f "$fp_findings" '.findings = $f' <<<"$verified_json")"
  # Must be an array of exactly 1 finding with fingerprint set
  count="$(jq '.findings | length' <<<"$verified_fp")"
  [ "$count" -eq 1 ]
  jq -e '.findings[0].fingerprint != null and (.findings[0].fingerprint | type) == "string"' <<<"$verified_fp"
  jq -e '.findings[0].path == "a.py"' <<<"$verified_fp"
}

@test "finding_fingerprints: old broken pattern (piping full object) does NOT produce correct findings — regression" {
  # This test documents WHY the fix was needed: piping the full verified.json
  # object (not .findings array) to post_finding_fingerprints is broken. In the
  # workflow's set -euo pipefail context, jq '.[$i]' with an integer index on an
  # object errors and aborts the posting step. Outside pipefail the function
  # iterates over object key count (6) producing phantom null entries.
  # Either outcome is wrong. The correct pattern is: extract .findings, pipe
  # the array, then merge back (see test above and review.yml step 1).
  # This test verifies: the OLD pattern does NOT produce 1 finding with path=="a.py".
  verified_json='{
    "mode": "full",
    "walkthrough": "text",
    "findings": [{"path":"a.py","body":"b","severity":"blocker","line":1}],
    "prior": [],
    "dropped_static": [],
    "rejected": []
  }'
  # OLD broken pattern (do NOT use this in production code):
  broken_output="$(post_finding_fingerprints <<<"$verified_json" 2>/dev/null)" || broken_output=""
  # The broken pattern must NOT produce the correct 1-finding result.
  # Either broken_output is empty (function errored), or the count is wrong,
  # or the first finding has no path (null path from indexing the object).
  if [ -z "$broken_output" ]; then
    : # empty output is correct — function errored as expected under pipefail
  else
    # If it produced output, it must not look like the correct 1-finding array.
    count="$(jq 'length' <<<"$broken_output" 2>/dev/null)" || count="0"
    first_path="$(jq -r '.[0].path // ""' <<<"$broken_output" 2>/dev/null)" || first_path=""
    # Correct result would be: count==1 AND path=="a.py". The broken pattern must differ.
    [ "$count" -ne 1 ] || [ "$first_path" != "a.py" ]
  fi
}

# ---------------------------------------------------------------------------
# Composition smoke test: full posting pipeline under set -euo pipefail
# Fixture: verified.json with 2 findings (1 anchorable blocker, 1 mis-anchored minor)
# + a matching diff — exercises fingerprints → budget → anchors → compose_review
# → state composition → reconcile round-trip.
# No network, no gh calls.
# ---------------------------------------------------------------------------

@test "pipeline: full posting pipeline smoke test (no network)" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/reconcile.sh"

  local verified diff_file threads_file

  # Fixture: verified.json — 1 anchorable blocker + 1 mis-anchored minor
  verified="$BATS_TEST_TMPDIR/verified.json"
  cat > "$verified" <<'EOF'
{
  "mode": "full",
  "walkthrough": "## Summary by ai-review\n\n| Files | Description |\n|---|---|\n| src/a.py | Added bad code |\n\n### Findings\n- Blockers: 1\n- Major: 0\n- Minor/Nit: 1",
  "findings": [
    {
      "path": "src/a.py",
      "line": 2,
      "end_line": null,
      "side": "RIGHT",
      "severity": "blocker",
      "confidence": "high",
      "evidence": "logic-proof",
      "body": "This is a blocking issue on the added line.",
      "tool": null,
      "rule_id": null,
      "verification": "Confirmed: line 2 is in diff"
    },
    {
      "path": "src/a.py",
      "line": 999,
      "end_line": null,
      "side": "RIGHT",
      "severity": "minor",
      "confidence": "low",
      "evidence": "opinion",
      "body": "Minor suggestion on a line not in the diff.",
      "tool": null,
      "rule_id": null,
      "verification": "Noted"
    }
  ],
  "prior": [],
  "dropped_static": [],
  "rejected": []
}
EOF

  # Fixture diff: one added line 2 in src/a.py
  diff_file="$BATS_TEST_TMPDIR/pipeline.diff"
  cat > "$diff_file" <<'DIFF'
diff --git a/src/a.py b/src/a.py
index abc..def 100644
--- a/src/a.py
+++ b/src/a.py
@@ -1,2 +1,3 @@
 line one
+bad code here
 line three
DIFF

  # Threads file: empty (no prior threads)
  threads_file="$BATS_TEST_TMPDIR/threads.json"
  printf '[]' > "$threads_file"

  set -euo pipefail

  # Step 1: fingerprint findings — verbatim from review.yml "Post review" run block.
  # post_finding_fingerprints expects a JSON ARRAY; extract .findings first,
  # then merge the fingerprinted array back into the full object.
  # (This mirrors the fix for bug #1: feeding the whole object caused jq errors.)
  fp_findings="$(jq -c '.findings // []' "$verified" | post_finding_fingerprints)"
  jq --argjson f "$fp_findings" '.findings = $f' "$verified" > "$BATS_TEST_TMPDIR/verified-fp.json"
  jq -e '.[0].fingerprint != null' <<<"$fp_findings"

  # Step 2: budget selection — blocker (high, valid path+line) -> inline; minor (low) -> minors
  budget_json="$(post_select_budget < "$BATS_TEST_TMPDIR/verified-fp.json")"
  inline_count="$(jq '.inline | length' <<<"$budget_json")"
  minors_count="$(jq '.minors | length' <<<"$budget_json")"
  # blocker/high goes inline; minor/low goes to minors
  [ "$inline_count" -eq 1 ]
  [ "$minors_count" -eq 1 ]
  inline_candidates="$(jq -c '.inline' <<<"$budget_json")"
  minors_from_budget="$(jq -c '.minors' <<<"$budget_json")"

  # Step 3: validate anchors — blocker on line 2 valid; minor on line 999 demoted
  anchor_result="$(post_validate_anchors "$diff_file" <<<"$inline_candidates")"
  valid_inline="$(jq -c '.valid' <<<"$anchor_result")"
  demoted="$(jq -c '.demoted' <<<"$anchor_result")"
  jq -e 'length == 1' <<<"$valid_inline"
  jq -e 'length == 0' <<<"$demoted"
  # The mis-anchored minor was already in minors from budget; anchor step only sees inline candidates
  all_minors="$(jq -n --argjson d "$demoted" --argjson m "$minors_from_budget" '$d + $m')"
  jq -e 'length == 1' <<<"$all_minors"

  # Step 4: verdict — blocker/high -> REQUEST_CHANGES
  verdict="$(post_derive_verdict < "$BATS_TEST_TMPDIR/verified-fp.json")"
  [ "$verdict" = "REQUEST_CHANGES" ]

  # Step 5: compose review — 1 inline comment + 1 minors entry
  walkthrough="$(jq -r '.walkthrough' "$BATS_TEST_TMPDIR/verified-fp.json")"
  compose_input="$(jq -n \
    --arg w "$walkthrough" \
    --argjson inline "$valid_inline" \
    --argjson minors "$all_minors" \
    --argjson ds '[]' \
    --argjson rej '[]' \
    '{"walkthrough":$w,"inline":$inline,"minors":$minors,"dropped_static":$ds,"rejected":$rej}')"
  review_payload="$(post_compose_review "REQUEST_CHANGES" <<<"$compose_input")"
  jq -e '.event == "REQUEST_CHANGES"' <<<"$review_payload"
  jq -e '.comments | length == 1' <<<"$review_payload"
  jq -e '.comments[0].path == "src/a.py"' <<<"$review_payload"
  jq -e '.comments[0].line == 2' <<<"$review_payload"
  jq -e '.body | contains("Minor suggestions")' <<<"$review_payload"

  # Step 6: state composition — blocker is inline/unfixed, so appears in state
  # Simulate: posted comments matched to threads (none here since threads=[])
  posted_file="$BATS_TEST_TMPDIR/posted.json"
  jq -c '[.comments[] | {path: .path, body: .body}]' <<<"$review_payload" > "$posted_file"
  matched="$(post_match_threads "$posted_file" "$threads_file")"
  # threadId null since no threads exist yet
  jq -e '.[0].threadId == null' <<<"$matched"

  # Build state findings via post_build_state_findings (sub-block 9 helper):
  # the posted blocker with null threadId. intended_verdict==REQUEST_CHANGES.
  state_findings_input="$(jq -n \
    --argjson prior '[]' \
    --argjson inline "$valid_inline" \
    --argjson matched "$matched" \
    '{"prior":$prior,"inline":$inline,"matched":$matched}')"
  posted_findings="$(post_build_state_findings "REQUEST_CHANGES" <<<"$state_findings_input")"
  jq -e 'length == 1' <<<"$posted_findings"
  jq -e '.[0].severity == "blocker"' <<<"$posted_findings"
  jq -e '.[0].threadId == null' <<<"$posted_findings"

  # Step 7: compose state marker
  state_marker="$(post_compose_state "deadbeef1234567890abcdef1234567890abcdef" <<<"$posted_findings")"
  [[ "$state_marker" == '<!-- ai-review:state '* ]]
  [[ "$state_marker" == *' -->' ]]
  echo "$state_marker" | grep -o '{.*}' | jq -e '.lastSha == "deadbeef1234567890abcdef1234567890abcdef"'
  echo "$state_marker" | grep -o '{.*}' | jq -e '.findings | length == 1'
  echo "$state_marker" | grep -o '{.*}' | jq -e '.findings[0].severity == "blocker"'

  # Step 7b: summary (sub-block 10 helper post_summarize) — full mode, 1 blocker
  # high-confidence inline + 1 minor -> "1 blocking, 0 major, 1 minor/nit findings."
  summary_input="$(jq -n \
    --argjson findings "$(jq -c '.findings' "$BATS_TEST_TMPDIR/verified-fp.json")" \
    --argjson prior "$(jq -c '.prior' "$BATS_TEST_TMPDIR/verified-fp.json")" \
    --argjson minors_count "$(jq 'length' <<<"$all_minors")" \
    --argjson new_count "$(jq 'length' <<<"$valid_inline")" \
    '{"findings":$findings,"prior":$prior,"minors_count":$minors_count,"new_count":$new_count}')"
  summary="$(post_summarize "full" <<<"$summary_input")"
  [ "$summary" = "1 blocking, 0 major, 1 minor/nit findings." ]

  # Step 7c: status body (sub-block 10 helper post_compose_status_body)
  status_body_input="$(jq -n \
    --arg mode "full" \
    --arg last_sha "" \
    --arg head_sha "deadbeef1234567890abcdef1234567890abcdef" \
    --arg repo_url "https://github.com/o/r" \
    --arg event_used "REQUEST_CHANGES" \
    --arg trigger_desc "push" \
    --arg size_warning "" \
    --arg config_warning "" \
    --arg summary "$summary" \
    --arg state_marker "$state_marker" \
    '{"mode":$mode,"last_sha":$last_sha,"head_sha":$head_sha,"repo_url":$repo_url,"event_used":$event_used,"trigger_desc":$trigger_desc,"size_warning":$size_warning,"config_warning":$config_warning,"summary":$summary,"state_marker":$state_marker}')"
  status_body="$(post_compose_status_body <<<"$status_body_input")"
  [[ "$status_body" == '<!-- ai-review:ack -->'* ]]
  [[ "$status_body" == *"$state_marker" ]]
  printf '%s' "$status_body" | grep -qF '**REQUEST_CHANGES**'

  # Step 8: round-trip — reconcile reads the state back (from the composed body)
  comments_json="$(jq -n --arg body "$status_body" \
    '[{"user":{"type":"Bot","login":"github-actions[bot]"},"body":$body}]')"
  recovered="$(echo "$comments_json" | reconcile_state_from_comments)"
  echo "$recovered" | jq -e '.lastSha == "deadbeef1234567890abcdef1234567890abcdef"'
  echo "$recovered" | jq -e '.findings | length == 1'
}

# ---------------------------------------------------------------------------
# Composition smoke test: the rung-2 / rung-3 fallback payload chain under
# set -euo pipefail. Mirrors review.yml's ladder payload construction (the
# network if/else stays in YAML; only the pure transforms run here):
#   rung 2: post_fold_inline_to_minors | post_compose_review "$verdict"
#   rung 3: post_compose_review "COMMENT" | post_prepend_approval_notice
# Guards the new compose|prepend pipe against pipefail/SIGPIPE regressions.
# ---------------------------------------------------------------------------

@test "pipeline: rung-2/rung-3 fallback payload chain smoke test (no network)" {
  set -euo pipefail

  # compose_input as built in sub-block 6: 1 inline blocker + 1 minor.
  compose_input="$(jq -n '{
    "walkthrough": "## Summary\nFindings present.",
    "inline": [{"path":"a.py","line":2,"side":"RIGHT","body":"blocking issue","severity":"blocker","confidence":"high"}],
    "minors": [{"path":"m.py","line":9,"body":"nit: rename"}],
    "dropped_static": [],
    "rejected": []
  }')"

  # Rung 2: fold inline into minors (inline-first), then compose with verdict.
  degrade_input="$(post_fold_inline_to_minors <<<"$compose_input")"
  jq -e '.inline == []' <<<"$degrade_input"
  jq -e '.minors | length == 2' <<<"$degrade_input"
  jq -e '.minors[0].body == "blocking issue"' <<<"$degrade_input"
  rung2="$(post_compose_review "REQUEST_CHANGES" <<<"$degrade_input")"
  jq -e '.event == "REQUEST_CHANGES"' <<<"$rung2"
  # Inline folded into minors -> no inline review comments posted.
  jq -e '.comments == []' <<<"$rung2"
  jq -e '.body | contains("Minor suggestions")' <<<"$rung2"

  # Rung 3: COMMENT event, then prepend the approval notice (the new pipe).
  rung3="$(post_compose_review "COMMENT" <<<"$degrade_input" | post_prepend_approval_notice)"
  jq -e '.event == "COMMENT"' <<<"$rung3"
  jq -e '.body | startswith("**Verdict: APPROVE** — posted as a comment because")' <<<"$rung3"
  # Original walkthrough survives after the notice.
  jq -e '.body | contains("## Summary")' <<<"$rung3"
}
