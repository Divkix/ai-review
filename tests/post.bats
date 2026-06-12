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

@test "post: match_threads missing posted file -> non-zero exit" {
  local threads_file
  threads_file="$BATS_TEST_TMPDIR/threads.json"
  printf '[]' > "$threads_file"
  run bash -c 'source "$1/scripts/lib/post.sh"; post_match_threads /nonexistent/path.json "$2"' _ "$REPO_ROOT" "$threads_file"
  [ "$status" -ne 0 ]
}
