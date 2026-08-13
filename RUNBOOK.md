# Runbook: publishing a private repo as a public snapshot

Written for agents. Derived from the first real run (`homeassistant-config` →
`homeassistant-config-public`, 2026-08-13). Follow the phases in order; each one
gates the next.

The end state: the private repo stays canonical, and every merge to `main`
publishes a **filtered file tree** to `<repo>-public`. The public repo never
receives commits, branches, or refs from the private one.

---

## Phase 0 — Decide whether the repo can be published in place

**Do this before anything else. It's the decision the rest depends on, and it's
the one most likely to be gotten wrong.**

The instinct is "scrub the secret, rewrite history, flip to public." Verify that's
even possible before planning around it:

```bash
# Any large or sensitive blobs ever committed, on any branch?
git log --all --oneline --name-only --diff-filter=A | less

# For each suspicious path, find which refs carry it and whether a PR exists
gh pr list --state all --head <branch-that-added-it> --json number,state,title
```

**If a sensitive blob was ever pushed on a branch that had a PR opened — even a
closed, never-merged one — the repo can never be safely made public.** GitHub
retains `refs/pull/*` and serves those commits at their original SHAs
permanently. Branch deletion doesn't remove them. `git-filter-repo` plus a
force-push doesn't either, because PR refs aren't rewritable by the repo owner.
Only GitHub Support can purge them.

This is exactly what happened with `homeassistant-config`: a 991 KB
`core.device_registry` (1,356 devices, 116 MAC/Bluetooth connections, 8 serial
numbers, house floorplan) sat on closed PRs #79 and #77.

→ If clean, publishing in place is an option.
→ If not, use this snapshot pattern. **Say so explicitly and explain why** — the
   user may otherwise assume a rewrite was skipped out of caution.

## Phase 1 — Audit and scrub the working tree

The sync publishes the tree, so the tree must be clean. History doesn't matter
here (it never leaves the private repo), but **everything at HEAD does**.

```bash
# Baseline: what does a scanner already see?
gitleaks dir . --redact --no-banner

# RFC1918 addresses, MACs, key material in tracked files only
git ls-files -z | xargs -0 grep -nIE '\b(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
git ls-files -z | xargs -0 grep -nIE '\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b'
git ls-files -z | xargs -0 grep -nIiE 'bearer [A-Za-z0-9._-]{12,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN'

# Secret-adjacent literals -- catches values written into prose
git ls-files -z | xargs -0 grep -nIiE '(pin|passcode|pan_id|network_key|token|password|api.?key)[^a-z]{0,4}[:=(`'"'"'" ]{1,4}[A-Za-z0-9]{4,}'
```

Then **read the prose docs end to end**. Grep finds patterns; it doesn't find "the
code is 138321" written in a migration note. Planning docs, progress trackers, and
agent notes are where secrets actually hide, because nobody thinks of them as code.

`git grep` with multiple revs and `-o` silently misbehaves — prefer
`git ls-files -z | xargs -0 grep`, and sanity-check that a pattern you *know* is
present actually returns a hit before trusting a clean result.

### If you're handed an existing audit

**Verify every finding yourself.** On the first run, two of six were wrong:

- A Zigbee PAN ID was flagged as needing device re-pairing. It didn't: `pan_id` +
  `channel` can't join a network without the network key, which was encrypted and
  never exposed. Re-pairing 100+ devices would have been wasted work.
- Plaintext AWS credentials were reported "in the repo." The file was gitignored
  and had **never been committed** — not in history at all.

Both errors pointed the same way: toward more alarm and more work. Confirm before
acting, and report corrections plainly.

### Rotation vs. redaction

Redacting a leaked value does **not** unleak it — it's in history, and on any
clone. Anything genuinely exposed must be rotated. Redaction only stops it
reaching the public tree.

Ship this as its own PR, before the publishing pipeline exists.

## Phase 2 — Create the public counterpart

```bash
REPO=<private-repo-name>

# --add-readme matters: actions/checkout can't check out a completely empty repo
gh repo create "jcwearn/${REPO}-public" --public --add-readme \
  --description "Public snapshot of jcwearn/${REPO}"

# Synced workflow files would otherwise try to run here without secrets and fail
# on every single sync
gh api -X PUT "repos/jcwearn/${REPO}-public/actions/permissions" -F enabled=false

# Second layer behind the gitleaks gate
gh api -X PATCH "repos/jcwearn/${REPO}-public" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```

### Deploy key — read this before creating it

A key made with `gh repo deploy-key add` is associated with the gh CLI's OAuth
token, so pushes are attributed to that OAuth app. Without the `workflow` scope,
**any push touching `.github/workflows/**` is rejected**:

```
! [remote rejected] main -> main (refusing to allow an OAuth App to create or
  update workflow `.github/workflows/deploy.yaml` without `workflow` scope)
```

The failure is misleading — checkout, rsync, and the secret scan all go green and
only the push fails. Grant the scope first:

```bash
# --hostname is required when not on a TTY. This is an interactive browser device
# flow, so the user must run it; an agent cannot.
gh auth refresh -s workflow --hostname github.com
```

Note this widens the gh CLI's privileges **account-wide**. Say so — it's the
user's call. Alternatives that avoid it: exclude `.github/workflows/` in
`.publicignore`, or add the deploy key through the github.com web UI (UI-added
keys aren't OAuth-app-associated).

If a key already exists from before the scope was granted, delete and recreate it
so it inherits the new scope.

```bash
ssh-keygen -t ed25519 -f /tmp/${REPO}-sync -N "" -C "public-sync:${REPO}"
gh repo deploy-key add /tmp/${REPO}-sync.pub -R "jcwearn/${REPO}-public" -w -t "public-sync"
gh secret set PUBLIC_SYNC_DEPLOY_KEY -R "jcwearn/${REPO}" < /tmp/${REPO}-sync
rm /tmp/${REPO}-sync /tmp/${REPO}-sync.pub   # never leave the private half on disk
```

## Phase 3 — Wire up the private repo

Copy from `templates/`:

| File | Purpose |
|---|---|
| `.github/workflows/publish.yaml` | Caller for `public-sync.yaml` |
| `.publicignore` | rsync exclusions |
| `.github/public-README.md` | Replaces the README publicly; states it's read-only |

`.publicignore` should duplicate the sensitive parts of `.gitignore` even though
`actions/checkout` only materializes tracked files. It keeps the filter correct
when run locally against a dirty tree, and it still holds if one of those paths
gets committed by mistake.

**Sequencing matters.** If the scrub PR from Phase 1 is still open, base this
branch on it, and say plainly in the PR that the scrub must merge first —
otherwise the first sync publishes the unscrubbed tree.

## Phase 4 — Verify, then run

Test the filter locally before trusting it:

```bash
mkdir -p /tmp/pubcheck
rsync -a --delete --exclude=.git/ --exclude-from=.publicignore ./ /tmp/pubcheck/
gitleaks dir /tmp/pubcheck --redact --no-banner --exit-code 1; echo "exit $?"
```

**Then prove the gate fails closed** — an untested fail-closed gate is not a gate:

```bash
printf 'token: ghp_9fK2mQ7xZaWtY4hLcR6uE1oGfNsQiTbXv3Ld\n' > /tmp/pubcheck/planted.yaml
gitleaks dir /tmp/pubcheck --exit-code 1 >/dev/null 2>&1; echo "expect 1, got $?"
rm /tmp/pubcheck/planted.yaml
```

Do **not** use `AKIAIOSFODNN7EXAMPLE` for this. gitleaks allowlists it as the AWS
documentation example, the scan passes, and it looks like the gate is broken when
it isn't. (This happened on the first run.)

Trigger the first publish manually so it's deliberate:

```bash
gh workflow run publish.yaml --ref main
gh run watch <id> --exit-status
```

Then verify against a **fresh clone of the published repo**, not the job log:

```bash
git clone --depth 1 https://github.com/jcwearn/${REPO}-public.git /tmp/verify
cd /tmp/verify
# absent: gitignored dirs, decrypted secrets, runtime state, the README override source
# present: *.sops.yaml, the real config, docs
gitleaks dir . --redact --no-banner --exit-code 1
gh api repos/jcwearn/${REPO}-public/commits --jq '.[].commit.message'  # only "sync:" + "Initial commit"
```

Also confirm `--delete` propagation works by removing a file, merging, and
checking it disappears publicly.

---

## Reference: commit messages are also published

Under the default `message-mode: passthrough`, upstream commit subjects and bodies
are replayed onto the public commit. Before enabling it on a repo, skim what the
commit history actually says — internal PR numbers, design arguments, and references
to private infrastructure all become public along with the code.

Messages are scanned with `gitleaks stdin` and block the push on a hit, but that
only catches credentials, not candour. `message-mode: generic` falls back to an
opaque `sync: <short-sha>` if a repo's history isn't suitable.

## Reference: what's safe to publish

- **SOPS-encrypted `*.sops.yaml`**: yes, that's the point of SOPS. Note the
  ciphertext becomes permanently public — if the age private key ever leaks,
  every secret is retroactively exposed. Worth stating once, explicitly.
- **Workflow files**: they reference secret *names*, not values. But they also
  document your deploy topology. For `homeassistant-config` that's "a CI runner
  SSHes as root into the home network over Tailscale" — reconnaissance value with
  little upside, since Actions are disabled on the target anyway. Defensible
  either way; make it a conscious choice.
- **Internal IPs, hostnames, device inventories**: low individual severity, but
  they aggregate into a map of the network. Prefer env-var defaults
  (`homeassistant.local`) over hardcoded addresses.

## Failure modes seen so far

| Symptom | Cause | Fix |
|---|---|---|
| Push rejected, everything else green | gh-created deploy key lacks `workflow` scope | `gh auth refresh -s workflow --hostname github.com`, recreate key |
| Gate passes with a planted secret | Used gitleaks' allowlisted AWS example key | Use a non-allowlisted synthetic value |
| `actions/checkout` fails on target | Public repo created with no initial commit | `gh repo create --add-readme` |
| Failed runs on the public repo | Actions enabled there | `gh api -X PUT .../actions/permissions -F enabled=false` |
| Empty commits on unrelated merges | — | Already handled: the workflow no-ops when the filtered tree is unchanged |
