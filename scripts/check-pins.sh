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
#       half-finished release bump can't ship.
#
# Run from the repo root: scripts/check-pins.sh
set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOWS=(.github/workflows/review.yml .github/workflows/commands.yml)
fail=0
err() { echo "::error::$*" >&2; fail=1; }

# --- 1 & 2: OPENCODE_VERSION / OPENCODE_SHA256 internal consistency ----------
mapfile -t versions < <(grep -rhoE 'OPENCODE_VERSION="[^"]+"' "${WORKFLOWS[@]}" \
  | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
mapfile -t shas < <(grep -rhoE 'OPENCODE_SHA256="[0-9a-f]+"' "${WORKFLOWS[@]}" \
  | sed -E 's/.*="([^"]+)"/\1/' | sort -u)

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
  url="https://github.com/anomalyco/opencode/releases/download/v${ver}/opencode-linux-x64.tar.gz"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
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

# Single source-of-truth tool list — used by BOTH the consistency loop and the
# live-verification loop below. Add/remove tools here only.
TOOLS=(OPENGREP GITLEAKS OSV_SCANNER RIPGREP RUFF GOLANGCI OXLINT SHELLCHECK HADOLINT ACTIONLINT ZIZMOR TRIVY TYPOS ASTGREP)

# Per-tool: assert exactly one distinct VERSION and one distinct SHA256.
# URL templates use $ver below (set per-tool).
declare -A TOOL_URL
TOOL_URL[OPENGREP]="https://github.com/opengrep/opengrep/releases/download/v\${ver}/opengrep_manylinux_x86"
TOOL_URL[GITLEAKS]="https://github.com/gitleaks/gitleaks/releases/download/v\${ver}/gitleaks_\${ver}_linux_x64.tar.gz"
TOOL_URL[OSV_SCANNER]="https://github.com/google/osv-scanner/releases/download/v\${ver}/osv-scanner_linux_amd64"
TOOL_URL[RIPGREP]="https://github.com/BurntSushi/ripgrep/releases/download/\${ver}/ripgrep-\${ver}-x86_64-unknown-linux-musl.tar.gz"
TOOL_URL[RUFF]="https://github.com/astral-sh/ruff/releases/download/\${ver}/ruff-x86_64-unknown-linux-gnu.tar.gz"
TOOL_URL[GOLANGCI]="https://github.com/golangci/golangci-lint/releases/download/v\${ver}/golangci-lint-\${ver}-linux-amd64.tar.gz"
TOOL_URL[OXLINT]="https://github.com/oxc-project/oxc/releases/download/\${ver}/oxlint-x86_64-unknown-linux-gnu.tar.gz"
TOOL_URL[SHELLCHECK]="https://github.com/koalaman/shellcheck/releases/download/\${ver}/shellcheck-\${ver}.linux.x86_64.tar.xz"
TOOL_URL[HADOLINT]="https://github.com/hadolint/hadolint/releases/download/\${ver}/hadolint-linux-x86_64"
TOOL_URL[ACTIONLINT]="https://github.com/rhysd/actionlint/releases/download/v\${ver}/actionlint_\${ver}_linux_amd64.tar.gz"
TOOL_URL[ZIZMOR]="https://github.com/zizmorcore/zizmor/releases/download/\${ver}/zizmor-x86_64-unknown-linux-gnu.tar.gz"
TOOL_URL[TRIVY]="https://github.com/aquasecurity/trivy/releases/download/v\${ver}/trivy_\${ver}_Linux-64bit.tar.gz"
TOOL_URL[TYPOS]="https://github.com/crate-ci/typos/releases/download/\${ver}/typos-\${ver}-x86_64-unknown-linux-musl.tar.gz"
TOOL_URL[ASTGREP]="https://github.com/ast-grep/ast-grep/releases/download/\${ver}/app-x86_64-unknown-linux-gnu.zip"

for tool in "${TOOLS[@]}"; do
  mapfile -t tool_versions < <(grep -hoE "${tool}_VERSION=\"[^\"]+\"" "$REVIEW_WF" \
    | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
  mapfile -t tool_shas < <(grep -hoE "${tool}_SHA256=\"[0-9a-f]+\"" "$REVIEW_WF" \
    | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
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
mapfile -t rules_refs < <(grep -hoE 'OPENGREP_RULES_REF="[^"]+"' "$REVIEW_WF" \
  | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
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
  trap 'rm -f "$tmp_scanner"' EXIT
  for tool in "${TOOLS[@]}"; do
    mapfile -t tv < <(grep -hoE "${tool}_VERSION=\"[^\"]+\"" "$REVIEW_WF" \
      | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
    mapfile -t ts < <(grep -hoE "${tool}_SHA256=\"[0-9a-f]+\"" "$REVIEW_WF" \
      | sed -E 's/.*="([^"]+)"/\1/' | sort -u)
    ver="${tv[0]}"
    want="${ts[0]}"
    # Expand the URL template (uses $ver).
    # shellcheck disable=SC2059
    url="$(eval "echo \"${TOOL_URL[$tool]}\"")"
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
fi

if [ "$fail" -ne 0 ]; then
  echo "pin check FAILED" >&2
  exit 1
fi
echo "pin check OK"
