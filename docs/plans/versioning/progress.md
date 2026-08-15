# Progress: Versioning system for `jcwearn/workflows`

## Current Status: Complete

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| A. Labels and seed tag | Complete | 2026-08-14 | 4 labels here, `release:skip` added to the sibling repos. `v1.0.0` + `v1` seeded at `d053075` |
| B. Consumers to `@v1` | Complete | 2026-08-14 | All five merged and syncing green. Digest pins with `# v1` comments, no custom Renovate config |
| C. Land the machinery | Complete | 2026-08-14 | C1 `ci.yaml` (#5), C2 composite actions + tests (#6), manual `v1.1.0` cut, C3 the release workflows (#7), then #8 fixing nested-job permissions. Released as `v1.1.1` |
| D. Image repos | Complete | 2026-08-14 | `ansible-runner` 0.1.36, `withjoy-exporter` v0.4.2, `world-clock` v0.2.19 — each verified against the GHCR registry, not the run log |

### Released artifacts, verified

Every version below was confirmed by resolving the tag against the registry directly,
because "the run was green" is exactly the check that failed to catch the original bug.

| Repo | Version | Image digest |
|---|---|---|
| `ansible-runner` | `0.1.36` | `sha256:1741b843…` (`0.1` and `0` moved to match) |
| `withjoy-exporter` | `v0.4.2` | `sha256:bef16d80…` (`v0.4` and `v0` moved to match) |
| `world-clock` | `v0.2.19` | `sha256:8cf8250a…` (`v0.2` and `v0` moved to match) |

`ansible-runner` `0.1.35` remains **absent from the registry** while its git tag and
Release exist. That is the original defect, left in place deliberately: the tags are
real, nothing consumes those versions, and deleting seven of them is churn.

## Still open

- **Renovate has not yet offered `k3s-cluster` the image bumps** (`withjoy-exporter`
  `v0.4.1` → `v0.4.2`, `world-clock` `v0.2.12` → `v0.2.19`). That is the last
  confirmation that `image-tag-prefix: "v"` did its job. Not a failure — the
  self-hosted config schedules PR creation for `* 0-7 * * 0,5,6` America/New_York, so
  the next window is Saturday 00:00 ET.
- Those bumps will **automerge unattended**: the global config auto-approves and
  automerges all non-major updates, and `pin`/`digest` are in `matchUpdateTypes`.

## Handoff Notes

### Three copies, three different latent defects

The original case for consolidating was drift. What the migration actually found was
that all three copies had the *same* bug in different states of having gone off:

| Repo | Ordering | Outcome |
|---|---|---|
| `ansible-runner` | tag → build | **Fired.** `v0.1.29`–`v0.1.35`: seven tags and Releases, no images, unnoticed for a month |
| `world-clock` | tag → build → Release, one job | **Latent.** A failed build would have left a tag with *neither* image nor Release. All 20 tags happened to have images |
| `withjoy-exporter` | build → tag | Correct, but by accident — nothing enforced it |

Only chance separated them. That is the argument for `publish` sitting behind
`needs: build` *inside* the reusable workflow, where a caller cannot rewire it.

Two supporting details that mattered as much as the ordering: `ansible-runner` lacked
`cache-to ...,ignore-error=true` (the flag whose absence failed those seven builds,
and which `withjoy-exporter` already had), and both label checks matched loosely —
one on substrings, one accepting any `release:*` suffix into a `case` with no default
arm.

### Two GitHub behaviours worth not re-learning

**Nested-job permissions are validated statically.** A job that declares a scope the
caller did not grant makes the workflow *invalid*, before any `if:` is evaluated — so
a job that would have been skipped still breaks the file. This took out the first real
release run. `build` therefore declares no `permissions:` and inherits the caller's.

**`uses: ./...` inside a reusable workflow resolves against the CALLER's checkout**,
not the repo holding the workflow. Shared logic has to travel as a composite action
referenced by full path.

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
