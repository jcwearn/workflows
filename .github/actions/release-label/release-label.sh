#!/usr/bin/env bash
# Decides whether a merged PR cuts a release, and which component to bump.
#
# Reads a JSON array of PR label names from $LABELS (or $1) and prints
# `release=` and `bump=` on stdout, suitable for appending to $GITHUB_OUTPUT.
# Diagnostics go to stderr so they never contaminate that.
#
# Lives here rather than inline in release.yaml so tests/test-release-label.sh
# can exercise the real thing. A test holding a copy of the logic tests the
# copy.
set -euo pipefail

LABELS="${1:-${LABELS:-}}"
ALLOWED="release:major, release:minor, release:patch, release:skip"

# A read loop rather than `mapfile` so this runs on bash 3.x too. The runner
# has bash 5, but macOS ships 3.2, and a script that only executes in CI is a
# script nobody can test before pushing.
found=()
while IFS= read -r line; do
  if [ -n "$line" ]; then found+=("$line"); fi
done < <(printf '%s' "$LABELS" | jq -r '.[] | select(startswith("release:"))')

if [ "${#found[@]}" -ne 1 ]; then
  echo "::error::PR must carry exactly one of ${ALLOWED} -- found ${#found[@]}: ${found[*]:-none}" >&2
  exit 1
fi

# The default arm is the whole point of this block. Its absence in the
# implementation this replaces is what let an unrecognised suffix fall through
# to "bump nothing" and then die on a duplicate tag, which reads as a flaky
# release rather than as a mislabelled PR.
case "${found[0]}" in
  release:major) bump="major" ;;
  release:minor) bump="minor" ;;
  release:patch) bump="patch" ;;
  release:skip)  bump="skip"  ;;
  *) echo "::error::'${found[0]}' is not a release label. Allowed: ${ALLOWED}." >&2; exit 1 ;;
esac

if [ "$bump" = skip ]; then
  echo "release=false"
  echo "No version cut: PR is labelled release:skip." >&2
else
  echo "release=true"
fi
echo "bump=${bump}"
