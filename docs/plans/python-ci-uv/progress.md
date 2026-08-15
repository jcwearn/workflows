# Progress: A uv install path for `python-ci.yaml`

## Current Status: In Progress

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| 1. `python-ci.yaml` uv path (`v1.4.0`) | In Progress | 2026-08-15 | Workflow, template, and README written. actionlint green locally. Awaiting review and a `release:minor` merge |
| 2. `jcwearn/resume` conforms and calls it | Not Started | — | Blocked on `v1` moving to `v1.4.0` |

## Handoff Notes

**Phase 1 is code-complete and locally verified.** `actionlint 1.7.12` run over
`.github/workflows/*.yaml templates/*.yaml` — the same invocation `ci.yaml` uses — exits 0.
The `shellcheck` job was not run locally (shellcheck isn't installed on this machine), but it
globs `.github/actions/*/*.sh` and `tests/*.sh`, neither of which this change touches.

**No new `tests/test-*.sh`.** That harness covers the composite actions' shell scripts; there
is no harness for the reusable workflows themselves, and building one is out of scope here.
Phase 2's PR run is the real verification of the uv path.

**Decisions worth not re-litigating** (rationale in `plan.md`, and in comments in the
workflow itself):

- Detection over a `package-manager:` input — the lockfile is the declaration, and the
  reversal is asymmetric (adding an override input later is minor; removing one is major).
- `uv.lock` wins when both manifests are present. `uv export > requirements.txt` for a
  container build is a normal thing to have done.
- `$GITHUB_PATH` over a `uv run` prefix — the prefix is unquotable on the pip path (empty
  `argv[0]`), so it cannot pass shellcheck.
- No `uv lock --check` counterpart to node-ci's lockfile diff — re-resolving consults the
  live index, so it would go red on untouched repos.

**The README taxonomy was amended**, not just applied: "new behaviour that can only activate
on the presence of a repo file no existing caller has" is now written down as minor, so the
next judgement call of this shape is precedent rather than argument.

**Phase 2 starting point.** `resume` currently has no `.python-version`, no `ruff.toml`, no
dev dependency group, and no tests at all. Pins chosen: `ruff==0.16.3` (matching
`withjoy-exporter`, so Renovate bumps both together) and `pytest==9.1.1`. `.python-version`
→ `3.13`; there is no container there, so the pin tracks the local toolchain (3.13.3).

One trap for Phase 2: `resume`'s `uv.lock` records `source = { virtual = "." }`, so uv never
installs the project and `render.py` is not importable from site-packages. Without
`[tool.pytest.ini_options] pythonpath = ["."]`, pytest's prepend import mode puts `tests/` on
`sys.path` but not the repo root, and `import render` fails.
