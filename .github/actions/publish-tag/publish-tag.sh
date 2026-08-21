#!/usr/bin/env bash
# Creates the immutable vX.Y.Z tag, and optionally re-points the moving vX
# alias, in a repository that has already been checked out with fetch-depth: 0
# and push credentials.
#
# Reads VERSION, MAJOR, SHA and MOVE_MAJOR from the environment. Lives here
# rather than inline in release.yaml for the same reason next-version.sh does:
# tests/ can only exercise a standalone script, and both of the failure modes
# below were found the expensive way.
#
# Not `set -e`. A rejected push is the interesting case, and the whole point of
# this script is to say what it means before it exits.
set -uo pipefail

VERSION="${VERSION:?}"
MAJOR="${MAJOR:?}"
SHA="${SHA:?}"
MOVE_MAJOR="${MOVE_MAJOR:-false}"

# The plan job computed VERSION from the tag list at the time it ran. "Re-run
# failed jobs" does not re-run a job that succeeded, so a retry of a failed
# publish arrives carrying whatever plan decided the first time -- which
# another release may have published since. Without this the symptom is
# `fatal: tag 'vX.Y.Z' already exists`, which reads as a bug in next-version.sh
# and sends you nowhere near the truth.
if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
  echo "::error::${VERSION} already exists at $(git rev-parse --short "refs/tags/${VERSION}^{commit}"). The plan job's outputs are stale -- this is a re-run of the failed jobs of a run whose Plan was cached, and another release has published this version in the meantime. Re-run ALL jobs so the version is recomputed." >&2
  exit 1
fi

# GitHub refuses any write -- git push, POST git/refs, and the releases API
# alike -- that would put .github/workflows content into the repository that
# is not already on the default branch tip, unless the token carries
# `workflows`. GITHUB_TOKEN never can: there is no `permissions: workflows:`
# key to grant it. Tagging trips this whenever a later PR changed a workflow
# file between the merge and this push, which is why it looks intermittent.
diagnose_push() {
  ref="$1"; out="$2"
  printf '%s\n' "$out" >&2
  # Matched without the backticks GitHub puts around `workflows`, which also
  # picks up the OAuth-App wording a laptop gets for the same refusal.
  case "$out" in
    *"refusing to allow a"*)
      echo "::error::Pushing ${ref} was refused because ${SHA} carries .github/workflows content that is not on the default branch tip -- another PR merged and changed a workflow file before this release pushed. GITHUB_TOKEN cannot carry the 'workflows' permission, and the REST refs and releases APIs enforce the same rule, so there is nothing to retry. Give the caller a client-id/private-key pair for a GitHub App with contents:write and workflows:write, or cut this one by hand -- see the manual release recipe in RUNBOOK.md." >&2
      ;;
  esac
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Immutable first, and deliberately not forced: if the ref somehow exists the
# push is rejected and the release stops here rather than rewriting something a
# consumer may already have pinned.
git tag -a "$VERSION" -m "$VERSION" "$SHA" || exit 1
if ! out=$(git push origin "refs/tags/${VERSION}" 2>&1); then
  diagnose_push "$VERSION" "$out"
  exit 1
fi
echo "Pushed ${VERSION} -> ${SHA}"

if [ "$MOVE_MAJOR" != "true" ]; then
  echo "move-major-tag is off; published ${VERSION} only."
  exit 0
fi

# Re-point the moving alias. The force is confined to this one refspec --
# never a bare `git push --force`. Every immutable vX.Y.Z stays where it was.
git tag -f -a "$MAJOR" -m "${MAJOR} -> ${VERSION}" "$SHA" || exit 1
if ! out=$(git push --force origin "refs/tags/${MAJOR}" 2>&1); then
  # Reached only after vX.Y.Z pushed successfully, so this leaves a published
  # version with a stale alias rather than a torn release. Re-running the whole
  # release is not the fix -- the version is already taken; move the alias by
  # hand.
  diagnose_push "$MAJOR" "$out"
  exit 1
fi
echo "Moved ${MAJOR} -> ${VERSION}"
