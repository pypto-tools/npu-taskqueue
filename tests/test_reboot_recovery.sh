#!/usr/bin/env bash
# Reuse the isolated daemon integration harness, without running its scenarios.
set -euo pipefail
REAP_TEST_HARNESS_ONLY=1 source "$(dirname "$0")/test_reap_orphans_race.sh"
case_root=$(setup_case reboot 2)
# An unrelated live PID in the old PID file must not block startup.
echo $$ > "$case_root/state/task-daemon.pid"
old=task_20260101_000010_10
legacy=task_20260101_000011_11
pending=task_20260101_000012_12
for task in "$old" "$legacy"; do
    submit "$case_root" "$task" none "touch $case_root/SHOULD_NOT_RUN"
    mv "$case_root/state/pending/$task" "$case_root/state/running/$task"
    # If recovery signals the recycled PID, it kills this test harness.
    printf 'TASK_PID=%s\nSTART_TIME=2000-01-01T00:00:00+00:00\n' "$$" >> "$case_root/state/running/$task"
    touch "$case_root/state/running/$task.env" "$case_root/logs/$task.log"
done
echo BOOT_ID=previous-boot >> "$case_root/state/running/$old"
submit "$case_root" "$pending" none "touch $case_root/pending-ran"
start_daemon "$case_root"
for task in "$old" "$legacy" "$pending"; do
    wait_for_path "$case_root/state/done/$task"
done
for task in "$old" "$legacy"; do
    [[ "$(field INTERRUPT_REASON "$case_root/state/done/$task")" == server-reboot ]] || fail 'missing reboot reason'
    [[ "$(field EXIT_CODE "$case_root/state/done/$task")" == 137 ]] || fail 'missing interruption status'
    [[ ! -e "$case_root/state/running/$task" && ! -e "$case_root/state/running/$task.env" ]] || fail 'stale running files'
    [[ -e "$case_root/logs/$task.log" ]] || fail 'log removed'
done
[[ ! -e "$case_root/SHOULD_NOT_RUN" && -e "$case_root/pending-ran" ]] || fail 'retry or pending regression'
# A second daemon must fail while the first holds the lock.
first=$DAEMON_PID
start_daemon "$case_root"
second=$DAEMON_PID
DAEMON_PID=$first
if wait "$second"; then fail 'second daemon acquired the lock'; fi
[[ "$(cat "$case_root/state/task-daemon.pid")" == "$first" ]] || fail 'second daemon overwrote PID'
stop_daemon

# The supervisor and its payload must not retain the singleton lock after SIGKILL.
case_root=$(setup_case inheritance 2)
task=task_20260101_000013_13
submit "$case_root" "$task" none 'sleep 30'
start_daemon "$case_root"
wait_for_field "$case_root/state/running/$task" TASK_PID
[[ "$(field BOOT_ID "$case_root/state/running/$task")" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || fail 'missing boot ID'
kill -KILL "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=''
flock -w 3 "$case_root/state/task-daemon.lock" true || fail 'task inherited daemon lock'
start_daemon "$case_root"
wait_for_path "$case_root/state/task-daemon.pid"
# Allow reconciliation to run; the same-boot live task must stay running.
sleep 1
[[ -e "$case_root/state/running/$task" && ! -e "$case_root/state/done/$task" ]] || fail 'same-boot task interrupted'
stop_daemon
echo 'test_reboot_recovery: OK'
