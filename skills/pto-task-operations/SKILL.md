---
name: pto-task-operations
description: Submit and run NPU work through the pypto TaskQueue, and read its usage telemetry. Use when working with task-submit or pto-task submissions, device allocation, queue status/logs, device-usage sampling, --stats, or --usage-ranking. For install, deployment, scheduler policy or host configuration, see the repository README.
---

# TaskQueue operations

`task-submit` and `pto-task` are the same client; both queue work and allocate
cards. Every command that touches an NPU goes through the queue — never run one
around it. Compile, install dependencies and generate inputs outside the card
allocation, then submit only the on-device run. CPU-only queued work uses
`--no-device`.

## Before submitting

Split preparation from the run. Build and prepare first, check the exit status,
then submit the smallest allocation that fits:

```bash
cmake --build build -j 8 &&
  task-submit --device auto --run './build/onboard_test --device "$TASK_DEVICE"'
```

- Keep each device task short. The scheduler holds every requested card for the
  whole submitted process; releasing a runtime handle inside it returns nothing.
  Related cases that share one configuration may run in a single submission, each
  keeping its own pass/fail result. Do not put builds, installs, input generation,
  aggregation, long sweeps or unrelated work in a device task. If JIT compilation
  cannot be separated, say so rather than claiming it moved outside.
- Architecture prechecks, `npu-smi`, DCMI and ACL initialization access devices
  and belong inside the same allocated job as the test, even though they look like
  preparation. Never run a hardware query from the submitter shell or a
  `--no-device` task.
- Use the card the queue gave you through the appended `--device`, the `{}`
  placeholder or `$TASK_DEVICE`. Card IDs are physical IDs; do not remap or
  hardcode them. Request cards with `--device auto` and `--device-num N`.
- A grouped `DEVICE_WHITELIST` (`0,1,2,3;4,5,6,7`) defines scheduling pools; auto
  multi-card requests use one pool only. `--ignore-whitelist` requires a
  comma-only whitelist. `--ignore-group-affinity` only when the workload really
  communicates across HCCS planes — pypto/simpler cross-group hangs and wedges
  the cards.

## While the task runs

- Use `--status`, `--log`, `--wait`, `--cancel` and `--kill` with the task id.
- Long runs need `--max-time 0`; the default 300 s kills the task.
- Interactive runs use `-i` with `--run` and a real terminal (line-based stdin
  only; stdin cannot be reconnected after a disconnect).
- Do not call `task-submit` inside a task (nested submissions are rejected) and
  do not wrap `npu-lock` yourself; the daemon locks the cards.
- Dangerous commands (`rm -rf /`, `mkfs`, `reboot`, ...) are rejected by
  substring matching; rewrite the command instead of fighting the filter.
- `task-submit --help` lists every option, including `--ptoas`, `--env` and the
  device-pool flags.

## Reading usage telemetry

With sampling enabled, a device job samples its own cards every 15 seconds after
acquiring the device locks; CPU jobs never sample. `--stats [--days N]`,
`--device-usage TASK_ID` and `--usage-ranking` share one vocabulary:

- **Valid sample** — one successful per-card query. The count grows with cards ×
  duration; failed queries count only as attempts.
- **Valid coverage** — valid sampled card-seconds / recorded card-seconds.
- **Card-active-time ratio** — card-seconds with observed compute / recorded
  card-seconds, capped at 100%. Sampling gaps count for neither; no valid sample
  means unknown, never zero.
- **Suspected idle** — 60 continuous seconds of valid zero-compute samples from
  the moment all cards are held. A nonzero sample closes it; timeouts and gaps
  are unknown, never idle. Assessed per card.

`--stats` is own-user unless run as root; `--usage-ranking` aggregates all users
(default two days, lowest ratio first) and excludes tasks held 30 seconds or less
overall. Both are advisory: submitters can edit
their own record, and telemetry never cancels a task or releases cards. `--list`
annotates sampled running tasks with accumulated idle history and current state.
A3 and A5 use different mapping/query formats: never infer a mapping by dividing
card IDs by two or treating a logic ID as a physical ID.

## Administration

Install, update, scheduler policy, device pools and automatic updates are covered
in the repository README and `GUIDE_ZH.md`. Deploy as root only when the queue is
idle; `deploy.sh` updates files but skips the daemon restart while a task runs, and
must be rerun after the queue drains. Start the daemon, enable usage collectors,
or change scheduler configuration only on an explicit request.
