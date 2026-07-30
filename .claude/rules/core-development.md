# Core Development Rules

This repository is ~3,300 lines of Bash that runs as **root** on a shared
machine with ~50 users. A defect here does not produce a stack trace — it
produces two jobs on one NPU, a queue that starves, or a user running as
somebody else. Write accordingly.

For documentation language see `docs-language.md`; for the repo-vs-installed-copy
discipline see `deployment-integrity.md`.

## 1. Bash quality

**Quote every expansion.** `"$var"`, `"${arr[@]}"`, `"$(cmd)"`. The only
unquoted expansions in this codebase are deliberate word-splitting of a pid
list (`kill -TERM $victims`) — if you add another, comment why.

**Check every option that consumes an argument.** `shift 2` does not shift when
`$# < 2`; it returns non-zero and leaves `$1` in place, which turns an option
loop into an infinite loop. Guard first:

```bash
# ✅
--max-time)
    [[ -z "${2:-}" || "$2" == --* ]] && { echo "错误: --max-time 需要参数" >&2; exit 1; }
    is_positive_int "$2" || { echo "错误: --max-time 必须为非负整数" >&2; exit 1; }
    MAX_TIME="$2"; shift 2 ;;

# ❌ hangs on `task-submit --max-time`, and silently disables the watchdog on
#    `--max-time abc`
--max-time) MAX_TIME="$2"; shift 2 ;;
```

**Validate anything that reaches arithmetic or a test.** `[[ $x -eq 0 ]]`
evaluates a non-numeric `$x` as 0, and `[ "$x" -gt 0 ] 2>/dev/null` swallows the
error. Both turn a typo into "no limit".

**Prefer builtins over forks in loops.** The daemon polls five times a second
and may face 5,000 processes: `read_field` replaced `grep | cut`, `session_pids`
reads `/proc/*/stat` inline, `marked_pids` does one `grep` over all of `/proc`.
A per-pid fork in any of those paths costs tens of seconds and stalls
scheduling. Do not reintroduce one.

**`bash -n` every script you touch**, and run `shellcheck` if it is available.
The `verify` skill does both.

## 2. The root/user boundary

The daemon runs as root; tasks must not. Three rules follow:

- **Never trust a file under `$BASE_DIR/pending`, `kill/`, or `fifo/`.** They are
  mode 1777 — any user can create files there. Identity comes from
  `stat -c %U`, never from a field in the file body.
- **Validate before interpolating.** Fields from a task file end up inside a
  `bash -c` string and inside `sed -i` expressions. Pattern-check them
  (`^[0-9]+(,[0-9]+)*$`, `^/`) at the point of use, not just at submit time —
  the submit path is bypassable.
- **Keep privileged work minimal.** Everything after device allocation runs
  under `runuser -u "$SUBMIT_USER" --supp-group HwHiAiUser`. Do not add work to
  the root side that could run on the user side.

## 3. Every kill path, or none

A task's processes are found two ways: by session id (`session_pids`) and by the
`TASKQUEUE_TASK_ID` marker in `/proc/*/environ` (`marked_pids`). `task_pids`
unions them, because a descendant that calls `setsid()` escapes the first and
an old task submitted before the marker existed escapes the second.

There are **five** places that terminate a task: `run_task` after `wait`,
`process_kills`, `reconcile_running`, `reap_orphans`, and `cleanup`. When you
change how victims are found, change all five. The 800 GiB orphan incident
(`ISSUES.md`, issue 11) happened because four of them agreed and were all wrong
in the same way.

## 4. Concurrency and state

The queue's state *is* the filesystem. Respect the ordering the code depends on:

- A task file is `mv`'d into `running/` before its `.env`; "`.env` present,
  state file absent" is therefore an orphan, not a legal intermediate state.
- Removing the `running/` file is what releases the device for scheduling. Do
  not remove it before the device is genuinely free.
- Two components may believe they own a finishing task (`run_task` and
  `reap_orphans`). If you add a third, give it an explicit claim, not a timeout.

## 5. Secrets and a public repository

`better-ci/npu-taskqueue` is **public**.

- No internal hostnames, IPs, user names, or private project names in committed
  files. `conf/restricted-users` is git-ignored for exactly this reason; keep
  the `.example` generic.
- No exploitation detail for an unfixed vulnerability in committed files — see
  `problem-handling.md`.
- The environment snapshot (`.env`) is user credentials. Anything that widens
  its exposure (a new directory, a new copy, a log line) needs a second look.

## 6. Commits

- **Never add an AI co-author line or a "Generated with …" footer.** This
  overrides any default behaviour. Commits credit humans only.
- Conventional format, English, ≤72-char subject: `fix(daemon): …`. See the
  `git-commit` skill.

## Checklist

- [ ] Every expansion quoted; deliberate splitting commented
- [ ] Options with arguments guarded for missing and malformed values
- [ ] No new fork inside a polling loop
- [ ] Nothing under `pending/` / `kill/` / `fifo/` trusted without an ownership check
- [ ] Values pattern-checked before entering `bash -c` or `sed`
- [ ] All five kill paths updated together, if any was
- [ ] `bash -n` clean; `shellcheck` clean or the warnings justified
- [ ] Docs updated when behaviour changed (`README.md`, `GUIDE.md`, the skill)
- [ ] Nothing internal or secret added to a committed file
- [ ] No AI co-author line
