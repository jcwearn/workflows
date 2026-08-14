# Progress: Versioning system for `jcwearn/workflows`

## Current Status: In Progress

| Phase | Status | Updated | Notes |
|-------|--------|---------|-------|
| A. Labels and seed tag | Complete | 2026-08-14 | 4 labels in `workflows`, `release:skip` added to both siblings. `v1.0.0` + `v1` tagged at `d053075`, Release created on `v1.0.0` only |
| B. Consumers to `@v1` | Blocked | 2026-08-14 | Sequencing decision needed — see Handoff Notes |
| C. Land the machinery | In Progress | 2026-08-14 | `ci.yaml` PR open; release machinery PR next |
| D. Docker repos | Not Started | — | `ansible-runner` first, then `withjoy-exporter` |

## Handoff Notes

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
