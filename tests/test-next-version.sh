#!/usr/bin/env bash
# Exercises .github/actions/next-version/next-version.sh against real throwaway
# git repositories, so `git tag --list` and the moving-alias filtering are
# actually tested rather than simulated.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../.github/actions/next-version/next-version.sh"
FAILED=0

# Prints just the `version=` line, which is what every assertion below is about.
version_for() { "$SCRIPT" "$1" 2>/dev/null | sed -n 's/^version=//p'; }

t() {
  desc="$1"; want="$2"; got="$3"
  if [ "$got" = "$want" ]; then printf 'PASS  %-48s %s\n' "$desc" "$got"
  else printf 'FAIL  %-48s got=%s want=%s\n' "$desc" "$got" "$want"; FAILED=1; fi
}

D="$(mktemp -d)"
cd "$D" || exit 1
git init -q .
git config user.email test@example.com
git config user.name test
git commit -q --allow-empty -m c1

t "no tags yet, patch" "v0.0.1" "$(version_for patch)"
t "no tags yet, minor" "v0.1.0" "$(version_for minor)"
t "no tags yet, major" "v1.0.0" "$(version_for major)"

git tag -a v1.0.0 -m x
git tag -a v1 -m x
t "v1.0.0 plus moving v1, patch" "v1.0.1" "$(version_for patch)"
t "v1.0.0 plus moving v1, minor" "v1.1.0" "$(version_for minor)"
t "v1.0.0 plus moving v1, major" "v2.0.0" "$(version_for major)"

# The ordering trap: a lexical sort puts v1.9.9 above v1.10.0.
git tag -a v1.9.9 -m x
git tag -a v1.10.0 -m x
t "v1.10.0 beats v1.9.9 (numeric, not lexical)" "v1.10.1" "$(version_for patch)"

# A moving v2 alias must not be mistaken for the newest full triple -- the
# answer must stay derived from v1.10.0.
git tag -a v2 -m x
t "moving v2 alias ignored" "v1.10.1" "$(version_for patch)"

git tag -a v2.0.0 -m x
t "a real v2.0.0 does count" "v2.0.1" "$(version_for patch)"

# Tags that must not parse as releases.
git tag -a v2.0.0-rc1 -m x
git tag -a latest -m x
git tag -a v1.2 -m x
t "prerelease, latest, two-part all ignored" "v2.0.1" "$(version_for patch)"

# Refuses to reuse an existing tag rather than racing another release to it.
git tag -a v2.0.1 -m x
out="$("$SCRIPT" patch 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "Tag v2.0.2 already exists"; then
  printf 'FAIL  %-48s unexpectedly reported v2.0.2\n' "duplicate tag guard"; FAILED=1
elif [ "$rc" = 0 ]; then
  printf 'PASS  %-48s %s\n' "advances past an existing tag" "$(printf '%s' "$out" | sed -n 's/^version=//p')"
else
  printf 'FAIL  %-48s rc=%s out=[%s]\n' "duplicate tag guard" "$rc" "$out"; FAILED=1
fi

# An unknown bump must fail loudly, never silently republish the same version.
out="$("$SCRIPT" pathc 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "unknown bump 'pathc'"; then
  printf 'PASS  %s\n' "unknown bump rejected"
else
  printf 'FAIL  %-48s rc=%s out=[%s]\n' "unknown bump rejected" "$rc" "$out"; FAILED=1
fi

cd /
rm -rf "$D"
echo
if [ "$FAILED" = 0 ]; then echo "next-version: all passed"; else echo "next-version: FAILURES"; exit 1; fi
