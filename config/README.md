# Installed configuration

The installer creates this file automatically when it is missing:

```text
/home/pypto-tools/pto-task/config/taskqueue.conf
```

It also creates `pypto-env.conf` in the same directory. That file configures
the paths reported and exported by `pypto-setup`; like `taskqueue.conf`, it is
host-local and preserved across updates. Users can override it with exported
environment variables or `~/.config/pypto-env.conf`.

It is local machine configuration and is never copied or overwritten during an
update. Set `MAX_CONCURRENT`, `MAX_TIME_HARD_CAP`, `KILL_GRACE`, and
`AVAILABLE_DEVICES` there. `TASK_EXECUTION_MODE` defaults to `HwHiAiUser`: a
task keeps its submitting user's UID and gains the `HwHiAiUser` NPU group. Set
it to `root` only for a fully trusted queue; every submitted command will then
run with root privileges. `STATE_DIR` and `LOGS_DIR` normally remain the paths
written by the installer.

`SCHEDULER_MODE` selects a root-managed scheduler module. `backfill` is the
default and preserves the historical behavior: a blocked task is skipped so
later runnable tasks may use otherwise idle resources.
`pool_aware_reservation` prevents multi-device starvation by stopping younger
device jobs when the oldest
satisfiable multi-device request is waiting for cards. Its effective
`DEVICE_POOL` is protected while released cards accumulate; younger jobs may
still use enough free devices outside that range, including disjoint pools from
other repositories' `task-submit.conf` files. Device-free work may continue
while a concurrency slot is reserved. `POOL_AWARE_RESERVATION_MIN_DEVICES`
controls the minimum reservation size and defaults to `2`. Unknown modes and
invalid module settings are rejected instead of silently falling back. The
mode is read when the daemon starts; change it only while the queue is idle,
then restart the service.

The two policies share `app/schedulers/_core.sh`. The core owns queue traversal,
host admission, allocation validation, and atomic execution; selectable API-v2
modules only return scheduling decisions. `SCHEDULER_MODE` is a safe lowercase
identifier resolved to a root-managed `app/schedulers/<mode>.sh`, not an
arbitrary path. A new repository module is installed automatically by
`setup.sh`; `_core.sh` cannot be selected as a policy.

`DEVICE_GROUPS` describes which cards share a communication domain (HCCS plane)
on this host, as semicolon-separated groups of comma-separated card ids, for
example `DEVICE_GROUPS="0,1;2,3"`. It is per-machine hardware truth, so it
belongs here rather than in a repository's `task-submit.conf`, which travels to
hosts with a different topology. A card may appear in at most one group, and a
card left out of every group is treated as sharing a plane with nothing else, so
it can only ever satisfy a single-card request.

Empty is the default and means the topology is unknown, which is not the same as
every card sharing one plane: a host that really is single-plane declares that
with one all-inclusive group. A repository that has not opted in is unaffected
by an empty value, but a repository that opted in has its multi-card requests
refused until the host declares its groups, because guessing "fully connected"
is wrong exactly on the multi-plane hosts the constraint exists for, and being
wrong there costs a card until the platform resets it.

A repository opts in per task with `DEVICE_GROUP_AFFINITY=1` in its
`task-submit.conf`. Every multi-card task from that repository is then confined
to one group: `--device auto --device-num N` is allocated from a single group
that has `N` free cards and otherwise waits, while an explicit `--device` list
or a `DEVICE_SEQ_N` sequence that spans groups is refused at submission. The
scheduler core, not the selected policy, owns this rule, and it revalidates the
devices immediately before locking them, so no policy can allocate across
planes. `--ignore-group-affinity` (or `TASKQUEUE_IGNORE_GROUP_AFFINITY=1`) turns
the constraint off for loads that genuinely cross planes, such as pure HCCL
collectives with `HCCL_INTRA_ROCE_ENABLE=1`. The rule exists because pypto and
simpler build their data plane on ACL VMM Fabric handles, which cannot be
established across planes: the collective does not return an error, it hangs,
and the cards stay unusable until the platform resets them out of band.

`MAX_CONCURRENT_8_CARD_TASKS` defaults to `0`, which preserves the historical
scheduler behavior. Set it to `1` only in a host's local configuration when
that server should keep additional eight-card jobs pending without blocking
later smaller jobs. Automatic updates preserve the local configuration and do
not enable this policy elsewhere.

`USAGE_SAMPLING_ENABLED` defaults to `false`; set it to `true` and rerun
`setup.sh` to install and enable the independent usage-sampling timer.

Repository-controlled rollout settings are kept separately in
`config/repo-auto-update.env`, which is also preserved across updates. This is
the only automatic-update channel and its timer is enabled by default. The
remote gate is `update/rollout.json`; its default enabled-but-empty target keeps
servers polling without updating. A deployment target must be a full commit on
the configured branch with a monotonically increasing sequence. Candidate tests
run as `REPO_AUTO_UPDATE_TEST_USER`; after the queue becomes idle, the exact
target is installed and an active daemon is restarted automatically. Optional
`REPO_AUTO_UPDATE_FETCH_USER` and
`REPO_AUTO_UPDATE_FETCH_ALL_PROXY` settings support hosts where the root service
has no direct repository egress.

For a source checkout, put equivalent local configuration in the ignored
`runtime/config/taskqueue.conf`; source execution uses `runtime/state` and
`runtime/logs` by default.
