#!/usr/bin/env bash
# Validates KEY=value lines and prints them, suitable for appending to
# $GITHUB_ENV. Reads from $EXTRA_ENV (or $1). Diagnostics go to stderr so they
# never contaminate that.
#
# Lives here rather than inline in node-ci.yaml so tests/test-extra-env.sh can
# exercise the real thing. A test holding a copy of the logic tests the copy.
#
# This is the one place a caller's string reaches something the shared workflow
# executes, so it fails closed on anything it does not recognise. A malformed
# line is an error rather than a skip: a line that silently does nothing is
# worse than a red run, because it looks like the setting took effect.
set -euo pipefail

EXTRA_ENV="${1:-${EXTRA_ENV:-}}"

# Two passes: validate every line, then print. Streaming would append the good
# lines that precede a bad one to $GITHUB_ENV before exiting non-zero, leaving
# the environment half-applied. The job fails either way, but "rejected" should
# mean nothing was written -- tests/test-extra-env.sh asserts exactly that.
#
# Buffered in a string rather than an array so this runs on bash 3.x too. The
# runner has bash 5, but macOS ships 3.2, and a script that only executes in CI
# is a script nobody can test before pushing.
validated=""

# Multi-line values are deliberately unsupported. $GITHUB_ENV has a heredoc
# form for them, but a parser that accepts it is a parser that can be talked
# into writing arbitrary variables by the value it was handed.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    # GITHUB_* and ACTIONS_* steer the runner itself rather than the build.
    # Nothing a caller legitimately needs lives under those prefixes.
    GITHUB_*|ACTIONS_*)
      echo "::error::extra-env refuses to set a reserved variable: ${line%%=*}" >&2
      exit 1 ;;
    # A shell glob, not a regex: [A-Za-z_] matches one leading character, and
    # the * before = allows the rest of the name. This rejects a leading digit,
    # a leading space, and a line with no = at all.
    [A-Za-z_]*=*) ;;
    *)
      echo "::error::extra-env takes KEY=value per line, got: $line" >&2
      exit 1 ;;
  esac
  validated="${validated}${line}"$'\n'
  # Logged during validation rather than in a second pass over $validated:
  # stderr is not $GITHUB_ENV, so there is nothing to hold back, and a trailing
  # empty read in a second loop trips `set -e` on the final short-circuit.
  echo "set ${line%%=*}" >&2
done <<< "$EXTRA_ENV"

# printf rather than echo, and only when there is something to write, so an
# empty input appends nothing at all rather than a blank line. $validated
# already carries its own trailing newline per line.
if [ -n "$validated" ]; then
  printf '%s' "$validated"
fi
