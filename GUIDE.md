# TaskQueue User Guide

> 中文版见 [GUIDE_ZH.md](GUIDE_ZH.md). Keep the two in sync when editing.

A task queue for a shared NPU machine. Submit your command, get a card
allocated and locked for you, and stop competing with everyone else for
devices.

## Submitting

```bash
# NPU task — a free card is allocated and "--device <card>" is appended for you
task-submit --device auto --run "python train.py"

# NPU task — pick the card yourself (nothing is appended; you pass the number)
task-submit --device 9 --run "python train.py -d 9"

# Multiple cards
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"

# Non-NPU task — omit --device and no card is allocated
task-submit --run "make build"
task-submit --run "pytest tests/test_foo.py"

# Long training (the default kills the task after 300s — use --max-time 0)
task-submit --device auto --max-time 0 --run "python train.py"

# ... and wait for it to finish, however long that takes (--timeout 0)
task-submit --device auto --max-time 0 --timeout 0 --run "python train.py"

# Interactive task (you can type into the task's stdin while it runs)
task-submit -i --device auto --run "python interactive_script.py"
```

### Telling your program which card it got

With `--device auto` the daemon appends `--device <card>` to the command. If
your program spells that flag differently, use the `{}` placeholder or the
`TASK_DEVICE` environment variable instead:

```bash
# {} placeholder — replaced with the allocated card number (double quotes are fine)
task-submit --device auto --run "python train.py -d {}"
task-submit --device auto --run "python train.py --npu-id {}"

# $TASK_DEVICE — single quotes required, or your shell expands it at submit time
task-submit --device auto --run 'python train.py -d $TASK_DEVICE'

# In code: device = os.environ.get("TASK_DEVICE", "0")
```

The number you receive is the **physical** card id. Use it as given.

## Inspecting

```bash
task-submit --list                  # all tasks
task-submit --status <task-id>      # one task's state
task-submit --log <task-id>         # its log
task-submit --wait <task-id>        # reattach and follow until it finishes
task-submit --devices               # current device whitelist
task-submit --find "<substring>"    # task ids whose full command matches (for scripts)
```

Use `--find`, not `--list`, when a script needs to locate a task: `--list`
truncates the command column at 77 characters.

## Managing

```bash
task-submit --cancel <task-id>      # drop a queued task
task-submit --kill <task-id>        # terminate a running task (Ctrl+C also works)
task-submit --clean                 # remove tasks finished more than 1 day ago
task-submit --clean --days 7        # ... more than 7 days ago
```

## Time limits

| Option | Effect | Default | Meaning of `0` |
|---|---|---|---|
| `--max-time N` | Server-side kill timer for the task | `300` s | no limit |
| `--timeout N` | How long the client waits | `600` s | wait forever |

`--timeout` only detaches the client — **the task keeps running**. Reattach with
`task-submit --wait <task-id>`.

## Things to know

1. **Use the card number you are given.** It is a physical id, delivered via the
   appended `--device`, the `{}` placeholder, or `$TASK_DEVICE`. There is no
   remapping to a logical 0, so hard-coding a card number means locking one card
   and running on another.
2. **Long training needs `--max-time 0`.** The default kills the task at 300
   seconds.
3. **Do not wrap your command in `npu-lock`.** The daemon locks devices for you,
   and a manual `npu-lock` in the command is rejected.
4. **Do not call `task-submit` from inside a task.** Nested submission is
   refused, to avoid queue deadlock.
5. **Do not bypass the queue** to run NPU work directly — you will collide with
   queued tasks.
6. **Dangerous commands are rejected** at submit time (`rm -rf /`, `mkfs`,
   `reboot`, …). The match is a substring match, so a harmless command
   containing one of those words is rejected too; rename or restructure it.
7. **Interactive tasks need `-i`** plus `--run` and a real terminal. Line-based
   input only, and stdin cannot be reattached after disconnecting (the log
   still can, via `--wait`).
