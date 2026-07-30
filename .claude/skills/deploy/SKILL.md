---
name: deploy
description: Deploy npu-taskqueue to the machine safely — pre-flight drift and BASE_DIR checks, drain running tasks via maintenance mode, run deploy.sh, then verify the installed build and smoke-test it. Use when the user asks to deploy, install, update, or roll out queue changes.
---

# npu-taskqueue Deploy

A deploy on this machine overwrites the tooling that ~50 people use and, by
default, kills every task currently running. Nothing here is reversible by
`Ctrl-Z`. Work through the steps in order.

**Requires the user's explicit go-ahead.** Present the pre-flight findings and
wait for confirmation before step 3 — always, including when the user's opening
message was "deploy it".

## Task tracking

```text
- [ ] Step 1: Pre-flight — drift, BASE_DIR, running work
- [ ] Step 2: Drain
- [ ] Step 3: deploy.sh
- [ ] Step 4: Post-deploy verification + smoke test
- [ ] Step 5: Undrain and report
```

## Step 1: pre-flight

Run the `verify` skill first — it covers syntax, drift, and doc consistency. Then
the three deploy-specific questions:

**a) Where is this host's `BASE_DIR`, and does it exist?**

```bash
grep '^BASE_DIR=' /etc/taskqueue.conf conf/taskqueue.conf
BASE_DIR=$(. /etc/taskqueue.conf; echo "$BASE_DIR"); ls -d "$BASE_DIR"
```

`BASE_DIR` is per-machine. `deploy.sh` keeps the host's value and only falls
back to the repository's when the host has no conf at all, so a difference
between the two lines above is **expected, not a problem** — the repo value is
just the fresh-install default (`ISSUES.md`, issue 25).

Two things still stop a deploy:

- **The host has no `/etc/taskqueue.conf`.** It was never installed; run
  `setup.sh --base-dir <path>` instead of deploying.
- **`BASE_DIR` points at a directory that does not exist.** `deploy.sh` refuses
  before copying anything. Find out why before creating it — a wrong path here
  means the running daemon and the conf already disagree.

Never edit `conf/taskqueue.conf` to match one host. It breaks every other host.

**b) Has anyone edited the installed copies in place?**

```bash
diff -u /usr/local/bin/task-submit  task-submit.sh
diff -u /usr/local/sbin/task-daemon task-daemon.sh
diff -u /usr/local/bin/npu-lock     npu_lock.sh
```

Anything present only in the installed copy is about to be destroyed. Read it,
show it to the user, and recover it into the repository before continuing —
this is exactly how the 07-13 incident happened (`ISSUES.md`, issue 4).

**c) What is running right now?**

```bash
task-submit --list
systemctl show taskqueue -p ExecMainStartTimestamp
```

`taskqueue.service` sets no `KillMode`, so `systemctl restart` — which
`deploy.sh` always does — SIGTERMs everything in the service cgroup, including
setsid'd task descendants. Those tasks are recorded as `EXIT_CODE=137` and their
owners get no explanation.

Report to the user: how many tasks are running, whose they are, how long they
have been going, and which committed fixes are not yet live.

## Step 2: drain

If anything is running and it is not the user's own throwaway work:

```bash
sudo task-submit --maintenance on "deploying <what changed>"
```

Queued tasks stop being scheduled; running tasks continue. Poll until `running/`
empties:

```bash
watch -n 30 'task-submit --list | sed -n "/=== Running/,/^$/p"'
```

Long jobs are submitted with `--max-time 0`, so "wait for it to drain" can mean
hours. Do not wait silently — tell the user the expected wait and let them
decide between waiting, asking the owner, or accepting the kill.

## Step 3: deploy

```bash
sudo bash deploy.sh
```

It copies the three scripts, the systemd unit, the udev rule, the profile.d
script, the cron file and the conf files, then `systemctl restart taskqueue`.

`deploy.sh` is `set -e`. If it stops partway, the machine is in a mixed state —
do not re-run it blindly. Find the failing line, understand what was already
copied, and fix that first.

## Step 4: verify what actually landed

```bash
for p in task-submit.sh:/usr/local/bin/task-submit \
         task-daemon.sh:/usr/local/sbin/task-daemon \
         npu_lock.sh:/usr/local/bin/npu-lock; do
  src="${p%%:*}"; dst="${p##*:}"
  diff -q "$src" "$dst" >/dev/null && echo "in sync : $dst" || echo "MISMATCH: $dst"
done

systemctl is-active taskqueue
systemctl show taskqueue -p ExecMainStartTimestamp   # must be just now
tail -20 /var/lib/taskqueue/taskqueue.log            # or $BASE_DIR from /etc/taskqueue.conf
```

A daemon that starts is not a daemon that schedules. Run one real task end to
end:

```bash
task-submit --timeout 60 --run "echo deploy-smoke-ok"          # no device
task-submit --device auto --timeout 60 --run 'echo "got $TASK_DEVICE"'   # allocation + lock
task-submit --list
```

Then check the daemon log for `assign`, `exec`, and `done` lines for those two
task ids. If the second one queues forever, the whitelist did not load — check
`task-submit --devices` and the `loaded runtime devices` line in the log.

## Step 5: undrain

```bash
sudo task-submit --maintenance off
task-submit --list      # queued work should start moving
```

Watch the first task through to completion before walking away.

## Report

State plainly:

- What was deployed (commit, which files changed)
- Whether anything installed-only was found and what happened to it
- Which tasks were killed or drained, and whose they were
- Smoke test result, with the actual output
- Anything still not deployed or still diverged

If a step was skipped, say which and why. "Deployed and verified" means every
step above ran.

## Never

- Edit `/usr/local/bin/task-submit` or any installed copy directly — see
  `.claude/rules/deployment-integrity.md`
- Deploy with a `BASE_DIR` mismatch
- Restart the daemon to "clear something up" while tasks are running
- Report success from `systemctl is-active` alone
