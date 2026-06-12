#!/usr/bin/env bash
# Pin bumper for release preparation. Edits every internal ref:/uses:@<tag> pin
# to the new tag and verifies the result. Does NOT commit, tag, or push.
#
# Usage: scripts/release.sh <new-tag>
#   e.g. scripts/release.sh v0.0.4
set -euo pipefail

cd "$(dirname "$0")/.."

# --- arg validation ----------------------------------------------------------
new_tag="${1:-}"
if [[ ! "$new_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh v<MAJOR>.<MINOR>.<PATCH>" >&2
  exit 1
fi

# --- working tree must be clean ----------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash changes first" >&2
  exit 1
fi

# --- detect current tag from anchored pin contexts ---------------------------
pin_files=(.github/workflows/review.yml .github/workflows/commands.yml templates/caller-review.yml templates/caller-commands.yml)

mapfile -t current_pins < <(grep -rhoE \
  '(ref: v[0-9]+(\.[0-9]+)*|uses:[^#]*@v[0-9]+(\.[0-9]+)*)' \
  "${pin_files[@]}" \
  | grep -oE 'v[0-9]+(\.[0-9]+)*' | sort -u)

if [ "${#current_pins[@]}" -eq 0 ]; then
  echo "error: no internal version pins found in ${pin_files[*]}" >&2
  exit 1
fi
if [ "${#current_pins[@]}" -ne 1 ]; then
  echo "error: mixed internal version pins (half-finished bump?): ${current_pins[*]}" >&2
  exit 1
fi
current_tag="${current_pins[0]}"

# --- refuse a no-op ----------------------------------------------------------
if [ "$new_tag" = "$current_tag" ]; then
  echo "error: new tag ($new_tag) is the same as the current tag — nothing to do" >&2
  exit 1
fi

echo "bumping $current_tag -> $new_tag in ${pin_files[*]}"

# --- replace pins in anchored contexts only ----------------------------------
# Two anchored forms:
#   ref: <current>        ->  ref: <new>
#   @<current>            ->  @<new>
# Using sed with word-boundary-free literals is safe here because we match
# only within the two known syntactic contexts.
for f in "${pin_files[@]}"; do
  sed -i.bak \
    -e "s|ref: ${current_tag}|ref: ${new_tag}|g" \
    -e "s|@${current_tag}|@${new_tag}|g" \
    "$f"
  rm -f "${f}.bak"
done

# --- verify ------------------------------------------------------------------
echo ""
echo "running pin check..."
CHECK_PINS_OFFLINE=1 bash scripts/check-pins.sh

echo ""
echo "running actionlint..."
actionlint .github/workflows/*.yml

# --- summary -----------------------------------------------------------------
echo ""
echo "--- diff summary ---"
git diff --stat

echo ""
echo "next steps:"
echo "  1. Review the diff:       git diff"
echo "  2. Commit:                git commit -am 'chore: pin internal refs to exact ${new_tag}'"
echo "  3. Push and wait for CI:  git push"
echo "  4. Cut the release tag:   git tag -a ${new_tag} -m 'Release ${new_tag}'"
echo "  5. Push the tag:          git push origin ${new_tag}"
