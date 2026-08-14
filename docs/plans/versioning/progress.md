# Progress: Versioning system for `jcwearn/workflows`

## Current Status: In Progress

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| A. Labels and seed tag | Complete | 2026-08-14 | 4 labels in `workflows`, `release:skip` added to both siblings. `v1.0.0` + `v1` tagged at `d053075`, Release created on `v1.0.0` only |
| B. Consumers to `@v1` | In Review | 2026-08-14 | All five PRs open: homeassistant-config#104, k3s-cluster#716, cf-worker-email#143, borderline#72, anupamaandjackson#271. Proven no-op |
| C. Land the machinery | In Progress | 2026-08-14 | Split into C1 `ci.yaml` (#5), C2 composite actions + tests (#6), C3 the release workflows (#7). All three PRs open and stacked; **a manual `v1.1.0` cut is required between C2 and C3** |
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

### Consumption is digest pinning, not a floating `@v1`

Revised after review. Consumers pin a digest with a `# v1` comment — the same shape as
every other action in these repos (`actions/checkout@3d3c42e5… # v7`). The four
`pinDigests: false` Renovate rules were **removed**: they existed only to keep `@v1`
floating, and they opted these repos out of their own house convention.

The moving `v1` tag still matters, and this is the part worth not forgetting: **it is
what Renovate follows to notice a release and open the bump PR.** A digest pin with no
tag tracking it is a dependency that silently never updates. `v1` triggers the PR; it
is not what applies the change.

Producer and consumer are separate decisions, and they are not in tension —
`actions/checkout` publishes a moving `v7` *and* is consumed as a pinned digest.

`move-major-tag` is an input, default `false`. `workflows` sets it `true`.
`ansible-runner` and `withjoy-exporter` leave it off: their artifact is a container
image consumed by image tag, so a moving git tag there would be created and never read.

### Phase B: read remote state, not local branches

An earlier pass called Phase B blocked, on the basis that four consumer repos had
unmerged branches touching `publish.yaml`. **That was wrong.** It came from running
`git log main..HEAD` in local clones whose `main` was stale, and from treating a
non-ancestor SHA as proof a branch was unmerged — which fails for squash merges, as
`k3s-cluster` demonstrated.

The check that actually settles it is the file on the remote default branch:

```bash
git -C <repo> fetch -q origin
git -C <repo> show origin/main:.github/workflows/publish.yaml | grep -nE 'uses:'
```

All five were clean and matched what the plan assumed. Use this form for Phase D too.

### The consumer move is a provable no-op

`v1`, `v1.0.0`, and the digest three consumers were pinned to are all
`d05307571ec735cdd30d60377db0fff881bb78e2`, and `git diff d053075 v1.0.0` is empty.
Nothing about what those repos execute changes on merge.

`homeassistant-config` gets no Renovate rule — its `renovate.json` has no `extends`,
so `helpers:pinGitHubActionDigests` was never active. That is exactly why it was still
on literal `@main` while three siblings had been digest-pinned.

### SSH note

`anupamaandjackson` could not be pushed over SSH — `github.com:22` timed out
repeatedly from this machine while HTTPS and the API worked, and while the other four
repos pushed over SSH fine minutes earlier. Its branch and commit were created through
the git trees API instead. Nothing about the repo's remote config was changed.

### Phase A notes

`v1.0.0` and `v1` both point at `d053075`, which was `HEAD == origin/main` at the time
and is the digest `cf-worker-email`, `borderline`, and `anupamaandjackson` were already
pinned to. That is what makes the Phase B move provably behavior-identical.

No Release was created on the `v1` tag, and none should be: a Release on a moving tag
makes "latest release" jump backwards and breaks `--notes-start-tag` on the next run.

### Verified environment facts

- All three release-scheme repos have `default_workflow_permissions: read`, so **every
  caller job must declare `permissions:`** — a reusable workflow can only narrow what
  the caller granted. Two symptoms, and the second one cost a broken release run:
  under-granting a scope a job *uses* gives a 403 at the tag push; under-granting a
  scope any nested job merely *declares* makes the workflow **invalid and unrunnable**,
  because that check is static and runs before any `if:` is evaluated. A job that
  would have been skipped still invalidates the file. Hence `build` declares no
  `permissions:` and inherits the caller's.
- 0 rulesets on all three repos, so nothing currently blocks the `vX` force-push. If a
  tag-protection ruleset is ever added, exempt `v[0-9]*`.
- actionlint `1.7.12` checksum `8aca8db9…a3d8` verified against the real release
  tarball, not taken on trust.
