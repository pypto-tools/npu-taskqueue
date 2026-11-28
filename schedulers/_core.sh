# Shared scheduler planning and validation core.
#
# This file is sourced by task-daemon before the selected policy module. It is
# deliberately named with a leading underscore so it cannot be selected by the
# SCHEDULER_MODE identifier grammar. Policies decide whether to start, defer, or
# stop; daemon core owns queue traversal, validates every start decision, and
# performs the atomic pending -> running transition.

# shellcheck source=_priority.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_priority.sh"

SCHEDULER_CORE_API_VERSION=1

SCHEDULER_DECISION=""
SCHEDULER_DECISION_DEVICES=""
SCHEDULER_DECISION_REASON=""

scheduler_reset_decision() {
    SCHEDULER_DECISION=""
    SCHEDULER_DECISION_DEVICES=""
    SCHEDULER_DECISION_REASON=""
}

scheduler_set_decision() {
    local decision="$1" devices="${2:-}" reason="${3:-}"
    if [[ -n "$SCHEDULER_DECISION" ]]; then
        log "scheduler error: policy returned more than one decision"
        return 1
    fi
    SCHEDULER_DECISION="$decision"
    SCHEDULER_DECISION_DEVICES="$devices"
    SCHEDULER_DECISION_REASON="$reason"
}

scheduler_plan_start() {
    scheduler_set_decision start "${1:-}" "${2:-}"
}

scheduler_plan_defer() {
    scheduler_set_decision defer "" "${1:-}"
}

scheduler_plan_stop() {
    scheduler_set_decision stop "" "${1:-}"
}

# Print the effective auto pool in global allocation order: runtime/configured
# devices intersected with the task's DEVICE_POOL from task-submit.conf policy.
scheduler_effective_pool() {
    local pool="${1:-}"
    local id candidate joined
    local -a candidates pool_arr
    local -a effective=()
    local -A allowed=() seen=()

    if [[ -n "${RUNTIME_DEVICES:-}" ]]; then
        IFS=',' read -ra candidates <<< "$RUNTIME_DEVICES"
    elif [[ -n "${AVAILABLE_DEVICES:-}" ]]; then
        IFS=',' read -ra candidates <<< "$AVAILABLE_DEVICES"
    else
        local num
        num=$(detect_device_count)
        candidates=($(seq 0 $((num-1))))
    fi

    if [[ -n "$pool" ]]; then
        IFS=',' read -ra pool_arr <<< "$pool"
        for id in "${pool_arr[@]}"; do
            [[ -n "$id" ]] && allowed["$id"]=1
        done
    fi

    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        if [[ -n "$pool" && -z "${allowed[$candidate]:-}" ]]; then
            continue
        fi
        [[ -n "${seen[$candidate]:-}" ]] && continue
        seen["$candidate"]=1
        effective+=("$candidate")
    done
    joined=$(IFS=,; echo "${effective[*]}")
    printf '%s' "$joined"
}

# --- HCCS plane affinity ----------------------------------------------------
#
# DEVICE_GROUPS declares which cards share a communication domain (HCCS plane)
# on this host, for example DEVICE_GROUPS="0,1;2,3". A task whose repository set
# DEVICE_GROUP_AFFINITY must take all of its cards from one group: pypto and
# simpler build their data plane on ACL VMM Fabric handles, which cannot be
# established across planes. The resulting collective does not fail, it hangs,
# and the cards stay wedged until the platform resets them out of band.
#
# Affinity is a host invariant rather than a policy choice, so the core applies
# it inside allocation and revalidates it before claiming a task. Policy modules
# need no changes and cannot bypass it.

SCHEDULER_TASK_GROUP_AFFINITY=0
SCHEDULER_TASK_ALLOCATION_POOLS=""
SCHEDULER_GROUPS_LOADED=0
SCHEDULER_GROUPS_LOADED_SPEC=""
declare -gA SCHEDULER_GROUP_OF=()
SCHEDULER_POOLS_LOADED_SPEC=""
declare -gA SCHEDULER_POOL_OF=()

scheduler_load_allocation_pools() {
    local spec="${SCHEDULER_TASK_ALLOCATION_POOLS:-}" group id index=0
    local -a groups ids
    [[ "$spec" == "$SCHEDULER_POOLS_LOADED_SPEC" ]] && return 0
    SCHEDULER_POOL_OF=()
    SCHEDULER_POOLS_LOADED_SPEC="$spec"
    [[ -n "$spec" ]] || return 0
    IFS=';' read -ra groups <<< "$spec"
    for group in "${groups[@]}"; do
        IFS=',' read -ra ids <<< "$group"
        for id in "${ids[@]}"; do SCHEDULER_POOL_OF["$id"]="$index"; done
        index=$((index + 1))
    done
}

scheduler_allocation_pools_valid() {
    local spec="$1" group
    local -a groups
    [[ "$spec" == *';'* && "$spec" != *';' ]] || return 1
    scheduler_device_groups_valid "$spec" || return 1
    IFS=';' read -ra groups <<< "$spec"
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^(0|[1-9][0-9]*)(,(0|[1-9][0-9]*))*$ ]] || return 1
    done
}

SCHEDULER_ALLOCATION_KEY=""
scheduler_set_allocation_key() {
    local id="$1" affinity="${2:-${SCHEDULER_TASK_GROUP_AFFINITY:-0}}"
    scheduler_set_group_key "$id"
    SCHEDULER_ALLOCATION_KEY="$SCHEDULER_GROUP_KEY"
    if [[ -n "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]]; then
        scheduler_load_allocation_pools
        [[ -n "${SCHEDULER_POOL_OF[$id]:-}" ]] || return 1
        SCHEDULER_ALLOCATION_KEY="p${SCHEDULER_POOL_OF[$id]}"
        if [[ "$affinity" == 1 && -n "${DEVICE_GROUPS:-}" ]]; then
            SCHEDULER_ALLOCATION_KEY="${SCHEDULER_ALLOCATION_KEY}_${SCHEDULER_GROUP_KEY}"
        fi
    fi
}

scheduler_devices_same_allocation_pool() {
    local devices="$1" id first=""
    local -a ids
    [[ -n "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]] || return 0
    scheduler_load_allocation_pools
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ -n "${SCHEDULER_POOL_OF[$id]:-}" ]] || return 1
        if [[ -z "$first" ]]; then
            first="${SCHEDULER_POOL_OF[$id]}"
        elif [[ "${SCHEDULER_POOL_OF[$id]}" != "$first" ]]; then
            return 1
        fi
    done
    return 0
}

scheduler_device_groups_spec() {
    local spec="${DEVICE_GROUPS:-}"
    printf '%s' "${spec//[[:space:]]/}"
}

# Reject a malformed or overlapping declaration instead of silently planning
# against a partition that does not describe the hardware.
scheduler_device_groups_valid() {
    local spec="${1//[[:space:]]/}" group id
    local -a groups ids
    local -A seen=()
    [[ -n "$spec" ]] || return 0
    IFS=';' read -ra groups <<< "$spec"
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
        IFS=',' read -ra ids <<< "$group"
        for id in "${ids[@]}"; do
            [[ -z "${seen[$id]:-}" ]] || return 1
            seen["$id"]=1
        done
    done
    return 0
}

scheduler_load_device_groups() {
    local spec group id index=0
    local -a groups ids
    spec="$(scheduler_device_groups_spec)"
    if (( SCHEDULER_GROUPS_LOADED )) && [[ "$spec" == "$SCHEDULER_GROUPS_LOADED_SPEC" ]]; then
        return 0
    fi
    SCHEDULER_GROUP_OF=()
    SCHEDULER_GROUPS_LOADED=1
    SCHEDULER_GROUPS_LOADED_SPEC="$spec"
    [[ -n "$spec" ]] || return 0
    IFS=';' read -ra groups <<< "$spec"
    for group in "${groups[@]}"; do
        [[ -n "$group" ]] || continue
        IFS=',' read -ra ids <<< "$group"
        for id in "${ids[@]}"; do
            [[ -n "$id" ]] && SCHEDULER_GROUP_OF["$id"]="$index"
        done
        index=$((index + 1))
    done
}

# A card outside every declared group shares a plane with nothing else, so it
# gets a private identity and can only ever satisfy a single-card request.
scheduler_group_of() {
    local id="$1"
    scheduler_load_device_groups
    if [[ -n "${SCHEDULER_GROUP_OF[$id]:-}" ]]; then
        printf 'g%s' "${SCHEDULER_GROUP_OF[$id]}"
    else
        printf 'solo%s' "$id"
    fi
}

# Non-forking companion to scheduler_group_of. Allocation classifies every free
# card of every pending task on every poll, so the command substitution that
# scheduler_group_of needs is not affordable there.
SCHEDULER_GROUP_KEY=""
scheduler_set_group_key() {
    scheduler_load_device_groups
    if [[ -n "${SCHEDULER_GROUP_OF[$1]:-}" ]]; then
        SCHEDULER_GROUP_KEY="g${SCHEDULER_GROUP_OF[$1]}"
    else
        SCHEDULER_GROUP_KEY="solo$1"
    fi
}

scheduler_group_affinity_active() {
    [[ "${SCHEDULER_TASK_GROUP_AFFINITY:-0}" == 1 && -n "$(scheduler_device_groups_spec)" ]]
}

scheduler_devices_same_group() {
    local devices="$1" id group first=""
    local -a ids
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        group="$(scheduler_group_of "$id")"
        if [[ -z "$first" ]]; then
            first="$group"
        elif [[ "$group" != "$first" ]]; then
            return 1
        fi
    done
    return 0
}

# Largest number of cards one group contributes to the list. Under affinity this
# -- not the pool size -- bounds what a multi-card request can ever be given.
scheduler_max_group_size() {
    local list="$1" id group max=0
    local -a ids
    local -A tally=() seen=()
    scheduler_load_device_groups
    IFS=',' read -ra ids <<< "$list"
    for id in "${ids[@]}"; do
        [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
        seen["$id"]=1
        group="$(scheduler_group_of "$id")"
        tally["$group"]=$(( ${tally[$group]:-0} + 1 ))
        (( tally[$group] > max )) && max=${tally[$group]}
    done
    printf '%s' "$max"
}

scheduler_task_group_affinity() {
    local value
    value=$(read_field DEVICE_GROUP_AFFINITY "$1" || true)
    case "$value" in
        1|true|TRUE|yes|YES|on|ON) printf 1 ;;
        *) printf 0 ;;
    esac
}

# Count feasible cards in the supplied list, independently of the live allowlist.
scheduler_capacity_for_devices() {
    local effective="$1" id key max=0
    local -a ids
    local -A counts=() seen=()
    if [[ -n "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]]; then
        IFS=',' read -ra ids <<< "$effective"
        for id in "${ids[@]}"; do
            [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
            seen["$id"]=1
            scheduler_set_allocation_key "$id" || continue
            key="$SCHEDULER_ALLOCATION_KEY"
            counts["$key"]=$(( ${counts[$key]:-0} + 1 ))
            (( counts[$key] > max )) && max=${counts[$key]}
        done
        printf '%s' "$max"
        return
    fi
    if scheduler_group_affinity_active; then
        scheduler_max_group_size "$effective"
        return
    fi
    device_request_count "$effective"
}

scheduler_pool_capacity() {
    scheduler_capacity_for_devices "$(scheduler_effective_pool "${1:-}")"
}

scheduler_devices_intersect() {
    local left="$1" right="$2" id
    local wrapped=",$right,"
    local -a ids
    IFS=',' read -ra ids <<< "$left"
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$wrapped" == *",$id,"* ]] && return 0
    done
    return 1
}

scheduler_devices_subset() {
    local devices="$1" pool="$2" id
    local wrapped=",$pool,"
    local -a ids
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$wrapped" == *",$id,"* ]] || return 1
    done
    return 0
}

# Allocate an auto request from its effective pool while optionally excluding a
# reservation pool. The result is concrete and suitable for scheduler_plan_start.
#
# Cards are taken from the most fragmented group first. A group that is still
# whole is the only thing that can ever satisfy a large affinity request, so
# spending one on a request that a partly used group could have absorbed costs
# the host that capability until the cards come back, while the reverse costs
# nothing. Ranking is stable, so where DEVICE_GROUPS is unset -- every card its
# own solo group, every group equally fragmented -- allocation order is exactly
# the pool order it has always been.
scheduler_find_free_devices() {
    local need="$1" pool="${2:-}" excluded="${3:-}"
    local affinity="${4:-${SCHEDULER_TASK_GROUP_AFFINITY:-0}}"
    local effective id joined group pos group_count prev_count
    local wrapped=",$excluded,"
    local -a candidates group_free selected=()
    local -a group_order=() ranked=()
    local -A free_in_group=() free_count=()
    (( need > 0 )) || return 1
    effective=$(scheduler_effective_pool "$pool")
    IFS=',' read -ra candidates <<< "$effective"

    # Bin the free cards by group, keeping first-seen group order and pool order
    # within a group so equally fragmented groups keep their historical rank.
    for id in "${candidates[@]}"; do
        [[ -n "$id" ]] || continue
        [[ "$wrapped" == *",$id,"* ]] && continue
        any_device_in_use "$id" && continue
        scheduler_set_allocation_key "$id" "$affinity" || continue
        group="$SCHEDULER_ALLOCATION_KEY"
        if [[ -z "${free_in_group[$group]:-}" ]]; then
            group_order+=("$group")
            free_in_group["$group"]="$id"
        else
            free_in_group["$group"]="${free_in_group[$group]},$id"
        fi
        free_count["$group"]=$(( ${free_count[$group]:-0} + 1 ))
    done

    # Insertion sort by ascending free count over a handful of groups. Shifting
    # only on a strict inequality keeps it stable, so ties fall back to pool
    # order and an ungrouped host sees no change at all.
    for group in "${group_order[@]}"; do
        group_count=${free_count[$group]}
        pos=${#ranked[@]}
        while (( pos > 0 )); do
            prev_count=${free_count[${ranked[$((pos - 1))]}]}
            (( prev_count > group_count )) || break
            ranked[$pos]="${ranked[$((pos - 1))]}"
            pos=$((pos - 1))
        done
        ranked[$pos]="$group"
    done

    # Under either logical pool partitioning or hardware affinity, a multi-card
    # request is satisfied from one eligible intersection or not at all. The
    # first ranked group that covers it is the smallest one that can; partial
    # free capacity in separate groups is never combined.
    if (( need > 1 )) && { [[ -n "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]] ||
        { [[ "$affinity" == 1 ]] && [[ -n "$(scheduler_device_groups_spec)" ]]; }; }; then
        for group in "${ranked[@]}"; do
            (( ${free_count[$group]} >= need )) || continue
            IFS=',' read -ra selected <<< "${free_in_group[$group]}"
            joined=$(IFS=,; echo "${selected[*]:0:need}")
            printf '%s' "$joined"
            return 0
        done
        return 1
    fi

    for group in "${ranked[@]}"; do
        IFS=',' read -ra group_free <<< "${free_in_group[$group]}"
        for id in "${group_free[@]}"; do
            selected+=("$id")
            if (( ${#selected[@]} >= need )); then
                joined=$(IFS=,; echo "${selected[*]}")
                printf '%s' "$joined"
                return 0
            fi
        done
    done
    return 1
}

# Re-read and validate a policy start decision immediately before claiming the
# task. This prevents a buggy or future policy from double-allocating a device,
# escaping an auto pool, changing the requested cardinality, or exceeding a
# host admission limit. Explicit requests retain their historical semantics.
scheduler_start_planned_task() {
    local task_file="$1" task_id="$2" pending_request="$3"
    local pending_device_count="$4" device_pool="$5" assigned="$6"
    local current_request current_pool current_affinity current_allocation_pools effective assigned_count
    local -a assigned_ids=()

    if [[ "$task_file" != "$PENDING_DIR/$task_id" || "$(basename "$task_file")" != "$task_id" ||
          ! -f "$task_file" ]]; then
        log "scheduler reject $task_id: pending task identity changed before claim"
        return 1
    fi

    current_request=$(read_field DEVICE "$task_file" || true)
    current_pool=$(read_field DEVICE_POOL "$task_file" || true)
    current_affinity=$(scheduler_task_group_affinity "$task_file")
    current_allocation_pools=$(read_field DEVICE_ALLOCATION_POOLS "$task_file" || true)
    if [[ "$current_request" != "$pending_request" || "$current_pool" != "$device_pool" ||
          "$current_affinity" != "${SCHEDULER_TASK_GROUP_AFFINITY:-0}" ||
          "$current_allocation_pools" != "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]]; then
        log "scheduler reject $task_id: task device metadata changed during planning"
        return 1
    fi

    if (( CURRENT_JOBS >= MAX_CONCURRENT )); then
        log "scheduler reject $task_id: concurrent limit changed during planning"
        return 1
    fi
    if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
       (( pending_device_count == 8 )) &&
       (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
        log "scheduler reject $task_id: eight-card admission limit changed during planning"
        return 1
    fi

    case "$pending_request" in
        ""|none)
            if [[ -n "$assigned" && "$assigned" != none ]]; then
                log "scheduler reject $task_id: no-device task was assigned '$assigned'"
                return 1
            fi
            ;;
        auto|auto:*)
            assigned_count=$(device_request_count "$assigned")
            IFS=',' read -ra assigned_ids <<< "$assigned"
            if (( pending_device_count <= 0 ||
                  assigned_count != pending_device_count ||
                  ${#assigned_ids[@]} != assigned_count )); then
                log "scheduler reject $task_id: auto request '$pending_request' received invalid allocation '$assigned'"
                return 1
            fi
            effective=$(scheduler_effective_pool "$device_pool")
            if ! scheduler_devices_subset "$assigned" "$effective"; then
                log "scheduler reject $task_id: allocation '$assigned' is outside effective pool [$effective]"
                return 1
            fi
            ;;
        *)
            if [[ "$assigned" != "$pending_request" ]]; then
                log "scheduler reject $task_id: explicit request '$pending_request' changed to '$assigned'"
                return 1
            fi
            ;;
    esac

    if [[ -n "$assigned" && "$assigned" != none ]] && any_device_in_use "$assigned"; then
        log "scheduler reject $task_id: planned device $assigned is already in use"
        return 1
    fi

    # Last line of defence for the plane invariant. task-submit already refuses
    # a cross-group request, and allocation above never builds one, but a
    # cross-plane start wedges cards irrecoverably, so it is checked again here
    # against the devices actually about to be locked.
    if [[ -n "$assigned" && "$assigned" != none ]] && scheduler_group_affinity_active &&
       (( $(device_request_count "$assigned") > 1 )) &&
       ! scheduler_devices_same_group "$assigned"; then
        log "scheduler reject $task_id: allocation '$assigned' spans device groups [$(scheduler_device_groups_spec)]"
        return 1
    fi
    if [[ -n "$assigned" && "$assigned" != none &&
          -n "${SCHEDULER_TASK_ALLOCATION_POOLS:-}" ]] &&
       ! scheduler_devices_same_allocation_pool "$assigned"; then
        log "scheduler reject $task_id: allocation '$assigned' spans logical whitelist pools [$SCHEDULER_TASK_ALLOCATION_POOLS]"
        return 1
    fi

    start_pending_task "$task_file" "$task_id" "$assigned" "$pending_device_count"
}

# --- Priority ordering ------------------------------------------------------
#
# Head-of-queue grants are evaluated on every tick, so they need no timer and
# expire on their own. A task joins the head bucket when its owner holds an
# unexpired grant or when it has waited PRIORITY_AGING_SECONDS. Both buckets
# keep FIFO order.
#
# Aging is what bounds an ordinary user's wait. Submission order is queue order,
# so an aged task re-enters the head bucket at its true FIFO position: a grant
# can reorder only tasks younger than the threshold, and every ordinary task
# reaches the head bucket after waiting at most the threshold (plus the backlog
# older than it). ctime is the submission clock because a file owner can
# backdate mtime with touch, while ctime only moves forward.
#
# PRIORITY_AGING_SECONDS=0 disables the mechanism and restores plain FIFO.

SCHEDULER_ORDERED_TASKS=()
SCHEDULER_PRIORITY_COUNT=0

scheduler_order_pending_tasks() {
    local file owner ctime rest record now threshold
    local -a files=() head=() normal=()
    local -A classified=()

    SCHEDULER_PRIORITY_COUNT=0
    SCHEDULER_ORDERED_TASKS=()
    for file in "$PENDING_DIR"/task_*; do
        [[ "$file" != *.env && -f "$file" ]] && files+=("$file")
    done
    (( ${#files[@]} )) || return 0

    threshold="${PRIORITY_AGING_SECONDS:-0}"
    if [[ ! "$threshold" =~ ^[0-9]+$ ]] || (( threshold == 0 )); then
        SCHEDULER_ORDERED_TASKS=("${files[@]}")
        return 0
    fi

    priority_load_grants || return 1
    printf -v now '%(%s)T' -1

    # Publication renames the pending file and sets its ctime. Sort the full
    # timestamp numerically (including nanoseconds), then the pathname for ties.
    # Batch stat inputs to stay below ARG_MAX even on a backed-up queue.
    while IFS= read -r -d '' record; do
        owner=${record%% *}
        rest=${record#* }
        ctime=${rest%% *}
        file=${rest#* }
        [[ -n "$owner" && "$ctime" =~ ^[0-9]+\.[0-9]{9}$ && -n "$file" ]] || continue
        if [[ -n "${PRIORITY_GRANT_UNTIL[$owner]:-}" ]] ||
           (( now - ${ctime%.*} >= threshold )); then
            head+=("$file")
            classified["$file"]=priority
        else
            classified["$file"]=normal
        fi
    done < <(printf '%s\0' "${files[@]}" |
        LC_ALL=C xargs -0 -r stat --printf='%U %.9Z %n\0' -- 2>/dev/null |
        LC_ALL=C sort -z -k2,2n -k3)

    # A cancellation can legitimately leave a stat record missing. Any live
    # task without metadata could be the priority head: retry the whole tick.
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        case "${classified[$file]:-}" in
            priority) ;;
            normal) normal+=("$file") ;;
            *) log "defer dispatch: priority metadata unavailable for $file"; return 1 ;;
        esac
    done
    SCHEDULER_PRIORITY_COUNT=${#head[@]}
    SCHEDULER_ORDERED_TASKS=("${head[@]}" "${normal[@]}")
}

# Return a reason only for requests which cannot fit even with all cards free.
# Explicit requests keep their own IDs, independent of the auto-device pool.
scheduler_request_error() {
    local request="$1" count="$2" pool="$3" capacity
    if [[ -n "$SCHEDULER_TASK_ALLOCATION_POOLS" ]] &&
       ! scheduler_allocation_pools_valid "$SCHEDULER_TASK_ALLOCATION_POOLS"; then
        echo "malformed logical whitelist pools"
        return
    fi
    [[ -n "$request" && "$request" != none ]] || return 0
    if (( count <= 0 )); then
        echo "invalid device request '$request'"
    elif [[ "$request" == auto || "$request" == auto:* ]]; then
        # Only fixed task constraints can prove this request impossible. A
        # runtime allowlist may expand again while an admitted task waits.
        if [[ -z "$pool" ]]; then
            if [[ -n "$SCHEDULER_TASK_ALLOCATION_POOLS" ]]; then
                pool=${SCHEDULER_TASK_ALLOCATION_POOLS//;/,}
            elif scheduler_group_affinity_active; then
                pool=${DEVICE_GROUPS//;/,}
            else
                return 0
            fi
        fi
        capacity=$(scheduler_capacity_for_devices "$pool")
        if (( count > capacity )); then
            echo "device request '$request' exceeds eligible pool capacity ($capacity)"
        fi
    elif ! scheduler_devices_same_allocation_pool "$request"; then
        echo "requested devices '$request' span logical whitelist pools"
    elif scheduler_group_affinity_active && ! scheduler_devices_same_group "$request"; then
        echo "requested devices '$request' span device groups"
    fi
}

# Claim before publishing the terminal result, just as a start claims before
# launching. If a client cancelled first, its result already owns the task.
scheduler_reject_pending_task() (
    local task_file="$1" task_id="$2" reason="$3"
    mv "$task_file" "$RUNNING_DIR/$task_id" 2>/dev/null || return 0
    rm -f "$PENDING_DIR/${task_id}.env"
    parse_task_file "$RUNNING_DIR/$task_id"
    log "reject $task_id: $reason"
    write_reject "$task_id" "error: $reason"
)

# Traverse the pending queue once. Policy modules see a stable per-task snapshot
# and return exactly one decision; all mutation remains in daemon core.
scheduler_schedule_tick() {
    local task_file task_id pending_request pending_device_count device_pool
    local policy_failed=0 waiting_priority="" request_error index

    if declare -F scheduler_begin_tick >/dev/null && ! scheduler_begin_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to begin tick"
        return 1
    fi

    scheduler_order_pending_tasks || policy_failed=1
    for index in "${!SCHEDULER_ORDERED_TASKS[@]}"; do
        task_file=${SCHEDULER_ORDERED_TASKS[$index]}
        # Every exit path below (policy defer, host limit, failed claim) obeys
        # the same barrier. Start, rejection and cancellation all remove the
        # pending file and immediately allow the next task through.
        if [[ -n "$waiting_priority" && -f "$waiting_priority" ]]; then
            break
        fi
        waiting_priority=""
        [[ -f "$task_file" ]] || continue
        [[ "$task_file" == *.env ]] && continue

        if (( CURRENT_JOBS >= MAX_CONCURRENT )); then
            log "concurrent limit ($MAX_CONCURRENT), deferring"
            break
        fi

        task_id=$(basename "$task_file")
        pending_request=$(read_field DEVICE "$task_file" || true)
        pending_device_count=$(device_request_count "$pending_request")
        device_pool=$(read_field DEVICE_POOL "$task_file" || true)
        # Part of the per-task snapshot the policy sees; the core consumes it in
        # allocation and validation so policies cannot opt out of the invariant.
        SCHEDULER_TASK_GROUP_AFFINITY=$(scheduler_task_group_affinity "$task_file")
        SCHEDULER_TASK_ALLOCATION_POOLS=$(read_field DEVICE_ALLOCATION_POOLS "$task_file" || true)
        if (( index < SCHEDULER_PRIORITY_COUNT )); then
            waiting_priority="$task_file"
            request_error=$(scheduler_request_error "$pending_request" "$pending_device_count" "$device_pool")
            if [[ -n "$request_error" ]]; then
                scheduler_reject_pending_task "$task_file" "$task_id" "$request_error"
                continue
            fi
        elif [[ -n "$SCHEDULER_TASK_ALLOCATION_POOLS" ]] &&
           ! scheduler_allocation_pools_valid "$SCHEDULER_TASK_ALLOCATION_POOLS"; then
            log "scheduler reject $task_id: malformed logical whitelist pools"
            continue
        fi

        # This is a host admission invariant, not a policy choice. Keeping it in
        # core prevents future schedulers from accidentally bypassing the cap.
        if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
           (( pending_device_count == 8 )) &&
           (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
            continue
        fi

        scheduler_reset_decision
        if ! scheduler_consider_task "$task_file" "$task_id" "$pending_request" \
            "$pending_device_count" "$device_pool"; then
            log "scheduler error: $SCHEDULER_MODE failed while considering $task_id"
            policy_failed=1
            break
        fi

        case "$SCHEDULER_DECISION" in
            start)
                scheduler_start_planned_task "$task_file" "$task_id" "$pending_request" \
                    "$pending_device_count" "$device_pool" "$SCHEDULER_DECISION_DEVICES" || continue
                if declare -F scheduler_task_started >/dev/null; then
                    scheduler_task_started "$task_id" "$SCHEDULER_DECISION_DEVICES" ||
                        log "scheduler warning: $SCHEDULER_MODE start notification failed for $task_id"
                fi
                ;;
            defer)
                continue
                ;;
            stop)
                break
                ;;
            *)
                log "scheduler error: $SCHEDULER_MODE returned invalid decision '${SCHEDULER_DECISION:-<empty>}' for $task_id"
                policy_failed=1
                break
                ;;
        esac
    done

    SCHEDULER_TASK_GROUP_AFFINITY=0
    SCHEDULER_TASK_ALLOCATION_POOLS=""

    if declare -F scheduler_end_tick >/dev/null && ! scheduler_end_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to end tick"
        return 1
    fi
    (( policy_failed == 0 ))
}
