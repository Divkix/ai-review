#!/usr/bin/env bash
# Pin-consistency guard. Fails (non-zero) if any of these invariants break:
#   1. All OPENCODE_VERSION values across the workflows are identical.
#   2. All OPENCODE_SHA256 values are identical.
#   3. The pinned sha256 matches the actual release asset on GitHub
#      (catches "bumped version, forgot to update the hash"). Skip with
#      CHECK_PINS_OFFLINE=1.
#   3b. Each pinned binary (OPENGREP, GITLEAKS, OSV_SCANNER, RIPGREP, RUFF,
#       GOLANGCI, OXLINT, SHELLCHECK, HADOLINT, ACTIONLINT, ZIZMOR, TRIVY,
#       TYPOS, ASTGREP — 14 tools total) has exactly one distinct VERSION and
#       one distinct SHA256 in review.yml; OPENGREP_RULES_REF is a 40-char hex
#       commit. Live mode verifies all 14 asset hashes.
#   4. Every internal version pin (`ref: vN`, `@vN`) shares one major N, so a
#       half-finished release bump can't ship. When EXPECT_PIN_TAG is set (the
#       release workflow sets it to the pushed tag), the single pin must also
#       EQUAL that tag — catches "tagged vX but pins still point at vX-1".
#
# Run from the repo root: scripts/check-pins.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Single source of truth for the tool roster + download URLs (shared with
# scripts/bump-pins.sh; unit-tested by tests/pins.bats).
# shellcheck source=scripts/lib/pins.sh
. scripts/lib/pins.sh

WORKFLOWS=(.github/workflows/review.yml .github/workflows/commands.yml)
fail=0
err() { echo "::error::$*" >&2; fail=1; }

# Temp files for the two live-download sections. One trap cleans up both: a
# second `trap ... EXIT` would *replace* the first, leaking the earlier file.
tmp="" tmp_scanner=""
trap 'rm -f "$tmp" "$tmp_scanner"' EXIT

# --- 1 & 2: OPENCODE_VERSION / OPENCODE_SHA256 internal consistency ----------
# Extraction mechanics live in pins.sh (shared with the bumper); here we add
# `sort -u` to assert all copies agree.
mapfile -t versions < <(pins_grep_assignments OPENCODE_VERSION "${WORKFLOWS[@]}" | sort -u)
mapfile -t shas < <(pins_grep_assignments OPENCODE_SHA256 "${WORKFLOWS[@]}" | sort -u)

if [ "${#versions[@]}" -eq 0 ]; then
  err "no OPENCODE_VERSION pins found"
elif [ "${#versions[@]}" -ne 1 ]; then
  err "OPENCODE_VERSION mismatch across workflows: ${versions[*]}"
fi
if [ "${#shas[@]}" -ne 1 ]; then
  err "OPENCODE_SHA256 mismatch across workflows: ${shas[*]}"
fi

# Count occurrences so a deleted/extra copy is noticed (expect 3 of each).
vcount=$(grep -rhoE 'OPENCODE_VERSION="' "${WORKFLOWS[@]}" | wc -l | tr -d ' ')
scount=$(grep -rhoE 'OPENCODE_SHA256="' "${WORKFLOWS[@]}" | wc -l | tr -d ' ')
if [ "$vcount" != "$scount" ]; then
  err "OPENCODE_VERSION ($vcount) and OPENCODE_SHA256 ($scount) copy counts differ"
fi
echo "opencode pins: version=${versions[0]:-?} sha=${shas[0]:0:12}… copies=$vcount"

# --- 3: live sha256 verification --------------------------------------------
if [ "${CHECK_PINS_OFFLINE:-0}" = "1" ]; then
  echo "CHECK_PINS_OFFLINE=1 — skipping live release sha256 verification"
elif [ "$fail" -eq 0 ]; then
  ver="${versions[0]}"
  want="${shas[0]}"
  url="$(pins_url OPENCODE "$ver")"
  tmp="$(mktemp)"
  echo "fetching $url"
  if curl -fsSL -o "$tmp" "$url"; then
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
      err "pinned OPENCODE_SHA256 ($want) != real asset sha256 ($got) for v$ver"
    else
      echo "live sha256 OK for opencode v$ver"
    fi
  else
    err "could not download pinned opencode asset v$ver (bad version pin?)"
  fi
fi

# --- 3b: scanner binary + rules-ref pin consistency -------------------------
REVIEW_WF=.github/workflows/review.yml

# Single source-of-truth tool list — the sha256-pinned scanner binaries come
# from scripts/lib/pins.sh (shared with the bumper; add/remove tools there).
# Download URLs are built per-tool via pins_url; no local map needed.
mapfile -t TOOLS < <(pins_scanners)

for tool in "${TOOLS[@]}"; do
  mapfile -t tool_versions < <(pins_grep_assignments "${tool}_VERSION" "$REVIEW_WF" | sort -u)
  mapfile -t tool_shas < <(pins_grep_assignments "${tool}_SHA256" "$REVIEW_WF" | sort -u)
  if [ "${#tool_versions[@]}" -eq 0 ]; then
    err "no ${tool}_VERSION pin found in $REVIEW_WF"
  elif [ "${#tool_versions[@]}" -ne 1 ]; then
    err "${tool}_VERSION has multiple distinct values in $REVIEW_WF: ${tool_versions[*]}"
  fi
  if [ "${#tool_shas[@]}" -eq 0 ]; then
    err "no ${tool}_SHA256 pin found in $REVIEW_WF"
  elif [ "${#tool_shas[@]}" -ne 1 ]; then
    err "${tool}_SHA256 has multiple distinct values in $REVIEW_WF: ${tool_shas[*]}"
  fi
  if [ "${#tool_versions[@]}" -eq 1 ] && [ "${#tool_shas[@]}" -eq 1 ]; then
    echo "${tool,,} pins: version=${tool_versions[0]} sha=${tool_shas[0]:0:12}…"
  fi
done

# Assert OPENGREP_RULES_REF is a 40-char hex commit.
mapfile -t rules_refs < <(pins_grep_assignments OPENGREP_RULES_REF "$REVIEW_WF" | sort -u)
if [ "${#rules_refs[@]}" -eq 0 ]; then
  err "no OPENGREP_RULES_REF pin found in $REVIEW_WF"
elif [ "${#rules_refs[@]}" -ne 1 ]; then
  err "OPENGREP_RULES_REF has multiple distinct values: ${rules_refs[*]}"
elif ! [[ "${rules_refs[0]}" =~ ^[0-9a-f]{40}$ ]]; then
  err "OPENGREP_RULES_REF '${rules_refs[0]}' is not a 40-char hex commit"
else
  echo "opengrep-rules ref: ${rules_refs[0]}"
fi

# Live sha256 verification for each scanner binary (skip if offline).
if [ "${CHECK_PINS_OFFLINE:-0}" = "1" ]; then
  echo "CHECK_PINS_OFFLINE=1 — skipping live scanner sha256 verification"
elif [ "$fail" -eq 0 ]; then
  tmp_scanner="$(mktemp)"
  for tool in "${TOOLS[@]}"; do
    mapfile -t tv < <(pins_grep_assignments "${tool}_VERSION" "$REVIEW_WF" | sort -u)
    mapfile -t ts < <(pins_grep_assignments "${tool}_SHA256" "$REVIEW_WF" | sort -u)
    ver="${tv[0]}"
    want="${ts[0]}"
    # Build the asset URL from the shared pins.sh descriptor (no eval).
    url="$(pins_url "$tool" "$ver")"
    echo "fetching $url"
    if curl -fsSL -o "$tmp_scanner" "$url"; then
      got="$(sha256sum "$tmp_scanner" | cut -d' ' -f1)"
      if [ "$got" != "$want" ]; then
        err "pinned ${tool}_SHA256 ($want) != real asset sha256 ($got) for v$ver"
      else
        echo "live sha256 OK for ${tool,,} v$ver"
      fi
    else
      err "could not download pinned ${tool,,} asset v$ver (bad version pin?)"
    fi
  done
fi

# --- 4: internal version-pin consistency ------------------------------------
# Match real pin contexts only: `ref: vX[.Y.Z]` (checkout/uses refs) and
# `uses: …@vX[.Y.Z]` (reusable-workflow refs). Anchoring `uses:` avoids
# matching version strings mentioned in prose comments. Every internal pin
# must reference the SAME tag, so a half-finished release bump can't ship.
mapfile -t pins < <(grep -rhoE '(ref: v[0-9]+(\.[0-9]+)*|uses:[^#]*@v[0-9]+(\.[0-9]+)*)' \
  .github/workflows/*.yml templates/*.yml \
  | grep -oE 'v[0-9]+(\.[0-9]+)*' | sort -u)
if [ "${#pins[@]}" -eq 0 ]; then
  err "no internal vN pins found"
elif [ "${#pins[@]}" -ne 1 ]; then
  err "mixed internal version pins (half-finished release bump?): ${pins[*]}"
else
  echo "internal pin: ${pins[0]}"
  # Release gate: when cutting a tag, assert the single internal pin equals the
  # tag being released — catches "tagged vX but pins still say vX-1", which the
  # self-consistency check above cannot see. Opt-in via EXPECT_PIN_TAG.
  if [ -n "${EXPECT_PIN_TAG:-}" ] && [ "${pins[0]}" != "$EXPECT_PIN_TAG" ]; then
    err "internal pin (${pins[0]}) != release tag ($EXPECT_PIN_TAG) — run scripts/release.sh $EXPECT_PIN_TAG"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "pin check FAILED" >&2
  exit 1
fi
echo "pin check OK"
