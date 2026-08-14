#!/usr/bin/env bash
# Exercises .github/actions/release-label/release-label.sh -- the real script
# the action runs, not a copy of its logic.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../.github/actions/release-label/release-label.sh"
FAILED=0

t() {
  desc="$1"; labels="$2"; want_rc="$3"; want="$4"
  got="$("$SCRIPT" "$labels" 2>&1)"; rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    printf 'FAIL  %s\n      rc=%s want_rc=%s\n      got=[%s]\n      want=[%s]\n' \
      "$desc" "$rc" "$want_rc" "$got" "$want"
    FAILED=1
  fi
}

ERR_ONE="::error::PR must carry exactly one of release:major, release:minor, release:patch, release:skip -- found"

t "major"                 '["release:major"]'  0 'release=true
bump=major'
t "minor"                 '["release:minor"]'  0 'release=true
bump=minor'
t "patch"                 '["release:patch"]'  0 'release=true
bump=patch'
t "skip does not release" '["release:skip"]'   0 'release=false
No version cut: PR is labelled release:skip.
bump=skip'
t "release label among unrelated ones" '["bug","release:patch","documentation"]' 0 'release=true
bump=patch'

t "no labels at all"      '[]'                 1 "$ERR_ONE 0: none"
t "only unrelated labels" '["bug","docs"]'     1 "$ERR_ONE 0: none"
t "two release labels"    '["release:major","release:patch"]' 1 \
  "$ERR_ONE 2: release:major release:patch"

# The regression that motivated the default arm: the implementation this
# replaces accepted any release:* suffix and fed it to a case with no *)
# branch, so this silently became "bump nothing" and then died on a duplicate
# tag -- surfacing as a flaky release rather than a mislabelled PR.
t "unrecognised release: suffix" '["release:pathc"]' 1 \
  "::error::'release:pathc' is not a release label. Allowed: release:major, release:minor, release:patch, release:skip."
t "release:none is not a skip alias" '["release:none"]' 1 \
  "::error::'release:none' is not a release label. Allowed: release:major, release:minor, release:patch, release:skip."

# A substring-grep implementation matched this; jq startswith does not.
t "lookalike prefix" '["prerelease:patch"]' 1 "$ERR_ONE 0: none"

echo
if [ "$FAILED" = 0 ]; then echo "release-label: all passed"; else echo "release-label: FAILURES"; exit 1; fi
