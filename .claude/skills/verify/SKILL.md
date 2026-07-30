---
name: verify
description: Check npu-taskqueue changes — bash syntax, shellcheck, repo-vs-installed drift, doc/config consistency, and a rootless end-to-end smoke test of the queue. Use before committing, before deploying, or when the user asks to verify/check/test the queue scripts.
context: fork
allowed-tools: Read, Grep, Glob, Bash
---

# npu-taskqueue Verification

You are a verification agent. Run the checks, report what you found, and do not
fix anything.

## There is no test suite

Six Bash scripts, no test framework, no `make check`. Never claim "tests
passed". The gate is: syntax, static analysis, a live smoke test on a private
queue, and consistency between the scripts and the documents that describe them.

## This may be the production host

Check before doing anything that touches system state:

```bash
systemctl is-active taskqueue 2>/dev/null && cat /etc/taskqueue.conf
```

If the daemon is active, the machine is serving real users. Then:

- **Never** restart the service, edit anything under `/usr/local`, or write to
  the deployed `BASE_DIR`.
- The smoke test below is safe — it runs a private queue under your own uid in a
  scratch directory, with its own `BASE_DIR` and its own lock namespace.
- Because the lock namespace is per-`BASE_DIR`, a scratch task that really opens
  an NPU would **not** be excluded by production's locks. Keep smoke-test
  commands to `echo` / `true` and never let one touch a device.

## 1. Syntax

```bash
for f in *.sh; do bash -n "$f" && echo "OK   $f" || echo "FAIL $f"; done
```

Must be clean for every file. `taskqueue-npu.sh` is comments only — still check it.

## 2. Static analysis

```bash
command -v shellcheck >/dev/null && shellcheck -x *.sh || echo "shellcheck not installed — say so in the report"
```

Do not report "lint clean" when the tool is absent. Say it did not run.

Expect pre-existing findings in unchanged code. Separate them from anything the
current diff introduced:

```bash
git diff --name-only            # what actually changed
git diff --cached --name-only
```

## 3. Repo vs installed drift

The most valuable check in this repository, and the cheapest. See
`.claude/rules/deployment-integrity.md` for why.

```bash
for p in task-submit.sh:/usr/local/bin/task-submit \
         task-daemon.sh:/usr/local/sbin/task-daemon \
         npu_lock.sh:/usr/local/bin/npu-lock; do
  src="${p%%:*}"; dst="${p##*:}"
  [ -f "$dst" ] || { echo "not installed: $dst"; continue; }
  diff -q "$src" "$dst" >/dev/null && echo "in sync : $src" || echo "DIVERGED: $src <-> $dst"
done
grep -H '^BASE_DIR=' /etc/taskqueue.conf conf/taskqueue.conf 2>/dev/null
```

`BASE_DIR` differing between the host and the repository is **normal** — it is
per-machine, and `deploy.sh` preserves the host's value. Report it as context,
not as a finding. What *is* a finding: no `/etc/taskqueue.conf` on a host that
is supposed to be installed, or a `BASE_DIR` naming a directory that does not
exist.

Any divergence is a finding, and the direction matters — report both:

- **Installed is ahead** — someone edited a deployed copy in place. Their change
  is one `deploy.sh` away from being erased. Name the functions involved.
- **Repo is ahead** — committed fixes are not running. List which ones, by
  grepping for their markers, so the reader knows what is still live in
  production:

  ```bash
  for m in ignore-whitelist 未知选项 'tail -n +1' 'TERM HUP' marked_pids sweep_task find_tasks; do
    printf '%-20s installed=%s repo=%s\n' "$m" \
      "$(grep -c -- "$m" /usr/local/bin/task-submit /usr/local/sbin/task-daemon 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')" \
      "$(grep -c -- "$m" task-submit.sh task-daemon.sh 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
  done
  ```

**Committed fixes that are not deployed are a blocking finding.** Say which
behaviours are still live on the host, by name, so nobody reports a bug as fixed
on the strength of the repository alone.

## 4. Docs and config agree with the code

Cheap greps that have each caught a real defect:

```bash
cat conf/available_devices                       # the auto pool
grep -rn "available_devices\|12,13,14,15\|4-15" README.md GUIDE.md claude-skill/
grep -rn "ASCEND_RT_VISIBLE_DEVICES" *.sh        # must appear only as an exclusion
grep -rn "逻辑编号\|logical device" *.md          # numbering is physical; see issue 16
grep -c "MAX_CONCURRENT" conf/taskqueue.conf
```

Flag: a whitelist documented differently in two places; a device-numbering claim
that the code does not implement; an option in `--help` that the parser does not
accept, or vice versa.

```bash
# every long option the parser knows, vs every one the usage text advertises
grep -oE '^\s+--[a-z-]+' task-submit.sh | tr -d ' ' | sort -u > /tmp/tq_parsed
grep -oE 'task-submit --[a-z-]+' GUIDE.md README.md claude-skill/task-submit/SKILL.md |
  grep -oE '\--[a-z-]+' | sort -u > /tmp/tq_documented
comm -13 /tmp/tq_parsed /tmp/tq_documented   # documented but not parsed → broken docs
```

## 5. Rootless end-to-end smoke test

Runs a complete queue as your own user. Verified working on this host.

```bash
SB=$(mktemp -d); SRC=$PWD
mkdir -p "$SB/tq"/{pending,running,done,logs,locks,kill,fifo}
printf 'BASE_DIR="%s/tq"\nMAX_CONCURRENT=2\n' "$SB" > "$SB/tq/taskqueue.conf"
export TASKQUEUE_CONF="$SB/tq/taskqueue.conf" TASKQUEUE_ALLOW_USER=1

nohup bash "$SRC/task-daemon.sh" > "$SB/daemon.out" 2>&1 &
DPID=$!; sleep 1

# a) submit / schedule / complete
id=$(bash "$SRC/task-submit.sh" "echo hello-from-task")
sleep 2
bash "$SRC/task-submit.sh" --status "$id"     # expect: completed (exit=0)
bash "$SRC/task-submit.sh" --log "$id"        # expect: hello-from-task

# b) device allocation + npu-lock + TASK_DEVICE injection (no real device touched)
bash "$SRC/task-submit.sh" --device auto --timeout 20 --run 'echo "TASK_DEVICE=$TASK_DEVICE"'

# c) exit-code propagation to the client
bash "$SRC/task-submit.sh" --timeout 20 --run 'exit 42'; echo "client exit=$?  (expect 42)"

kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; rm -rf "$SB"
```

`--device auto` works here even without real hardware: with no
`available_devices` file the daemon falls back to `/dev/davinci*` detection and
then to a two-device default, and `npu-lock` only `flock`s a file.

Extend it for what the change touched — `--kill` and `--cancel` for kill-path
changes, `--clean --days 0` for cleanup changes, a task that outlives its leader
(`bash -c 'sleep 30 & exit 0'`) for sweep changes.

## Report format

```text
## Verification Summary
**Status:** ✅ PASS / ⚠️ WARNINGS / ❌ FAIL

### Syntax
[bash -n per file]

### Static analysis
[shellcheck findings, or "not installed — did not run"]

### Repo vs installed
[in sync / diverged, which direction, which fixes are not running,
 BASE_DIR agreement]

### Docs vs code
[inconsistencies found, with file:line]

### Smoke test
[which scenarios ran and their observed output; "not run" and why, if skipped]

### Tests
No test suite exists in this repository. (Never omit this line — its absence
reads as "tests passed".)

### Recommendations
[specific, ordered]
```

| Status | Criteria |
|---|---|
| PASS | Syntax clean, smoke test green, no drift, docs agree |
| WARNINGS | Pre-existing shellcheck findings, or drift that is understood and intended |
| FAIL | Any syntax error, a failing smoke scenario, a missing/dangling `BASE_DIR`, or committed fixes that are not deployed |
