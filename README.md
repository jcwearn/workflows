# workflows

Reusable GitHub Actions workflows.

> Onboarding a new repo to the public-snapshot pattern? Read **[RUNBOOK.md](RUNBOOK.md)** —
> it covers the full sequence, the decision about whether a repo can be published
> in place at all, and the failure modes hit so far.

## Versioning

Two kinds of tag, the same shape `actions/checkout` publishes:

| Tag | Mutability | Purpose |
|---|---|---|
| `vX.Y.Z` | immutable | What a GitHub Release attaches to |
| `vX` | **re-pointed** at each compatible release | Tracks the newest `vX.Y.Z`, so tooling can tell a release happened |

### How to consume it

**Pin the digest, comment the tag** — the same way every other action in these repos
is pinned:

```yaml
uses: jcwearn/workflows/.github/workflows/public-sync.yaml@d05307571ec735cdd30d60377db0fff881bb78e2 # v1
```

Write `@v1` and let Renovate resolve it, or paste the digest yourself. The comment is
not decoration: it records which tag the digest came from, and it's how Renovate knows
to watch `v1` and open a PR when a release moves it.

This is why the moving tag exists even though nothing resolves `@v1` at run time. A
digest pin with nothing tracking it is a dependency that silently never updates.

For comparison, `actions/checkout` right now:

```
9c091bb…  refs/tags/v7.0.0     frozen
3d3c42e5  refs/tags/v7.0.1     frozen
3d3c42e5  refs/tags/v7         currently tracking v7.0.1
```

`@3d3c42e5… # v7` is a pin to a specific commit *and* a statement about what to follow.

### What counts as a version bump

**Major** — anything that breaks a caller that changed nothing:

- Removing or renaming an input or secret
- Making an optional input required
- Changing a default such that an unchanged caller now publishes something
  different (`ignore-file`, `message-mode`, `readme-override`)
- Changing the `permissions:` a caller must grant
- Renaming the workflow file

**Minor** — a new optional input or secret; new behaviour behind a default-off flag.

**Patch** — bug fixes, doc changes, internal refactors with identical observable
behaviour, and bumping the pinned `gitleaks-version` / `gitleaks-sha256` defaults.

### What digest pinning buys you here

A `gitleaks-version` default bump is a patch by the taxonomy above, but a newer
gitleaks can newly flag a repo that was previously passing. That would be an
unpleasant surprise if it arrived automatically.

It doesn't. Because consumers pin a digest, every release — patch included — arrives
as a Renovate PR you can read and merge on your own schedule. The moving `v1` tag is
what triggers that PR; it isn't what applies the change.

A repo that wants to opt out of even that can pin `gitleaks-version` explicitly rather
than inheriting the default.

## `public-sync.yaml`

Publishes a filtered snapshot of a private repo to a public counterpart, on every
merge to `main`.

The private repo stays canonical. The public repo receives **file trees only** —
never commits, branches, or refs from the source. Its history is an independent
linear series of `sync:` commits, so private history can't leak, and a secret
buried in the source repo's history (or in a closed PR's `refs/pull/*`, which
GitHub keeps permanently) never becomes reachable.

Naming convention: `<repo>` (private) → `<repo>-public`.

### Usage

```yaml
# .github/workflows/publish.yaml in the private repo
name: Publish Public Snapshot

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  publish:
    permissions:
      contents: read
    # Write @v1 and let Renovate pin it to a digest on its next run, or paste
    # the digest yourself. Either way the trailing comment must say v1.
    uses: jcwearn/workflows/.github/workflows/public-sync.yaml@v1
    with:
      target-repo: jcwearn/myrepo-public
      readme-override: .github/public-README.md
    secrets:
      DEPLOY_KEY: ${{ secrets.PUBLIC_SYNC_DEPLOY_KEY }}
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `target-repo` | yes | — | `owner/repo` of the public counterpart |
| `ignore-file` | no | `.publicignore` | rsync `--exclude-from` file. **The job fails if it's missing** rather than publishing an unfiltered tree. Pass `''` to opt out deliberately |
| `readme-override` | no | `''` | Path in the source repo to publish as the target's `README.md` |
| `message-mode` | no | `passthrough` | `passthrough` replays upstream commit messages; `generic` publishes an opaque `sync: <short-sha>` |
| `signer-name` | no | `''` | Committer name used when `SIGNING_KEY` is set |
| `signer-email` | no | `''` | Committer email used when `SIGNING_KEY` is set. **Must be an email on the account owning the key** |
| `gitleaks-version` | no | `8.30.1` | Pinned gitleaks release |
| `gitleaks-sha256` | no | (matching) | Checksum for the pinned release |

Secrets:

| Secret | Required | Description |
|---|---|---|
| `DEPLOY_KEY` | yes | SSH private key with write access to `target-repo` |
| `SIGNING_KEY` | no | SSH private key registered on the account as a **signing** key. Without it, commits push unsigned |

### Signed commits (the Verified badge)

Supply `SIGNING_KEY` plus `signer-name`/`signer-email` and published commits get
GitHub's **Verified** badge.

The constraint to understand: **GitHub matches a signature to an account by the
_committer_ email.** `github-actions[bot]` isn't an email on your account, so a
bot-committed commit can never verify no matter how it's signed. The workflow
therefore sets the **committer** to your identity.

The **author** is passed through from upstream, so a Renovate bump publishes as
Renovate rather than as the sync bot. GitHub renders "renovate-bot[bot] authored
and *you* committed". When a single sync spans commits by more than one author it
falls back to `github-actions[bot]`, since the result is genuinely collective and
crediting the newest commit's author would hand one person everyone else's work.

Author and committer are independent, so passing the author through cannot affect
verification. One consequence worth knowing: GitHub collapses the two into a single
line only when they are byte-identical, so if you want your own commits to read
"*you* authored" alone, `signer-email` has to be the same address your commits are
authored with — `you@users.noreply.github.com` and `<id>+you@users.noreply.github.com`
resolve to the same account but are not the same string.

Two failure modes worth knowing:

- **The key must be registered as a Signing Key**, not an Authentication key. GitHub's
  "New SSH key" form has a Key type dropdown that defaults to Authentication. Wrong
  type gives no error anywhere — commits just quietly never verify.
- If `SIGNING_KEY` is set but `signer-email` is empty, **the job fails** rather than
  pushing unsigned. After the commit is made, the workflow also checks that a
  signature header actually attached and fails if not, so a misconfiguration surfaces
  as a red run instead of a missing badge nobody notices.

**One signing key serves every repo pair** — generate and register it once, then reuse
it. Deploy keys are the opposite: GitHub rejects reusing one across repos, so each
pair needs its own. Personal accounts have no org-level Actions secrets, so the same
signing key still has to be set as a secret in each private repo — keep the private
key rather than deleting it after the first setup.

Blast radius is wider than the deploy keys: anyone holding it can sign commits that
appear verified as you in *any* repo. Revoke from the account keys page.

### What it does

1. Checks out the source (`persist-credentials: false`) and the target (via deploy key).
2. `rsync -a --delete --exclude=.git/ --exclude-from=<ignore-file> source/ target/`.
   `--delete` propagates removals. `--exclude=.git/` is what keeps private history
   out, and also what protects `target/.git` from `--delete` — rsync excludes apply
   to both sides. **Don't remove it.**
3. Applies `readme-override`, if set.
4. **Secret-scan gate**: runs gitleaks against the rendered tree — after filtering,
   so it sees exactly what's about to be published — and fails closed on any finding.
   Findings print redacted; nothing is pushed.
5. Composes the commit message and pushes. No-ops cleanly when the filtered tree is
   unchanged, so unrelated merges don't create empty commits.

### Commit messages

Under the default `passthrough` mode the public commit carries the real upstream
subject and body, so the public history is readable on its own terms.

Subject and body come from the newest **non-merge** commit in scope — for a merged
feature branch that's the actual work, not `Merge pull request #NN`, which points at
a PR nobody outside the private repo can open. When more than one commit is being
published, they're listed as bare short SHAs. Deliberately not `owner/repo@sha`:
GitHub auto-linkifies that form into a link that 404s without private access.

Each commit ends with a `Source-commit: <full-sha>` trailer. The next run reads it
back to work out what's new, so if a sync fails and two pushes accumulate, the
following commit describes both.

Two things to know:

- **Commit messages are a leak path the tree scan can't see**, so they're scanned
  separately with `gitleaks stdin` and the push is blocked on any hit. Fix the
  upstream message, or switch to `message-mode: generic`.
- Passthrough publishes whatever your private commits discuss — internal PR numbers,
  design debate, references to private infrastructure. That's usually the point, but
  it's worth a look before enabling it on a repo with candid commit history.

A false positive from the scan should be handled with a `.gitleaks.toml` allowlist
in the source repo. Don't bypass the step — across several repos it's the only thing
standing between a bad commit and a public one.

## Setting up a new repo pair

```bash
REPO=myrepo

# 1. Public counterpart. --add-readme matters: actions/checkout can't check out
#    a completely empty repo.
gh repo create "jcwearn/${REPO}-public" --public --add-readme \
  --description "Public snapshot of jcwearn/${REPO}"

# 2. Deploy key, scoped to exactly this one public repo.
#
#    IMPORTANT: a key created by `gh` is associated with the gh CLI's OAuth
#    token, so pushes are attributed to that OAuth app. Without the `workflow`
#    scope, any push touching .github/workflows/** is rejected:
#
#      ! [remote rejected] main -> main (refusing to allow an OAuth App to
#        create or update workflow `.github/workflows/deploy.yaml`
#        without `workflow` scope)
#
#    The sync fails at the push step with everything upstream green. Grant it
#    first (--hostname is required when not on a TTY), then create the key:
#
#      gh auth refresh -s workflow --hostname github.com
#
#    If you'd rather not widen the CLI's scopes, either add `.github/workflows/`
#    to .publicignore, or add the deploy key through the github.com web UI --
#    UI-added keys aren't OAuth-app-associated and aren't subject to this.
ssh-keygen -t ed25519 -f /tmp/${REPO}-sync -N "" -C "public-sync:${REPO}"
gh repo deploy-key add /tmp/${REPO}-sync.pub -R "jcwearn/${REPO}-public" -w -t "public-sync"
gh secret set PUBLIC_SYNC_DEPLOY_KEY -R "jcwearn/${REPO}" < /tmp/${REPO}-sync
rm /tmp/${REPO}-sync /tmp/${REPO}-sync.pub

# 3. Disable Actions on the target -- synced workflow files would otherwise try
#    to run there without secrets and fail on every sync.
gh api -X PUT "repos/jcwearn/${REPO}-public/actions/permissions" -F enabled=false

# 4. Push protection, as a second layer behind the gitleaks gate
gh api -X PATCH "repos/jcwearn/${REPO}-public" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```

Then copy `templates/publish.yaml` → `.github/workflows/publish.yaml` and
`templates/.publicignore` → `.publicignore` in the private repo, and adjust both.

Run it once via `workflow_dispatch` before relying on the push trigger, so the first
publish is deliberate.

### Checking the filter before you trust it

```bash
rsync -an --delete --exclude=.git/ --exclude-from=.publicignore ./ /tmp/pubcheck/
```

## `node-ci.yaml`

The universal core of a Node repo's checks — install, format, lint, typecheck, test,
build — as one job, in that order.

### Usage

```yaml
# .github/workflows/ci.yml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  ci:
    permissions:
      contents: read
    uses: jcwearn/workflows/.github/workflows/node-ci.yaml@v1
```

Start from `templates/ci-node.yaml`.

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `timeout-minutes` | no | `10` | Job timeout. Raise for a long build or a browser-driven suite |
| `extra-env` | no | `''` | `KEY=value` per line, set for the whole job. Rejects `GITHUB_*`/`ACTIONS_*` and anything that isn't `KEY=value` |

**Secrets: none.** `GITHUB_TOKEN` only, at `contents: read`.

### The contract

Most of what this workflow needs is not an input, because a tool already fails with a
better message than a parameter default could:

| Requirement | What enforces it |
|---|---|
| `.node-version`, pinned exact | `setup-node` errors on a missing `node-version-file` |
| `package-lock.json` | `npm ci` |
| scripts `format:check`, `lint`, `typecheck`, `test`, `build` | `npm run` exits 1 naming the missing script |

**Every input not added is a repo that conforms instead.** `world-clock` gained a
`typecheck` script rather than this file gaining a `typecheck-command`.

A repo with no test suite satisfies the contract honestly with
`"test": "vitest run --passWithNoTests"` rather than this file growing a `test: false`.
The script is real, runs the real runner, and states the repo's actual position — which
a skip flag would hide, and which would outlive the reason it was added.

### Configuration, never code

`extra-env` can only activate behaviour a caller's own committed scripts already
implement. There is deliberately no way to inject a step, and there could not be one:
`workflow_call` inputs are `boolean`, `number`, or `string` and nothing else. The only
way to fake it is running a caller-supplied string as shell — one `run:` block with no
`uses:`, no per-step `if:`, no step names in the log, and a shared workflow that executes
whatever it is handed.

`extra-env` exists for exactly one case, and the ways around it were checked and fail.
`jackson-wearn`'s build needs `SKIP_RESUME_FETCH=1`, which cannot be inferred from
`GITHUB_ACTIONS` (its `resume:fetch` script runs *inside* Actions from
`refresh-resume.yml` and must not skip) nor from `CI` (Cloudflare Pages sets it, and
Pages must fetch).

### Bespoke steps go in a local workflow

Not here, and not behind a flag. `lint: false` has no expiry date — the repo that sets it
to unblock a migration stays unlinted forever, and this file carries a permanent flag
describing a temporary state.

The worked example is `borderline`: its Chrome-driven layout suite and its generated-data
drift check are ~40 lines that mean nothing in the other repos. As a local
`ci-extras.yml` they run **in parallel** with the shared job instead of extending it, so
the repo that looked like it needed flags got *faster* by not having them. Splitting
bespoke work out of a serial job is a speedup, not a tax.

### The lockfile check

`npm ci` already fails when `package.json` and the lockfile disagree about *declared*
dependencies. The extra check here catches the narrower case it cannot see: a lockfile
that satisfies `package.json` but isn't what `npm install` would produce — hand-edited,
or a stale transitive resolution. Most lockfile changes in these repos are Renovate's,
which is why it runs everywhere rather than in the one repo that thought of it.

It is safe unconditionally **only because `.node-version` is mandatory.** Pinning Node
pins the npm bundled with it, so a lockfile-format change can only arrive attached to a
deliberate `.node-version` bump someone is already reading. Make the pin optional and
this check becomes a time bomb on GitHub's runner-image schedule.

### Concurrency

Declared inside this workflow as `node-ci-<caller workflow>-<ref>`, cancelling superseded
pull request runs but never runs on `main`. **Callers must not declare their own
`concurrency:`** — two groups for one logical run means the outer one holds a slot while
the inner one queues behind it.

## `release.yaml`

Cuts a release for the calling repo when a labelled PR merges to `main`. Every PR
carries exactly one of:

| Label | Effect |
|---|---|
| `release:major` | `vX.Y.Z` → `v(X+1).0.0` |
| `release:minor` | → `vX.(Y+1).0` |
| `release:patch` | → `vX.Y.(Z+1)` |
| `release:skip` | No release. Green run, no tag |

`release:skip` exists so a docs-only or CI-only PR has a way out that isn't "forget
the label and go red after the merge."

### Usage

For a repo whose artifact is the git ref — a reusable workflow, an action:

```yaml
# .github/workflows/release.yaml
on:
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  release:
    if: github.event.pull_request.merged == true
    permissions:
      contents: write
    uses: jcwearn/workflows/.github/workflows/release.yaml@v1
```

For a repo that ships a container image, add `image` and `packages: write`:

```yaml
jobs:
  release:
    if: github.event.pull_request.merged == true
    permissions:
      contents: write
      packages: write
    uses: jcwearn/workflows/.github/workflows/release.yaml@v1
    with:
      image: ghcr.io/jcwearn/myrepo
```

### Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `image` | no | `''` | GHCR image to build and push. Empty means the repo has no build step and the git ref is the artifact |
| `image-context` | no | `.` | Docker build context, relative to the repo root |
| `image-tag-prefix` | no | `''` | Prepended to the semver image tags. Docker convention is no prefix. Pass `v` only to preserve an existing published tag shape |
| `move-major-tag` | no | `false` | Also publish a `vX` tag re-pointed at each release. Turn on when something resolves the repo by git ref, so Renovate has a tag to follow. Leave off for image repos — they're consumed by image tag, so the git tag would never be read |

Outputs: `released` (`true`/`false`) and `version` (e.g. `v1.2.3`, empty when skipped).

**Secrets: none.** `GITHUB_TOKEN` only.

**The caller job must declare `permissions:`.** This account's default
`GITHUB_TOKEN` permission is `read`, and a reusable workflow can only *narrow* what
the caller granted — the `permissions:` blocks inside `release.yaml` are a ceiling,
not a grant.

Two symptoms, and the second is the one that surprises people:

| Under-granted scope | Symptom |
|---|---|
| One a job actually **uses** | Run goes green through build, then 403s on the tag push |
| One any nested job merely **declares** | `Invalid workflow file … is requesting 'packages: write', but is only allowed 'packages: none'` — the workflow doesn't run at all |

The second is checked **statically, before any `if:` is evaluated**, so a job that
would have been skipped still invalidates the file. That's why the `build` job
declares no `permissions:` of its own and inherits the caller's instead — otherwise
every caller that builds no image would still have to grant `packages: write` to
satisfy a job that never runs. This repo's own first release run is what found it.

### What it publishes

- An immutable `vX.Y.Z` tag.
- One GitHub Release, on `vX.Y.Z`. **Never on a moving tag** — a Release on a tag that
  moves makes "latest release" jump backwards and breaks `--notes-start-tag`.
- With `move-major-tag: true`: a `vX` tag re-pointed at the same commit.
- When `image` is set: `X.Y.Z`, `X.Y`, `X`, and `sha-<short>` image tags on GHCR.

### Why build comes before tag

```
plan → build [skipped when image is empty] → publish
```

`publish` `needs: build`, and its condition excludes `failure` and `cancelled`, so
**nothing is tagged until the artifact it names already exists.**

This is the whole reason the workflow is centralised rather than copied. The
implementation it replaces tagged first and built second, and `ansible-runner`
`v0.1.29`–`v0.1.35` are the result: seven git tags and seven GitHub Releases with no
container image behind them, over a month, unnoticed. On a failed build this ordering
leaves an image with no tag instead — recoverable, because a retry recomputes the
same version and overwrites the image from the same source.

### Concurrency

One group per calling repo, `cancel-in-progress: false`. A cancelled release can
leave an image pushed with no tag, or a tag with no Release.

Queue depth is 1, so merging three PRs in quick succession can cancel the middle run
*while it is still pending*. Nothing partial happens — that PR simply never releases.
Recover with "Re-run all jobs". Don't "fix" this by allowing cancellation; it trades
a benign miss for a torn release.

## `require-release-label.yaml`

Fails a PR that doesn't carry exactly one release label, so the mistake is visible
before the merge rather than as a failed release afterwards.

```yaml
on:
  pull_request:
    types: [opened, reopened, edited, labeled, unlabeled, synchronize]
    branches: [main]

jobs:
  check:
    uses: jcwearn/workflows/.github/workflows/require-release-label.yaml@v1
```

**Keep `edited` in that list.** It's what fires when a PR's base branch changes. Drop
it and a stacked PR retargeted onto `main` after its parent merges never runs this
check at all — every earlier event was filtered out by `branches: [main]` while the
base was still the parent branch, and the retarget is the only thing that happens
afterwards. This repo's own PR #7 hit exactly that.

**Advisory only without branch protection**: a red check here does not block a merge.
A PR merged without a label produces a red release run and no tag, which is the safe
direction.

## Composite actions

The pieces of real logic live in `.github/actions/` rather than inline in the
workflows, so `tests/` can exercise the code that actually runs instead of a copy of
it. Both halves of the label check call the same action, so the vocabulary is defined
once.

| Action | Purpose |
|---|---|
| `release-label` | Resolve a PR's labels into a bump, or a decision not to release |
| `next-version` | Compute the next semver tag from the tags already in the repo |
| `extra-env` | Validate `KEY=value` lines and export them to the job environment |

`extra-env` is the newest and makes the case for the rule plainly: it is the one place
a caller's string reaches something a shared workflow executes, and writing
`tests/test-extra-env.sh` against the real script is what found that a malformed line
used to leave the lines *before* it already appended to `$GITHUB_ENV`. Inline in the
workflow, that bug had nowhere to be caught.

They're usable on their own if you want the pieces without the workflow:

```yaml
- id: label
  uses: jcwearn/workflows/.github/actions/release-label@v1
  with:
    labels: ${{ toJson(github.event.pull_request.labels.*.name) }}
```

Two things to know if you edit them:

- **They're referenced by full path, not `./`.** Inside a reusable workflow called
  from another repo, `uses: ./...` resolves against the *caller's* checkout, where
  this repo's files don't exist. A composite action referenced as
  `jcwearn/workflows/.github/actions/...@v1` brings its own files with it.
- **`next-version` reads the tag list from the workspace**, so the calling job must
  check out with `fetch-depth: 0` first. A shallow clone carries no tags and every
  release comes out as `v0.0.1`.

Run the tests with `bash tests/test-release-label.sh` and
`bash tests/test-next-version.sh`. Both are portable to bash 3.2 on purpose — the
runner has bash 5, but macOS ships 3.2, and a script that only executes in CI is a
script nobody can test before pushing.
