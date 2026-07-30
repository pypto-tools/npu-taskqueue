---
name: create-issue
description: File a GitHub issue on better-ci/npu-taskqueue, with the public/private routing check that a public repo and an unfixed vulnerability require. Use when the user wants to file a bug, request a feature, or open an issue for this queue.
---

# Create an Issue (npu-taskqueue)

Repository: `better-ci/npu-taskqueue` — **public**, no issue templates, no
labels configured yet.

## Step 0: does this belong on GitHub at all?

Ask before writing anything. Three destinations:

| The problem | Where it goes |
|---|---|
| Security defect, **not yet fixed** | `KNOWN_ISSUES.md` (git-ignored). **Not** a public issue. |
| Anything else worth tracking in-repo | `ISSUES.md`, numbered, under P0/P1/P2 |
| Something a person needs to act on, discuss, or be assigned | GitHub issue |

`ISSUES.md` is this repository's defect tracker and it works — 24 entries with
incident write-ups. A GitHub issue is for work that needs a conversation or an
owner, not for recording a defect you just found. Recording is
`.claude/rules/problem-handling.md`; this skill is for the other case.

**Never open a public issue describing how to exploit an unfixed defect on this
machine.** ~50 people are logged into it. If the user asks for one anyway, say
plainly why not, offer the `KNOWN_ISSUES.md` entry instead, and let them decide.

## Step 1: check for duplicates

```bash
gh issue list --repo better-ci/npu-taskqueue --state all --limit 50
gh issue list --repo better-ci/npu-taskqueue --search "device auto" --state all
grep -n "<keyword>" ISSUES.md
```

If `ISSUES.md` already has it, the issue should reference that number rather
than restate it.

## Step 2: classify

| Type | Title prefix | Needs |
|---|---|---|
| Bug | `bug:` | Repro, observed vs expected, affected script and line |
| Feature | `feat:` | The problem it solves, not the solution you have in mind |
| Ops / deployment | `ops:` | Current state of the host, what should be true |
| Docs | `docs:` | The wrong statement, and what the code actually does |

## Step 3: write it

```bash
gh issue create --repo better-ci/npu-taskqueue \
  --title "bug: --wait exits 130 instead of 143 when a task is killed" \
  --body "$(cat <<'EOF'
## Summary

One sentence: what is wrong.

## Observed

```
$ task-submit --kill task_20260729_120000_12345
$ task-submit --status task_20260729_120000_12345
completed (exit=130)
```

## Expected

`143`, or a client that treats 130/137/143 alike, so a deliberately killed
task is not displayed as "任务失败".

## Where

`npu_lock.sh:263-274` — the SIGTERM trap ends in a hard-coded `exit 130`, which
propagates through `bash -c` and `runuser` into the `done/` record.
`task-submit.sh:819` only special-cases 143.

## Related

`ISSUES.md` issue 21.
EOF
)"
```

Rules for the body:

- **Quote script output verbatim, in Chinese.** The scripts print Chinese; a
  translated quote cannot be grepped for. Prose around it stays English
  (`.claude/rules/docs-language.md`).
- **Anchor to `file.sh:line` and the function name.** Line numbers drift.
- **Scrub before submitting.** No internal hostnames, IPs, account names,
  private project names, or absolute paths from the production host. Replace a
  real task id with a plausible one.
- **No reproduction steps for an unfixed security defect.** See step 0.

## Step 4: after creating

```bash
gh issue view <n> --repo better-ci/npu-taskqueue
```

Give the user the URL. If the issue mirrors an `ISSUES.md` entry, add the issue
number to that entry so the two do not drift apart.
