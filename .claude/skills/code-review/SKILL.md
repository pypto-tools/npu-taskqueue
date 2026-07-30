---
name: code-review
description: Review npu-taskqueue changes against this repository's standards — Bash correctness, the root/user boundary, the five kill paths, scheduler state, and doc drift. Use when reviewing a diff, preparing a commit, or when the user asks for a code review.
context: fork
allowed-tools: Read, Grep, Glob, Bash
---

# npu-taskqueue Code Review

You review; you do not edit. Report findings ranked by severity with
`file.sh:line` anchors and a concrete failure scenario for each.

## Scope

```bash
git diff                 # unstaged
git diff --cached        # staged
git diff main...HEAD     # a branch
```

Review the diff, but read enough of the surrounding function to judge it. In
this codebase a change is usually wrong because of what it does *not* touch —
one of five kill paths, one of two schedulers of the same device.

## What this code is

~3,300 lines of Bash. `task-daemon.sh` runs as **root** and executes strings
built from files that unprivileged users can write. `task-submit.sh` is the
client. `npu_lock.sh` is the mutex. A defect here means two jobs on one NPU, a
starved queue, or a user running as someone else — not a stack trace.

Read `.claude/rules/core-development.md` before the first review of a session.

## Checklist

### 1. Bash correctness

- [ ] Every expansion quoted. Unquoted splitting is deliberate and commented.
- [ ] Options taking an argument reject missing **and** malformed values.
      `shift 2` with `$# < 2` does not shift and does not exit the loop — that
      is an infinite loop, already present for six options (`ISSUES.md`, 14).
- [ ] No unvalidated value reaching `[[ $x -eq … ]]` or `$(( ))`. A non-numeric
      value evaluates to 0, which reads as "no limit" (`ISSUES.md`, 15).
- [ ] `local` on every function variable. Loop variables too — `find_free_devices`
      leaks `id` today.
- [ ] Array emptiness handled: `"${arr[@]}"` on an empty array, `${#arr[@]}`
      before indexing.
- [ ] No new fork inside a polling loop. The daemon polls 5×/s and may see 5,000
      processes; `session_pids` and `marked_pids` are hand-optimized for that
      reason, and a regression there stalls scheduling for minutes.
- [ ] `bash -n` clean. Ask the `verify` skill for the full pass.

### 2. The root/user boundary

- [ ] Nothing from `pending/`, `kill/`, or `fifo/` is trusted. Those directories
      are 1777 — identity comes from `stat -c %U`, never from a field in the
      file (`ISSUES.md`, 12 and 18).
- [ ] Any task-file field that reaches `bash -c`, `sed`, or `runuser` is
      pattern-checked at the point of use, not only at submit time. The submit
      path is bypassable.
- [ ] New files under `$BASE_DIR` get explicit permissions. Default umask puts
      0644 into a world-readable directory — that is how the environment
      snapshot leaks credentials.
- [ ] Nothing new runs as root that could run under `runuser`.

### 3. The five kill paths

`run_task` (after `wait`), `process_kills`, `reconcile_running`, `reap_orphans`,
`cleanup`.

- [ ] A change to victim-finding lands in **all five**. Four agreeing is exactly
      how the 800 GiB orphan incident happened (`ISSUES.md`, 11).
- [ ] Victims come from `task_pids` — the union of `session_pids` and
      `marked_pids`. Process-group or session alone misses any descendant that
      called `setsid()`.
- [ ] SIGTERM, grace, then SIGKILL. Nothing assumes a task dies on the first
      signal.
- [ ] `marked_pids`' task-id pattern guard survives. Without it, an empty or
      metacharacter-bearing id turns the `/proc` grep into "match everything".

### 4. Scheduler and state

- [ ] The `running/` file is removed only when the device is genuinely free —
      removing it is what lets another task be scheduled onto that card.
- [ ] No second owner for a finishing task. `run_task` and `reap_orphans`
      already race (`ISSUES.md`, 13); a third claimant needs an explicit claim,
      not a timeout.
- [ ] Ordering preserved: state file into `running/` before its `.env`, so
      "`.env` without state file" stays a reliable orphan signal.
- [ ] `IN_USE_SET` updated when a device is allocated mid-loop, or the same card
      goes to two tasks in one tick.
- [ ] `*.env` skipped in every loop over `running/` and `pending/`. One loop
      still forgets (`ISSUES.md`, 19).

### 5. Client behaviour

- [ ] Exit codes propagate. `--wait` returns the task's code; CI depends on it.
- [ ] A new option is added to the parser, the `usage()` text, `GUIDE.md`,
      `GUIDE_ZH.md`, and `claude-skill/task-submit/SKILL.md` together. A
      documented-but-unparsed option is a hard error for the user, and an
      English-only doc update strands the machine's actual readers.
- [ ] Client death still cleans up: `INT`, `TERM`, and `HUP` are all trapped —
      CI runners send TERM, and an untrapped TERM leaves an ownerless task that
      grabs the whole machine an hour later (`ISSUES.md`, 8's neighbours).
- [ ] Machine-readable output stays machine-readable. `--list` truncates at 77
      chars and must not be parsed; `--find` exists for that.

### 6. Docs and language

- [ ] Behaviour changes are reflected in `README.md` / `GUIDE.md` +
      `GUIDE_ZH.md` / the user skill. Doc drift here is a live hazard, not a
      tidiness issue: the "use logical device 0" instruction told users to run
      on the wrong card.
- [ ] Markdown is English, with `GUIDE_ZH.md` as the one sanctioned mirror;
      script messages and comments stay Chinese
      (`.claude/rules/docs-language.md`).
- [ ] Nothing internal (hostnames, IPs, user names, private project names) is
      added to a committed file — the repository is public.
- [ ] No exploitation detail for an unfixed vulnerability in a committed file
      (`.claude/rules/problem-handling.md`).

## Severity

| Level | Meaning |
|---|---|
| **Critical** | Root/user boundary, or two tasks can get one card |
| **High** | Task killed wrongly, task not killed, exit code lost, CI reports green without running |
| **Medium** | Queue stalls, misleading output, doc contradicts code |
| **Low** | Style, naming, a missing `local` with no reachable effect |

## Output

```text
## Code Review Summary
**Verdict:** ✅ Approve / ⚠️ Approve with comments / ❌ Request changes

### Critical
- `task-daemon.sh:466` — <defect>. Failure: <concrete inputs → wrong outcome>.
  Fix: <one or two sentences>.

### High / Medium / Low
[same shape]

### Not reviewed
[anything you could not judge, and why]
```

Say what breaks, for whom, and how to fix it. "Consider refactoring" is not a
finding. If the diff is clean, say so plainly rather than manufacturing
suggestions.
