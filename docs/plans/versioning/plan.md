# Plan: Versioning system for `jcwearn/workflows`

## Context

This repo publishes `public-sync.yaml`, a reusable workflow consumed by five private
repos. Until now it had **zero git tags** and **no CI** — consumers pinned either
`@main` or a branch digest, and nothing validated a change before five repos picked
it up.

Two sibling repos, `ansible-runner` and `withjoy-exporter`, already ran a label-based
release scheme (`release:major|minor|patch` on a PR, hand-rolled shell bump). The
scheme is sound and is being kept: intent is explicit, visible before merge, and does
not depend on commit-message discipline. But the two copies drifted, and the drift
caused a live outage:

- **`ansible-runner` `v0.1.29`–`v0.1.35` are git tags and GitHub Releases with no
  container image.** Seven consecutive releases failed at `build-and-push` on GHA
  cache quota, unnoticed for a month. Root cause: the tag is published *before* the
  artifact is built.
- `withjoy-exporter` carries `cache-to: ...,ignore-error=true` — the fix for exactly
  that failure. `ansible-runner` does not.
- `ansible-runner`'s parser feeds `.replace('release:','')` into a shell `case` with
  **no `*)` default arm**, so an unrecognized suffix silently yields `NEXT == LATEST`
  and dies on a duplicate tag.
- Neither has a `concurrency:` group.

Goal: give this repo a semver scheme with a moving major tag, and hoist one correct
release implementation into it that all three repos call.

## Design

One `release.yaml` with an optional `image` input, ordered build-then-tag. A reusable
workflow cannot invoke caller steps between its own jobs, so a split
(`compute-version` + `publish-release`) would hand each caller the job-ordering
decision back — precisely the mistake that produced the seven orphaned releases.
Keeping `publish` `needs: build` *inside* the reusable workflow makes the ordering
unwirable-wrong.

```
self-release.yaml:  verify (./ci.yaml) → release (./release.yaml)
release.yaml:       plan → build [skipped when image==""] → publish
```

`image: ""` means "this repo builds nothing; the git ref is the artifact."

## Phases

### Phase A: Labels and seed tag
- Create `release:{major,minor,patch,skip}` in this repo; add `release:skip` to the
  two siblings.
- Seed `v1.0.0` and `v1` at `d053075` — the exact digest three consumers already run,
  so the consumer move is a provable no-op.
- Acceptance: `git ls-remote --tags` shows both; one Release on `v1.0.0`, none on `v1`.

### Phase B: Move the five consumers to `@v1`
- Files: `.github/workflows/publish.yaml` in `homeassistant-config`, `k3s-cluster`,
  `cf-worker-email`, `borderline`, `anupamaandjackson`.
- Add a Renovate `pinDigests: false` rule for `jcwearn/workflows` in every repo that
  extends `config:best-practices`, or Renovate re-pins `@v1` to a digest and the
  moving tag stops moving. `homeassistant-config` needs no rule (no `extends`).
- **Blocked on a sequencing decision** — see progress.md. Four of the five have
  pushed, unmerged branches editing this same file.
- Acceptance: each repo's sync run goes green on `@v1`.

### Phase C: Land the machinery
- `ci.yaml` (actionlint, dual-triggered) lands alone first so it gates everything after.
- Then `release.yaml`, `require-release-label.yaml`, `self-release.yaml`,
  `self-require-release-label.yaml`, plus README/RUNBOOK/template/renovate edits.
- Acceptance: merging the second PR labelled `release:minor` cuts `v1.1.0` and moves
  `v1`, with `git diff v1.0.0 v1.1.0 -- .github/workflows/public-sync.yaml` empty.

### Phase D: Migrate the Docker repos
- `ansible-runner` first (it is the broken one), then `withjoy-exporter`.
- `withjoy-exporter` passes `image-tag-prefix: "v"` — `k3s-cluster` pins its images by
  tag string, so dropping the `v` would stall Renovate silently rather than fail.
- Leave `v0.1.29`–`v0.1.35` in place: the tags and Releases are real, only the images
  are missing, and `k3s-cluster` pins `0.1.28` so nothing consumes them.
- Acceptance: **the image actually exists** — `docker buildx imagetools inspect` —
  before declaring victory. That is the failure this whole exercise is about.

## Non-goals

- **Branch protection.** Deliberately out of scope, which makes the label check
  advisory: a red check does not block a merge. An unlabeled merge produces a red
  release and no tag, which is the safe direction.
