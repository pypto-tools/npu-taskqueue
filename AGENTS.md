# AGENTS.md — npu-taskqueue

Guidance for AI agents and automated review (Claude Code, Codex, and others).
The authoritative conventions live in [`.claude/rules/`](.claude/rules/) and the
workflows in [`.claude/skills/`](.claude/skills/) — read those before changing
or reviewing code. This file is a short pointer.

## What this is

A file-system-based task queue for a shared Ascend NPU machine. `task-submit`
(user CLI) writes a task file; `task-daemon` (root) allocates a card from a
whitelist, takes a `flock` on it via `npu-lock`, and runs the command as the
submitting user with the `HwHiAiUser` group added. ~3,300 lines of Bash, no
build, no test suite, no CI.

`README.md` is the design reference, `GUIDE.md` the user manual, `ISSUES.md` the
defect tracker and incident history.

## Non-negotiables

- **The daemon is root and reads world-writable directories.** `pending/`,
  `kill/`, and `fifo/` are mode 1777. Never trust a field in a file found there;
  identity comes from `stat -c %U`. Pattern-check anything that reaches
  `bash -c`, `sed`, or `runuser`.
- **Five kill paths, not one.** `run_task`, `process_kills`,
  `reconcile_running`, `reap_orphans`, `cleanup`. Change victim-finding in all
  five or none. Use `task_pids` — session id alone misses `setsid()` escapees.
- **Quote every expansion. Guard every option that takes an argument.**
  `shift 2` with too few arguments does not shift and does not exit the loop.
- **No fork inside the daemon's polling loop.** It polls five times a second on
  a machine with thousands of processes.
- **The repository is the source of truth.** Never edit `/usr/local/bin/…` in
  place; a later `deploy.sh` erases it silently. Committed ≠ deployed — say
  which one you achieved.
- **The repository is public.** No internal hostnames, IPs, account names, or
  private project names in committed files. No exploitation detail for an
  unfixed defect — that goes in the git-ignored `KNOWN_ISSUES.md`.
- **Markdown is English; script messages and comments stay Chinese.** Do not
  translate user-facing output as a drive-by change.
- **Never add an AI co-author line or a "Generated with …" footer.**

## Verification

There is no test command. Do not invent one and never report "tests passed".

```bash
bash -n *.sh                    # must be clean
shellcheck -x *.sh              # if installed
```

Plus a rootless end-to-end run of the real queue in a scratch directory — the
[`verify`](.claude/skills/verify/SKILL.md) skill has the exact procedure, along
with the repo-vs-installed drift check that matters most here.

Before anything that touches system state, check whether you are on the
production host: `systemctl is-active taskqueue`.
