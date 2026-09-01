# Shared scheduler planning and validation core.
#
# This file is sourced by task-daemon before the selected policy module. It is
# deliberately named with a leading underscore so it cannot be selected by the
# SCHEDULER_MODE identifier grammar. Policies decide whether to start, defer, or
# stop; daemon core owns queue traversal, validates every start decision, and
# performs the atomic pending -> running transition.

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
SCHEDULER_GROUPS_LOADED=0
SCHEDULER_GROUPS_LOADED_SPEC=""
declare -A SCHEDULER_GROUP_OF=()

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
    local -A tally=()
    scheduler_load_device_groups
    IFS=',' read -ra ids <<< "$list"
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
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

scheduler_pool_capacity() {
    local effective
    effective=$(scheduler_effective_pool "${1:-}")
    if scheduler_group_affinity_active; then
        scheduler_max_group_size "$effective"
        return
    fi
    device_request_count "$effective"
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
scheduler_find_free_devices() {
    local need="$1" pool="${2:-}" excluded="${3:-}"
    local affinity="${4:-${SCHEDULER_TASK_GROUP_AFFINITY:-0}}"
    local effective id joined group
    local wrapped=",$excluded,"
    local -a candidates selected=()
    (( need > 0 )) || return 1
    effective=$(scheduler_effective_pool "$pool")
    IFS=',' read -ra candidates <<< "$effective"

    # Under affinity a multi-card request is satisfied from one group or not at
    # all: bin the free cards by group in pool order and take the first group
    # that can cover the request. Another group being partly free never leaks a
    # cross-plane allocation; the task simply waits.
    if [[ "$affinity" == 1 ]] && (( need > 1 )) && [[ -n "$(scheduler_device_groups_spec)" ]]; then
        local -a group_order=()
        local -A free_in_group=()
        scheduler_load_device_groups
        for id in "${candidates[@]}"; do
            [[ -n "$id" ]] || continue
            [[ "$wrapped" == *",$id,"* ]] && continue
            any_device_in_use "$id" && continue
            group="$(scheduler_group_of "$id")"
            if [[ -z "${free_in_group[$group]:-}" ]]; then
                group_order+=("$group")
                free_in_group["$group"]="$id"
            else
                free_in_group["$group"]="${free_in_group[$group]},$id"
            fi
        done
        for group in "${group_order[@]}"; do
            IFS=',' read -ra selected <<< "${free_in_group[$group]}"
            if (( ${#selected[@]} >= need )); then
                joined=$(IFS=,; echo "${selected[*]:0:need}")
                printf '%s' "$joined"
                return 0
            fi
        done
        return 1
    fi

    for id in "${candidates[@]}"; do
        [[ -n "$id" ]] || continue
        [[ "$wrapped" == *",$id,"* ]] && continue
        any_device_in_use "$id" || selected+=("$id")
        if (( ${#selected[@]} >= need )); then
            joined=$(IFS=,; echo "${selected[*]}")
            printf '%s' "$joined"
            return 0
        fi
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
    local current_request current_pool current_affinity effective assigned_count
    local -a assigned_ids=()

    if [[ "$task_file" != "$PENDING_DIR/$task_id" || "$(basename "$task_file")" != "$task_id" ||
          ! -f "$task_file" ]]; then
        log "scheduler reject $task_id: pending task identity changed before claim"
        return 1
    fi

    current_request=$(read_field DEVICE "$task_file" || true)
    current_pool=$(read_field DEVICE_POOL "$task_file" || true)
    current_affinity=$(scheduler_task_group_affinity "$task_file")
    if [[ "$current_request" != "$pending_request" || "$current_pool" != "$device_pool" ||
          "$current_affinity" != "${SCHEDULER_TASK_GROUP_AFFINITY:-0}" ]]; then
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

    start_pending_task "$task_file" "$task_id" "$assigned" "$pending_device_count"
}

# Traverse the pending queue once. Policy modules see a stable per-task snapshot
# and return exactly one decision; all mutation remains in daemon core.
scheduler_schedule_tick() {
    local task_file task_id pending_request pending_device_count device_pool
    local policy_failed=0

    if declare -F scheduler_begin_tick >/dev/null && ! scheduler_begin_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to begin tick"
        return 1
    fi

    for task_file in "$PENDING_DIR"/task_*; do
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

    if declare -F scheduler_end_tick >/dev/null && ! scheduler_end_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to end tick"
        return 1
    fi
    (( policy_failed == 0 ))
}
