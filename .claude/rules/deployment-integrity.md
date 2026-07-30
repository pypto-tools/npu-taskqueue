# Deployment Integrity

## The rule

**This repository is the only source of truth for what runs on the machine.**

Never edit `/usr/local/bin/task-submit`, `/usr/local/sbin/task-daemon`,
`/usr/local/bin/npu-lock`, `/etc/taskqueue.conf`, or any other installed copy in
place. Change the file here, commit it, and run `sudo bash deploy.sh`.

## Why this is a rule and not a preference

`deploy.sh` copies unconditionally. Any edit made only to an installed copy
survives until the next deploy and then vanishes without a trace — and the
deploy that erases it looks like a routine update.

That is not a hypothetical failure mode. It happened on 2026-07-13
(`ISSUES.md`, issue 4): fixes made directly in `/usr/local/bin/task-submit` on
07-03 and 07-07 were never committed here, so deploying this repository rolled
`task-submit` back to the 06-29 build, which did not understand
`--ignore-whitelist`. The CI job that passed that flag then locked 8 cards, ran
the string `--ignore-whitelist` as its command, skipped pytest entirely, and
**reported green for a week**.

The option parser now rejects unknown flags, so that exact silent failure cannot
recur. The underlying hazard — installed copy diverging from the repository —
is unchanged.

## Before you deploy

1. **Check for divergence.** If the installed copy differs from `HEAD`, someone
   edited it in place; recover their change into the repository before you
   overwrite it.

   ```bash
   diff -u /usr/local/bin/task-submit  task-submit.sh
   diff -u /usr/local/sbin/task-daemon task-daemon.sh
   diff -u /usr/local/bin/npu-lock     npu_lock.sh
   ```

2. **Check `BASE_DIR`.** `deploy.sh` preserves the host's value, but confirm the
   host actually has one and that it exists — a host with no
   `/etc/taskqueue.conf` gets the repository's fallback path, which is probably
   not what that machine uses.

   ```bash
   grep '^BASE_DIR=' /etc/taskqueue.conf conf/taskqueue.conf
   ```

3. **Check for running work.** `taskqueue.service` sets no `KillMode`, so the
   default `control-group` applies and `systemctl restart` — which `deploy.sh`
   always does — kills every running task, setsid'd descendants included. They
   are recorded as `EXIT_CODE=137` and their owners are not told why.

   ```bash
   task-submit --list        # anything under "=== Running ==="?
   ```

4. **Drain, don't interrupt.** If there is running work and it is not yours:

   ```bash
   sudo task-submit --maintenance on "deploying <what>"
   # wait for running/ to empty
   sudo bash deploy.sh
   sudo task-submit --maintenance off
   ```

## After you deploy

Confirm the installed copies match the repository and the daemon came back:

```bash
diff -q /usr/local/bin/task-submit task-submit.sh && echo "task-submit in sync"
systemctl is-active taskqueue
task-submit --list
```

Then run one real task end to end. A daemon that starts is not a daemon that
schedules — the `deploy` skill's smoke test covers this.

## What is per-machine, and what the repository owns

**`BASE_DIR` belongs to the machine.** Every host picks its own at install time
(`setup.sh --base-dir`), so the repository must not sync it. `deploy.sh` reads
the host's `/etc/taskqueue.conf`, keeps its `BASE_DIR`, syncs the remaining keys
from `conf/taskqueue.conf`, carries over any host-only keys it finds (e.g.
`KILL_GRACE`), and refuses to run when `BASE_DIR` does not exist. The value in
`conf/taskqueue.conf` is the fallback for a host that has never been installed —
nothing else.

Do not "fix" a `BASE_DIR` mismatch by editing `conf/taskqueue.conf` to match one
host. That breaks every other host, and it is the mistake the current design
exists to prevent (`ISSUES.md`, issue 25).

**The device whitelist belongs to the repository.** `deploy.sh` overwrites
`$BASE_DIR/available_devices` with `conf/available_devices`, so a whitelist set
at runtime with `task-submit --devices "2,3"` is silently reverted by the next
deploy. If a runtime change is meant to last, commit it; if it is temporary, say
so where it will be seen.

`conf/restricted-users` is copied to `/etc/taskqueue-restricted-users` and read
by nothing (`ISSUES.md`, issue 24). Editing it does not restrict anyone; the
group change is manual (`gpasswd -d <user> HwHiAiUser`). Do not report a roster
change as done on the strength of a deploy.
