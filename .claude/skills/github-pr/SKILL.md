---
name: github-pr
description: Open a pull request on better-ci/npu-taskqueue — branch, rebase onto main, push, and create the PR with a body that states the deployment status. Use when the user asks to create a PR, open a pull request, or submit changes for review.
---

# npu-taskqueue Pull Request Workflow

Remote: `origin` → `https://github.com/better-ci/npu-taskqueue.git`, default
branch `main`. **The repository is public.** Everything in the diff, the branch
name, and the PR body is world-readable and permanent.

## Step 1: branch

The repository's history is short and linear; there is no branch convention yet.
Use `type/short-description`:

```bash
git branch --show-current
git checkout -b fix/verify-task-file-ownership     # if you are on main
```

If you already committed on `main`, move the commits onto a branch before
pushing:

```bash
git branch fix/verify-task-file-ownership
git reset --hard origin/main
git checkout fix/verify-task-file-ownership
```

## Step 2: rebase and verify

```bash
git fetch origin
git rebase origin/main
```

Re-run the `verify` skill after rebasing — a clean rebase can still produce a
broken script when two changes touch the same function.

## Step 3: push

```bash
git push -u origin "$(git branch --show-current)"
```

## Step 4: open the PR

```bash
gh pr create --title "fix(daemon): Verify task file ownership before dropping privileges" --body "$(cat <<'EOF'
## What

One or two sentences: what changed, in which script.

## Why

The behaviour that was wrong, and what it cost. Link the issue number in
`ISSUES.md` if one exists.

## Verification

- `bash -n` clean on the changed scripts
- shellcheck: <result, or "not installed on the host">
- Rootless smoke test: <which scenarios, observed output>
- Kill paths touched: <which of the five, or "none">

## Deployment status

Not deployed. The machine keeps running the installed copies until someone
runs `deploy.sh`; see `.claude/rules/deployment-integrity.md`.
EOF
)"
```

`## Deployment status` is not optional. In this repository a merged fix and a
live fix are months apart, and a PR that does not say so reads as "shipped".

## What must not go in a PR

- Internal hostnames, IPs, account names, private project names
- The contents of `KNOWN_ISSUES.md`, or a reference to it by name. External
  readers cannot see it, and naming it advertises that something is withheld.
  Describe the defect being fixed, not the local tracking entry.
- Screenshots or logs from the production host without scrubbing paths

If the PR fixes something recorded in `KNOWN_ISSUES.md`, describe the defect and
the fix on their own terms. After the fix is **deployed**, promote the full
detail into `ISSUES.md` as a resolved entry (`.claude/rules/problem-handling.md`).

## Step 5: report

```bash
gh pr view --web       # or: gh pr view
gh pr checks           # no CI is configured yet; expect an empty result
```

Give the user the URL, the branch name, and one line on what is still not
deployed.

## Never

- Force-push a branch someone else has reviewed
- Push directly to `main`
- Add an AI co-author line or a "Generated with …" footer to the commit or PR
- Claim CI passed — this repository has no CI and no test suite
