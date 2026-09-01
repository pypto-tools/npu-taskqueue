#!/usr/bin/env bash
# reap_orphans 与 run_task 收尾窗口的竞态回归测试。
#
# 背景：任务 leader 正常退出（exit 0）后，run_task 还要在 sweep_task 里清扫脱离
# 出去的后代，有残留时最长卡 KILL_GRACE 秒，这期间 running 文件仍在。旧实现的
# reap_orphans 只看 leader 死活，1 秒宽限一到就把这个正常收尾中的任务当孤儿：写
# 「任务被中断」、提前删 running 文件释放卡，随后 run_task 再用 exit=0 覆盖 done，
# 留下"PASS 却标记中断"的矛盾现场。
#
# 三个场景：
#   1. 正常收尾（有赖着不走的后代）不得被 reap；
#   2. 真孤儿（监管进程和 leader 都被 kill -9）仍要被 reap；
#   3. 没有 RUN_TASK_PID 的 running 文件（旧 daemon 遗留 / run_task 在 exec 出
#      leader 之前就挂掉）仍要被 reap，不能永久占着设备。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
DAEMON_PID=""

cleanup() {
    if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

wait_for_path() {
    local path="$1" limit="${2:-200}"
    for _ in $(seq 1 "$limit"); do
        [[ -e "$path" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $path"
}

wait_for_field() {
    local file="$1" key="$2" limit="${3:-200}"
    for _ in $(seq 1 "$limit"); do
        if [[ -f "$file" ]] && grep -q "^${key}=." "$file"; then
            return 0
        fi
        sleep 0.05
    done
    fail "timed out waiting for $key in $file"
}

field() {
    local key="$1" file="$2"
    sed -n "s/^${key}=//p" "$file" | head -1
}

ppid_of() {
    local pid="$1" line
    { read -r line < "/proc/$pid/stat"; } 2>/dev/null || return 1
    line="${line##*) }"
    # shellcheck disable=SC2086
    set -- $line
    printf '%s' "$2"
}

# task-daemon 要求配置文件 root 所有。这里只伪造启动时的那几次元数据读取，让集成
# 场景能以普通用户跑起来；运行期的 stat 调用仍走真实二进制。
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$REAP_TEST_CONFIG_DIR" || "$3" == "$REAP_TEST_CONFIG" ]]; then
    printf '0\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$REAP_TEST_CONFIG_DIR" ]]; then
    printf '755\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$REAP_TEST_CONFIG" ]]; then
    printf '644\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod 755 "$FAKE_BIN/stat"
cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
EOF
chmod 755 "$FAKE_BIN/id"

# 建一个独立的 state/logs/config 树并返回 case 根目录。
setup_case() {
    local name="$1" max_concurrent="$2"
    local case_root="$TEST_ROOT/$name"
    mkdir -p "$case_root/config" "$case_root/logs" \
             "$case_root/state"/{pending,running,done,locks,kill,fifo,usage}
    chmod 1777 "$case_root/state"/{pending,locks,kill,fifo}
    cat > "$case_root/config/taskqueue.conf" <<EOF
STATE_DIR="$case_root/state"
LOGS_DIR="$case_root/logs"
MAX_CONCURRENT=$max_concurrent
SCHEDULER_MODE=backfill
KILL_GRACE=5
MAX_TIME_HARD_CAP=0
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7"
EOF
    printf '%s' "$case_root"
}

start_daemon() {
    local case_root="$1"
    REAP_TEST_CONFIG_DIR="$case_root/config" \
    REAP_TEST_CONFIG="$case_root/config/taskqueue.conf" \
    TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$case_root/config/taskqueue.conf" \
    PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/task-daemon.sh" &
    DAEMON_PID=$!
}

stop_daemon() {
    [[ -n "$DAEMON_PID" ]] || return 0
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=""
}

submit() {
    local case_root="$1" task_id="$2" device="$3" command="$4"
    cat > "$case_root/state/pending/$task_id" <<EOF
SUBMIT_USER=$(/usr/bin/id -un)
SUBMIT_TIME=2026-01-01T00:00:00+00:00
WORK_DIR=$case_root
COMMAND=$command
DEVICE=$device
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$case_root/state/pending/$task_id"
}

# --- 场景 1：正常收尾期间不得被误判为孤儿 -----------------------------------
# leader 立刻 exit 0，但留下一个无视 SIGTERM 的后代。run_task 的 sweep_task 会
# SIGTERM → 等满 KILL_GRACE(5s) → SIGKILL，整个窗口远超 reap 的 ~1s 宽限。
run_finishing_task_not_reaped() {
    local case_root task_id done_file task_log
    case_root=$(setup_case finishing 2)
    task_id=task_20260101_000001_1
    submit "$case_root" "$task_id" 0 \
        'bash -c '"'"'trap "" TERM; sleep 60'"'"' >/dev/null 2>&1 & exit 0'
    start_daemon "$case_root"

    done_file="$case_root/state/done/$task_id"
    task_log="$case_root/logs/${task_id}.log"
    wait_for_path "$done_file" 400
    stop_daemon

    local daemon_log="$case_root/logs/taskqueue.log"
    # 先确认竞态窗口真的被撑开了，否则本用例会无意义地通过。
    grep -Fq "sweep: $task_id leftover" "$daemon_log" ||
        fail "scenario 1 did not reproduce: run_task never entered sweep_task"
    grep -Fq "sweep: $task_id survivors ignored SIGTERM" "$daemon_log" ||
        fail "scenario 1 did not reproduce: sweep window shorter than KILL_GRACE"

    grep -Fq "reap: $task_id" "$daemon_log" &&
        fail "scenario 1: finishing task was reaped as an orphan"
    [[ "$(field EXIT_CODE "$done_file")" == 0 ]] ||
        fail "scenario 1: expected EXIT_CODE=0, got '$(field EXIT_CODE "$done_file")'"
    grep -Fq '任务被中断' "$task_log" &&
        fail "scenario 1: successful task was marked as interrupted"
    [[ ! -e "$case_root/state/running/$task_id" ]] ||
        fail "scenario 1: running file left behind"
    return 0
}

# --- 场景 2：真孤儿仍要被回收 ------------------------------------------------
run_real_orphan_reaped() {
    local case_root task_id running_file done_file
    case_root=$(setup_case orphan 2)
    task_id=task_20260101_000002_2
    submit "$case_root" "$task_id" 1 'sleep 300'
    start_daemon "$case_root"

    running_file="$case_root/state/running/$task_id"
    wait_for_field "$running_file" TASK_PID
    wait_for_field "$running_file" RUN_TASK_PID

    local owner tpid
    owner=$(field RUN_TASK_PID "$running_file")
    tpid=$(field TASK_PID "$running_file")

    # $$ 在 `run_task ... &` 的子 shell 里仍是 daemon 自己的 pid。写错了的话每个
    # 任务都会被判成"有活的监管进程"，孤儿回收静默失效——这里直接钉死。
    [[ "$owner" != "$DAEMON_PID" ]] ||
        fail "scenario 2: RUN_TASK_PID equals daemon pid (must be \$BASHPID, not \$\$)"
    [[ "$(ppid_of "$owner")" == "$DAEMON_PID" ]] ||
        fail "scenario 2: RUN_TASK_PID $owner is not a child of daemon $DAEMON_PID"

    kill -9 "$owner" 2>/dev/null || true
    kill -9 "$tpid" 2>/dev/null || true

    done_file="$case_root/state/done/$task_id"
    wait_for_path "$done_file" 400
    stop_daemon

    grep -Fq "reap: $task_id" "$case_root/logs/taskqueue.log" ||
        fail "scenario 2: real orphan was not reaped"
    [[ "$(field EXIT_CODE "$done_file")" == 137 ]] ||
        fail "scenario 2: expected EXIT_CODE=137, got '$(field EXIT_CODE "$done_file")'"
    [[ ! -e "$case_root/state/running/$task_id" ]] ||
        fail "scenario 2: running file left behind, device stays leaked"
    return 0
}

# --- 场景 3：没有 RUN_TASK_PID 的 running 文件仍要被回收 ---------------------
# legacy 文件带一个已死的 TASK_PID（旧 daemon 遗留）；stillborn 文件两个 pid 都
# 没有（run_task 在 exec 出 leader 之前就挂了）——旧实现对后者是无条件跳过，设备
# 永远回不来。
run_pidless_running_files_reaped() {
    local case_root dead_pid
    case_root=$(setup_case pidless 4)
    bash -c 'exit 0' & dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    write_stale() {
        local task_id="$1" device="$2" pid_line="$3"
        cat > "$case_root/state/running/$task_id" <<EOF
SUBMIT_USER=$(/usr/bin/id -un)
SUBMIT_TIME=2026-01-01T00:00:00+00:00
WORK_DIR=$case_root
COMMAND=true
DEVICE=$device
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
${pid_line}
EOF
        chmod 644 "$case_root/state/running/$task_id"
    }

    start_daemon "$case_root"
    # 落在 daemon 启动之后，确保走的是 reap_orphans 而不是启动时的 reconcile_running。
    sleep 1
    write_stale task_20260101_000003_3 6 "TASK_PID=$dead_pid"
    write_stale task_20260101_000004_4 7 ""

    local t
    for t in task_20260101_000003_3 task_20260101_000004_4; do
        wait_for_path "$case_root/state/done/$t" 400
    done
    stop_daemon

    for t in task_20260101_000003_3 task_20260101_000004_4; do
        [[ "$(field EXIT_CODE "$case_root/state/done/$t")" == 137 ]] ||
            fail "scenario 3: $t expected EXIT_CODE=137, got '$(field EXIT_CODE "$case_root/state/done/$t")'"
        [[ ! -e "$case_root/state/running/$t" ]] ||
            fail "scenario 3: $t running file left behind"
    done
    return 0
}

run_finishing_task_not_reaped
run_real_orphan_reaped
run_pidless_running_files_reaped
echo "test_reap_orphans_race: OK"
