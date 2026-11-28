#!/usr/bin/env bash
# Priority ordering contract: granted users and aged ordinary tasks share the
# priority queue. Incomplete metadata pauses dispatch until the next tick.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PENDING_DIR="$TEST_ROOT/pending"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$PENDING_DIR" "$FAKE_BIN"
LOG_FILE="$TEST_ROOT/scheduler.log"
PRIORITY_FILE="$TEST_ROOT/priority.conf"
PRIORITY_STAT_FIXTURE="$TEST_ROOT/stat.fixture"
PRIORITY_STAT_CALLS="$TEST_ROOT/stat.calls"
export PRIORITY_STAT_FIXTURE PRIORITY_STAT_CALLS

AVAILABLE_DEVICES="0,1,2,3,4"
RUNTIME_DEVICES=""
IN_USE_SET=","
CURRENT_JOBS=0
MAX_CONCURRENT=4
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0
SCHEDULER_MODE=contract_test

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
    local -a ids
    case "$1" in
        ""|none) printf '0' ;;
        auto) printf '1' ;;
        auto:*) printf '%s' "${1#auto:}" ;;
        *) IFS=, read -ra ids <<< "$1"; printf '%s' "${#ids[@]}" ;;
    esac
}

# The ordering code reads owner and ctime through the external `stat` command,
# so the fixture can script any ownership/age combination without root or sleep.
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '--printf=%U %.9Z %n\0' ]]; then
    printf 'called\n' >> "${PRIORITY_STAT_CALLS:?}"
    [[ "${PRIORITY_STAT_FAIL:-0}" == 1 ]] && exit 1
    [[ -r "${PRIORITY_STAT_FIXTURE:-}" ]] || exit 1
    [[ -z "${PRIORITY_CANCEL_DURING_STAT:-}" ]] || rm -f "$PRIORITY_CANCEL_DURING_STAT"
    cat "$PRIORITY_STAT_FIXTURE"
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod 755 "$FAKE_BIN/stat"
PATH="$FAKE_BIN:$PATH"

# shellcheck source=../schedulers/_core.sh
load_scheduler() { source "$REPO_DIR/schedulers/_core.sh"; }
load_scheduler

NOW="$(printf '%(%s)T' -1)"
FUTURE=$((NOW + 86400))
PAST=$((NOW - 86400))

make_task() {
    printf 'DEVICE=none\n' > "$PENDING_DIR/$1"
}

# add_entry <task_id> <owner> <age_seconds> [nine-digit fraction]
add_entry() {
    printf '%s %s.%s %s\0' "$2" "$((NOW - $3))" "${4:-000000000}" "$PENDING_DIR/$1" \
        >> "$PRIORITY_STAT_FIXTURE"
}

reset_case() {
    rm -f "$PENDING_DIR"/task_*
    : > "$PRIORITY_STAT_FIXTURE"
    rm -f "$PRIORITY_STAT_CALLS"
    : > "$PRIORITY_FILE"
    PRIORITY_AGING_SECONDS=1800
    SCHEDULER_ORDERED_TASKS=()
    unset PRIORITY_STAT_FAIL PRIORITY_CANCEL_DURING_STAT
}

ordered_basenames() {
    local file out=""
    scheduler_order_pending_tasks
    for file in "${SCHEDULER_ORDERED_TASKS[@]}"; do
        out+="${out:+ }$(basename "$file")"
    done
    printf '%s' "$out"
}

grant() {
    printf '%s %s %s\n' "$1" "$2" "$NOW" > "$PRIORITY_FILE"
}

OLD=task_20260101_000001_101
NEW=task_20260101_000002_102

# Baseline: below the aging threshold and without a grant, glob order stands.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
assert_eq "$OLD $NEW" "$(ordered_basenames)" "plain FIFO baseline"

# An unexpired grant moves its owner's task into the head bucket.
grant bob "$FUTURE"
assert_eq "$NEW $OLD" "$(ordered_basenames)" "granted owner takes the head"

# An expired grant grants nothing; the ledger needs no cleanup for that.
grant bob "$PAST"
assert_eq "$OLD $NEW" "$(ordered_basenames)" "expired grant is ignored"

# Aging: an ordinary task past the threshold joins the head bucket and keeps
# FIFO order inside it, so a grant can only reorder younger tasks.
reset_case
T1=task_20260101_000001_201
T2=task_20260101_000002_202
T3=task_20260101_000003_203
make_task "$T1"
make_task "$T2"
make_task "$T3"
add_entry "$T1" carol 60
add_entry "$T2" dave 5000
add_entry "$T3" bob 5
grant bob "$FUTURE"
assert_eq "$T2 $T3 $T1" "$(ordered_basenames)" "aged task joins the head bucket"

# Aging disabled: the mechanism is off entirely, including grant evaluation,
# so no file metadata is read at all.
reset_case
make_task "$T1"
make_task "$T2"
make_task "$T3"
add_entry "$T1" carol 60
add_entry "$T2" dave 5000
add_entry "$T3" bob 5
grant bob "$FUTURE"
PRIORITY_AGING_SECONDS=0
assert_eq "$T1 $T2 $T3" "$(ordered_basenames)" "aging 0 restores plain FIFO"
[[ ! -e "$PRIORITY_STAT_CALLS" ]] || fail "aging 0 still read file metadata"

# A non-numeric threshold (core default when the daemon did not vet it) is
# also treated as disabled rather than as "age everything".
PRIORITY_AGING_SECONDS=abc
assert_eq "$T1 $T2 $T3" "$(ordered_basenames)" "invalid threshold disables ordering"

# Malformed and unknown-user lines grant nothing; the valid line still counts.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
cat > "$PRIORITY_FILE" <<EOF
# user expiry_epoch granted_epoch
garbage
alice notanumber $NOW
!bad user $FUTURE $NOW
bob $PAST $PAST
bob $FUTURE $NOW
EOF
assert_eq "$NEW $OLD" "$(ordered_basenames)" "malformed ledger lines are ignored"

# A missing ledger is not an error.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
PRIORITY_FILE="$TEST_ROOT/absent.conf"
assert_eq "$OLD $NEW" "$(ordered_basenames)" "missing ledger keeps FIFO"
PRIORITY_FILE="$TEST_ROOT/priority.conf"

# Environment sidecars are not tasks and must not occupy a queue slot.
reset_case
make_task "$OLD"
printf 'K=V\n' > "$PENDING_DIR/$OLD.env"
add_entry "$OLD" alice 100
assert_eq "$OLD" "$(ordered_basenames)" "env sidecar is excluded"

# Dispatch using the shipped backfill policy with an in-memory occupancy set
# and a successful claim modelled by removing the pending file.
source "$REPO_DIR/schedulers/backfill.sh"
any_device_in_use() { scheduler_devices_intersect "$1" "$BUSY_DEVICES"; }
resolve_device_request() {
    scheduler_find_free_devices "$(device_request_count "$3")" "$4"
}
start_pending_task() {
    rm "$1"
    STARTED+="${STARTED:+ }$2"
    BUSY_DEVICES+=",${3}"
}

# The older, larger priority task has the lexically later ID. One nanosecond
# must decide their order even at modern (ten-digit) epoch times.
reset_case
EARLIER=task_20260101_000001_999
LATER=task_20260101_000001_111
printf 'DEVICE=auto:4\nDEVICE_POOL=0,1,2,3\n' > "$PENDING_DIR/$EARLIER"
make_task "$LATER"
add_entry "$LATER" bob 10 900000002
add_entry "$EARLIER" bob 10 900000001
grant bob "$FUTURE"
BUSY_DEVICES=2
STARTED=""
scheduler_schedule_tick
assert_eq "" "$STARTED" "younger task in same second cannot pass blocked head"
BUSY_DEVICES=""
scheduler_schedule_tick
assert_eq "$EARLIER $LATER" "$STARTED" "subsecond FIFO"

reset_case
make_task "$EARLIER"
make_task "$LATER"
add_entry "$EARLIER" bob 10 900000001
add_entry "$LATER" alice 10 900000001
grant bob "$FUTURE"
printf 'alice %s %s\n' "$FUTURE" "$NOW" >> "$PRIORITY_FILE"
assert_eq "$LATER $EARLIER" "$(ordered_basenames)" "equal timestamps use task ID"

# Check both total and partial stat failure through dispatch. The known task
# is runnable, but the unread task may outrank it.
reset_case
make_task "$T1"
make_task "$T2"
add_entry "$T2" bob 5
grant bob "$FUTURE"
STARTED=""
export PRIORITY_STAT_FAIL=1
if scheduler_schedule_tick; then fail "total metadata failure went undetected"; fi
assert_eq "" "$STARTED" "no dispatch after total stat failure"
unset PRIORITY_STAT_FAIL
if scheduler_schedule_tick; then fail "partial metadata failure went undetected"; fi
assert_eq "" "$STARTED" "no dispatch after partial stat failure"
add_entry "$T1" alice 5000
scheduler_schedule_tick
assert_eq "$T1 $T2" "$STARTED" "retry starts the previously unread aged head first"

reset_case
make_task "$T1"
make_task "$T2"
add_entry "$T2" bob 5
export PRIORITY_CANCEL_DURING_STAT="$PENDING_DIR/$T1"
STARTED=""
scheduler_schedule_tick
assert_eq "$T2" "$STARTED" "missing metadata for a cancelled file does not stall dispatch"

# A submitted request with or without a task-local pool survives a temporary
# runtime restriction and still precedes ordinary work when cards return.
for task_pool in '' '0,1,2,3'; do
    reset_case
    printf 'DEVICE=auto:4\nDEVICE_POOL=%s\n' "$task_pool" > "$PENDING_DIR/$T1"
    make_task "$T2"
    add_entry "$T1" bob 10
    add_entry "$T2" alice 5
    grant bob "$FUTURE"
    RUNTIME_DEVICES="0,1"
    BUSY_DEVICES=""
    STARTED=""
    scheduler_schedule_tick
    [[ -f "$PENDING_DIR/$T1" ]] || fail "runtime pool shrink removed the priority head"
    assert_eq "" "$STARTED" "temporarily narrowed pool blocks later starts"
    RUNTIME_DEVICES=""
    scheduler_schedule_tick
    assert_eq "$T1 $T2" "$STARTED" "restoring capacity unblocks the original request"
done

reset_case
make_task "$T1"
printf 'DEVICE=auto:4\nDEVICE_POOL=0,1,2,3\n' > "$PENDING_DIR/$T2"
printf 'DEVICE=4\n' > "$PENDING_DIR/$T3"
add_entry "$T1" alice 5
add_entry "$T2" bob 10
add_entry "$T3" bob 5
grant bob "$FUTURE"
BUSY_DEVICES=1
STARTED=""
scheduler_schedule_tick
assert_eq "" "$STARTED" "waiting priority head blocks a younger priority job and ordinary CPU work"
BUSY_DEVICES=""
scheduler_schedule_tick
assert_eq "$T2 $T3 $T1" "$STARTED" "freeing last card drains priority and resumes backfill in the same tick"

reset_case
printf 'DEVICE=0,1,2,3,4,5,6,7\n' > "$PENDING_DIR/$T1"
make_task "$T2"
add_entry "$T1" alice 5000
add_entry "$T2" bob 10
grant bob "$FUTURE"
MAX_CONCURRENT_8_CARD_TASKS=1
RUNNING_8_CARD_TASKS=1
STARTED=""
scheduler_schedule_tick
assert_eq "" "$STARTED" "aged ordinary head waiting on eight-card cap blocks granted user"
rm "$PENDING_DIR/$T1"
scheduler_schedule_tick
assert_eq "$T2" "$STARTED" "cancelling the capped head unblocks dispatch"
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0

reset_case
printf 'DEVICE=0,1\n' > "$PENDING_DIR/$T1"
make_task "$T2"
add_entry "$T1" bob 10
add_entry "$T2" alice 5
grant bob "$FUTURE"
BUSY_DEVICES=1
STARTED=""
scheduler_schedule_tick
assert_eq "" "$STARTED" "active grant blocks ordinary backfill"
grant bob "$PAST"
scheduler_schedule_tick
assert_eq "$T2" "$STARTED" "expired grant restores ordinary backfill"

# Ledger query helpers: only unexpired grants are visible.
reset_case
grant alice "$FUTURE"
printf 'bob %s %s\n' "$PAST" "$PAST" >> "$PRIORITY_FILE"
assert_eq "$FUTURE" "$(priority_expiry_of alice)" "active grant expiry"
if priority_expiry_of bob >/dev/null; then
    fail "expired grant was reported as active"
fi
if priority_expiry_of nobody >/dev/null; then
    fail "ungranted user was reported as active"
fi

echo 'priority queue tests passed'
