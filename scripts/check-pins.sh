#!/usr/bin/env bash
# Pin-consistency guard. Fails (non-zero) if any of these invariants break:
#   1. All OPENCODE_VERSION values across the workflows are identical.
#   2. All OPENCODE_SHA256 values are identical.
#   3. The pinned sha256 matches the actual release asset on GitHub
#      (catches "bumped version, forgot to update the hash"). Skip with
#      CHECK_PINS_OFFLINE=1.
#   4. Every internal version pin (`ref: vN`, `@vN`) shares one major N, so a
#      half-finished release bump can't ship.
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
