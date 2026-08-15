# Progress: A uv install path for `python-ci.yaml`

## Current Status: In Progress — both PRs open, both green, awaiting merge

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| 1. `python-ci.yaml` uv path (`v1.4.0`) | In Review | 2026-08-15 | jcwearn/workflows#14. actionlint, shellcheck, tests all green |
| 2. `jcwearn/resume` conforms and calls it | In Review | 2026-08-15 | jcwearn/resume#10. Green against #14's head; needs the temporary pin reverted once `v1` moves |

## Verification

**The uv path is proven end to end**, not inferred. `resume`#10 pins `ci.yml` to this branch's
head so its run exercises the real thing rather than going red on v1.3.2's `pip install`:

```
Package manager: uv
uv sync --locked -> Resolved 11 packages, Installed 9 packages
8 files already formatted        # ruff format --check
131 passed in 0.79s              # pytest
```

**The pip path is the actual regression risk here**, since no existing consumer has run against
this branch. The only new logic on that path is the detect step's branch selection, exercised
against repo-shaped fixtures:

| Fixture | Result |
|---|---|
| `requirements*.txt` + `.python-version` (the `withjoy-exporter` shape) | `pip` |
| `requirements-dev.txt`, no `.python-version` | `pip` — setup-python still owns that error, unchanged |
| `uv.lock` + `.python-version` (the `resume` shape) | `uv`, `python-version=3.13` |
| `uv.lock`, no `.python-version` | exit 1, `::error::` naming `uv python pin` |
| **both** manifests | `uv` — the documented precedence |
| neither | exit 1, `::error::` |
| `.python-version` containing `"  3.13 \n"` | `uv`, `python-version=3.13` — whitespace trimmed |

No existing consumer's behaviour changes: every one of them lands in the `pip` row.

## Handoff Notes

**Merge order matters.** #14 first, then `self-release` cuts `v1.4.0` and repoints `v1`, then
revert `resume`#10's last commit (`TEMPORARY: pin ci.yml to jcwearn/workflows#14`) so `@v1`
ships, then merge #10. Merging #10 first would ship a digest pin to an unmerged branch.

**No new `tests/test-*.sh`.** That harness covers the composite actions' shell scripts; there is
no harness for the reusable workflows themselves, and building one is out of scope. The fixture
table above was run ad hoc for this change rather than committed — worth turning into a real
`tests/test-detect-package-manager.sh` if the detect step ever grows a third branch (poetry,
pdm), which is exactly when its rules stop being obvious.

**Decisions worth not re-litigating** (rationale in `plan.md` and in the workflow's own comments):

- Detection over a `package-manager:` input — the lockfile is the declaration, and the reversal
  is asymmetric (adding an override input later is minor; removing one is major).
- `uv.lock` wins when both manifests are present. `uv export > requirements.txt` for a container
  build is a normal thing to have done, so the ambiguity is a real state rather than a mistake.
- `$GITHUB_PATH` over a `uv run` prefix — the prefix is unquotable on the pip path (empty
  `argv[0]`), so it cannot pass the shellcheck this repo's own CI runs.
- No `uv lock --check` counterpart to node-ci's lockfile diff — re-resolving consults the live
  index, so it would go red on untouched repos.

**The README taxonomy was amended, not just applied**: "new behaviour that can only activate on
the presence of a repo file no existing caller has" is now written down as minor, so the next
judgement call of this shape is precedent rather than argument.

**What Phase 2 turned out to need**, for the record — `resume` had no `.python-version`, no
`ruff.toml`, no dev group, and no tests:

- `ruff==0.16.3` (matching `withjoy-exporter`, so Renovate bumps both together), `pytest==9.1.1`.
- `.python-version` → `3.13`. No container there, so the pin tracks the local toolchain.
- Exactly **one** `ruff check` finding (`EXE001`), against `withjoy-exporter`'s 21.
- `[tool.pytest.ini_options] pythonpath = ["."]` is load-bearing: `resume`'s `uv.lock` records
  `source = { virtual = "." }`, so uv never installs the project and `render.py` is not
  importable from site-packages. Without it, pytest's prepend import mode puts `tests/` on
  `sys.path` but not the repo root. **Any future uv consumer that is a virtual project hits
  this**, so it belongs in the README if a second one appears.
