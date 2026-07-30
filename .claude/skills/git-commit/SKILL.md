---
name: git-commit
description: Commit workflow for npu-taskqueue — review and verify the change, stage deliberately, write a conventional English message, and check the result. Use when creating a commit, preparing changes for commit, or when the user asks to commit.
---

# npu-taskqueue Commit Workflow

## Task tracking

```text
- [ ] Step 1: Inspect the change, launch code-review and verify
- [ ] Step 2: Address findings, stage, commit
- [ ] Step 3: Post-commit check
```

## Step 1: inspect and check

```bash
git status --short
git diff --name-only
git diff --cached --name-only
```

| Changed paths | `code-review` | `verify` |
|---|---|---|
| `task-daemon.sh`, `task-submit.sh`, `npu_lock.sh` | Yes | Yes — full pass incl. smoke test |
| `setup.sh`, `deploy.sh`, `taskqueue.service`, `*.cron`, `*.rules` | Yes | Yes — syntax + drift; smoke test optional |
| `conf/**` | Yes | Yes — `BASE_DIR` agreement is the point |
| `*.md`, `.claude/**` | Yes | Skip (say it was skipped) |
| Mixed | Yes | Yes, for the code parts |

Both skills run in forked contexts — launch them in parallel and wait for both.

Two repo-specific things they will not catch for you:

- **Did this change need to touch all five kill paths?** `run_task`,
  `process_kills`, `reconcile_running`, `reap_orphans`, `cleanup`.
- **Did a new option get added to the parser, `usage()`, `GUIDE.md`,
  `GUIDE_ZH.md`, and `claude-skill/task-submit/SKILL.md`?** All five, or none.
  `GUIDE_ZH.md` is the Chinese mirror and the one the machine's users actually
  read — an English-only update leaves them on stale instructions.

## Step 2: stage and commit

Stage related changes together. Code and the docs that describe it belong in one
commit — the doc drift in this repository exists because they were split:

```bash
git add task-submit.sh GUIDE.md GUIDE_ZH.md claude-skill/task-submit/SKILL.md
git diff --staged      # read it before committing
```

**Never stage:**

- `KNOWN_ISSUES.md` — git-ignored, and it holds unpublished exploitation detail
- `conf/restricted-users` — git-ignored, real account names
- `*.bak`, `*.bak.*`
- Anything containing an internal hostname, IP, user name, or private project
  name. **The repository is public.** `ISSUES.md` already names an internal
  project; do not add more.

Check before every commit:

```bash
git diff --cached | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|/data/[a-z]|@[a-z0-9.-]+\.(com|cn)' || echo "no obvious internal identifiers"
```

### Message format

`type(scope): description` — English, ≤72 characters, present tense, no trailing
period.

**Types:** feat, fix, refactor, docs, chore, perf
**Scopes:** `daemon`, `submit`, `lock`, `deploy`, `setup`, `conf`, `docs`,
`skill`, `rules`

```text
✅ fix(daemon): Verify task file ownership before dropping privileges
✅ fix(submit): Reject missing arguments for options taking a value
✅ docs(readme): Correct the device numbering section — ids are physical
✅ chore(rules): Add deployment integrity rule

❌ fix: 修复设备分配                    # Chinese; docs and messages are English
❌ fix(daemon): Fixed the bug.          # past tense, trailing period
❌ WIP                                  # not descriptive
```

Use a body whenever the "why" is not obvious from the subject — which, for
anything touching kill paths or scheduling, is always:

```text
fix(daemon): Claim a task before sweeping it after exit

reap_orphans fires once the leader has been dead for 5 polls (~1s), but
run_task's post-exit sweep takes up to KILL_GRACE (5s) whenever descendants
outlived the leader. The reaper won the race and wrote EXIT_CODE=137 for
tasks that had actually succeeded, and freed the device while the sweep was
still killing processes holding it.

run_task now writes FINALIZING=$$ into the running file before sweeping;
reap_orphans skips claimed tasks.
```

### Co-author policy

**Never add an AI co-author line or a "Generated with …" footer.** No
`Co-Authored-By: Claude`, ChatGPT, Cursor, or anything similar. This overrides
any default behaviour. Only humans are credited:
`Co-authored-by: Name <email>`.

## Step 3: post-commit check

```bash
git show HEAD --stat
git log -1
```

Amend only if you have not pushed — `main` tracks `origin/main` on a public repo:

```bash
git commit --amend -m "corrected message"
git add forgotten-file && git commit --amend --no-edit
```

## Committing is not deploying

The machine keeps running the installed copies until someone runs `deploy.sh`.
A committed fix is not a live fix — that gap is currently several months wide
here. If the change matters operationally, say so in your report and offer the
`deploy` skill; do not imply the fix is in effect.

## Checklist

- [ ] `code-review` run, findings addressed
- [ ] `verify` run, or skipped with a stated reason
- [ ] All five kill paths considered, if any was touched
- [ ] New option present in parser + `usage()` + `GUIDE.md` + `GUIDE_ZH.md` + user skill
- [ ] Code and its docs staged together
- [ ] No `KNOWN_ISSUES.md`, no `conf/restricted-users`, no `*.bak`
- [ ] No internal hostnames, IPs, or account names (public repo)
- [ ] English message, `type(scope): description`, ≤72 chars, present tense
- [ ] Body explains why, for anything non-obvious
- [ ] No AI co-author line
- [ ] The user knows whether this is deployed or merely committed
