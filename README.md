# NPU TaskQueue

Shared Ascend NPU task queue. The daemon allocates and locks NPU devices, then
runs submitted work as the submitting user. The command-line options and task
workflow of `task-submit` are unchanged. `task-submit` remains supported for
existing users, and `pto-task` is the pypto-tools entry point.

## Install and update

```bash
# First install or manual update: install, activate, and verify everything.
sudo bash deploy.sh

# Install code/configuration links without starting or restarting the daemon.
sudo bash setup.sh
```

`deploy.sh` replaces the former manual `daemon-reload`, config initialization,
service start, status, and `task-submit --list` sequence. It enables the daemon
at boot and keeps `taskqueue.service` as an alias of `pto-task.service`. During
an upgrade it restarts the daemon only when no task is running; otherwise it
updates the files, leaves the running task untouched, and asks you to rerun the
same command after the queue drains.

The initial configuration is created automatically. Common host settings can
be supplied without editing a file:

```bash
sudo bash deploy.sh --max-concurrent 8 --available-devices 0,1,2,3 \
  --ptoas-base /usr/local/ptoas --task-execution-mode HwHiAiUser
```

On a first install from an interactive terminal, the installer prompts for the
NPU card count and maximum concurrency; Enter accepts the detected/recommended
value. Use `--non-interactive` for unattended provisioning. Explicit command
line options always take precedence.

On migration, a safe root-owned `/etc/taskqueue.conf` is detected automatically;
its legacy `BASE_DIR` queue state and `MAX_CONCURRENT` value are retained.

The default installation is:

```text
/home/pypto-tools/pto-task/
├── app/       # deployed programs and root-managed scheduler modules
├── config/    # local taskqueue.conf; never overwritten by an update
├── state/     # pending, running, done, locks, FIFO, usage and daemon state
├── update/    # repository-controlled rollout sequence and staging markers
├── logs/      # task and daemon logs
└── tmp/       # temporary files
```

Deployment creates this complete tree up front. Re-running it preserves local
configuration and queue data while repairing the required sticky permissions
on shared state directories. Administrative directories and persistent lock
files are normalized to `root:root`; shared directories use mode `1777` and
device locks use mode `0666`, so every local user can submit work without owning
or changing a lock file. Deployment pre-creates one lock per configured/detected
device, and tasks reuse those files instead of creating them on first use.

Use `--tools-root DIR` to install below another root, for example
`sudo bash deploy.sh --tools-root /srv/pypto-tools`. Deployment must be run as
root from an administrator-reviewed checkout. `/home/pypto-tools` is the
default tools root. Use `setup.sh` instead when only copying files and installing
system integration without starting or restarting the main daemon is desired.

`/usr/local/bin/task-submit` and `/usr/local/bin/pto-task` are symbolic links
to the same `<tools-root>/pto-task/app/task-submit` program. No
`npu-lock` or daemon command alias is installed in `/usr/local/bin`.

The one-command deployment manages the systemd service. For diagnostics, the
private daemon can also be run directly when systemd is intentionally not used:

```bash
TOOLS_ROOT=/home/pypto-tools  # or the value passed to --tools-root
sudo "$TOOLS_ROOT/pto-task/app/task-daemon"
```

## Usage

Both commands are equivalent; existing users can keep using `task-submit`.
Every option and argument pattern is retained.

```bash
task-submit --device auto --run "python train.py"
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"
task-submit --ptoas 0.54 --device auto --run "python train.py"
pto-task --device 3 --run "python train.py --device 3"
pto-task --version
task-submit --run "pytest tests/"
task-submit --list
pto-task --status <task-id>
task-submit --log <task-id>
task-submit --wait <task-id>
task-submit --cancel <task-id>
task-submit --kill <task-id>
pto-task --stats --days 7
task-submit --devices status
```

`--max-time` defaults to 300 seconds; `--timeout` defaults to 600 seconds and
only controls client waiting. Project-local `task-submit.conf` device policies
and the existing `TASKQUEUE_DEVICE_*` environment controls continue to work.
`task-submit --devices status` reports every auto-pool source, the discovered
project policy, the effective intersection used by the daemon, and conflicts
such as fixed sequences outside the global auto pool. Malformed lists,
duplicate device IDs, sequence-size mismatches, and blacklist violations are
reported at the configuration source instead of being included in a computed
candidate pool. Submitted task metadata preserves the original project
whitelist/blacklist, environment pool, and `--ignore-whitelist` state through
completion for later diagnosis.

Hosts whose cards are split across HCCS planes declare the partition once in
`config/taskqueue.conf` as `DEVICE_GROUPS`, for example `"0,1;2,3"`. A project
sets `DEVICE_GROUP_AFFINITY=1` in its `task-submit.conf` to require that all of
a task's cards come from one group. `--device auto --device-num N` then waits
for a single group with `N` free cards instead of being handed a cross-plane
pair, and an explicit `--device` list or `DEVICE_SEQ_N` sequence that spans
groups is refused at submission with the groups named. `task-submit --devices
status` shows the topology and the largest number of cards a single request can
receive. An unset `DEVICE_GROUPS` means the topology is unknown rather than
fully connected, so an opted-in project's multi-card requests are refused until
the host declares its groups; a genuinely single-plane host declares one
all-inclusive group. `--ignore-group-affinity` turns the constraint off for
loads that do work across planes. Runtime
`state/available_devices` overrides configured `AVAILABLE_DEVICES`, which in
turn overrides device detection.
`--ptoas VERSION` validates `PTOAS_BASE/VERSION`, sets `PTOAS_ROOT`, and
prepends both the version root and its `bin` directory to the submitted `PATH`.
The root takes precedence so legacy wrapper scripts can configure their
matching libraries. `PTOAS_BASE` is a
server-side default (`/usr/local/ptoas`) that a submitter may explicitly
override in their environment for a host with a separately installed tree.
Without `--ptoas`, the submitter's existing `PTOAS_ROOT` and `PATH` are
preserved unchanged. A non-empty exported `PTOAS_ROOT` also takes precedence
over a conflicting `--ptoas` option, leaving both `PTOAS_ROOT` and `PATH`
unchanged for that task.

## Configuration and security

`config/taskqueue.conf` is Bash-style `KEY=value` configuration. Keep it
administrator-writable and never place passwords, access tokens, or other
credentials in it. The software does not store or print credentials.

| Key | Default | Meaning |
|---|---:|---|
| `MAX_CONCURRENT` | `10` | Maximum simultaneously running jobs |
| `SCHEDULER_MODE` | `backfill` | `backfill` for opportunistic throughput, or `pool_aware_reservation` for pool-aware multi-device reservation |
| `POOL_AWARE_RESERVATION_MIN_DEVICES` | `2` | Minimum request size that creates a reservation in `pool_aware_reservation` |
| `MAX_CONCURRENT_8_CARD_TASKS` | `0` | Optional per-host limit for exactly eight-card jobs; `0` disables it |
| `MAX_TIME_HARD_CAP` | `0` | Server maximum task duration; `0` means unlimited |
| `KILL_GRACE` | `5` | Seconds from SIGTERM to SIGKILL |
| `PTOAS_BASE` | `/usr/local/ptoas` | Default root containing installed PTOAS versions; submitter environment takes precedence |
| `TASK_EXECUTION_MODE` | `HwHiAiUser` | Task identity: submitter with NPU group, or `root` |
| `AVAILABLE_DEVICES` | empty | Comma-separated automatic device pool; empty detects devices |

`STATE_DIR` and `LOGS_DIR` are set by the installer to the unified deployment
tree. Do not point them at `/data` or a user home directory.

`MAX_CONCURRENT_8_CARD_TASKS` is deliberately disabled by default. A host may
set it to `1` in its preserved local `config/taskqueue.conf` to keep a second
eight-card job pending while the daemon continues scheduling later smaller
jobs. Code-only and automatic updates do not enable the policy on other hosts.

`pool_aware_reservation` retains FIFO order for multi-device reservations. When
the oldest satisfiable request at or above
`POOL_AWARE_RESERVATION_MIN_DEVICES` is blocked by current allocations, its
effective `DEVICE_POOL` becomes protected until enough cards have accumulated.
Younger jobs still run when their own effective pool contains enough free
devices outside that protected range. Device-free jobs may continue while one
concurrency slot is reserved. Existing running jobs are never preempted, and
impossible `auto:N` requests do not become queue barriers. Select the mode in
the preserved local configuration and restart the daemon while the queue is
idle.

### Scheduler module architecture

Scheduling uses a shared planning core plus independently selectable policy
modules. `schedulers/_core.sh` owns FIFO traversal, the per-task resource
snapshot, host admission limits, decision validation, and the final call into
the daemon's atomic claim/start path. A policy such as `backfill.sh` or
`pool_aware_reservation.sh` may only return `start`, `defer`, or `stop` through
the core decision helpers; it does not move queue files or launch processes.
Every `start` is revalidated immediately before claim, including device count,
effective auto pool, current occupancy, and concurrency caps.

Policy modules implement API version 2, declare a matching
`SCHEDULER_MODULE_NAME`, and provide `scheduler_consider_task`. Optional hooks
are `scheduler_validate_config`, `scheduler_begin_tick`,
`scheduler_end_tick`, and `scheduler_task_started`. Safe lowercase identifiers
are resolved to root-managed `schedulers/<mode>.sh` files, so adding a policy
does not require changing a daemon-side name list; `setup.sh` installs all
repository scheduler files. The leading-underscore core cannot be selected as
a mode. Installed scheduler files and their directory must remain root-owned
and not group/world-writable.

### Task execution identity

The daemon itself must run as root to schedule work. By default,
`TASK_EXECUTION_MODE="HwHiAiUser"` runs a normal user's task as that submitting
user with the `HwHiAiUser` NPU device group; it does **not** run the task as
root. Set `TASK_EXECUTION_MODE="root"` in the installed configuration only
when every queue submitter is trusted: it makes every queued command root
privileged. Restart the daemon after changing this setting.

## NPU usage statistics

`pto-task --stats [--days N]` (or `task-submit --stats`) reports task count,
card-hours, and sampled NPU utilization. An unprivileged caller sees only their
own records; root sees the per-user aggregate. The report is read-only. Its
sampler is an independent timer; it only reads NPU utilization for cards owned
by running queue tasks and never participates in scheduling.

Sampling and its timer are disabled by default. Enable it in the local
configuration, then rerun `sudo bash setup.sh` to install and enable the timer;
the task daemon does not need a restart:

```bash
# /home/pypto-tools/pto-task/config/taskqueue.conf
USAGE_SAMPLING_ENABLED=true
```

Samples are stored in `state/usage/YYYYMMDD.csv`. The sampler uses a per-run
lock and a timeout for every `npu-smi` call, so a stalled device cannot block
the queue daemon.

## Source checkout mode

The Git checkout remains source only. Running `task-submit.sh`,
`task-daemon.sh`, or `npu_lock.sh` directly resolves configuration at the
ignored `runtime/config/taskqueue.conf`, and uses `runtime/state`,
`runtime/logs`, and `runtime/tmp`. Create that local configuration from the
template when needed:

```bash
mkdir -p runtime/config runtime/state runtime/logs runtime/tmp
cp config/default.conf runtime/config/taskqueue.conf
./task-submit.sh --help
```

`runtime/` is intentionally git-ignored. It keeps local test state out of both
Git and deployed installations.

## Automatic updates

There is one automatic-update channel: the main repository explicitly selects
an exact commit through `update/rollout.json`. Servers never treat branch HEAD
as an implicit deployment target. The polling timer is enabled by default for a
root installation with initialized configuration. To opt out:

```bash
sudo bash deploy.sh --disable-auto-update
```

Pass `--disable-auto-update` on later manual deployments too because the default
is enabled. The committed manifest defaults to the armed-but-idle state:
`enabled: true`, empty `target`, and `sequence: 0`. Servers keep polling but do
nothing until the main repository supplies a full commit ID and a positive,
increasing sequence. Reused or decreasing sequences are rejected; moving to an
older installed commit additionally requires `allow_rollback: true`.

The rollout timer checks daily at 03:37 `Asia/Shanghai` with up to 20 minutes
of randomized delay. It fetches the exact target, verifies it as the
unprivileged account configured in
`config/repo-auto-update.env` (default `daemon`), takes the update reservation,
and waits up to two hours for the pending and running queues to become empty.
It then installs the selected revision and safely restarts an active daemon
before accepting new submissions. Failed activation remains retryable; a daemon
that was intentionally inactive is not started. Local configuration, queue
state, logs, and rollout state are preserved. Repository fetches use root by
default; hosts that require a local egress proxy can set
`REPO_AUTO_UPDATE_FETCH_USER` and
`REPO_AUTO_UPDATE_FETCH_ALL_PROXY` in that same configuration file.

Recommended release order:

1. Merge and test the application change on `main`; record its full commit ID.
2. Commit only the rollout manifest with that target and a higher sequence.
3. Observe deployed revisions under `<tools-root>/pto-task/update/`; stop the
   rollout by clearing `target` or setting `enabled` to `false` if needed.

Repository polling, manifest validation, ancestry checks, rollback control,
locking, and sequence markers live in the reusable
`modules/repo_auto_update/` package. `scripts/repo-auto-update-adapter.sh`
contains the pto-task verification bridge; `repo-auto-update-deploy.sh` owns
idle-only installation and activation.

For a concise Chinese usage guide, see [GUIDE_ZH.md](GUIDE_ZH.md). AI agents
can use [skills/pto-task-operations/SKILL.md](skills/pto-task-operations/SKILL.md).
