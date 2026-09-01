#!/usr/bin/env bash
# HCCS plane affinity: DEVICE_GROUPS on the host plus DEVICE_GROUP_AFFINITY in a
# repository's task-submit.conf must keep every multi-card task inside one group.
# Part 1 drives the scheduler core directly; part 2 drives task-submit.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

# --- part 1: scheduler core -------------------------------------------------

PENDING_DIR="$TEST_ROOT/pending"
mkdir -p "$PENDING_DIR"
LOG_FILE="$TEST_ROOT/scheduler.log"
AVAILABLE_DEVICES="0,1,2,3"
RUNTIME_DEVICES=""
DEVICE_GROUPS="0,1;2,3"
IN_USE_SET=","
CURRENT_JOBS=0
MAX_CONCURRENT=4
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0
SCHEDULER_MODE=group_affinity_test
STARTED_TASKS=""

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

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

detect_device_count() { printf '4\n'; }

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
    local task_id="$1" request="$2" pool="$3" affinity="${4:-0}"
    cat > "$PENDING_DIR/$task_id" <<EOF
DEVICE=$request
DEVICE_POOL=$pool
DEVICE_GROUP_AFFINITY=$affinity
EOF
}

reset_runtime() {
    CURRENT_JOBS=0
    IN_USE_SET=","
    STARTED_TASKS=""
    SCHEDULER_TASK_GROUP_AFFINITY=0
    : > "$LOG_FILE"
    rm -f "$PENDING_DIR"/task_*
}

# A declaration is only usable if it is well formed and assigns each card once.
scheduler_device_groups_valid "0,1;2,3" || fail "rejected a valid declaration"
scheduler_device_groups_valid "" || fail "rejected an empty declaration"
scheduler_device_groups_valid "0,1;1,2" && fail "accepted a card in two groups"
scheduler_device_groups_valid "0,1;a" && fail "accepted a non-numeric card id"
scheduler_device_groups_valid "0,1;;2" && fail "accepted an empty group"

assert_eq g0 "$(scheduler_group_of 1)" "card 1 group"
assert_eq g1 "$(scheduler_group_of 2)" "card 2 group"
# An undeclared card shares a plane with nothing, so it never joins another card.
assert_eq solo9 "$(scheduler_group_of 9)" "undeclared card group"
scheduler_devices_same_group "0,1" || fail "0,1 should be one group"
scheduler_devices_same_group "0,2" && fail "0,2 must not be one group"

# With card 0 busy, the ungrouped scheduler would hand out the cross-plane pair
# 1,2. Under affinity the whole request moves to the group that can hold it.
reset_runtime
IN_USE_SET=",0,"
SCHEDULER_TASK_GROUP_AFFINITY=0
assert_eq "1,2" "$(scheduler_find_free_devices 2 '' '')" "ungrouped allocation"
SCHEDULER_TASK_GROUP_AFFINITY=1
assert_eq "2,3" "$(scheduler_find_free_devices 2 '' '')" "affinity moves to a whole group"

# Two free cards in different groups cannot satisfy a two-card request: the task
# waits instead of being given a pair that would wedge both cards.
reset_runtime
IN_USE_SET=",1,2,"
SCHEDULER_TASK_GROUP_AFFINITY=1
if scheduler_find_free_devices 2 '' '' >/dev/null; then
    fail "affinity allocated across groups when each group had one free card"
fi
SCHEDULER_TASK_GROUP_AFFINITY=0
assert_eq "0,3" "$(scheduler_find_free_devices 2 '' '')" "ungrouped still spans groups"

# Single-card requests are unaffected: there is nothing to keep on one plane.
reset_runtime
IN_USE_SET=",0,1,2,"
SCHEDULER_TASK_GROUP_AFFINITY=1
assert_eq "3" "$(scheduler_find_free_devices 1 '' '')" "single card ignores affinity"

# Capacity under affinity is the largest group, not the pool size. The
# reservation policy uses this to tell "waiting for cards" from "never runnable".
reset_runtime
SCHEDULER_TASK_GROUP_AFFINITY=0
assert_eq 4 "$(scheduler_pool_capacity '')" "ungrouped capacity"
SCHEDULER_TASK_GROUP_AFFINITY=1
assert_eq 2 "$(scheduler_pool_capacity '')" "affinity capacity is the largest group"

# The claim-time check is the last line of defence: a policy that plans a
# cross-group start is refused before any card is locked.
reset_runtime
make_task task_20260101_000001_1 auto:2 "" 1
SCHEDULER_TASK_GROUP_AFFINITY=1
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000001_1" \
    task_20260101_000001_1 auto:2 2 "" "0,2"; then
    fail "core claimed a cross-group allocation"
fi
assert_eq "" "$STARTED_TASKS" "cross-group allocation did not start"

reset_runtime
make_task task_20260101_000002_2 auto:2 "" 1
SCHEDULER_TASK_GROUP_AFFINITY=1
scheduler_start_planned_task "$PENDING_DIR/task_20260101_000002_2" \
    task_20260101_000002_2 auto:2 2 "" "2,3"
assert_eq "task_20260101_000002_2:2,3;" "$STARTED_TASKS" "same-group allocation started"

# An explicit cross-group request is refused at claim time as well.
reset_runtime
make_task task_20260101_000003_3 "0,2" "" 1
SCHEDULER_TASK_GROUP_AFFINITY=1
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000003_3" \
    task_20260101_000003_3 "0,2" 2 "" "0,2"; then
    fail "core claimed an explicit cross-group request"
fi

# A task that never opted in keeps the historical behaviour.
reset_runtime
make_task task_20260101_000004_4 "0,2" "" 0
SCHEDULER_TASK_GROUP_AFFINITY=0
scheduler_start_planned_task "$PENDING_DIR/task_20260101_000004_4" \
    task_20260101_000004_4 "0,2" 2 "" "0,2"
assert_eq "task_20260101_000004_4:0,2;" "$STARTED_TASKS" "opt-out keeps cross-group"

# A task file rewritten to drop its affinity flag after planning is refused,
# the same way a rewritten device request is.
reset_runtime
make_task task_20260101_000005_5 auto:2 "" 0
SCHEDULER_TASK_GROUP_AFFINITY=1
if scheduler_start_planned_task "$PENDING_DIR/task_20260101_000005_5" \
    task_20260101_000005_5 auto:2 2 "" "2,3"; then
    fail "core accepted a task whose affinity flag changed during planning"
fi

# Without a declared topology the flag cannot mean anything, so nothing changes.
reset_runtime
DEVICE_GROUPS=""
SCHEDULER_TASK_GROUP_AFFINITY=1
IN_USE_SET=",0,"
assert_eq "1,2" "$(scheduler_find_free_devices 2 '' '')" "no topology means no constraint"
DEVICE_GROUPS="0,1;2,3"

# --- part 2: task-submit ----------------------------------------------------

SUBMIT_ROOT="$TEST_ROOT/submit"
STATE_DIR="$SUBMIT_ROOT/state"
CONFIG_FILE="$SUBMIT_ROOT/config/taskqueue.conf"
PROJECT_DIR="$SUBMIT_ROOT/project"
mkdir -p "$SUBMIT_ROOT/config" "$SUBMIT_ROOT/logs" "$PROJECT_DIR" \
    "$STATE_DIR"/{pending,running,done,locks,kill,fifo,usage}
install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"

write_host_conf() {
    cat > "$CONFIG_FILE" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$SUBMIT_ROOT/logs"
MAX_CONCURRENT=1
AVAILABLE_DEVICES="0,1,2,3"
DEVICE_GROUPS="${1-}"
EOF
}

write_repo_conf() {
    printf '%s\n' "$@" > "$PROJECT_DIR/task-submit.conf"
}

submit() {
    (
        cd "$PROJECT_DIR"
        TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" "$@"
    )
}

# Every submission that reaches the queue leaves a pending file; read the flag
# the daemon will act on back out of the newest one.
newest_pending_field() {
    local field="$1" newest
    newest=$(ls -t "$STATE_DIR"/pending/task_* 2>/dev/null | grep -v '\.env$' | head -1)
    [[ -n "$newest" ]] || fail "no pending task file was written"
    read_field "$field" "$newest"
}

write_host_conf "0,1;2,3"
write_repo_conf "DEVICE_GROUP_AFFINITY=1"

status=$(submit --devices status 2>&1)
grep -Fq "卡组拓扑   [0,1] (2 张)  [2,3] (2 张)" <<< "$status" ||
    fail "status did not report the host topology: $status"
grep -Fq "多卡上限   2 张" <<< "$status" ||
    fail "status did not report the per-request card ceiling: $status"

# Requesting more cards than any group holds can never be satisfied, so it is
# refused at submission instead of queueing forever.
if out=$(submit --device auto --device-num 3 "echo hi" 2>&1); then
    fail "submit accepted a request larger than the biggest group"
fi
grep -Fq "最大的卡组只有 2 张" <<< "$out" || fail "unhelpful over-size error: $out"

# A request the topology can satisfy is queued and carries the flag onward. The
# group itself is left to the daemon so a busy group does not block a free one.
submit --device auto --device-num 2 "echo hi" >/dev/null
assert_eq auto:2 "$(newest_pending_field DEVICE)" "auto request reaches the queue unpinned"
assert_eq 1 "$(newest_pending_field DEVICE_GROUP_AFFINITY)" "affinity flag propagated"

if out=$(submit --device 0,2 "echo hi" 2>&1); then
    fail "submit accepted an explicit cross-group request"
fi
grep -Fq "跨越了 HCCS plane 卡组" <<< "$out" || fail "unhelpful cross-group error: $out"
grep -Fq "卡 0 属于卡组 [0,1]" <<< "$out" || fail "error did not name the groups: $out"

submit --device 0,1 "echo hi" >/dev/null
assert_eq "0,1" "$(newest_pending_field DEVICE)" "same-group explicit request accepted"

# The escape hatch exists for loads that really do cross planes, such as pure
# HCCL collectives over RoCE. It warns, and it tells the daemon not to enforce.
out=$(submit --ignore-group-affinity --device 0,2 "echo hi" 2>&1)
grep -Fq "已关闭同组约束" <<< "$out" || fail "override did not warn: $out"
assert_eq 0 "$(newest_pending_field DEVICE_GROUP_AFFINITY)" "override clears the flag"

out=$(TASKQUEUE_IGNORE_GROUP_AFFINITY=1 submit --device 0,2 "echo hi" 2>&1)
grep -Fq "已关闭同组约束" <<< "$out" || fail "env override did not warn: $out"

# A fixed sequence is an explicit request, so it is held to the same rule and
# the error points at the key that produced it.
write_repo_conf "DEVICE_GROUP_AFFINITY=1" "DEVICE_SEQ_2=0,2"
if out=$(submit --device-num 2 "echo hi" 2>&1); then
    fail "submit accepted a cross-group DEVICE_SEQ_2"
fi
grep -Fq "固定序列 [0,2] 跨越了 HCCS plane 卡组" <<< "$out" || fail "unhelpful sequence error: $out"
grep -Fq "DEVICE_SEQ_2@" <<< "$out" || fail "sequence error did not name its source: $out"

write_repo_conf "DEVICE_GROUP_AFFINITY=1" "DEVICE_SEQ_2=2,3"
submit --device-num 2 "echo hi" >/dev/null
assert_eq "2,3" "$(newest_pending_field DEVICE)" "same-group sequence accepted"

# A repository that does not opt in is unaffected.
write_repo_conf "DEVICE_WHITELIST=0,1,2,3"
submit --device 0,2 "echo hi" >/dev/null
assert_eq "0,2" "$(newest_pending_field DEVICE)" "opt-out repository keeps cross-group"
assert_eq 0 "$(newest_pending_field DEVICE_GROUP_AFFINITY)" "opt-out clears the flag"

# An unset topology means "unknown", not "every card shares a plane" -- a host
# that really is single-plane says so with one big group. Guessing wrong wedges
# cards irrecoverably, so a repository that opted in fails closed on multi-card.
write_host_conf ""
write_repo_conf "DEVICE_GROUP_AFFINITY=1"
if out=$(submit --device 0,2 "echo hi" 2>&1); then
    fail "submit allowed a multi-card request with no declared topology"
fi
grep -Fq "本机未声明卡组拓扑" <<< "$out" || fail "unhelpful missing-topology error: $out"
grep -Fq "空值表示拓扑未知，不等于所有卡同 plane" <<< "$out" ||
    fail "error did not explain the empty-vs-single-plane distinction: $out"

if out=$(submit --device auto --device-num 2 "echo hi" 2>&1); then
    fail "submit allowed an auto multi-card request with no declared topology"
fi
grep -Fq "本机未声明卡组拓扑" <<< "$out" || fail "auto path missed the topology gate: $out"

# Single-card work is unaffected: there is no plane to keep it on.
submit --device auto "echo hi" >/dev/null
assert_eq auto "$(newest_pending_field DEVICE)" "single card runs without a topology"
submit --device 1 "echo hi" >/dev/null
assert_eq 1 "$(newest_pending_field DEVICE)" "explicit single card runs without a topology"

# The override still releases a host that is known to be safe to cross.
out=$(submit --ignore-group-affinity --device 0,2 "echo hi" 2>&1)
grep -Fq "已关闭同组约束" <<< "$out" || fail "override did not release the topology gate: $out"
assert_eq "0,2" "$(newest_pending_field DEVICE)" "override submitted the cross-plane pair"

# A host that declares a single all-inclusive group is genuinely single-plane,
# so the same multi-card request is allowed.
write_host_conf "0,1,2,3"
submit --device 0,2 "echo hi" >/dev/null
assert_eq "0,2" "$(newest_pending_field DEVICE)" "one all-inclusive group permits any pair"
assert_eq 1 "$(newest_pending_field DEVICE_GROUP_AFFINITY)" "single-group host still enforces"

# Malformed configuration is reported at its source instead of being planned against.
write_host_conf "0,1;0,3"
if out=$(submit --device auto --device-num 2 "echo hi" 2>&1); then
    fail "submit accepted an overlapping DEVICE_GROUPS"
fi
grep -Fq "DEVICE_GROUPS 格式无效" <<< "$out" || fail "unhelpful topology error: $out"

write_host_conf "0,1;2,3"
write_repo_conf "DEVICE_GROUP_AFFINITY=maybe"
if out=$(submit --device 0 "echo hi" 2>&1); then
    fail "submit accepted a non-boolean DEVICE_GROUP_AFFINITY"
fi
grep -Fq "DEVICE_GROUP_AFFINITY 取值无效" <<< "$out" || fail "unhelpful flag error: $out"

# The topology is host truth from the root-owned config; a submitter's
# environment must not be able to present a different partition.
write_repo_conf "DEVICE_GROUP_AFFINITY=1"
if out=$(DEVICE_GROUPS="0,1,2,3" submit --device 0,2 "echo hi" 2>&1); then
    fail "an exported DEVICE_GROUPS overrode the installed topology"
fi
grep -Fq "跨越了 HCCS plane 卡组" <<< "$out" || fail "environment topology leaked in: $out"

echo "device group affinity tests passed"
