# TaskQueue: a lightweight task queue for shared NPU machines

## Summary

Implement a lightweight task queue for shared Ascend NPU machines, enabling multi-user job scheduling with automatic device allocation, mutual exclusion, and privilege separation. Users submit commands via `task-submit`, a root-privileged daemon dispatches them with flock-based NPU locking and `runuser` de-escalation, ensuring no two tasks compete for the same device.

## Motivation / Use Case

Shared NPU machines with multiple users face a core conflict:

```
User A: python train.py -d 0    ← occupies NPU 0
User B: python train.py -d 0    ← same device, silent corruption or crash
User C: python train.py -d 0    ← unaware of A and B
```

Without coordination:
- Users manually check `npu-smi` and pick a card — error-prone, race-prone
- No mutual exclusion — two jobs on the same NPU cause silent data corruption or OOM kills
- No privilege separation — users need direct device access, can't enforce policies
- No queuing — if all cards are busy, users busy-wait or give up

TaskQueue solves this with:
- **Automatic device allocation**: daemon picks a free NPU from a whitelist, user code just uses logical device 0
- **flock-based mutual exclusion**: `npu-lock` holds a file lock per device, released on process exit (even crashes)
- **Privilege separation**: daemon runs as root, tasks run as the submitting user via `runuser`
- **Queueing**: tasks wait in pending/ until a device is free, FIFO order

## Current Architecture

### Three-Layer Design

| Layer | Component | Mechanism | Purpose |
|---|---|---|---|
| Terminal isolation | `HwHiAiUser` group | `/dev/davinci*` is `0660 root:HwHiAiUser` | A restricted user's own shell cannot open a device |
| Device mutex | `npu-lock` / flock | Per-device lock files | Prevent concurrent NPU access |
| Device allocation | daemon / `available_devices` | Whitelist (currently `0,1,2,3,12,13,14,15`) | Pool `--device auto` draws from |

**Environment**: 16 NPU cards (physical 0-15), 50 restricted users, `MAX_CONCURRENT=15`.

Terminal isolation used to be a `profile.d` script exporting
`ASCEND_RT_VISIBLE_DEVICES`; that file is now a comment-only no-op and the
`99-npu-taskqueue.rules` udev file is likewise inert. Nothing in the deployed
path sets `ASCEND_RT_VISIBLE_DEVICES`, so **all device numbers are physical** —
see issue 16.

### Task Lifecycle

```
User                        Daemon                      AICore
  │                           │                           │
  ├─ task-submit "cmd" ──►  pending/task_xxx             │
  │   (snapshot env,          │                           │
  │    write task file)       │                           │
  │                         ┌─┤ poll: mv pending→running  │
  │                         │ ├─ resolve_device(auto→12)  │
  │                         │ ├─ npu-lock 12 flock()      │
  │                         │ ├─ inject TASK_DEVICE=12    │
  │                         │ ├─ runuser -u $USER -- cmd ─┼──► execute on NPU 12
  │                         │ │   (watchdog: max-time)    │
  │  --wait ──► tail -f log │ │                           │
  │                         │ ├─ wait $pid; exit_code=$?  │
  │                         │ ├─ write done/task_xxx      │
  │                         │ └─ release flock            │
  │  ◄── exit $exit_code ──┘                              │
```

### Components

| File | Role |
|---|---|
| `task-submit.sh` | User CLI: submit, wait, log, cancel, kill, list, maintenance, device management |
| `task-daemon.sh` | Root daemon: poll pending/, allocate devices, de-escalate, timeout watchdog |
| `npu_lock.sh` | flock-based device mutex, multi-card deadlock-free (ascending lock order) |
| `taskqueue-npu.sh` | profile.d script: terminal device visibility control |
| `setup.sh` | First-time install (system-level or `--local` user-level) |
| `deploy.sh` | One-command redeploy after source changes |

### What's Working

**Core**: task-submit → daemon dispatch → npu-lock → runuser execution → done, full lifecycle with `--wait`/`--status`/`--log`/`--cancel`/`--kill`. Ctrl+C during `--wait` auto-cancels pending or sends kill request to running tasks.

**Device management**: `--device auto` allocates from whitelist, `--device-num N` for multi-card, `--devices "2,3,4,5"` hot-reloads whitelist via SIGHUP. npu-lock supports multi-card ascending-order locking with reentry detection.

**Environment**: full env snapshot at submit time (`env -0`), `--env`/`--env-file` overrides, `~/.task-env` user-level setup script sourced before execution. `ASCEND_RT_VISIBLE_DEVICES` is stripped from the snapshot and never re-injected; `TASK_DEVICE` carries the physical card number.

**Operations**: systemd service with PID singleton, maintenance mode, `--clean`, log rotation (1MB cap), colored `--list` output.

## Known Issues

### P0 — Correctness / Security

1. **Orphaned tasks on daemon restart** — `cleanup()` kills running processes but never writes `done/` records. Tasks remain in `running/` after daemon restart: not rescheduled, not cleared, invisible to users. (task-daemon.sh:322-338)

2. **Env snapshot world-readable** — `pending/` has permission 1777. The `.env` file captures the user's full environment (potentially including `*_API_KEY`, `*_SECRET`, `*_TOKEN`). Any user on the machine can read it. (task-submit.sh:320-329)

3. ~~**`parse_task_file` truncates values containing `=`**~~ — **NOT A BUG (misdiagnosis, corrected 2026-07-29)**: `IFS='=' read -r key value` does not stop at the first `=`. `read` assigns everything left over to the *last* variable, delimiters included, so `COMMAND=python train.py --lr=0.01` yields `value=python train.py --lr=0.01`. Verified:

   ```bash
   $ printf 'COMMAND=python train.py --lr=0.01\n' |
     while IFS='=' read -r k v; do echo "key=[$k] value=[$v]"; done
   key=[COMMAND] value=[python train.py --lr=0.01]
   ```

   The real (much smaller) defect is that a **trailing** `=` is eaten, because a
   single trailing non-whitespace IFS delimiter marks an empty final field:
   `A=b=` parses as `value=b`. Both `parse_task_file` and `read_field` are
   affected, so a command ending in `=` loses that character. Tracked below as
   issue 20.

12. **daemon does not verify task-file ownership** — `run_task` takes `SUBMIT_USER` from the task file body and never compares it against the file's owner, while `pending/` is world-writable (mode 1777) by design. The user identity a task runs as is therefore attacker-controlled rather than authenticated, and every check that lives in `task-submit` (blocked commands, device parsing, nesting guard) is bypassable by writing the file directly. `USER_HOME` has the same property and is sourced (`source $USER_HOME/.task-env`) before the command runs. Fix: derive the user from `stat -c %U` on the task file, reject root-owned files, resolve `USER_HOME` via `getent passwd`, and validate `DEVICE` / `MAX_TIME` / `WORK_DIR` against strict patterns before interpolating them into a shell string. (task-daemon.sh:349-468, setup.sh:149)

4. ~~**Unknown option silently becomes the task command → CI passes without running anything**~~ — **RESOLVED (2026-07-14)**: the option loop ended in `*) break`, so an unrecognized flag stopped parsing and everything after it — including `--run` — was dropped. `$1` then fell through the main `case` to `submit_task "$1"`, submitting the literal flag string as the command; with `RUN_MODE` unset, `task-submit` printed a task-id and exited **0**.

   Hit in production: `task-submit.sh` was deployed from this repo on 2026-07-13, silently rolling the installed binary back from the 07-07 build (which had `--ignore-whitelist`) to the 06-29 build (which did not) — the 07-03/07-07 changes had only ever been copied into `/usr/local/bin`, never committed back here. The pypto-serving CI action calls `--device auto --device-num 8 --ignore-whitelist ... --run "<pytest>"`, so from 07-13 until the fix it locked 8 cards, ran the string `--ignore-whitelist`, skipped pytest entirely, and reported **green**.

   Fix: unknown `--*` now exits 1 with a "本机 task-submit 过旧，请重新部署" hint; real subcommands (`--wait`/`--list`/…) break out explicitly; `submit_task` refuses any command starting with `--`. **Always `deploy.sh` from this repo — never edit `/usr/local/bin/task-submit` in place.**

11. ~~**Descendants that call `setsid()` escape every kill path**~~ — **RESOLVED (2026-07-14)**: all four sweep sites found victims by session id (`session_pids`) or process group. Both are escapable: a descendant that calls `setsid()` becomes its own session *and* group leader, so its SID is no longer `TASK_PID` and it is invisible to all of them. `process_kills` even carried a comment claiming it "covered re-setsid'd descendants" — it did not.

    Hit in production: pypto-serving's accuracy test starts the inference engine with `subprocess.Popen(start_new_session=True)` (so it can `killpg` the engine's own workers). When the task is killed — `--max-time` watchdog or a cancelled/re-run CI job — pytest dies without running its `finally`, and the engine survives in its own session. Four had accumulated by the time it was noticed, holding **~800 GiB of shared memory** and all 8 NPU cards; the queue was starving with `no free device` while 1.5 TiB of RAM sat unusable. The cards had been released (npu-lock traps its shell), so nothing in `--list` or `running/` hinted at it — only `free -h` did.

    Fix: daemon injects `TASKQUEUE_TASK_ID=<task_id>` into every task's environment. `environ` is inherited across fork/exec and `setsid()` does not rewrite it, so it is the one mark a descendant cannot shed — unlike session and process group, which it can. `marked_pids` greps `/proc/*/environ` for it (single grep over all of `/proc`, not one fork per pid — see the `session_pids` lesson), `task_pids` unions that with `session_pids`, and all four sweep sites (`run_task` post-exit, `process_kills`, `reconcile_running`, `reap_orphans`, plus `cleanup`) now use the union. The session half is still needed: tasks submitted before the upgrade have no marker in their environment.

    The test side is fixed separately — CPython leaves SIGTERM at `SIG_DFL`, so `finally`/`atexit` never run on a plain `kill`; the test now installs a SIGTERM handler that raises, and sets `PR_SET_PDEATHSIG` as a backstop for SIGKILL.

### P1 — Correctness / User Experience

5. **Blocked command filter false positives** — Substring regex matching: `passwd`, `shutdown`, `reboot` etc. have no word boundaries. `cat /etc/passwd`, `grep shutdown /var/log`, `python train.py --tag reboot-exp` all rejected. (task-submit.sh:257-279)

6. **`--max-time` defaults to 300s** — Most training jobs exceed 5 minutes. Users unaware of the default get silently killed. Documented in GUIDE.md but easily missed. (task-submit.sh:36)

7. **Auto-inject `-d` heuristic unreliable** — Daemon appends `-d $DEVICE` to command tail. Not all programs use `-d` for device; appending may cause CLI parse errors; user unaware of injection. Skip conditions (pipe, `&&`, `--device` present) are incomplete. (task-daemon.sh:203-222)

8. ~~**`--wait` silently truncates the first lines of task output**~~ — **RESOLVED (2026-07-14)**: `wait_task` followed the log with a bare `tail -f`, which starts at the **last 10 lines**. Anything the task printed before `tail` attached was dropped from the user's view — the log file itself was always complete.

   Surfaced as "the devices it says it locked don't match the ones it actually locked": an 8-card task emits 16 npu-lock lines (2 per device), so `tail -f` began at line 7 and the locks for the first 3 cards were invisible. Nothing was wrong with the locking. Fixed by `tail -n +1 -f`.

13. **`reap_orphans` finalizes a task while `run_task` is still sweeping it** — `reap_orphans` fires once the leader pid has been dead for 5 consecutive polls (~1s at `POLL_INTERVAL=0.2`). But after `wait` returns, `run_task` calls `sweep_task`, which takes up to `KILL_GRACE` (default 5s) whenever descendants outlived the leader — i.e. exactly the case `sweep_task` exists for. The reaper wins the race and writes `done/` with `EXIT_CODE=137` plus "任务被中断（daemon 停止或重启）" in the log, so a **successful** task is reported to `--wait` as killed; it also removes the `running/` file early, freeing the device for scheduling while the sweep is still killing processes that hold it. `run_task` then overwrites `done/` with the real exit code. Fix: have `run_task` claim the task before sweeping (write `FINALIZING=$$` into the running file and skip those in `reap_orphans`), or raise the threshold above `KILL_GRACE / POLL_INTERVAL`. (task-daemon.sh:489-523, 615-639)

14. **A missing option argument spins forever** — the option loop uses `shift 2` for `--timeout`, `--device-num`, `--days`, `--env`, `--env-file`, and `--max-time`. Bash leaves the positional parameters untouched when `n > $#`, so `$1` never changes and the `while` loop never exits: `task-submit --timeout` burns 100% of a core and never returns. Only `--device` has a missing-argument check. (task-submit.sh:163-196)

15. **Numeric options are not validated, and both failure modes are silent** — `--max-time abc` makes the daemon's `[ "$MAX_TIME" -gt 0 ] 2>/dev/null` fail, which **disables the watchdog** (the task never times out); `--timeout abc` evaluates to 0 in `[[ $TIMEOUT -eq 0 ]]`, which means **wait forever**. Neither prints a warning. `--device-num` already has `is_positive_int`; apply it to the other two. (task-submit.sh:165, 182)

16. **Documentation describes a device-numbering scheme that no longer exists** — README and GUIDE both state "always use logical device 0, 1, 2… in your code, never hard-code the physical card number". That was true when `ASCEND_RT_VISIBLE_DEVICES` was injected and CANN remapped the visible cards to a 0-based range. Nothing sets that variable any more: `taskqueue-npu.sh` is a comment-only no-op, the daemon injects only `TASK_DEVICE`, and `task-submit` strips `ASCEND_RT_VISIBLE_DEVICES` out of the environment snapshot. Card numbering seen by the task is therefore **physical**, and the auto-appended `--device N` carries a physical id. Following the old instruction means locking card 13 and running on card 0 — the exact double-occupancy this system exists to prevent. Related drift: the whitelist is documented three different ways (`conf/available_devices` = `0,1,2,3,12,13,14,15`, README = `12,13,14,15`, `claude-skill/task-submit/SKILL.md` = "cards 4-15"), and the "three-layer design" table still lists terminal isolation via `ASCEND_RT_VISIBLE_DEVICES` as an active layer when the actual mechanism is `HwHiAiUser` group membership. (Docs corrected 2026-07-29; the whitelist numbers still need an owner's decision.)

### P2 — Edge Cases

9. **task-id collision under concurrency** — `task_$(date)_${$}${RANDOM}`: same PID in a loop, `$RANDOM` range 0-32767, theoretical collision within one second. (task-submit.sh:302)

10. ~~**Non-interactive submit silently skips device check**~~ — **RESOLVED**: the `warn_no_lock` interactive prompt is gone, so the interactive and non-interactive paths behave identically. (The original note claimed this was fixed by making `--device auto` the default — see issue 17, that part never landed.)

17. **`--device auto` is not the default, contrary to what this document claimed** — the "Implemented: Transparent Device Allocation" section asserted that a bare `task-submit --run "..."` allocates a card and that `--no-device` opts out. In the code, `LOCK_DEVICE` defaults to empty, `build_device_request` returns an empty string, and the daemon then allocates nothing, locks nothing, and injects no `TASK_DEVICE`. GUIDE and the skill file document the actual behaviour (an explicit `--device auto` is required); this file was the outlier. Either implement the default or drop the idea — but the two must not disagree, because "the docs say a card is allocated" is how a job ends up racing a terminal user for a card. (task-submit.sh:33, 223-241)

18. **Kill markers and interactive FIFOs are not owner-checked** — `process_kills` acts on any file present in `kill/`, and the interactive FIFO is created world-writable; both directories are mode 1777, and task ids are public via `--list`. A user can therefore terminate another user's job or write into its stdin. Fix: compare `stat -c %U` on the marker against the target task's owner, and create FIFOs owned by the submitting user with mode 600. (task-daemon.sh:452-461, 661-708, setup.sh:151)

19. **`--list` renders orphan `.env` snapshots as tasks** — the Pending loop skips `*.env`, the Running loop does not, so a snapshot left in `running/` (up to 60s, until `reap_orphan_envs` collects it) appears as a task row with an empty command. One missing line. (task-submit.sh:1168-1169)

20. **Trailing `=` is stripped from task-file values** — `IFS='=' read -r k v` treats a single trailing delimiter as an empty final field, so `COMMAND=... base64 -d <<< $x=` loses the final character. Affects `parse_task_file` and `read_field`. Use `v="${line#*=}"` instead. (task-daemon.sh:23-62)

21. **A killed task reports exit 130, not 143** — `npu-lock`'s SIGTERM trap ends with a hard-coded `exit 130`, which propagates through `bash -c` and `runuser` into the `done/` record. `wait_task` only special-cases 143 as "任务已终止", so a deliberately killed task is displayed as "任务失败 (exit=130)". Either have the trap re-raise the signal (`trap - TERM; kill -TERM $$`) or teach the client that 130/137/143 all mean "terminated". (npu_lock.sh:263-274, task-submit.sh:819)

22. **`--device` accepts arbitrary strings** — the value is stored verbatim, later interpolated into `sed -i "s/^DEVICE=.*/DEVICE=$dev/"` and into the `bash -c` string the daemon builds. It executes as the submitting user, so this is not an escalation, but a value containing `/` breaks the `sed` rewrite and leaves `DEVICE=auto` in the running file. Validate against `^(auto|none|[0-9]+(,[0-9]+)*)$` at submit time and again in the daemon. (task-submit.sh:166-173, task-daemon.sh:440-442)

23. **`deploy.sh` restarts the daemon unconditionally and kills every running task** — `taskqueue.service` does not set `KillMode`, so the default `control-group` applies and `systemctl restart` SIGTERMs everything in the service cgroup, setsid'd tasks included; `reconcile_running` then records them as `EXIT_CODE=137`. Deploying during working hours silently destroys other people's jobs. Fix: check `running/` first and refuse (or require `--force`), and prefer draining via `--maintenance on`. (deploy.sh:46, taskqueue.service)

24. **`conf/restricted-users` is deployed but never read** — `deploy.sh` copies it to `/etc/taskqueue-restricted-users` and no script in the repository ever opens that path. The actual restriction is manual `gpasswd -d <user> HwHiAiUser`. The file is documentation masquerading as configuration: editing it and running `deploy.sh` changes nothing, which is a trap for whoever maintains the roster next. Either make `deploy.sh` reconcile group membership from it, or state in the file that it is a record only. (deploy.sh:36-43)

25. ~~**`deploy.sh` overwrites `/etc/taskqueue.conf`, silently repointing a `BASE_DIR` set at install time**~~ — **RESOLVED (2026-07-29)**: `setup.sh` accepts `--base-dir` and every host chooses its own, but `deploy.sh` copied `conf/taskqueue.conf` over `/etc/taskqueue.conf` unconditionally. When the two disagreed, a routine update moved the queue to a different directory — `pending/`, `running/`, `done/` and the locks all stayed under the old `BASE_DIR`, the daemon kept using the old path until it restarted, and clients switched immediately. Worse than a clean break: `set -e` then aborted at the next line (`cp conf/available_devices "$BASE_DIR/available_devices"`, into a directory that does not exist), leaving new scripts installed, the conf repointed, and **no restart** — so the daemon went on running the old code while every user's `task-submit` failed to write a task file.

    Fix: `BASE_DIR` is now treated as a per-machine property. `deploy.sh` reads the host's existing `/etc/taskqueue.conf` and keeps its `BASE_DIR`, syncing only the other keys from the repository; the committed value is used solely when the host has no conf at all. Host-only keys (e.g. `KILL_GRACE`) are carried over instead of being erased, and the script now validates that `BASE_DIR` exists **before** copying anything, so a misconfigured host fails cleanly instead of half-deployed. (deploy.sh:12-69, conf/taskqueue.conf)

## Implemented: Privilege Separation via the `HwHiAiUser` Group

NPU access is enforced through `task-submit` by Linux group-based device
permissions. `/dev/davinci*` is `0660 root:HwHiAiUser` (the group is created by
the CANN driver installer, so no `groupadd` and no udev rule of our own are
needed). Restricted users are removed from that group, so their own shell cannot
open a device; the daemon adds it back for the duration of the task:

```text
User shell (not in HwHiAiUser) → /dev/davinci* is 0660 → access denied
task-submit → daemon (root) → runuser -u $USER --supp-group HwHiAiUser → access granted
```

The task still runs as the submitting user, so it reads and writes that user's
files normally; the only thing it gains is device access. No ACLs and no
two-phase uid switching.

Two caveats worth knowing:

- Group membership is edited **by hand** (`gpasswd -d <user> HwHiAiUser`).
  `conf/restricted-users` is a record of who should be restricted, not an input
  to anything — see issue 24.
- This separates *users* from the devices. It does not separate users from the
  *queue*: `pending/` is world-writable, and the daemon believes what it reads
  there — see issue 12. Fixing that is the next step.

## Proposed Next Step: Authenticate the Task File

Make the daemon trust the filesystem instead of the file body: take the
submitting user from `stat -c %U`, refuse root-owned task files, resolve
`USER_HOME` from `getent passwd`, and pattern-check every field the daemon
interpolates into a shell string. This closes issue 12 and, with it, all the
client-side checks that are currently bypassable by writing to `pending/`
directly.
