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
├── config/    # local taskqueue.conf and pypto-env.conf; never overwritten
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
to the same `<tools-root>/pto-task/app/task-submit` program. The installer also
links `/usr/local/bin/pypto-setup` to the environment helper in `app/`. No
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

`pypto-setup` reports the configured locations of shared pypto development
components and whether each path exists. To load those paths into the current
shell, use:

```bash
pypto-setup
eval "$(pypto-setup --export)"
```

The host configuration is
`<tools-root>/pto-task/config/pypto-env.conf`. It is created on first install
and preserved on updates. Existing exported variables take precedence, and a
user may override the host defaults in `~/.config/pypto-env.conf` without root
access. `PTOAS_ROOT`, `ASCEND_HOME_PATH`, `GCC15_ROOT`, `CLANG_FORMAT`, and
`MODELS_ROOT` are supported; `GCC15_ROOT` is optional and unset by default.
Legacy root-owned `/etc/pypto-env.conf` is imported on first install when safe.

`--max-time` defaults to 300 seconds and limits execution after the task starts.
`--timeout` defaults to 600 seconds and limits only the pending queue wait;
once the task starts, the client waits for the daemon's result. Project-local
`task-submit.conf` device policies and the existing `TASKQUEUE_DEVICE_*`
environment controls continue to work.
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
card-hours and legacy sampled utilization, plus a separate in-task telemetry
table: suspected idle card-hours, valid coverage, average computation utilization,
valid samples and idle-event count. The telemetry table selects tasks by their
start time; original task accounting retains its overlapping-time-window rules.
Ordinary users see their own telemetry; root sees all users.

Sampling is opt-in in the administrator-owned local configuration:

```bash
# /home/pypto-tools/pto-task/config/taskqueue.conf
USAGE_SAMPLING_ENABLED=true
USAGE_SAMPLE_INTERVAL=15
USAGE_SAMPLE_TIMEOUT=2
USAGE_SAMPLE_ROUND_TIMEOUT=6
USAGE_IDLE_GRACE=60
USAGE_IDLE_SECONDS=120
```

Deploy the updated code through the normal idle activation procedure. The daemon
reads sampling configuration on startup/reload, and new jobs use those settings.
Sampling now runs **inside each device job after acquiring its locks**, only for
allocated cards. CPU-only jobs never start a probe. Setup retires the old standalone
timer; its compatibility entry point performs no hardware queries. Old CSV samples
remain readable by `--stats`.

```bash
task-submit --device-usage TASK_ID
task-submit --device-usage TASK_ID --json
task-submit --list
```

Each card is marked **suspected idle** only after the startup grace and a
continuous interval of successful zero-computation samples. A single nonzero
compute metric prevents the mark. HBM occupancy is auxiliary, not proof of active
computation. Activity closes the event; missing/invalid data, timeouts and sampling
gaps also close it at the last confirmed observation and become unknown. Short
jobs need not produce an idle event. Once a card has recorded idle time, the
`--list` line keeps it: it reads `曾疑似占卡空闲 DEV=Ns；当前：<state>` with the
accumulated idle seconds per card, so a card that resumes computing still shows
its history next to the current state. These are sampled observations, not proof
that no kernel ran between samples. No task is killed and no allocation released
based on telemetry. Submitters can modify their own advisory telemetry; it is
separate from authoritative card-time accounting and scheduling.
The sampler supports up to 64 devices in one allocation. Larger allocations run
normally with telemetry disabled; telemetry availability does not change the
workload's exit code.

Queries are polled without blocking the workload, with at most two probes per
job, a per-query deadline (2 seconds by default, at most 5), a one-second SIGTERM
allowance before SIGKILL, and a round deadline (6 seconds by default, at most 10).
Failed devices back off up to 300 seconds. A probe stuck in uninterruptible driver
sleep cannot be guaranteed to die: it retains its probe slot, and task completion
never waits indefinitely for it. A separate shared probe guard also prevents later
jobs from spawning replacements while a stuck query still holds that guard.
Probes inherit no scheduler device-lock descriptors. Captured stdout is limited
to 64 KiB through nonblocking reads; driver log files are not size-limited by
the sampler.

A3 tables with an explicit physical-ID column use that mapping directly. Older
logic-only tables require a verified physical-ID remap; both use `usages -i N -c C`.
Ascend 950/A5 physical-ID tables use their explicit `Chip Phy-ID` mapping and
`usages -i N` without `-c`. Logic IDs are never assumed to be physical IDs, and
unrecognized hardware/driver formats remain unknown. These output formats are
covered with fixtures; a new platform still requires validation against its
actual driver output. See Huawei's [physical-ID remap reference](https://www.hiascend.com/document/detail/zh/Atlas%20200I%20A2/253RC1/re/npu/npusmi_059.html)
and the [950 mapping/query implementation in SwanLab](https://github.com/SwanHubX/SwanLab/blob/main/swanlab/sdk/internal/probe_python/hardware_vendor/accelerator/huawei.py).

Real-device checks on Ascend950DT / 9581 (board-reported software
`25.6.rc2.b023`) confirmed the A5 layout above and successful `usages -i N`
queries. Adding `-c 0` returned exit code 215 with
`This device does not support input parameter of -c.` The A5 `phyid-remap`
response uses `Chip Phy-ID` and also omits a logic ID; the sampler uses the
explicit physical-ID table. Queries on that host intermittently exceeded both
2-second and 5-second deadlines, including calls without a probe guard. A
bounded sampling run recorded four valid samples and an idle event, then
correctly transitioned to unknown on timeout. Keep query deadlines and backoff;
a timeout provides no zero-utilization evidence.

Records live in `state/usage/tasks/TASK_ID.json`, with task/user/device identity,
timestamps, per-card totals and the most recent 16 events per card. Event counts
and cumulative durations include older events too. Records survive normal task
cleanup; administrator `--clean` removes telemetry older than 35 days. Interrupted
or crashed samplers may leave incomplete records; live samples expire after two
sampling intervals instead of claiming continued activity or idle time.

### User sampling rankings

Ordinary users can read aggregate rankings without root or a device allocation:

```bash
task-submit --usage-ranking
task-submit --usage-ranking --days 7 --sort coverage --limit 20
task-submit --usage-ranking --days 7 --sort utilization --json
```

The default is the top 20 users over seven days, sorted by mean computation
utilization descending. `--sort coverage` selects valid sampling coverage;
`--limit` accepts 1–100 and `--days 0` includes all retained records. Both metrics,
valid/total sample counts, recorded card-seconds, suspected idle card-seconds and
task/event counts appear in JSON. Each valid sample uses the maximum recognized
AI Core, AI vector, AI CPU, AI cube or NPU utilization percentage. HBM occupancy
and control-CPU usage are excluded. The mean is weighted by valid sample count;
coverage is valid sampled intervals divided by recorded card duration. Missing
utilization is `null` and unranked, never zero. Tasks are selected by start time,
as in the telemetry table. This summarizes sampled, readable records, not every
allocation on the host; unreadable/incomplete records are counted as skipped.
Malformed records, invalid event timestamps and excessive JSON nesting are
skipped without preventing other users' records from being ranked.

The interface only reads stored telemetry and publishes user aggregates; no
task IDs, commands, environments, individual events or login information are
included. `--stats` retains its existing own-user restriction for ordinary
callers. Rankings remain advisory because submitters can modify their own
telemetry. JSON uses `schema_version: 1`, reports completeness with `status`,
and returns the rows in `ranking`.

### Public card-hour monitoring (development preview)

`task-submit --usage-monitor --json` provides per-user card usage for today,
the last 7 and the last 30 calendar days. An independent publisher combines
archived tasks with verified running allocations; final records replace
provisional values. Unknown end times freeze instead of continuing to charge.
Cleanup archives completed tasks before removing them. Completed records are
imported incrementally into daily aggregates; each sample overlays only live
allocations. Ordinary samples skip unchanged records. Directory changes trigger
metadata reconciliation; a five-minute content check catches same-timestamp edits.
Fixed-size SQLite headers detect archive changes. Initial backfill, archive changes
and timezone changes can take longer than ordinary refreshes.

The card-hour and device monitors support Python 3.9+ using standard-library modules.

Setup installs the independent 30-second timer, enabled by default. Set
`USAGE_MONITOR_ENABLED=false` to disable it. Use the same IANA
`USAGE_MONITOR_TIMEZONE` on all nodes (default UTC); the existing daily-report
timezone and Feishu publisher remain separate. Only summaries are public;
the ledger stays private. Missing history and collector gaps are explicit.

See the [interface contract](docs/task-submit-usage-monitor-api.md).
Validate with the usage Python tests and `bash tests/test_usage_install.sh`.
Use `python3 tests/benchmark_usage_monitor.py --history-tasks 50000 --done-files 1000`
for an isolated synthetic benchmark, including process startup and reconciliation.

### Archived server usage and Feishu daily reports

`task-submit --usage status` shows whether the independent collector is
enabled. `sudo task-submit --usage day --date YYYY-MM-DD` reads a local daily
report; the archive is administrator-only because it contains user sessions.
The collector archives completed task metadata and `wtmp` login sessions in
`state/usage-report/usage.sqlite3`; it does not query NPU devices. Card-hours
equal the task running interval within the day multiplied by assigned cards.
Login hours are the union of known sessions, not active working time.
Local task, session, and collection records are retained for 30 days by
default (`USAGE_RETENTION_DAYS`, allowed range 7–90); SQLite reclaims deleted
pages automatically. Published daily summaries remain in Feishu.

The feature is **off by default**. Ask the administrator whether to enable it
before setting `USAGE_REPORT_ENABLED=true` in `config/taskqueue.conf`:

```bash
USAGE_REPORT_ENABLED=true
USAGE_SERVER_LABEL="686"
USAGE_RETENTION_DAYS=30
USAGE_TIMEZONE="Asia/Shanghai" # 按服务器实际时区填写；本机为 America/Los_Angeles
USAGE_FEISHU_CONFIG="/home/pypto-tools/pto-simpler-perf-tracker/config/perf-tracker.env"
USAGE_INDEX_DOCX_TOKEN=""  # other servers use the first server's index ID
USAGE_HUB_STATE_FILE="/home/pypto-tools/pto-simpler-perf-tracker/state/usage-index.json" # hub server only
```

Run `sudo bash setup.sh` to install/enable the hourly collector and daily
publisher timers; the daemon needs no restart. The publisher creates a usage
index, one index per server, and weekly documents containing multiple days.
Each Feishu day is one server-wide summary without usernames; detailed user
records stay in the administrator-only local SQLite archive.
New documents are readable by members of the Feishu tenant who have the link.
It updates a date on retry and catches up after downtime. Credentials remain
in the 0600 Feishu config. The hub server writes a document ID to
`usage-index.json`, read by the performance tracker's report hub. Deploy a
tracker version with this integration before enabling publication.

## Local read-only monitoring

`task-submit --monitor --json` and `pto-task --monitor --json` return the same
machine-wide resource snapshot for ordinary monitoring accounts, including all
submitters, active allocations, overlapping reservation pools, scheduler state
and counts. The daemon publishes a sanitized atomic snapshot about every two
seconds; the CLI ignores project configuration and device-pool environment
variables. Stopped daemons, stale data and read failures never appear as an
empty, free machine. No HTTP service or hardware probe is added.

See the [monitor API and safe deployment instructions](docs/task-submit-monitor-api.md)
and [JSON example](docs/task-submit-monitor.example.json). Activate through the
existing guarded deployment process after running tasks finish; installing new
files alone does not add monitoring to an already running older daemon.

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

For a concise Chinese usage guide, see [GUIDE_ZH.md](GUIDE_ZH.md). Any assistant
that can run commands can read the full operating rules straight from the
installed client, with no per-tool setup:

```bash
task-submit --skill
```

It prints the
[skills/pto-task-operations/SKILL.md](skills/pto-task-operations/SKILL.md) that
ships with the deployed revision, so Claude Code, Codex and other agents see
instructions matching the installed client — including the rule that builds and
other preparation happen outside the card allocation. Assistants with a skill
directory may also link it for automatic discovery, for example:

```bash
mkdir -p ~/.codex/skills ~/.claude/skills
ln -s /absolute/path/to/npu-taskqueue/skills/pto-task-operations ~/.codex/skills/pto-task-operations
ln -s /absolute/path/to/npu-taskqueue/skills/pto-task-operations ~/.claude/skills/pto-task-operations
```

If a shared host has a canonical skills directory, keep the skill there and link
the assistant-specific entries to it instead. Installation does not overwrite an
existing skill or edit user-specific assistant configuration. Assistants without
a skill discovery mechanism can read `SKILL.md` directly.
