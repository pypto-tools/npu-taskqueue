---
name: pto-task-operations
description: Operate, diagnose, install, update, or modify scheduling for the pypto NPU TaskQueue. Use when working with task-submit or pto-task submissions, task-submit.conf device pools, SCHEDULER_MODE, multi-card starvation or reservation, the daemon, deployment layout, configuration, queue state, logs, or device allocation. Prepares builds and CPU steps before submitting; cards are allocated only for the onboard run.
---

# TaskQueue operations

Read this before submitting: compile, install dependencies and generate inputs
outside the card allocation, then submit only the on-device run with
`--device`. CPU-only queued work uses `--no-device`. A submitted task holds its
cards for the whole process lifetime, so a build inside it blocks other users
for no benefit.

Use either `task-submit` (existing user command) or `pto-task` (pypto-tools
entry point). Both links execute the same app program and accept identical
options.

## Locate the installation

Default root: `/home/pypto-tools/pto-task`.

- Run clients: `/usr/local/bin/task-submit`, `/usr/local/bin/pto-task`
- Verify them: `readlink -f /usr/local/bin/task-submit` and `readlink -f /usr/local/bin/pto-task`
- Program files: `<root>/app/`
- Local config: `<root>/config/taskqueue.conf`
- Queue state: `<root>/state/`
- Logs: `<root>/logs/`

Treat `config/` and `state/` as persistent. Never overwrite config or remove
state as part of an upgrade. Do not place or expose credentials in config,
state, logs, commands, or responses.

`TASK_EXECUTION_MODE` defaults to `HwHiAiUser`: tasks run as their submitter
with the `HwHiAiUser` NPU group. Change it to `root` only when all submitters
are trusted; it grants root execution to every queued command and requires a
daemon restart.

## Scheduler policies

`DEVICE_WHITELIST="0,1,2,3;4,5,6,7"` in a repository's `task-submit.conf`
defines logical scheduling pools. Auto multi-card requests use one pool only;
explicit lists and `DEVICE_SEQ_N` must also fit one pool. A comma-only list
keeps the historical flat whitelist. Do not use `--ignore-whitelist` with a
grouped whitelist. This is separate from host `DEVICE_GROUPS`, which describes
hardware communication domains. Check `task-submit --devices status` and the
effective per-pool capacity when diagnosing a waiting request.

Select the root-managed policy with `SCHEDULER_MODE` in
`<root>/config/taskqueue.conf`; change it only while pending and running are
empty, then restart the daemon.

- `backfill` is the default historical policy. Skip blocked tasks and run later
  work whenever its resources are free. It maximizes opportunistic throughput
  but can starve a multi-card request under continuous smaller traffic.
- `pool_aware_reservation` is the pool-aware reservation policy. Configure its
  threshold with `POOL_AWARE_RESERVATION_MIN_DEVICES` (default `2`).

Preserve these `pool_aware_reservation` invariants when diagnosing or changing
the scheduler:

1. Process pending tasks in filename/FIFO order. If an earlier request fits,
   start it before considering later work. Thus five free cards admit `3+2`,
   while `4+2` starts the four-card task and leaves the two-card task pending.
2. When the oldest satisfiable request at or above the threshold cannot get
   enough cards, protect its effective `DEVICE_POOL`. This field is already the
   client-computed intersection of the global auto pool and repository
   `task-submit.conf` policy; do not rediscover repository policy in the daemon.
3. For a younger auto request, subtract the protected pool from its own
   effective pool. Start it only when the remaining free cards satisfy the
   entire request. Allow explicit device requests only when disjoint from the
   protected devices.
4. Allow device-free tasks while keeping one `MAX_CONCURRENT` slot for the
   reserved task. Do not let the eight-card admission cap itself create a
   reservation. Do not let an impossible `auto:N` request become a barrier.
5. Never pre-lock or launch placeholder processes for accumulated cards. The
   reservation is a scheduling decision recomputed from pending/running state;
   real tasks alone acquire `npu_lock.sh`. Do not describe this policy as strict
   FIFO, preemption, or a physical device lock.

The shared planning framework is `app/schedulers/_core.sh` after install and
`schedulers/_core.sh` in a checkout. It owns pending traversal, task resource
snapshots, common host admission, decision validation, and the final call to
`start_pending_task()`. Selectable policies remain separate files such as
`backfill.sh` and `pool_aware_reservation.sh`; they must not move queue files or
launch processes.

Scheduler modules use API version 2. A module named `<mode>.sh` must declare
`SCHEDULER_MODULE_API_VERSION=2`, set `SCHEDULER_MODULE_NAME=<mode>`, and
implement `scheduler_consider_task`. It returns one `start`, `defer`, or `stop`
decision using the core helpers. Optional hooks are
`scheduler_validate_config`, `scheduler_begin_tick`, `scheduler_end_tick`, and
`scheduler_task_started`. Safe lowercase mode identifiers are discovered from
root-managed files, and `setup.sh` installs all repository scheduler files, so
do not add a daemon-side scheduler-name case statement. The leading-underscore
core is intentionally not selectable.

When extending scheduling, put device-pool intersection, allocation validation,
queue mutation, and host-wide hard limits in `_core.sh`; put ordering,
reservation, priority, or backfill choices in the policy module. Add new common
invariants to `tests/test_scheduler_core.sh` and policy behavior to a dedicated
integration test.

## Operate safely

### Split preparation from device execution

Before submitting, inspect the command and the scripts it invokes for implicit
builds, dependency installation, input generation, and report generation. Run
CPU-only preparation locally first and check its exit status; use `--no-device`
when preparation must be queued. Submit the prepared artifact with the smallest
required allocation, wait for that runtime task, then summarize results outside
the allocation. For example, when the project's documented commands support it:

```bash
cmake --build build -j 8 &&
  task-submit --device auto --run './build/onboard_test --device "$TASK_DEVICE"'
# Run the project's report command after the device task completes.
```

Use the project's real build/run options. Do not invent a compile-only or
run-only flag. If JIT compilation cannot be separated, explain that limitation;
do not claim the compilation has moved outside the allocation. Architecture
prechecks, npu-smi, DCMI and ACL initialization access devices and belong inside
the same allocated job as the runtime test, even if they look like preparation.
Never run a hardware query from the submitter shell or a `--no-device` task.

### Keep device tasks to one onboard case

Use a device allocation only for the runtime execution of one independent
onboard test case or workload configuration. Choose the device count required
by that case. Do not put compilation, environment setup, input generation,
multiple cases, a whole benchmark suite, or result aggregation into the same
device task. Run CPU-only preparation and post-processing outside the device
allocation; if they must be queued, submit them with `--no-device`. Submit
repeated cases as separate tasks. A case may retain its own repeated runtime
rounds when those rounds are the measurement itself.

The scheduler reserves every requested device for the lifetime of the submitted
process. Releasing a runtime-level device handle inside that process does not
release the task's scheduler allocation. Keep the task command bounded to the
single case so unrelated work does not hold cards or queue slots.

Use `task-submit --list` before maintenance. Submit with the existing syntax,
for example `task-submit --device auto --run "python train.py"`. Use
`--status`, `--log`, `--wait`, `--cancel`, and `--kill` with a task id.
Use `--ptoas VERSION` to select `PTOAS_BASE/VERSION`; the client canonicalizes
the path within the configured root, requires an executable `ptoas` or
`bin/ptoas`, injects the matching `PTOAS_ROOT`, and prepends the version root
followed by its `bin` directory to `PATH`. Root-first ordering preserves legacy
wrappers that configure the matching libraries.
`PTOAS_BASE` has a server default in `taskqueue.conf` (`/usr/local/ptoas`); an
explicitly exported submitter value takes precedence for a host with a
separately installed PTOAS tree.
Omitting `--ptoas` preserves the submitter's existing `PTOAS_ROOT` and `PATH`.
A non-empty exported `PTOAS_ROOT` also takes precedence over a conflicting
`--ptoas`, in which case the client leaves both variables unchanged.

Use `pto-task --stats --days 7` for read-only usage reporting. With
`USAGE_SAMPLING_ENABLED=true` in the administrator's `config/taskqueue.conf`,
new device jobs sample their own cards after acquiring the device locks. The
standalone sampling timer is retired. Activating updated daemon code follows
the existing idle deployment procedure; changing this flag requires a reload
or restart. Do not enable a collector or deploy merely to inspect telemetry.

Use `task-submit --device-usage TASK_ID` or append `--json` to inspect current
and retained telemetry. `--list` annotates sampled running tasks; `--status`
keeps its existing machine-readable states. From the moment a job holds all its
cards, 60 continuous seconds of valid zero-computation samples mark a card
suspected idle (`USAGE_IDLE_GRACE` defaults to 0; administrators may add a
startup grace). Sampling defaults to every 15 seconds.
Timeouts, unsupported formats, missing values and stale samples are unknown,
never idle. Multi-card tasks are assessed per card. Records are advisory, may
be written by the submitter, and must not trigger automatic cancellation or
resource release. A3 and A5 use different mapping/query formats: never infer
a mapping by dividing card IDs by two or treating a logic ID as a physical ID.

Use `task-submit --usage-ranking [--days N] [--sort utilization|coverage] [--json]`
for public per-user sampling aggregates. It is read-only and requires no device
allocation. The default order is lowest card-active-time ratio first (two-day
window): observed computing card-seconds divided by recorded card-seconds, capped
at 100%, with an interval counted active only when the closing sample is nonzero
and within twice the sampling interval. Coverage and sample counts explain
incomplete evidence. A user without valid samples is unranked, not zero. These
advisory rankings include only readable sampled tasks, selected by start time,
and do not expose commands or individual task records.

For archived daily server usage, use `task-submit --usage status` and
`sudo task-submit --usage day --date YYYY-MM-DD`. The archive is administrator
only because it contains user sessions. `USAGE_REPORT_ENABLED` defaults to
false. When configuring a server, **ask the user whether to enable this
collector and Feishu publisher before setting it to true or activating its
timers**. An install or update request alone does not answer that question.
Local details expire after 30 days by default (`USAGE_RETENTION_DAYS`, 7–90);
Feishu receives one server-wide summary per day without usernames.
`USAGE_SERVER_LABEL` controls the Feishu display name (for example, `686`).
See the README's archived server usage section for other settings. Do not
present login duration as active working time.

Start the daemon only when explicitly requested. `deploy.sh` is the explicit
one-command install/update-and-activate entry point; `setup.sh` intentionally
does not start or restart the daemon. Starting it requires root; normal
`task-submit`/`pto-task` client commands stay unprivileged.

## Install or update

Run installation and updates as root from an administrator-reviewed checkout.

First install or manual activated update: `sudo bash deploy.sh`.

Install code only, without daemon activation: `sudo bash setup.sh`.

The configuration is initialized automatically when missing. Common settings
can be supplied with `--max-concurrent`, `--max-time-hard-cap`,
`--available-devices`, `--task-execution-mode`, and `--ptoas-base`. Existing
configuration and state remain preserved except for keys explicitly selected
by these options. A safe legacy `/etc/taskqueue.conf` is migrated automatically.

Use `--tools-root DIR` when a non-default root is explicitly required. Confirm
that both public commands resolve to `<root>/app/task-submit` after
installation. `npu_lock.sh` and the daemon remain private app components.

## Automatic updates

The repository-controlled timer is the only automatic-update channel and is
enabled by default for root installations with initialized config. It never
treats branch HEAD as an implicit deployment target. Use
`sudo bash setup.sh --disable-auto-update` to opt out and repeat that flag on
later deployments. The main branch's `update/rollout.json` selects a full commit
ID and increasing sequence; rollback also requires `allow_rollback:true`. The
default enabled manifest has an empty target and sequence zero, so polling stays
healthy without updating until the main repository selects a commit.

The controlled timer checks at 03:37 Asia/Shanghai with up to twenty minutes of
random delay. It verifies the exact candidate as the non-root user configured
in `config/repo-auto-update.env`, then reuses the existing update reservation,
idle wait, installer verification, and persistent activation marker. It deploys
the exact revision and safely restarts an active daemon after the queue becomes
idle. Failed activation remains retryable; an intentionally inactive daemon is
not started. Preserve `config/`, queue state, logs, and rollout markers under
`<root>/update/`.
If root has no direct repository egress, configure the optional fetch user and
non-credentialed proxy URL in the same root-owned configuration file.

The generic polling and manifest implementation is
`modules/repo_auto_update/`; pto-task-specific verification and application
belong in `scripts/repo-auto-update-adapter.sh`. Every enabled rollout must
target a commit already on the configured branch and use a sequence greater
than the previous rollout. Keep the target empty until its code and tests have
already landed.

## Source mode

For direct checkout execution, use the ignored `runtime/` tree. Configuration
is `runtime/config/taskqueue.conf`; mutable state and logs belong in
`runtime/state` and `runtime/logs`. Do not use `/data` or a user's home as an
implicit runtime location.
