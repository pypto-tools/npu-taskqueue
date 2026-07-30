---
name: task-submit
description: Use this skill when the user asks to run, train, test, or execute any command that needs NPU/Ascend devices, or mentions "task-submit", "submit task", "run on NPU", "train model", "run training", "run test on device". Also applies when writing scripts that should be submitted to the task queue instead of running directly.
version: 2.0.0
---

# task-submit: NPU Task Queue

This machine uses a shared NPU task queue. **All NPU tasks MUST go through `task-submit`**, never run NPU code directly.
  
## Core Rules

1. **Always use `task-submit`** for any command that uses NPU/Ascend devices
2. **`--device auto`** for NPU tasks — daemon auto-assigns a free card and appends `--device <card>` to the command
3. **No `--device`** for non-NPU tasks — just `task-submit --run "..."`
4. **Long tasks need `--max-time 0`** — default is 300s which will kill training jobs
5. **Use `--run`** to submit and wait in one step; omit it to get a task-id for later

## Quick Reference

### NPU tasks — auto-assign card

```bash
# Auto-assign 1 NPU card (daemon appends --device <card>)
task-submit --device auto --run "python train.py"

# Long training (no time limit)
task-submit --device auto --max-time 0 --run "python train.py"

# Long training, wait forever for result
task-submit --device auto --max-time 0 --timeout 0 --run "python train.py"
```

### NPU tasks — specify card

```bash
# Specify physical card (daemon does NOT auto-append --device, user handles it)
task-submit --device 9 --run "python train.py -d 9"
```

### Non-NPU tasks — no --device needed

```bash
task-submit --run "make build"
task-submit --run "pytest tests/test_foo.py"
```

### Custom device parameter

If your program uses a flag other than `--device`, use `{}` placeholder or `$TASK_DEVICE`:

```bash
# {} placeholder — replaced with actual card number (double quotes OK)
task-submit --device auto --run "python train.py -d {}"
task-submit --device auto --run "python train.py --npu-id {}"

# $TASK_DEVICE env var (MUST use single quotes to prevent early expansion)
task-submit --device auto --run 'python train.py -d $TASK_DEVICE'

# In code: device = os.environ.get("TASK_DEVICE", "0")
```

The card number is a **physical** id. Nothing sets `ASCEND_RT_VISIBLE_DEVICES`,
so there is no remapping to a logical 0 — pass the number through to the
program instead of assuming it can use device 0.

### Submit without waiting

```bash
id=$(task-submit --device auto "python train.py")
task-submit --wait "$id"              # reconnect later
task-submit --timeout 0 --wait "$id"  # wait indefinitely
```

### Query and manage

```bash
task-submit --list                    # list all tasks
task-submit --status <task-id>        # check one task
task-submit --log <task-id>           # view task log (live)
task-submit --cancel <task-id>        # cancel queued task
task-submit --kill <task-id>          # kill running task
task-submit --clean                   # clean tasks older than 1 day
task-submit --clean --days 7          # clean tasks older than 7 days
task-submit --devices                 # show device whitelist
task-submit --find "<substring>"      # task ids matching the full command
```

Use `--find` when a script needs to locate a task. `--list` is for humans and
truncates the command column at 77 characters, so matching against it fails
silently for long commands.

## Decision Guide

When the user asks you to run something, decide:

| Situation | Action |
|-----------|--------|
| Needs NPU (training, inference, any Ascend op) | `task-submit --device auto --run "..."` |
| Needs NPU with custom device flag | `task-submit --device auto --run "... -d {}"` |
| Long running (>5 min) | Add `--max-time 0` |
| No NPU needed (build, lint, test without device) | `task-submit --run "..."` or run directly |
| User just wants to check tasks | `task-submit --list` or `--status` |

## Important Notes

- **`--device auto`**: daemon auto-assigns a free card from the whitelist and appends `--device <card>` to the command. Use `{}` or `$TASK_DEVICE` if your program uses a different flag. Run `task-submit --devices` to see the current pool — do not assume a fixed card range.
- **`--device N`**: daemon locks the specified card but does NOT append `--device` — user is responsible for passing the card number in the command.
- **No `--device`**: no card allocated, no lock, no injection. For non-NPU commands.
- **`--max-time` vs `--timeout`**: `--max-time` is server-side kill timer (default 300s). `--timeout` is client wait timer (default 600s). A timed-out client does NOT stop the task.
- **Do NOT nest**: never call `task-submit` inside a task-submitted command.
- **Do NOT use `npu-lock` manually**: the daemon handles device locking.
