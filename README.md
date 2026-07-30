# TaskQueue

A lightweight task queue for shared Ascend NPU machines. It removes the "who
gets which card" scramble: users submit commands with `task-submit`, a root
daemon allocates a free card, takes a lock on it, and runs the command as the
submitting user.

Documentation in this repository is written in English — see
[`.claude/rules/docs-language.md`](.claude/rules/docs-language.md). Messages
printed by the scripts themselves stay in Chinese, because that is what the
people on this machine read.

New here? [`GUIDE.md`](GUIDE.md) is the user-facing manual — also available in
Chinese as [`GUIDE_ZH.md`](GUIDE_ZH.md). [`ISSUES.md`](ISSUES.md) tracks known
defects and past incidents — read it before changing the kill or scheduling
paths.

## Design

### Device pool

The machine has 16 NPU cards (physical 0-15). `conf/available_devices` defines
the pool that `--device auto` draws from; it currently holds
`0,1,2,3,12,13,14,15`.

An explicit `--device N` is **not** restricted to that pool — the whitelist only
constrains automatic allocation.

> The original design reserved 0-11 as "free" cards for direct terminal use and
> 12-15 as a protected pool. The pool in use is deliberately wider than that.
> `conf/available_devices` is the authority — do not infer the pool from the
> historical split.

### Three layers

| Layer | Component | Mechanism | Purpose |
|---|---|---|---|
| Device access | `HwHiAiUser` group | `/dev/davinci*` is `0660 root:HwHiAiUser` | A restricted user's own shell cannot open a device |
| Device mutex | `npu-lock` / flock | One lock file per device | Two queued tasks never share a card |
| Device allocation | daemon / `available_devices` | Whitelist | Bounds what `--device auto` may hand out |

Access control is group membership: restricted users are removed from
`HwHiAiUser`, and the daemon adds the group back for the duration of a task via
`runuser --supp-group HwHiAiUser`. The membership list is maintained by hand
(`gpasswd -d <user> HwHiAiUser`); `conf/restricted-users` records who should be
restricted but is not read by any script.

`taskqueue-npu.sh` (profile.d) and `99-npu-taskqueue.rules` (udev) are inert
placeholders kept for deployment symmetry. Neither sets anything.

### Task lifecycle

1. `task-submit` writes a task file into `pending/` and snapshots the user's
   environment next to it.
2. The daemon allocates a device from the whitelist (`auto` mode) or uses the
   requested one, then moves the task to `running/`.
3. `npu-lock` takes an exclusive `flock` on each allocated device.
4. `runuser` drops privileges to the submitting user, with `HwHiAiUser` added.
5. On exit the daemon sweeps surviving descendants, releases the locks, and
   writes a `done/` record.

### Device numbering

**Card numbers are physical.** Nothing in the deployed path sets
`ASCEND_RT_VISIBLE_DEVICES` — `task-submit` even strips it out of the
environment snapshot — so there is no remapping and no logical 0-based view.

The daemon tells a task which card it got in three interchangeable ways:

- appends `--device <N>` to the command (only for `--device auto`, and only when
  the command does not already specify a device),
- substitutes `{}` anywhere in the command,
- exports `TASK_DEVICE=<N>`.

Use whichever fits the program, but use one of them. Hard-coding a card number,
or assuming the allocated card appears as device 0, means holding a lock on one
card and computing on another.

## Components

| File | Role |
|---|---|
| `task-submit.sh` | User CLI: submit, wait, log, cancel, kill, list, clean, maintenance, device whitelist |
| `task-daemon.sh` | Root daemon: poll `pending/`, allocate devices, drop privileges, watchdog, reap orphans |
| `npu_lock.sh` | flock-based device mutex; multi-card locking in ascending order to avoid deadlock |
| `taskqueue-npu.sh` | profile.d placeholder (inert) |
| `99-npu-taskqueue.rules` | udev placeholder (inert — CANN owns the device nodes) |
| `taskqueue.service` | systemd unit |
| `setup.sh` | First-time install, system-wide or `--local` |
| `deploy.sh` | Re-deploy after source changes |
| `claude-skill/task-submit/` | Skill shipped to *users* of the queue, to be installed on their machines |
| `.claude/` | Rules and skills for developing *this* repository |

## Layout

### Source

```text
npu-taskqueue/
├── conf/                          # configuration — edit here, then deploy
│   ├── taskqueue.conf             # BASE_DIR, MAX_CONCURRENT
│   ├── available_devices          # --device auto pool
│   └── restricted-users           # roster (git-ignored; .example is committed)
├── task-daemon.sh
├── task-submit.sh
├── npu_lock.sh
├── taskqueue-npu.sh
├── 99-npu-taskqueue.rules
├── taskqueue.service
├── taskqueue-clean.cron
├── deploy.sh
├── setup.sh
├── docs/                          # topic docs (interactive mode, …)
├── claude-skill/                  # skill for queue users
├── .claude/
│   ├── CLAUDE.md                  # index for agents working on this repo
│   ├── rules/                     # conventions (see below)
│   └── skills/                    # verify, deploy, code-review, git-commit, …
├── AGENTS.md                      # short pointer for non-Claude agents
├── GUIDE.md                       # user manual
├── GUIDE_ZH.md                    # its Chinese mirror — edit both together
├── ISSUES.md                      # known defects and incident history
└── README.md                      # this file
```

`.claude/rules/` holds the conventions that apply to the whole repository:

| Rule | Covers |
|---|---|
| `core-development.md` | Bash correctness, the root/user boundary, kill paths, secrets |
| `deployment-integrity.md` | The repo is the source of truth; deploy pre-flight |
| `problem-handling.md` | Where a defect gets recorded, and what may be published |
| `docs-language.md` | English Markdown, Chinese CLI output |
| `documentation-length.md` | Size limits and how to split |

### Runtime (`BASE_DIR`)

```text
/var/lib/taskqueue/
├── pending/           queued tasks (mode 1777)
├── running/           in-flight tasks
├── done/              completion records
├── logs/              per-task logs
├── locks/             NPU lock files
├── kill/              termination requests
├── fifo/              stdin pipes for interactive tasks
├── available_devices  runtime whitelist (SIGHUP reloads it)
├── maintenance        present ⇒ scheduling paused
├── taskqueue.log      daemon log (rotates at 1 MB)
└── task-daemon.pid
```

## Deployment

**The repository is the source of truth.** Never edit `/usr/local/bin/task-submit`
or the other installed copies in place — a later `deploy.sh` silently rolls those
edits back. That is not hypothetical: it produced a CI job that reported green
for a week without running its tests (`ISSUES.md`, issue 4). See
[`.claude/rules/deployment-integrity.md`](.claude/rules/deployment-integrity.md).

| Source | Installed to |
|---|---|
| `task-daemon.sh` | `/usr/local/sbin/task-daemon` |
| `task-submit.sh` | `/usr/local/bin/task-submit` |
| `npu_lock.sh` | `/usr/local/bin/npu-lock` |
| `taskqueue.service` | `/etc/systemd/system/taskqueue.service` |
| `99-npu-taskqueue.rules` | `/etc/udev/rules.d/` |
| `taskqueue-npu.sh` | `/etc/profile.d/` |
| `taskqueue-clean.cron` | `/etc/cron.d/taskqueue-clean` |
| `conf/taskqueue.conf` | `/etc/taskqueue.conf` |
| `conf/available_devices` | `/var/lib/taskqueue/available_devices` |
| `conf/restricted-users` | `/etc/taskqueue-restricted-users` |

### First install

```bash
sudo bash setup.sh --max-concurrent 15
```

A `--local` mode installs everything under `$HOME` for testing, with no root and
no impact on the shared queue:

```bash
bash setup.sh --local --max-concurrent 2
```

### Update

```bash
sudo bash deploy.sh
```

`deploy.sh` restarts the daemon, and the default systemd `KillMode` takes the
running tasks down with it. Check for in-flight work first:

```bash
task-submit --list                     # anything under "Running"?
sudo task-submit --maintenance on "deploying"   # stop new work, let running drain
sudo bash deploy.sh
sudo task-submit --maintenance off
```

`BASE_DIR` is per-machine and is **not** synced. `deploy.sh` keeps whatever the
host's `/etc/taskqueue.conf` already says, syncs the other keys from
`conf/taskqueue.conf`, preserves any host-only keys it finds, and refuses to
start if `BASE_DIR` does not exist. The value committed here is only the
fallback for a host that has never been installed.

### Day-to-day

```bash
sudo systemctl status taskqueue                       # daemon state
BASE_DIR=$(. /etc/taskqueue.conf; echo "$BASE_DIR")   # this host's data dir
cat "$BASE_DIR/taskqueue.log"                         # daemon log
sudo systemctl restart taskqueue                      # restart (kills running tasks)
```

### Changing the restricted-user roster

Edit `conf/restricted-users`, then apply the group change by hand — `deploy.sh`
copies the file but nothing reads it:

```bash
sudo gpasswd -d <user> HwHiAiUser      # restrict
sudo gpasswd -a <user> HwHiAiUser      # unrestrict
```

The user must log out and back in for the group change to take effect.

### Changing the device pool

At runtime, without a deploy (takes effect immediately via SIGHUP):

```bash
sudo task-submit --devices "2,3,4,5"
sudo task-submit --devices status
sudo task-submit --devices reset       # back to auto-detection
```

Persistently: edit `conf/available_devices` and run `sudo bash deploy.sh`. Note
that a deploy overwrites whatever `--devices` set at runtime.

### Maintenance mode

```bash
sudo task-submit --maintenance on "CANN driver upgrade"
sudo task-submit --maintenance status
sudo task-submit --maintenance off
```

Queued tasks stop being scheduled; running tasks continue.
