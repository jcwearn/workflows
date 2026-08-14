# Progress: Versioning system for `jcwearn/workflows`

## Current Status: In Progress

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| A. Labels and seed tag | Complete | 2026-08-14 | 4 labels in `workflows`, `release:skip` added to both siblings. `v1.0.0` + `v1` tagged at `d053075`, Release created on `v1.0.0` only |
| B. Consumers to `@v1` | Blocked | 2026-08-14 | Sequencing decision needed — see Handoff Notes |
| C. Land the machinery | In Progress | 2026-08-14 | Split into C1 `ci.yaml`, C2 composite actions + tests, C3 the release workflows. C1 and C2 PRs open |
| D. Docker repos | Not Started | — | `ansible-runner` first, then `withjoy-exporter` |

## Handoff Notes

### Phase C was split three ways, because of how `uses: ./` resolves

The approved plan kept the label and version logic inline in `release.yaml`.
Extracting it so tests can exercise the real code ran into a GitHub constraint:
**inside a reusable workflow called from another repo, `uses: ./...` resolves against
the *caller's* checkout**, not against the repo holding the workflow. A shared script
sitting in this repo is simply not on disk when `release.yaml` runs in
`ansible-runner`.

Composite actions are the fix — an action referenced as
`jcwearn/workflows/.github/actions/next-version@v1` brings its own files, and
`$GITHUB_ACTION_PATH` always points at them. No extra checkout, no token, no reliance
on `github.job_workflow_sha` (whose documentation is ambiguous enough not to build on).

That creates a bootstrap ordering requirement:

1. **C1** — `ci.yaml` alone. *(merged / PR open)*
2. **C2** — composite actions + scripts + tests, wired into `ci.yaml`. No workflow
   references them yet, so nothing can break.
3. **Manual step between C2 and C3.** After C2 merges, cut `v1.1.0` and move `v1`
   using the RUNBOOK block. `@v1` must already contain `.github/actions/` before any
   workflow references those actions at `@v1` — otherwise C3's own release run
   resolves `@v1` to `d053075`, which has no actions directory, and goes red.
4. **C3** — `release.yaml`, `require-release-label.yaml`, `self-release.yaml`,
   `self-require-release-label.yaml`, plus the README/RUNBOOK/template/renovate edits.

### Testing

`tests/` runs the real scripts, not copies. Both suites are portable to bash 3.2
deliberately — the runner has bash 5, but macOS ships 3.2, and a script that only
executes in CI is a script nobody can test before pushing. That is why
`release-label.sh` uses a read loop rather than `mapfile`.

23 cases green locally and in CI. The two that matter most are regressions against the
implementation being replaced: an unrecognised `release:*` suffix must fail loudly
rather than become "bump nothing", and a moving `vX` alias must never be mistaken for
the newest full triple.

### Phase B is blocked on a sequencing decision

Four of the five consumer repos have **pushed but unmerged** branches that edit
`.github/workflows/publish.yaml` — the same file and, in two cases, the same line
Phase B targets. None have an open PR.

| Repo | Branch | What it changes |
|---|---|---|
| `homeassistant-config` | `chore/signer-email-flatten` | `signer-email` → `jcwearn@users.noreply.github.com` |
| `k3s-cluster` | `chore/signer-email-flatten` | same |
| `borderline` | `chore/signer-email-flatten` | signer-email **and** pin bump to `d053075` |
| `cf-worker-email` | `chore/bump-workflows-pin` | pin bump to `d053075` |

`cf-worker-email`'s branch is **entirely superseded** by Phase B: it bumps the digest
pin to `d053075`, which is exactly what `@v1` resolves to. Merging it and then editing
the same line again is wasted motion.

Options: fold the `@v1` change into the existing branches; land those branches first
and do Phase B on top; or branch fresh from `main` and let the existing branches
rebase. Not decided.

`anupamaandjackson` is on `main` with no in-flight work — it is the one consumer that
can move without untangling anything.

### Phase A notes

`v1.0.0` and `v1` both point at `d053075`, which was `HEAD == origin/main` at the time
and is the digest `cf-worker-email`, `borderline`, and `anupamaandjackson` were already
pinned to. That is what makes the Phase B move provably behavior-identical.

No Release was created on the `v1` tag, and none should be: a Release on a moving tag
makes "latest release" jump backwards and breaks `--notes-start-tag` on the next run.

### Verified environment facts

- All three release-scheme repos have `default_workflow_permissions: read`, so **every
  caller job must declare `permissions:`** — a reusable workflow can only narrow what
  the caller granted. Symptom if omitted: green through build, 403 on the tag push.
- 0 rulesets on all three repos, so nothing currently blocks the `vX` force-push. If a
  tag-protection ruleset is ever added, exempt `v[0-9]*`.
- actionlint `1.7.12` checksum `8aca8db9…a3d8` verified against the real release
  tarball, not taken on trust.
