# Interactive Mode

## Usage

```bash
task-submit -i --run "python interactive_script.py"
```

`-i` requires `--run` and a real terminal — it cannot be driven from a pipe.

## How it works

Normally a task's stdin is `/dev/null`, so it cannot read input. Interactive
mode builds a stdin channel out of a **named pipe (FIFO)**:

1. The daemon creates a FIFO for the task under `$FIFO_DIR/`.
2. The task is started with that FIFO as its stdin (`< $fifo_path`).
3. Once the client sees the FIFO appear, it enters a forwarding loop: every
   second it tries to `read` one line from your terminal, and writes whatever it
   gets into the FIFO.
4. The task's ordinary `read` / `input()` receives that line.

It is a pipe in the filesystem stitching together the stdin of two otherwise
unrelated processes — your shell, and a task the daemon forked:

```text
your terminal                        daemon
─────────────                    ──────────────
keyboard input                   create FIFO
   │                                  │
   │  one line per second             │  keeper holds the write end open
   │                                  │
   └── write to FIFO ──────────> FIFO ──> task stdin
                                      │
                    task stdout/stderr ──> log file
                                            │
your terminal: tail -f log  <───────────────┘
```

Two channels, in short:

- **input**: keyboard → FIFO → task stdin (line by line)
- **output**: task stdout → log file → `tail -f` → your terminal

## What the keeper is for

The daemon starts a `sleep infinity > fifo` process whose only job is to **hold
the write end of the FIFO open**. Without it, the FIFO would have no writer
between two of your inputs and the task would read EOF and exit.

## Ctrl+C

- Task still queued: it is cancelled.
- Task running: a termination request is sent and the client waits for the
  daemon to kill it.

## Limits

- **Line-based**: input is sent when you press Enter. No per-character
  interaction — arrow keys, Tab completion and the like do not work.
- **Single client**: stdin cannot be reattached after disconnecting. The task
  survives (the keeper covers it) and its log can still be followed.
