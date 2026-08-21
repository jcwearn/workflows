#!/usr/bin/env bash
# Exercises .github/actions/publish-tag/publish-tag.sh against real throwaway
# repositories pushing to real bare remotes, so the push, the force-move and
# the rejection paths are actually executed rather than simulated.
#
# The rejection GitHub sends when a token lacks `workflows` is reproduced with
# a pre-receive hook on the bare remote. That is the whole reason this file
# exists: the message is the only thing standing between a future reader and
# the afternoon that produced run 32492220999.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../.github/actions/publish-tag/publish-tag.sh"
FAILED=0

t() {
  desc="$1"; want="$2"; got="$3"
  if [ "$got" = "$want" ]; then printf 'PASS  %-48s %s\n' "$desc" "$got"
  else printf 'FAIL  %-48s got=%s want=%s\n' "$desc" "$got" "$want"; FAILED=1; fi
}

D="$(mktemp -d)"

# Leaves you inside a work tree with one commit already on the remote's main.
setup() {
  git init -q --bare "$D/$1/remote.git"
  git init -q "$D/$1/work"
  cd "$D/$1/work" || exit 1
  git config user.email test@example.com
  git config user.name test
  git remote add origin "$D/$1/remote.git"
  git commit -q --allow-empty -m c1
  git push -q origin HEAD:refs/heads/main
}

# $2 empty rejects every ref; otherwise only that one, which is how the
# "moving alias failed after the immutable tag landed" case is built.
reject_pushes() {
  cat > "$D/$1/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
only="$REJECT_ONLY"
while read -r _old _new ref; do
  if [ -z "$only" ] || [ "$ref" = "$only" ]; then
    echo " ! [remote rejected] ${ref} (refusing to allow a GitHub App to create or update workflow \`.github/workflows/ci.yaml\` without \`workflows\` permission)" >&2
    exit 1
  fi
done
exit 0
HOOK
  chmod +x "$D/$1/remote.git/hooks/pre-receive"
  # The hook reads it from the environment; a local push runs receive-pack as a
  # child of this shell, so exporting it here is enough.
  export REJECT_ONLY="${2:-}"
}

# Exact ref names only -- a substring match would let refs/tags/v1.0.1 answer
# for refs/tags/v1 and quietly pass the "alias untouched" assertions.
peeled() { git ls-remote "$D/$1/remote.git" | awk -v r="refs/tags/$2^{}" '$2 == r { print $1 }'; }
present() { git ls-remote "$D/$1/remote.git" | awk -v r="refs/tags/$2" '$2 == r { print $1 }'; }

run() {
  VERSION="$1" MAJOR="$2" SHA="$3" MOVE_MAJOR="$4" bash "$SCRIPT" 2>&1
}

# --- the ordinary release, alias left alone --------------------------------
setup patch-only
SHA1="$(git rev-parse HEAD)"
out="$(run v1.0.1 v1 "$SHA1" false)"; rc=$?
t "patch: exits 0" "0" "$rc"
t "patch: vX.Y.Z on the remote" "$SHA1" "$(peeled patch-only v1.0.1)"
t "patch: no moving alias created" "" "$(present patch-only v1)"

# --- move-major-tag, first release in a repo (no v1 to move yet) -----------
setup first-major
SHA1="$(git rev-parse HEAD)"
out="$(run v1.0.0 v1 "$SHA1" true)"; rc=$?
t "first major: exits 0" "0" "$rc"
t "first major: v1.0.0 pushed" "$SHA1" "$(peeled first-major v1.0.0)"
t "first major: v1 created too" "$SHA1" "$(peeled first-major v1)"

# --- move-major-tag over an alias that already points somewhere else -------
setup move-major
OLD="$(git rev-parse HEAD)"
git tag -a v1 -m old "$OLD" && git push -q origin refs/tags/v1
git commit -q --allow-empty -m c2
NEW="$(git rev-parse HEAD)"
out="$(run v1.1.0 v1 "$NEW" true)"; rc=$?
t "move: exits 0" "0" "$rc"
t "move: v1.1.0 pushed" "$NEW" "$(peeled move-major v1.1.0)"
t "move: v1 force-moved off the old commit" "$NEW" "$(peeled move-major v1)"

# --- the stale plan, which is what a "re-run failed jobs" produces ---------
setup stale-plan
SHA1="$(git rev-parse HEAD)"
git tag -a v1.0.1 -m already "$SHA1"     # published by another run, already fetched
out="$(run v1.0.1 v1 "$SHA1" false)"; rc=$?
t "stale: exits 1" "1" "$rc"
case "$out" in
  *"Re-run ALL jobs"*) printf 'PASS  %-48s %s\n' "stale: says to re-run all jobs" "ok" ;;
  *) printf 'FAIL  %-48s out=[%s]\n' "stale: says to re-run all jobs" "$out"; FAILED=1 ;;
esac
t "stale: nothing pushed" "" "$(present stale-plan v1.0.1)"

# --- the rejection this whole change exists for ----------------------------
setup rejected
SHA1="$(git rev-parse HEAD)"
reject_pushes rejected ""
out="$(run v1.0.1 v1 "$SHA1" false)"; rc=$?
t "rejected: exits 1" "1" "$rc"
t "rejected: nothing pushed" "" "$(present rejected v1.0.1)"
case "$out" in
  *"client-id"*"workflows:write"*) printf 'PASS  %-48s %s\n' "rejected: names the app-token remedy" "ok" ;;
  *) printf 'FAIL  %-48s out=[%s]\n' "rejected: names the app-token remedy" "$out"; FAILED=1 ;;
esac
unset REJECT_ONLY

# --- rejected only on the alias: the version is published, the alias is not -
setup alias-rejected
SHA1="$(git rev-parse HEAD)"
reject_pushes alias-rejected "refs/tags/v1"
out="$(run v1.0.1 v1 "$SHA1" true)"; rc=$?
t "alias rejected: exits 1" "1" "$rc"
t "alias rejected: vX.Y.Z still published" "$SHA1" "$(peeled alias-rejected v1.0.1)"
t "alias rejected: alias not moved" "" "$(present alias-rejected v1)"
unset REJECT_ONLY

# --- a missing input must fail loudly, never tag something unnamed ---------
setup missing-input
out="$(VERSION="" MAJOR=v1 SHA=HEAD MOVE_MAJOR=false bash "$SCRIPT" 2>&1)"; rc=$?
t "empty VERSION rejected" "1" "$rc"

cd /
rm -rf "$D"
echo
if [ "$FAILED" = 0 ]; then echo "publish-tag: all passed"; else echo "publish-tag: FAILURES"; exit 1; fi
