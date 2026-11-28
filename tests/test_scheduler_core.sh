#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
DYNAMIC_DAEMON_PID=""

cleanup() {
    if [[ -n "$DYNAMIC_DAEMON_PID" ]] && kill -0 "$DYNAMIC_DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DYNAMIC_DAEMON_PID" 2>/dev/null || true
        wait "$DYNAMIC_DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PENDING_DIR="$TEST_ROOT/pending"
mkdir -p "$PENDING_DIR"
LOG_FILE="$TEST_ROOT/scheduler.log"
AVAILABLE_DEVICES="0,1,2,3"
RUNTIME_DEVICES=""
IN_USE_SET=","
CURRENT_JOBS=0
MAX_CONCURRENT=4
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0
SCHEDULER_MODE=contract_test
STARTED_TASKS=""

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

log() {
    printf '%s\n' "$*" >> "$LOG_FILE"
}

read_field() {
    local wanted="$1" file="$2" key value
    [[ -f "$file" ]] || return 1
    while IFS='=' read -r key value; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < "$file"
    return 1
}

device_request_count() {
    local request="$1" id
    local -a ids
    local -A seen=()
    case "$request" in
        ""|none) printf '0' ;;
        auto) printf '1' ;;
        auto:*)
            [[ "$request" =~ ^auto:([1-9][0-9]*)$ ]] && printf '%s' "${BASH_REMATCH[1]}" || printf '0'
            ;;
        *)
            [[ "$request" =~ ^[0-9]+(,[0-9]+)*$ ]] || { printf '0'; return; }
            IFS=',' read -ra ids <<< "$request"
            for id in "${ids[@]}"; do seen["$id"]=1; done
            printf '%s' "${#seen[@]}"
            ;;
    esac
}

detect_device_count() {
    printf '4\n'
}

any_device_in_use() {
    local devices="$1" id
    local -a ids
    [[ -z "$devices" || "$devices" == none ]] && return 1
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ "$IN_USE_SET" == *",$id,"* ]] && return 0
    done
    return 1
}

start_pending_task() {
    local task_file="$1" task_id="$2" assigned="$3" count="$4"
    STARTED_TASKS="${STARTED_TASKS}${task_id}:${assigned};"
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    [[ -z "$assigned" || "$assigned" == none ]] || IN_USE_SET="${IN_USE_SET}${assigned},"
}

# shellcheck source=../schedulers/_core.sh
source "$REPO_DIR/schedulers/_core.sh"

make_task() {
    local task_id="$1" request="$2" pool="$3"
    cat > "$PENDING_DIR/$task_id" <<EOF
DEVICE=$request
DEVICE_POOL=$pool
EOF
}

reset_runtime() {
    CURRENT_JOBS=0
    MAX_CONCURRENT=4
    MAX_CONCURRENT_8_CARD_TASKS=0
    RUNNING_8_CARD_TASKS=0
    IN_USE_SET=","
    STARTED_TASKS=""
    : > "$LOG_FILE"
    rm -f "$PENDING_DIR"/task_*
    unset -f scheduler_begin_tick scheduler_consider_task scheduler_end_tick scheduler_task_started 2>/dev/null || true
}

# Pool helpers preserve global device order, deduplicate candidates, and apply
# both task-pool and reservation exclusions.
AVAILABLE_DEVICES="3,1,2,1,0"
assert_eq "1,2" "$(scheduler_effective_pool '1,2')" "effective pool"
IN_USE_SET=",1,"
assert_eq "2,0" "$(scheduler_find_free_devices 2 '0,1,2,3' '3')" "free devices with exclusion"
AVAILABLE_DEVICES="0,1,2,3"

# A policy must make exactly one decision for each considered task.
scheduler_reset_decision
scheduler_plan_start "0" runnable
if scheduler_plan_defer duplicate; then
    fail "scheduler core accepted two decisions for one task"
fi
assert_eq start "$SCHEDULER_DECISION" "first decision remains authoritative"

# A valid auto allocation reaches daemon execution.
reset_runtime
make_task task_20260101_000001_1 auto:2 0,1,2
scheduler_start_planned_task "$PENDING_DIR/task_20260101_000001_1" \
    task_20260101_000001_1 auto:2 2 0,1,2 0,1
assert_eq "task_20260101_000001_1:0,1;" "$STARTED_TASKS" "valid allocation"

# Invalid policy allocations fail closed before start_pending_task.
reset_runtime
make_task task_20260101_000002_2 auto:2 0,1,2
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000002_2" \
    task_20260101_000002_2 auto:2 2 0,1,2 0,3; then
    fail "scheduler core accepted allocation outside effective pool"
fi
assert_eq "" "$STARTED_TASKS" "outside-pool allocation did not start"

reset_runtime
make_task task_20260101_000003_3 auto:2 0,1,2
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000003_3" \
    task_20260101_000003_3 auto:2 2 0,1,2 0,0; then
    fail "scheduler core accepted duplicate devices"
fi

reset_runtime
make_task task_20260101_000004_4 auto:2 0,1,2
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000004_4" \
    task_20260101_000004_4 auto:2 2 0,1,2 0,0,1; then
    fail "scheduler core accepted an allocation with repeated devices"
fi

reset_runtime
make_task task_20260101_000005_5 0,1 ''
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000005_5" \
    task_20260101_000005_5 0,1 2 '' 0,2; then
    fail "scheduler core rewrote an explicit request"
fi

reset_runtime
make_task task_20260101_000006_6 auto:2 0,1,2
IN_USE_SET=",1,"
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000006_6" \
    task_20260101_000006_6 auto:2 2 0,1,2 0,1; then
    fail "scheduler core double-allocated an in-use device"
fi

# Common host admission runs before policy code, so every future module obeys
# the same eight-card cap without reimplementing it.
reset_runtime
make_task task_20260101_000007_7 0,1,2,3,4,5,6,7 ''
MAX_CONCURRENT_8_CARD_TASKS=1
RUNNING_8_CARD_TASKS=1
CONSIDERED=0
scheduler_consider_task() {
    CONSIDERED=$((CONSIDERED + 1))
    scheduler_plan_start "$3" fixture
}
scheduler_schedule_tick
assert_eq 0 "$CONSIDERED" "eight-card cap bypassed policy"
assert_eq "" "$STARTED_TASKS" "capped task did not start"

# Missing/invalid policy decisions stop the tick safely instead of mutating the
# queue or silently falling back to another scheduler.
reset_runtime
make_task task_20260101_000008_8 none ''
scheduler_consider_task() { return 0; }
if scheduler_schedule_tick; then
    fail "scheduler core accepted an empty policy decision"
fi
assert_eq "" "$STARTED_TASKS" "empty decision did not start"
grep -Fq "returned invalid decision '<empty>'" "$LOG_FILE"

# During a file-by-file upgrade, an old API-v1 daemon may source a new policy
# before the daemon binary itself is replaced. Both shipped policies bridge
# that state by loading the shared core and exposing scheduler_schedule_tick.
for compatibility_module in backfill pool_aware_reservation; do
    (
        unset SCHEDULER_CORE_API_VERSION SCHEDULER_MODULE_API_VERSION SCHEDULER_MODULE_NAME
        # shellcheck source=/dev/null
        source "$REPO_DIR/schedulers/$compatibility_module.sh"
        assert_eq 1 "$SCHEDULER_MODULE_API_VERSION" "$compatibility_module upgrade API"
        declare -F scheduler_schedule_tick >/dev/null || fail "$compatibility_module did not load scheduler core"
        declare -F scheduler_consider_task >/dev/null || fail "$compatibility_module did not expose policy hook"
    )
done

# A new root-managed API-v2 module is discovered by its safe identifier; the
# daemon does not need a policy-name case statement change.
run_dynamic_module_case() {
    local case_root="$TEST_ROOT/dynamic-module"
    local app="$case_root/app" config_dir="$case_root/config"
    local config="$config_dir/taskqueue.conf" state="$case_root/state"
    local logs="$case_root/logs" fake_bin="$case_root/fake-bin"
    mkdir -p "$app/schedulers" "$config_dir" "$logs" "$fake_bin" \
        "$state"/{pending,running,done,locks,kill,fifo,usage}
    chmod 1777 "$state"/{pending,locks,kill,fifo}
    cp "$REPO_DIR/task-daemon.sh" "$app/task-daemon.sh"
    cp "$REPO_DIR/schedulers/_core.sh" "$app/schedulers/_core.sh"
    cp "$REPO_DIR/schedulers/_priority.sh" "$app/schedulers/_priority.sh"
    cat > "$app/schedulers/future_policy.sh" <<'EOF'
SCHEDULER_MODULE_API_VERSION=2
SCHEDULER_MODULE_NAME=future_policy
scheduler_consider_task() {
    log "considered $2"
    scheduler_plan_defer fixture
}
EOF
    cat > "$config" <<EOF
STATE_DIR="$state"
LOGS_DIR="$logs"
MAX_CONCURRENT=1
SCHEDULER_MODE=future_policy
MAX_CONCURRENT_8_CARD_TASKS=0
MAX_TIME_HARD_CAP=0
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0,1"
EOF
    cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
EOF
    cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$DYNAMIC_TEST_CONFIG_DIR" || "$3" == "$DYNAMIC_TEST_CONFIG" ]]; then
    printf '0\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$DYNAMIC_TEST_CONFIG_DIR" ]]; then
    printf '755\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$DYNAMIC_TEST_CONFIG" ]]; then
    printf '644\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
    chmod 755 "$app/task-daemon.sh" "$fake_bin/id" "$fake_bin/stat"

    # A stale priority request can fit the total card count but cannot fit
    # either logical pool. Exercise the daemon's actual claim and reject path.
    local impossible=task_20260101_000001_1
    printf '%s %s 0\n' "$(id -un)" "$(( $(date +%s) + 3600 ))" > "$config_dir/taskqueue-priority.conf"
    printf 'DEVICE=auto:2\nDEVICE_ALLOCATION_POOLS=0;1\nCOMMAND=false\n' > "$state/pending/$impossible"
    touch "$state/pending/$impossible.env"
    printf 'DEVICE=none\n' > "$state/pending/task_20260101_000002_2"
    DYNAMIC_TEST_CONFIG_DIR="$config_dir" DYNAMIC_TEST_CONFIG="$config" \
        TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$config" PATH="$fake_bin:$PATH" \
        bash "$app/task-daemon.sh" &
    DYNAMIC_DAEMON_PID=$!
    for _ in $(seq 1 100); do
        grep -Fq 'scheduler loaded: mode=future_policy api=2' "$logs/taskqueue.log" 2>/dev/null && break
        kill -0 "$DYNAMIC_DAEMON_PID" 2>/dev/null || fail "dynamic scheduler daemon exited early"
        sleep 0.05
    done
    grep -Fq 'scheduler loaded: mode=future_policy api=2' "$logs/taskqueue.log"
    for _ in $(seq 1 100); do
        grep -Fq "considered task_20260101_000002_2" "$logs/taskqueue.log" && break
        sleep 0.05
    done
    grep -Fq "considered task_20260101_000002_2" "$logs/taskqueue.log"
    grep -Fxq 'ACCOUNTING_STATE=not_started' "$state/done/$impossible"
    grep -Fxq 'EXIT_CODE=126' "$state/done/$impossible"
    grep -Fq 'exceeds eligible pool capacity (1)' "$logs/$impossible.log"
    [[ ! -e "$state/pending/$impossible.env" && ! -e "$state/running/$impossible" ]]
    kill -TERM "$DYNAMIC_DAEMON_PID"
    wait "$DYNAMIC_DAEMON_PID" || true
    DYNAMIC_DAEMON_PID=""
}

run_dynamic_module_case

echo 'scheduler core contract tests passed'
