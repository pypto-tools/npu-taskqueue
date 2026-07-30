# AI Assistant Rules for npu-taskqueue

A lightweight task queue for a shared Ascend NPU machine. Users submit commands
with `task-submit`; a root daemon allocates a card, locks it, and runs the
command as the submitting user.

## What you are working on

~3,300 lines of Bash. No build, no test suite, no CI.

| File | Role | Lines |
|---|---|---|
| `task-submit.sh` | User CLI — submit, wait, log, kill, list, clean, maintenance | 1,306 |
| `task-daemon.sh` | Root daemon — schedule, allocate, drop privileges, watchdog, reap | 797 |
| `npu_lock.sh` | flock device mutex, multi-card in ascending order | 303 |
| `setup.sh` / `deploy.sh` | Install and re-deploy | 244 |
| `conf/` | `BASE_DIR`, `MAX_CONCURRENT`, `available_devices`, restricted-user roster | — |
| `claude-skill/task-submit/` | Skill shipped to *users of the queue* — not for developing this repo | — |

`README.md` is the design and deployment reference, `GUIDE.md` the user manual,
`ISSUES.md` the defect tracker and incident history. Read `ISSUES.md` before
touching the kill or scheduling paths — most of the non-obvious code is there
because of an incident recorded in it.

## Four things that will bite you

**The daemon runs as root and executes strings built from user-writable files.**
`pending/`, `kill/`, and `fifo/` are mode 1777 by design. Identity must come
from `stat -c %U`, never from a field in the task file — today it does not, and
that is the top open defect (`ISSUES.md`, issue 12).

**There are five places that kill a task**, not one: `run_task` after `wait`,
`process_kills`, `reconcile_running`, `reap_orphans`, `cleanup`. A change to
victim-finding must land in all five. Victims come from `task_pids`, the union
of session id and the `TASKQUEUE_TASK_ID` marker in `/proc/*/environ` —
process-group alone misses any descendant that called `setsid()`, which once
cost 800 GiB of shared memory and all 8 cards.

**Committed is not deployed.** The repository is the source of truth, but the
machine keeps running `/usr/local/bin/task-submit` until someone runs
`deploy.sh` — and as of 2026-07-29 the installed build predates every fix
committed here. Never edit an installed copy in place. See
`.claude/rules/deployment-integrity.md`, and check drift with the `verify`
skill before claiming anything is fixed.

**Card numbers are physical.** Nothing sets `ASCEND_RT_VISIBLE_DEVICES`, so
there is no logical 0-based view. The daemon hands the number over via an
appended `--device N`, a `{}` placeholder, or `$TASK_DEVICE`. Documentation
claiming otherwise was wrong for months and told users to run on the wrong card.

## Rules (`.claude/rules/`)

- **`core-development.md`** — Bash correctness, the root/user boundary, kill
  paths, scheduler state, public-repo secrets, no AI co-authors
- **`deployment-integrity.md`** — the repo is the source of truth; deploy
  pre-flight; the `BASE_DIR` trap
- **`problem-handling.md`** — blocking vs non-blocking; `ISSUES.md` (public) vs
  `KNOWN_ISSUES.md` (git-ignored, holds unfixed-vulnerability detail)
- **`docs-language.md`** — Markdown and GitHub metadata in English; script
  messages and comments stay Chinese
- **`documentation-length.md`** — docs ≤500 lines, rules and skills ≤200

## Skills (`.claude/skills/`)

- **`verify`** — syntax, shellcheck, repo-vs-installed drift, doc consistency,
  rootless end-to-end smoke test (`context: fork`)
- **`code-review`** — reviews a diff against the checklist above (`context: fork`)
- **`git-commit`** — review, verify, stage, conventional English message
- **`deploy`** — pre-flight, drain, `deploy.sh`, post-deploy smoke test
- **`github-pr`** — branch, rebase, push, PR with a deployment-status section
- **`create-issue`** — file an issue, with the public/private routing check

`verify` and `code-review` fork, so they can run in parallel during a commit
without consuming the main context.

## Two things to know before you start

**There is nothing to run but the scripts themselves.** No `make`, no `npm`, no
`pytest`. Verification is `bash -n`, `shellcheck` (not installed on this host),
and a real queue started under your own uid in a scratch directory — see the
`verify` skill. Never report "tests passed".

**This host may be the production machine.** `systemctl is-active taskqueue`
tells you. If it is active, real users have work in flight: do not restart the
service, do not write under the deployed `BASE_DIR`, and do not run a smoke-test
task that opens a real device — lock namespaces are per-`BASE_DIR`, so a scratch
queue will not exclude production's tasks.
