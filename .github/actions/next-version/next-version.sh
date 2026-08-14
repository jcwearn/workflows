#!/usr/bin/env bash
# Computes the next semver tag from the tags already in the repository.
#
# Takes the bump type as $1 (or $BUMP), reads `git tag --list` in the current
# working directory, and prints version/semver/minor_series/major/major_bare/
# previous on stdout, suitable for appending to $GITHUB_OUTPUT.
#
# Lives here rather than inline in release.yaml so tests/test-next-version.sh
# can run it against real throwaway repositories.
set -euo pipefail

BUMP="${1:-${BUMP:-}}"

# Full triples only. The moving vX alias is a tag too, and sorting the raw list
# would eventually surface `v2` above `v1.9.9`.
latest=$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1) || true

previous="$latest"                 # empty on the very first release
base="${latest:-v0.0.0}"
IFS=. read -r major minor patch <<<"${base#v}"

case "$BUMP" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "::error::unknown bump '${BUMP}'. Expected major, minor, or patch." >&2; exit 1 ;;
esac

version="v${major}.${minor}.${patch}"

if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  echo "::error::Tag ${version} already exists. Two releases raced, or a tag was created by hand." >&2
  exit 1
fi

echo "version=${version}"
echo "semver=${major}.${minor}.${patch}"
echo "minor_series=${major}.${minor}"
echo "major=v${major}"
echo "major_bare=${major}"
echo "previous=${previous}"
echo "${base} -> ${version}" >&2
