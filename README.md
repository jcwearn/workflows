# workflows

Reusable GitHub Actions workflows.

> Onboarding a new repo to the public-snapshot pattern? Read **[RUNBOOK.md](RUNBOOK.md)** —
> it covers the full sequence, the decision about whether a repo can be published
> in place at all, and the failure modes hit so far.

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
    uses: jcwearn/workflows/.github/workflows/public-sync.yaml@main
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
| `gitleaks-version` | no | `8.30.1` | Pinned gitleaks release |
| `gitleaks-sha256` | no | (matching) | Checksum for the pinned release |

Secret: `DEPLOY_KEY` — SSH private key with write access to `target-repo`.

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
5. Commits as `sync: <source-repo>@<short-sha>` and pushes. No-ops cleanly when the
   filtered tree is unchanged, so unrelated merges don't create empty commits.

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
