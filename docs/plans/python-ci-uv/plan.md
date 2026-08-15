# Plan: A uv install path for `python-ci.yaml`

## Context

`withjoy-exporter` #44 was billed as completing the migration — every repo calling either
`node-ci.yaml` or `python-ci.yaml`. One repo was missed, and it turned out not to fit.

`jcwearn/resume` is a Python + LaTeX pipeline whose CI does not lint, format-check, or test.
Its two workflows (`build.yaml`, `publish.yaml`) are Tectonic build gates: they compile every
resume variant and fail if one spills past `MAX_PAGES`. Nothing has ever scrutinised
`render.py` — ~400 lines carrying all the LaTeX escaping, date parsing, and variant filtering
— as code. A content bug that still fits on two pages ships green.

It cannot call `python-ci.yaml` as it stands. That workflow installs with
`pip install -r requirements-dev.txt`, and `resume`'s single source of dependency truth is a
committed `uv.lock` (`source = { virtual = "." }`); its `Makefile` is built on
`PY := uv run --quiet python`. Adding `requirements*.txt` there would create a second
manifest that CI reads while the laptop reads the other — the same class of mistake #44
called out when CI ran Python 3.14 against a 3.12.3 container.

So the shared workflow grows a second install path, and `resume` becomes its first consumer.

## Design

**Detection, not an input.** A repo says which path it wants by committing a `uv.lock`, the
same way it says which interpreter it runs by committing `.python-version`. There is no
`package-manager:` input, because it would be a second and forgeable copy of a fact already
on disk, and copies drift — a repo setting `package-manager: pip` while holding only a
`uv.lock` fails as a confusing red run, where reading the tree cannot be wrong.

The reversal is asymmetric, which settles the close call: adding an override input later is a
minor bump, removing one later is a major. Ship detection; the door stays open.

**Both files present → uv wins**, and that is a real state rather than a tie to break.
`uv export > requirements.txt` to feed a container build leaves a repo holding both, and the
lock is the more specific claim.

**The branch is at setup only.** `Lint`, `Format`, and `Test` stay unconditional and
byte-identical to v1.3.2, because the two install paths converge on one postcondition — the
tools are on `PATH` — rather than the check steps learning how they got there. On the uv path
that means `uv sync --locked` followed by prepending `.venv/bin` to `$GITHUB_PATH`.

Two alternatives were considered and rejected:

- **A `RUN=` / `RUN=uv run` prefix in `$GITHUB_ENV`.** Cannot be written in a form shellcheck
  accepts: `$RUN ruff check .` is SC2086, and quoting it is unavailable because an empty
  `"$RUN"` is an empty `argv[0]`. It also makes the log show a command that is not the one
  that ran, and a bare `uv run` implicitly re-syncs the environment the previous step pinned.
- **`if:` on all six steps.** Gating setup is fine — the branch is the entire point of those
  steps. Gating the checks states the rule three more times and puts grey "skipped" entries
  where the actual verification should be.

**`.python-version` stays mandatory on both paths, but only one enforces itself.**
`setup-python` errors on a missing `python-version-file`; `uv sync` would quietly fall back to
`requires-python` and resolve an interpreter nobody chose — the `withjoy-exporter` failure
mode this file's header already warns about. So the detect step says it instead, with an
`::error::` annotation. This is the one contract line where "a tool already fails with a good
message" does not hold, and it is worth knowing that.

**No `uv lock --check` step, deliberately.** `node-ci.yaml` recomputes `package-lock.json` and
diffs it; there is no uv counterpart on purpose. `npm install --package-lock-only` is a pure
function of the manifest and the lock, but re-resolving with uv consults the index *as it is
today*, so a newly published transitive dependency would turn that check red on a repo nobody
touched. `uv sync --locked` already asserts the lock is current with `pyproject.toml`, which
is the check that matters.

## Phases

### Phase 1: `python-ci.yaml` gains the uv path — `v1.4.0`

- Files: `.github/workflows/python-ci.yaml`, `templates/ci-python.yaml`, `README.md`
- Detect step, two gated setup steps, two gated install steps, three unchanged check steps.
- `astral-sh/setup-uv@20cfd1bf945f4377ade1205e4dbc17946fc9a30d # v10.0.1` — an exact version
  in the trailing comment rather than a series, because astral-sh stopped publishing a
  floating major tag after v7. The one pin in this repo that does not read `# vN`.
- **Minor**, not major: no input removed, renamed, or made required; `permissions:`
  unchanged (`contents: read` still covers setup-uv's release lookups under the ambient
  `github.token`); the file is not renamed. No existing caller has a `uv.lock`, so none can
  observe the change. The README's minor clause is amended to make this precedent.
- Acceptance: `ci.yaml` green (actionlint covers `templates/*.yaml` too); merged with
  `release:minor`; `self-release.yaml` cuts `v1.4.0` and repoints `v1`.

### Phase 2: `jcwearn/resume` conforms and calls it

- Files: `.python-version`, `ruff.toml`, `pyproject.toml`, `uv.lock`, `tests/`,
  `.git-blame-ignore-revs`, `.github/workflows/ci.yml`, `README.md`
- Commits ordered so the reformat is blame-ignorable alone: config and pins → fix
  `ruff check` findings → `ruff format .` by itself → `.git-blame-ignore-revs` → the pytest
  suite → the caller workflow.
- `pytest` exits 5 on zero collected tests, so real tests are a precondition rather than a
  nicety. `render.py`'s escaping, date parsing, and variant filtering are the targets — in
  particular the documented invariant that `emphasize` reorders only *within* a priority
  tier, which nothing currently checks.
- `build.yaml` and `publish.yaml` are untouched. A Tectonic build is not a Python CI step;
  `borderline`'s `ci-extras.yml` is the precedent, and on a PR the shared job now runs in
  parallel with them rather than extending them.
- Acceptance: the run log reads `Package manager: uv`, the pip steps skip, `uv sync --locked`
  succeeds, and lint/format/test are green — read rather than trusted, since it is the uv
  path's first real execution.

## Sequencing

Phase 1 must merge **and** `v1` must move before Phase 2 can pass. Until then `@v1` resolves
to v1.3.2, which has no uv path and dies at `pip install -r requirements-dev.txt`. To test
Phase 2 early, point its `uses:` at the Phase 1 branch SHA and flip it back to `@v1` before
merge.

There is no bootstrap problem beyond that: the change is entirely inside one workflow file,
with no new composite action that `@v1` would not yet contain.
