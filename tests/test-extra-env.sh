#!/usr/bin/env bash
# Exercises .github/actions/extra-env/extra-env.sh -- the real script the
# action runs, not a copy of it.
#
# Portable to bash 3.2 on purpose: the runner has bash 5, but macOS ships 3.2,
# and a script that only executes in CI is a script nobody can test before
# pushing.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.github/actions/extra-env/extra-env.sh"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }

# Accepts, and prints exactly the expected $GITHUB_ENV content.
accepts() {
  desc="$1"; input="$2"; want="$3"
  if got="$(EXTRA_ENV="$input" "$SCRIPT" 2>/dev/null)"; then
    if [ "$got" = "$want" ]; then
      ok "$desc"
    else
      bad "$desc -- printed '$got', wanted '$want'"
    fi
  else
    bad "$desc -- expected accept, got a rejection"
  fi
}

# Rejects with a non-zero exit and writes nothing to stdout, so a failed parse
# can never half-populate $GITHUB_ENV.
rejects() {
  desc="$1"; input="$2"
  if got="$(EXTRA_ENV="$input" "$SCRIPT" 2>/dev/null)"; then
    bad "$desc -- expected reject, got accept"
  elif [ -n "$got" ]; then
    bad "$desc -- rejected but printed '$got'"
  else
    ok "$desc"
  fi
}

echo "accepts:"
accepts "the jackson-wearn case"      'SKIP_RESUME_FETCH=1'  'SKIP_RESUME_FETCH=1'
accepts "two variables"               $'A=1\nB=2'            $'A=1\nB=2'
accepts "leading underscore"          '_PRIVATE=x'           '_PRIVATE=x'
accepts "empty value"                 'EMPTY='               'EMPTY='
accepts "value containing ="          'URL=a=b'              'URL=a=b'
accepts "value with spaces"           'MSG=hello world'      'MSG=hello world'
accepts "blank lines are skipped"     $'A=1\n\nB=2'          $'A=1\nB=2'
accepts "digits after first char"     'NODE_ENV2=ci'         'NODE_ENV2=ci'
accepts "empty input is a no-op"      ''                     ''

echo "rejects:"
rejects "reserved GITHUB_ prefix"     'GITHUB_TOKEN=leak'
rejects "reserved ACTIONS_ prefix"    'ACTIONS_RUNNER_DEBUG=1'
rejects "no equals sign"              'JUST_A_WORD'
rejects "leading digit in name"       '9LIVES=x'
rejects "leading equals"              '=novalue'
rejects "a bare shell command"        'rm -rf /'
rejects "leading space before name"   ' A=1'

# The last one is the property that matters most: a bad line anywhere aborts
# the whole thing rather than exporting the good lines that preceded it.
rejects "a later line is malformed"   $'A=1\nnope'

echo
echo "pass=${pass} fail=${fail}"
[ "$fail" -eq 0 ]
