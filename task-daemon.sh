#!/bin/bash
# task-daemon: root task queue daemon

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -n "${TASKQUEUE_CONF:-}" ]]; then
    CONF_FILE="$TASKQUEUE_CONF"
elif [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then
    CONF_FILE="$SCRIPT_DIR/../config/taskqueue.conf"
else
    CONF_FILE="$SCRIPT_DIR/runtime/config/taskqueue.conf"
fi
if [ ! -f "$CONF_FILE" ]; then
    echo "error: $CONF_FILE not found; run setup.sh or set TASKQUEUE_CONF" >&2
    exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: task-daemon must run as root (including TASK_EXECUTION_MODE=HwHiAiUser)" >&2
    exit 1
fi
CONFIG_DIR="$(dirname "$CONF_FILE")"
if [[ -L "$CONFIG_DIR" || -L "$CONF_FILE" ||
      "$(stat -c %u "$CONFIG_DIR")" -ne 0 || "$(stat -c %u "$CONF_FILE")" -ne 0 ||
      $((8#$(stat -c %a "$CONFIG_DIR") & 8#022)) -ne 0 ||
      $((8#$(stat -c %a "$CONF_FILE") & 8#022)) -ne 0 ]]; then
    echo "error: $CONF_FILE and its parent must be root-owned, non-symlink, and not group/world-writable" >&2
    exit 1
fi
source "$CONF_FILE"
STATE_DIR="${STATE_DIR:-${BASE_DIR:-}}"
if [[ -z "$STATE_DIR" ]]; then
    if [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then STATE_DIR="$SCRIPT_DIR/../state"; else STATE_DIR="$SCRIPT_DIR/runtime/state"; fi
fi
LOGS_DIR="${LOGS_DIR:-${STATE_DIR%/state}/logs}"
PENDING_DIR="$STATE_DIR/pending"
RUNNING_DIR="$STATE_DIR/running"
DONE_DIR="$STATE_DIR/done"
KILL_DIR="$STATE_DIR/kill"
FIFO_DIR="$STATE_DIR/fifo"
LOG_FILE="$LOGS_DIR/taskqueue.log"
POLL_INTERVAL=0.2
KILL_GRACE=${KILL_GRACE:-5}   # --kill 后等待 SIGTERM 优雅退出的宽限期(秒)，超时升级到 SIGKILL
MAX_CONCURRENT=${MAX_CONCURRENT:-1}
SCHEDULER_MODE=${SCHEDULER_MODE:-backfill}
# Optional per-host admission limit for jobs that request exactly eight cards.
# Zero keeps historical scheduling behavior, so code updates do not enable the
# policy on hosts whose preserved local configuration does not opt in.
MAX_CONCURRENT_8_CARD_TASKS=${MAX_CONCURRENT_8_CARD_TASKS:-0}
if [[ ! "$MAX_CONCURRENT_8_CARD_TASKS" =~ ^[0-9]+$ ]]; then
    echo "error: MAX_CONCURRENT_8_CARD_TASKS must be a non-negative integer" >&2
    exit 1
fi
# 用户可请求更短超时，但不能绕过服务器硬上限。0 表示服务器不设硬上限。
MAX_TIME_HARD_CAP=${MAX_TIME_HARD_CAP:-0}
TASK_EXECUTION_MODE="${TASK_EXECUTION_MODE:-HwHiAiUser}"
case "$TASK_EXECUTION_MODE" in
    HwHiAiUser|root) ;;
    *) echo "error: TASK_EXECUTION_MODE must be HwHiAiUser or root" >&2; exit 1 ;;
esac
if [[ "$TASK_EXECUTION_MODE" == HwHiAiUser ]]; then
    command -v setpriv >/dev/null 2>&1 || {
        echo "error: TASK_EXECUTION_MODE=HwHiAiUser requires setpriv" >&2
        exit 1
    }
    getent group HwHiAiUser >/dev/null 2>&1 || {
        echo "error: required group HwHiAiUser does not exist" >&2
        exit 1
    }
fi
MAINT_FILE="$STATE_DIR/maintenance"
CURRENT_JOBS=0

parse_task_file() {
    local file="$1"
    SUBMIT_USER=""
    SUBMIT_TIME=""
    WORK_DIR=""
    COMMAND=""
    DEVICE=""
    DEVICE_AUTO=0
    DEVICE_POOL=""
    DEVICE_REQUEST_RAW=""
    DEVICE_REQUEST_ORIGIN=""
    DEVICE_SEQUENCE_SOURCE=""
    DEVICE_POLICY_CONF=""
    DEVICE_POLICY_WHITELIST=""
    DEVICE_POLICY_BLACKLIST=""
    DEVICE_POLICY_IGNORE_WHITELIST=""
    DEVICE_POLICY_ENV_POOL=""
    DEVICE_GLOBAL_POOL=""
    DEVICE_GLOBAL_POOL_SOURCE=""
    DEVICE_GROUP_AFFINITY=0
    MAX_TIME=300
    INTERACTIVE=0
    while IFS='=' read -r key value; do
        case "$key" in
            SUBMIT_USER) SUBMIT_USER="$value" ;;
            SUBMIT_TIME) SUBMIT_TIME="$value" ;;
            WORK_DIR)    WORK_DIR="$value" ;;
            COMMAND)     COMMAND="$value" ;;
            DEVICE)      DEVICE="$value" ;;
            DEVICE_AUTO) DEVICE_AUTO="$value" ;;
            DEVICE_POOL) DEVICE_POOL="$value" ;;
            DEVICE_REQUEST_RAW) DEVICE_REQUEST_RAW="$value" ;;
            DEVICE_REQUEST_ORIGIN) DEVICE_REQUEST_ORIGIN="$value" ;;
            DEVICE_SEQUENCE_SOURCE) DEVICE_SEQUENCE_SOURCE="$value" ;;
            DEVICE_POLICY_CONF) DEVICE_POLICY_CONF="$value" ;;
            DEVICE_POLICY_WHITELIST) DEVICE_POLICY_WHITELIST="$value" ;;
            DEVICE_POLICY_BLACKLIST) DEVICE_POLICY_BLACKLIST="$value" ;;
            DEVICE_POLICY_IGNORE_WHITELIST) DEVICE_POLICY_IGNORE_WHITELIST="$value" ;;
            DEVICE_POLICY_ENV_POOL) DEVICE_POLICY_ENV_POOL="$value" ;;
            DEVICE_GLOBAL_POOL) DEVICE_GLOBAL_POOL="$value" ;;
            DEVICE_GLOBAL_POOL_SOURCE) DEVICE_GLOBAL_POOL_SOURCE="$value" ;;
            DEVICE_GROUP_AFFINITY) DEVICE_GROUP_AFFINITY="$value" ;;
            MAX_TIME)    MAX_TIME="$value" ;;
            INTERACTIVE) INTERACTIVE="$value" ;;
        esac
    done < "$file" 2>/dev/null
}

# 纯 bash 提取单个 KEY=VALUE 字段，避免 grep+cut 的 fork 开销。
# 用法: val=$(read_field DEVICE /path/to/task_file)
read_field() {
    local key="$1" file="$2" k v
    # 轮询期间另一个调度路径可能刚把 pending 文件移到 running。
    # 消失是正常竞态，静默返回未命中即可。
    [ -f "$file" ] || return 1
    while IFS='=' read -r k v; do
        if [ "$k" = "$key" ]; then
            printf '%s' "$v"
            return 0
        fi
    done < "$file" 2>/dev/null
    return 1
}

# write reject result
write_reject() {
    local task_id="$1"
    local reason="$2"
    cat > "$DONE_DIR/$task_id" <<EOF
SUBMIT_USER=$SUBMIT_USER
SUBMIT_TIME=$SUBMIT_TIME
COMMAND=$COMMAND
DEVICE=$DEVICE
DEVICE_REQUEST_RAW=$DEVICE_REQUEST_RAW
DEVICE_REQUEST_ORIGIN=$DEVICE_REQUEST_ORIGIN
DEVICE_SEQUENCE_SOURCE=$DEVICE_SEQUENCE_SOURCE
DEVICE_POLICY_CONF=$DEVICE_POLICY_CONF
DEVICE_POLICY_WHITELIST=$DEVICE_POLICY_WHITELIST
DEVICE_POLICY_BLACKLIST=$DEVICE_POLICY_BLACKLIST
DEVICE_POLICY_IGNORE_WHITELIST=$DEVICE_POLICY_IGNORE_WHITELIST
DEVICE_POLICY_ENV_POOL=$DEVICE_POLICY_ENV_POOL
DEVICE_GLOBAL_POOL=$DEVICE_GLOBAL_POOL
DEVICE_GLOBAL_POOL_SOURCE=$DEVICE_GLOBAL_POOL_SOURCE
FINISH_TIME=$(date -Iseconds)
EXIT_CODE=126
EOF
    echo "$reason" > "$LOGS_DIR/${task_id}.log"
    chmod 644 "$LOGS_DIR/${task_id}.log"
    # .env 必须与状态文件一起删：此路径在 run_task 读取环境快照之前早退，
    # 状态文件一消失就没人再认领这个 .env（finalize_interrupted 会直接 return）。
    rm -f "$RUNNING_DIR/$task_id" "$RUNNING_DIR/${task_id}.env"
    chmod 644 "$DONE_DIR/$task_id"
}

# IN_USE_SET 是逗号包裹的"运行中设备号"快照（如 ",4,7,9,"），由 update_in_use_set
# 在主循环开头刷新；调度循环里每分配一张卡就追加一次，使本轮后续的 any_device_in_use
# 立刻能看到新占用，避免同一轮把同一张卡分给两个任务。
IN_USE_SET=","
RUNNING_8_CARD_TASKS=0

# Return the number of distinct devices represented by a task DEVICE field.
# Pending auto:N requests have not been resolved yet; running tasks contain the
# concrete comma-separated allocation. Invalid values return zero and are left
# to the existing daemon-side task validation/execution path.
device_request_count() {
    local request="$1" id
    local -a ids
    local -A seen=()
    case "$request" in
        ""|none) printf '0' ;;
        auto) printf '1' ;;
        auto:*)
            if [[ "$request" =~ ^auto:([1-9][0-9]*)$ ]]; then
                printf '%s' "${BASH_REMATCH[1]}"
            else
                printf '0'
            fi
            ;;
        *)
            if [[ ! "$request" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                printf '0'
                return
            fi
            IFS=',' read -ra ids <<< "$request"
            for id in "${ids[@]}"; do
                seen["$id"]=1
            done
            printf '%s' "${#seen[@]}"
            ;;
    esac
}

update_in_use_set() {
    IN_USE_SET=","
    RUNNING_8_CARD_TASKS=0
    local rf dev d device_count
    local -a _devs
    for rf in "$RUNNING_DIR"/task_*; do
        [ -f "$rf" ] || continue
        case "$rf" in *.env) continue;; esac
        dev=$(read_field DEVICE "$rf") || continue
        [[ -z "$dev" || "$dev" == "none" ]] && continue
        # 未被 sed -i 改写的 auto 标记跳过（窗口极短）
        [[ "$dev" == "auto" || "$dev" == auto:* ]] && continue
        device_count=$(device_request_count "$dev")
        if [[ "$device_count" -eq 8 ]]; then
            RUNNING_8_CARD_TASKS=$((RUNNING_8_CARD_TASKS + 1))
        fi
        # 支持多卡任务："5,7" 拆开各自落入集合
        IFS=',' read -ra _devs <<< "$dev"
        for d in "${_devs[@]}"; do
            [[ -n "$d" ]] && IN_USE_SET="$IN_USE_SET$d,"
        done
    done
}

# 检查设备列表（逗号分隔）是否与任何 running 任务有交集
# 参数: devices (如 "0" 或 "0,3,5")
# 返回: 0=有冲突, 1=无冲突
# 依赖 IN_USE_SET 已被调用方刷新（主循环每 tick 刷一次 + 分配后增量追加）
any_device_in_use() {
    local pending_devs="$1" p
    local -a _p_arr
    [[ -z "$pending_devs" || "$pending_devs" == "none" ]] && return 1
    IFS=',' read -ra _p_arr <<< "$pending_devs"
    for p in "${_p_arr[@]}"; do
        [[ -n "$p" ]] && [[ "$IN_USE_SET" == *",$p,"* ]] && return 0
    done
    return 1
}

# 自动发现 NPU 设备数量（基于 /dev/davinci*，不依赖 npu-smi）
detect_device_count() {
    local count
    count=$(ls -1 /dev/davinci[0-9]* 2>/dev/null | wc -l)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ $count -lt 1 ]] && count=2
    echo "$count"
}

# 解析设备请求:
# - auto / auto:N -> 分配具体设备并写回任务文件
# - none / 空 / 具体设备号 -> 原样返回
resolve_device_request() {
    local task_file="$1"
    local task_id="$2"
    local device_request="$3"
    local device_pool="$4"   # 任务卡组：收窄 auto 分配范围（与全局白名单取交集）

    if [[ "$device_request" != "auto" && "$device_request" != auto:* ]]; then
        echo "$device_request"
        return 0
    fi

    local request_count=1
    if [[ "$device_request" =~ ^auto:([1-9][0-9]*)$ ]]; then
        request_count="${BASH_REMATCH[1]}"
    elif [[ "$device_request" != "auto" ]]; then
        log "reject $task_id: invalid auto device request '$device_request'"
        return 1
    fi

    local assigned
    assigned=$(find_free_devices "$request_count" "$device_pool") || {
        log "defer $task_id: no free device for auto:$request_count${device_pool:+ in pool [$device_pool]}"
        return 1
    }

    if [[ -n "$task_file" && -f "$task_file" ]]; then
        sed -i "s/^DEVICE=.*/DEVICE=$assigned/" "$task_file"
    fi
    log "assign $task_id: $device_request -> $assigned"
    echo "$assigned"
    return 0
}

# 找 N 个空闲设备（使用内存中的 RUNTIME_DEVICES，由 load_runtime_devices 维护）
# 第二参数 pool：任务卡组，与全局候选取交集，使 auto 只在卡组内分配（白名单为硬上限）
find_free_devices() {
    local need="${1:-1}"
    local pool="${2:-}"
    scheduler_find_free_devices "$need" "$pool" ""
}

# 加载运行时设备白名单到内存（启动时和收到 SIGHUP 时调用）
load_runtime_devices() {
    local runtime_file="$STATE_DIR/available_devices"
    if [[ -f "$runtime_file" ]]; then
        RUNTIME_DEVICES=$(tr -d '[:space:]' < "$runtime_file" 2>/dev/null)
        log "loaded runtime devices: ${RUNTIME_DEVICES:-<empty>}"
    else
        RUNTIME_DEVICES=""
        log "no runtime device whitelist (using AVAILABLE_DEVICES or auto-detect)"
    fi
}

# SIGHUP 热加载不会改变 BASE_DIR；目录迁移仍需要停服。
reload_runtime_config() {
    local old_state="$STATE_DIR"
    local new_max new_cap new_grace

    # 配置由 root 管理。只在信号路径读取三个支持热更新的整数键。
    read_hot_key() {
        local wanted="$1" line value=""
        while IFS= read -r line; do
            case "$line" in
                "$wanted"=*) value="${line#*=}" ;;
            esac
        done < "$CONF_FILE"
        value="${value%%[[:space:]]#*}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        printf '%s' "$value"
    }
    new_max=$(read_hot_key MAX_CONCURRENT)
    new_cap=$(read_hot_key MAX_TIME_HARD_CAP)
    new_grace=$(read_hot_key KILL_GRACE)

    [[ "$new_max" =~ ^[1-9][0-9]*$ ]] && MAX_CONCURRENT="$new_max"
    [[ "$new_cap" =~ ^[0-9]+$ ]] && MAX_TIME_HARD_CAP="$new_cap"
    [[ "$new_grace" =~ ^[0-9]+$ ]] && KILL_GRACE="$new_grace"
    STATE_DIR="$old_state"
    load_runtime_devices
    log "config reloaded: max_concurrent=$MAX_CONCURRENT hard_cap=$MAX_TIME_HARD_CAP kill_grace=$KILL_GRACE"
}

# 列出某 session 内仍存活的所有进程。任务经 setsid 启动，SID==TASK_PID，
# 即便后代被 reparent 到 init（PPID=1）其 session id 不变，故能可靠捞全。
# 纯 bash 读 /proc/<pid>/stat，避免每个 pid 都 fork cat / 子 shell —— 在 5000+
# 进程的机器上，原实现一次扫描要 10+ 秒，会把主循环吞掉数分钟。
# comm 字段可能含空格/括号，故先剥到最后一个 ") " 为止，
# 剩下从 state 开始：state(1) ppid(2) pgrp(3) session(4) ...
session_pids() {
    local sid="$1" p line
    for p in /proc/[0-9]*; do
        { read -r line < "$p/stat"; } 2>/dev/null || continue
        line="${line##*) }"
        set -- $line
        [ "$4" = "$sid" ] && printf '%s ' "${p#/proc/}"
        set --
    done
}

# 向整个 session 发送一次信号（非阻塞）。返回 0 表示当时确有存活进程。
signal_session() {
    local sig="$1" sid="$2" pids
    pids=$(session_pids "$sid")
    [ -z "$pids" ] && return 1
    kill "-$sig" $pids 2>/dev/null
    return 0
}

# 列出 environ 里带本任务 marker 的所有进程。
#
# session_pids 的不变量（"后代即便 reparent 到 init，session id 不变"）只在后代
# 不主动改换门庭时成立。一个进程只要自己调 setsid()，SID 就变成它自己，从此
# 逃出 session_pids 的视野 —— 进程组同理。pytest 用 start_new_session=True 起
# 的推理引擎正是这样跑掉的：任务被 kill 后它活得好好的，攒到 4 个孤儿时吃掉了
# ~800 GiB 共享内存和 8 张卡，队列因无卡可分而饿死。
#
# environ 则不然：它在 fork/exec 时被继承，setsid 不会改写它。marker 是后代
# 无论怎么改换门庭都甩不掉的标记，也就是唯一可靠的归属证据。
#
# 一次 grep 扫完所有 /proc/*/environ。别改成逐个 pid fork 一次 grep —— 在 5000+
# 进程的机器上那要十几秒（session_pids 上面已经栽过一次同样的跟头）。
marked_pids() {
    local task_id="$1" f p out=""
    # task_id 由 task-submit 生成，形如 task_<日期>_<pid><rand>。挡一手：空值或含
    # 正则元字符的值会把下面的 grep 变成"匹配所有进程"，那是一场屠杀。
    [[ "$task_id" =~ ^task_[0-9_]+$ ]] || return 0
    for f in $(grep -lsz -- "^TASKQUEUE_TASK_ID=${task_id}\$" /proc/[0-9]*/environ 2>/dev/null); do
        p="${f#/proc/}"
        p="${p%/environ}"
        [ "$p" = "$$" ] && continue   # daemon 自己不带 marker，纯属防御
        out="$out $p"
    done
    printf '%s' "${out# }"
}

# 一个任务"仍然活着的进程"的权威定义：session 内的 ∪ 带 marker 的。
# 两个视角缺一不可：marker 捞得到 setsid 逃逸的后代，session 捞得到 marker 之前
# 提交、环境里还没有 TASKQUEUE_TASK_ID 的老任务（daemon 升级时正在跑的那些）。
task_pids() {
    local task_id="$1" tpid="$2" p
    local -A seen=()
    for p in $(session_pids "$tpid") $(marked_pids "$task_id"); do
        seen["$p"]=1
    done
    printf '%s ' "${!seen[@]}"
}

# 清扫一个任务残留的全部进程：SIGTERM → 宽限 KILL_GRACE 秒 → SIGKILL。
sweep_task() {
    local task_id="$1" tpid="$2" tag="${3:-sweep}" leftover i
    leftover=$(task_pids "$task_id" "$tpid")
    [ -z "${leftover// /}" ] && return 0
    log "$tag: $task_id leftover: $leftover (SIGTERM)"
    kill -TERM $leftover 2>/dev/null
    for i in $(seq 1 "$KILL_GRACE"); do
        sleep 1
        leftover=$(task_pids "$task_id" "$tpid")
        [ -z "${leftover// /}" ] && return 0
    done
    log "$tag: $task_id survivors ignored SIGTERM, SIGKILL: $leftover"
    kill -KILL $leftover 2>/dev/null
}

# 将一个未正常收尾的 running 任务标记为中断：写 done 记录、清理临时文件、
# 移除 running 文件。移除 running 文件是关键——它解除了 any_device_in_use 的设备占用。
finalize_interrupted() {
    local task_id="$1"
    local exit_code="${2:-137}"
    local rf="$RUNNING_DIR/$task_id"
    [ -f "$rf" ] || return 0
    local submit_user submit_time command device start_time request_raw request_origin
    local sequence_source policy_conf policy_whitelist policy_blacklist policy_ignore_whitelist policy_env_pool
    local global_pool global_pool_source
    submit_user=$(read_field SUBMIT_USER "$rf" || true)
    submit_time=$(read_field SUBMIT_TIME "$rf" || true)
    command=$(read_field COMMAND "$rf" || true)
    device=$(read_field DEVICE "$rf" || true)
    start_time=$(read_field START_TIME "$rf" || true)
    request_raw=$(read_field DEVICE_REQUEST_RAW "$rf" || true)
    request_origin=$(read_field DEVICE_REQUEST_ORIGIN "$rf" || true)
    sequence_source=$(read_field DEVICE_SEQUENCE_SOURCE "$rf" || true)
    policy_conf=$(read_field DEVICE_POLICY_CONF "$rf" || true)
    policy_whitelist=$(read_field DEVICE_POLICY_WHITELIST "$rf" || true)
    policy_blacklist=$(read_field DEVICE_POLICY_BLACKLIST "$rf" || true)
    policy_ignore_whitelist=$(read_field DEVICE_POLICY_IGNORE_WHITELIST "$rf" || true)
    policy_env_pool=$(read_field DEVICE_POLICY_ENV_POOL "$rf" || true)
    global_pool=$(read_field DEVICE_GLOBAL_POOL "$rf" || true)
    global_pool_source=$(read_field DEVICE_GLOBAL_POOL_SOURCE "$rf" || true)
    cat > "$DONE_DIR/$task_id" <<EOF
SUBMIT_USER=$submit_user
SUBMIT_TIME=$submit_time
COMMAND=$command
DEVICE=$device
DEVICE_REQUEST_RAW=$request_raw
DEVICE_REQUEST_ORIGIN=$request_origin
DEVICE_SEQUENCE_SOURCE=$sequence_source
DEVICE_POLICY_CONF=$policy_conf
DEVICE_POLICY_WHITELIST=$policy_whitelist
DEVICE_POLICY_BLACKLIST=$policy_blacklist
DEVICE_POLICY_IGNORE_WHITELIST=$policy_ignore_whitelist
DEVICE_POLICY_ENV_POOL=$policy_env_pool
DEVICE_GLOBAL_POOL=$global_pool
DEVICE_GLOBAL_POOL_SOURCE=$global_pool_source
START_TIME=$start_time
FINISH_TIME=$(date -Iseconds)
EXIT_CODE=$exit_code
EOF
    chmod 644 "$DONE_DIR/$task_id"
    [ -f "$LOGS_DIR/${task_id}.log" ] && echo "[taskqueue] 任务被中断（daemon 停止或重启）" >> "$LOGS_DIR/${task_id}.log"
    rm -f "$rf" "$RUNNING_DIR/${task_id}.env" "$FIFO_DIR/${task_id}" "$LOGS_DIR/${task_id}.sh"
}

# 启动时回收上一个 daemon 遗留的 running 任务。单例检查已保证旧 daemon 已死，
# 故所有遗留任务的监管进程（run_task）都已消失：
#   - TASK_PID 已退出 → 收尾，释放被永久占用的设备
#   - TASK_PID 仍存活（旧 daemon 被 kill -9、未触发 cleanup）→ 任务仍合法占用设备，保留原状
reconcile_running() {
    for rf in "$RUNNING_DIR"/task_*; do
        [ -f "$rf" ] || continue
        [[ "$rf" == *.env ]] && continue
        local task_id tpid
        task_id=$(basename "$rf")
        tpid=$(read_field TASK_PID "$rf")
        if [ -n "$tpid" ] && kill -0 "$tpid" 2>/dev/null; then
            log "reconcile: $task_id still alive (pid=$tpid), leaving as-is"
        else
            log "reconcile: $task_id orphaned (pid=${tpid:-none} dead), sweeping + finalizing"
            sweep_task "$task_id" "${tpid:-0}" reconcile
            finalize_interrupted "$task_id" 137
        fi
    done
}

# run one task
run_task() {
    local task_id="$1"

    parse_task_file "$RUNNING_DIR/$task_id"

    # 兜底: 避免 auto / auto:N 直接传给 npu-lock
    if [[ "$DEVICE" == "auto" || "$DEVICE" == auto:* ]]; then
        local resolved_device
        # This fallback runs outside a scheduler tick, so the task's own plane
        # affinity has to be re-established instead of inheriting whatever the
        # previous tick left in the shared snapshot variable.
        SCHEDULER_TASK_GROUP_AFFINITY=$(scheduler_task_group_affinity "$RUNNING_DIR/$task_id")
        resolved_device=$(resolve_device_request "$RUNNING_DIR/$task_id" "$task_id" "$DEVICE" "$DEVICE_POOL")
        local resolve_status=$?
        SCHEDULER_TASK_GROUP_AFFINITY=0
        if (( resolve_status != 0 )); then
            write_reject "$task_id" "error: failed to resolve device request '$DEVICE'"
            return 0
        fi
        DEVICE="$resolved_device"
    fi

    log "exec: [$SUBMIT_USER] $COMMAND"

    # 从 .env 快照加载用户完整环境
    local -a env_args=()
    local env_file="$RUNNING_DIR/${task_id}.env"
    if [ -f "$env_file" ]; then
        while IFS= read -r -d '' line; do
            env_args+=("$line")
        done < "$env_file"
        rm -f "$env_file"
    fi

    # 强制覆盖（优先级最高）
    env_args+=(TASKQUEUE_INSIDE=1)
    # 归属 marker：任务的每个后代都继承它，包括 setsid 出去、SID/PGID 都不再指向
    # 本任务的那些。清扫时靠它认人（见 marked_pids）。
    env_args+=(TASKQUEUE_TASK_ID="$task_id")
    env_args+=(TASKQUEUE_LOCK_STATE_DIR="$STATE_DIR")

    # 设备环境变量注入
    # 设备互斥靠 npu-lock 保证，设备选择靠自动追加 --device 参数
    if [[ -n "$DEVICE" && "$DEVICE" != "none" ]]; then
        env_args+=(TASK_DEVICE="$DEVICE")
    fi

    # {} 占位符替换（支持双引号命令，替换后跳过自动注入）
    local placeholder_used=false
    if [[ -n "$DEVICE" && "$DEVICE" != "none" && "$COMMAND" == *'{}'* ]]; then
        COMMAND="${COMMAND//\{\}/$DEVICE}"
        placeholder_used=true
        log "placeholder: {} -> $DEVICE"
    fi

    # 自动注入 --device 参数（仅 --device auto 时，手动指定卡号不注入）
    # 跳过条件：
    #   1. 非 auto 分配（用户手动指定了卡号）
    #   2. 使用了 {} 占位符（已替换完成）
    #   3. 使用了 $TASK_DEVICE 占位符（用户自己处理设备号）
    #   4. 命令已含 --device/--devices（用户已显式指定）
    #   5. 命令已含 -d <数字>（用户已显式指定设备号）
    #   6. 命令含管道/链式符号（追加到末尾会作用于错误的子命令）
    if [[ -n "$DEVICE" && "$DEVICE" != "none" && "${DEVICE_AUTO:-0}" == "1" ]]; then
        if [[ "$placeholder_used" == "true" ]]; then
            log "placeholder {} used, skip auto-inject"
        elif [[ "$COMMAND" == *'$TASK_DEVICE'* || "$COMMAND" == *'${TASK_DEVICE}'* ]]; then
            log "user uses \$TASK_DEVICE, skip auto-inject"
        elif [[ "$COMMAND" =~ (^|[[:space:]])(--devices?)(([[:space:]]+|=)|$) ]]; then
            log "user-specified: ${BASH_REMATCH[2]}, skip auto-inject"
        elif [[ "$COMMAND" =~ (^|[[:space:]])-d[[:space:]]+[0-9] ]]; then
            log "user-specified: -d <number>, skip auto-inject"
        elif [[ "$COMMAND" == *"|"* || "$COMMAND" == *"&&"* || "$COMMAND" == *"||"* || "$COMMAND" == *";"* ]]; then
            log "compound command detected, skip auto-inject (use \$TASK_DEVICE)"
        else
            COMMAND="$COMMAND --device $DEVICE"
            log "auto-inject: --device $DEVICE"
        fi
    fi

    # 构建执行脚本（避免多层 bash -c 引号嵌套）
    local task_script="$LOGS_DIR/${task_id}.sh"
    {
        echo '#!/bin/bash'
        # cd to working directory
        if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
            echo "cd '$WORK_DIR'"
        fi
        # 写入原始命令（无需转义，直接写入脚本文件）
        echo "$COMMAND"
    } > "$task_script"
    chmod 644 "$task_script"

    # daemon 统一包装 npu-lock（兼容旧任务：命令已含 npu-lock 则跳过）
    local exec_cmd="bash '$task_script'"
    if [[ -n "$DEVICE" && "$DEVICE" != "none" && "$COMMAND" != *npu-lock* ]]; then
        exec_cmd="'$SCRIPT_DIR/npu_lock.sh' $DEVICE --timeout 0 -- bash '$task_script'"
    fi

    local task_log="$LOGS_DIR/${task_id}.log"
    touch "$task_log"
    chmod 644 "$task_log"

    # 交互式 stdin: 创建 FIFO 供客户端写入
    local fifo_path="$FIFO_DIR/$task_id"
    local stdin_src="/dev/null"
    local fifo_keeper_pid=""
    if [[ "$INTERACTIVE" == "1" ]]; then
        mkfifo "$fifo_path" 2>/dev/null
        chmod 666 "$fifo_path" 2>/dev/null
        # keeper: 持有写端防止任务进程在无客户端时收到 EOF
        # 客户端连接后 keeper 和客户端共同持有写端；客户端断开后 keeper 仍保持
        sleep infinity > "$fifo_path" &
        fifo_keeper_pid=$!
        stdin_src="$fifo_path"
        log "interactive: fifo=$fifo_path keeper=$fifo_keeper_pid"
    fi

    local start_iso; start_iso=$(date -Iseconds)
    case "$TASK_EXECUTION_MODE" in
        HwHiAiUser)
            # 保留提交用户 UID，HwHiAiUser 只提供 NPU 访问权限。
            if [ -n "$SUBMIT_USER" ] && [ "$SUBMIT_USER" != root ] && [ "$(id -u)" -eq 0 ]; then
                local primary_gid user_groups hw_gid group_csv
                primary_gid=$(id -g "$SUBMIT_USER" 2>/dev/null) || {
                    write_reject "$task_id" "error: submit user '$SUBMIT_USER' does not exist"
                    return 0
                }
                user_groups=$(id -G "$SUBMIT_USER")
                hw_gid=$(getent group HwHiAiUser | cut -d: -f3)
                case " $user_groups " in
                    *" $hw_gid "*) ;;
                    *) user_groups="$user_groups $hw_gid" ;;
                esac
                group_csv="${user_groups// /,}"
                setsid setpriv --reuid "$SUBMIT_USER" --regid "$primary_gid" \
                    --groups "$group_csv" -- env "${env_args[@]}" /bin/bash -c "$exec_cmd" \
                    < "$stdin_src" > "$task_log" 2>&1 &
            else
                setsid env "${env_args[@]}" /bin/bash -c "$exec_cmd" < "$stdin_src" > "$task_log" 2>&1 &
            fi
            ;;
        root)
            log "exec: $task_id configured for root execution (submitted by $SUBMIT_USER)"
            setsid env "${env_args[@]}" /bin/bash -c "$exec_cmd" < "$stdin_src" > "$task_log" 2>&1 &
            ;;
    esac
    local task_pid=$!
    echo "TASK_PID=$task_pid" >> "$RUNNING_DIR/$task_id"
    echo "START_TIME=$start_iso" >> "$RUNNING_DIR/$task_id"

    # pending/ 是 1777，任务字段必须在 daemon 侧再次校验。
    local effective_max_time="$MAX_TIME"
    [[ "$effective_max_time" =~ ^[0-9]+$ ]] || effective_max_time=300
    if [[ "$MAX_TIME_HARD_CAP" =~ ^[0-9]+$ ]] &&
       (( MAX_TIME_HARD_CAP > 0 )) &&
       (( effective_max_time == 0 || effective_max_time > MAX_TIME_HARD_CAP )); then
        effective_max_time="$MAX_TIME_HARD_CAP"
    fi

    log "exec: pid=$task_pid (max_time=${effective_max_time}s)"

    # 超时看门狗：超过 MAX_TIME 自动 kill（0=不限时）
    local watchdog_pid=""
    if (( effective_max_time > 0 )); then
        (
            sleep "$effective_max_time"
            if kill -0 "$task_pid" 2>/dev/null; then
                echo "[taskqueue] 任务超时 (${effective_max_time}s)，已自动终止" >> "$task_log"
                kill -TERM -- -"$task_pid" 2>/dev/null
                sleep 3
                kill -0 "$task_pid" 2>/dev/null && kill -KILL -- -"$task_pid" 2>/dev/null
            fi
        ) &
        watchdog_pid=$!
    fi

    wait $task_pid
    local exit_code=$?

    # 取消看门狗
    [ -n "$watchdog_pid" ] && kill "$watchdog_pid" 2>/dev/null && wait "$watchdog_pid" 2>/dev/null

    # leader 退出后清扫：python/tee 等后代可能脱离 leader（reparent 到 init）仍在占用
    # NPU。不清扫就会把卡泄漏给已"完成"的任务，调度器误判空闲后引发双占卡。
    #
    # 这里是所有终止路径的必经之地 —— 正常结束、超时看门狗、--kill，最后都会走到
    # 上面的 wait 返回。session ∪ marker 的并集扫，能捞到自己 setsid 出去的后代。
    sweep_task "$task_id" "$task_pid" sweep

    # 清理 FIFO 和 keeper
    if [[ -n "$fifo_keeper_pid" ]]; then
        kill "$fifo_keeper_pid" 2>/dev/null
        wait "$fifo_keeper_pid" 2>/dev/null
    fi
    rm -f "$fifo_path"
    rm -f "$task_script"

    log "done: $task_id (exit=$exit_code)"

    cat > "$DONE_DIR/$task_id" <<EOF
SUBMIT_USER=$SUBMIT_USER
SUBMIT_TIME=$SUBMIT_TIME
COMMAND=$COMMAND
DEVICE=$DEVICE
DEVICE_REQUEST_RAW=$DEVICE_REQUEST_RAW
DEVICE_REQUEST_ORIGIN=$DEVICE_REQUEST_ORIGIN
DEVICE_SEQUENCE_SOURCE=$DEVICE_SEQUENCE_SOURCE
DEVICE_POLICY_CONF=$DEVICE_POLICY_CONF
DEVICE_POLICY_WHITELIST=$DEVICE_POLICY_WHITELIST
DEVICE_POLICY_BLACKLIST=$DEVICE_POLICY_BLACKLIST
DEVICE_POLICY_IGNORE_WHITELIST=$DEVICE_POLICY_IGNORE_WHITELIST
DEVICE_POLICY_ENV_POOL=$DEVICE_POLICY_ENV_POOL
DEVICE_GLOBAL_POOL=$DEVICE_GLOBAL_POOL
DEVICE_GLOBAL_POOL_SOURCE=$DEVICE_GLOBAL_POOL_SOURCE
START_TIME=$start_iso
FINISH_TIME=$(date -Iseconds)
EXIT_CODE=$exit_code
LOG_FILE=$task_log
EOF
    rm -f "$RUNNING_DIR/$task_id"
    chmod 644 "$DONE_DIR/$task_id"
    CURRENT_JOBS=$((CURRENT_JOBS - 1))
}

log() {
    # 简易日志轮转：超过 1MB 保留最近 500 行
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 1048576 )); then
        tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

# Claim and launch a task selected by the active scheduler. Policy modules do
# not move queue files or start processes directly; this keeps the atomic state
# transition and the in-tick resource accounting in daemon core.
start_pending_task() {
    local task_file="$1"
    local task_id="$2"
    local pending_dev="$3"
    local pending_device_count="$4"

    log "processing: $task_id"

    if ! mv "$task_file" "$RUNNING_DIR/$task_id" 2>/dev/null; then
        log "skip $task_id (already taken)"
        return 1
    fi
    # Older clients may create task metadata with mode 600. Normalize it so
    # every queue user can continue to inspect running tasks.
    chmod 644 "$RUNNING_DIR/$task_id" 2>/dev/null || log "warning: cannot normalize permissions for $task_id"
    [ -f "$PENDING_DIR/${task_id}.env" ] && mv "$PENDING_DIR/${task_id}.env" "$RUNNING_DIR/${task_id}.env" 2>/dev/null

    # Resolve DEVICE only after the sticky-directory claim succeeds.
    if [[ -n "$pending_dev" && "$pending_dev" != "none" ]]; then
        sed -i "s/^DEVICE=.*/DEVICE=$pending_dev/" "$RUNNING_DIR/$task_id"
        IN_USE_SET="$IN_USE_SET$pending_dev,"
    fi

    run_task "$task_id" &
    JOB_PIDS+=($!)
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    if [[ "$pending_device_count" -eq 8 ]]; then
        RUNNING_8_CARD_TASKS=$((RUNNING_8_CARD_TASKS + 1))
    fi
}

load_scheduler() {
    local scheduler_dir="$SCRIPT_DIR/schedulers"
    local scheduler_core="$scheduler_dir/_core.sh"
    local scheduler_module path

    # A mode is an identifier, never a path. The leading-underscore core file
    # therefore cannot be selected, while adding a policy no longer requires a
    # daemon case statement change.
    if [[ ! "$SCHEDULER_MODE" =~ ^[a-z][a-z0-9_]*$ ]]; then
        echo "error: unsupported SCHEDULER_MODE '$SCHEDULER_MODE'" >&2
        return 1
    fi
    scheduler_module="$scheduler_dir/$SCHEDULER_MODE.sh"

    if [[ -L "$scheduler_dir" || ! -d "$scheduler_dir" ]]; then
        echo "error: scheduler module directory is missing or unsafe: $scheduler_dir" >&2
        return 1
    fi
    for path in "$scheduler_core" "$scheduler_module"; do
        if [[ -L "$path" || ! -f "$path" ]]; then
            echo "error: unsupported SCHEDULER_MODE '$SCHEDULER_MODE'" >&2
            return 1
        fi
    done

    # Installed modules are executed by a root daemon and must be protected
    # like the installed app. Source-checkout tests use a separate runtime
    # layout and are intentionally not subject to installed-tree ownership.
    if [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" && -z "${TASKQUEUE_ALLOW_USER:-}" ]]; then
        if [[ "$(stat -c %u "$scheduler_dir")" -ne 0 ||
              $((8#$(stat -c %a "$scheduler_dir") & 8#022)) -ne 0 ]]; then
            echo "error: scheduler module and its parent must be root-owned and not group/world-writable" >&2
            return 1
        fi
        for path in "$scheduler_core" "$scheduler_module"; do
            if [[ "$(stat -c %u "$path")" -ne 0 ||
                  $((8#$(stat -c %a "$path") & 8#022)) -ne 0 ]]; then
                echo "error: scheduler module and its parent must be root-owned and not group/world-writable" >&2
                return 1
            fi
        done
    fi

    unset SCHEDULER_CORE_API_VERSION
    # shellcheck source=schedulers/_core.sh
    source "$scheduler_core"
    if [[ "${SCHEDULER_CORE_API_VERSION:-}" != 1 ]] ||
       ! declare -F scheduler_schedule_tick >/dev/null ||
       ! declare -F scheduler_plan_start >/dev/null; then
        echo "error: scheduler core does not implement API version 1" >&2
        return 1
    fi

    unset -f scheduler_validate_config scheduler_begin_tick scheduler_consider_task scheduler_end_tick \
        scheduler_task_started 2>/dev/null || true
    unset SCHEDULER_MODULE_API_VERSION SCHEDULER_MODULE_NAME
    # shellcheck source=/dev/null
    source "$scheduler_module"
    if [[ "${SCHEDULER_MODULE_API_VERSION:-}" != 2 ]] ||
       [[ "${SCHEDULER_MODULE_NAME:-}" != "$SCHEDULER_MODE" ]] ||
       ! declare -F scheduler_consider_task >/dev/null; then
        echo "error: scheduler '$SCHEDULER_MODE' does not implement API version 2" >&2
        return 1
    fi
    if declare -F scheduler_validate_config >/dev/null && ! scheduler_validate_config; then
        return 1
    fi
}

load_scheduler || exit 1

# HCCS plane topology for this host, e.g. DEVICE_GROUPS="0,1;2,3". Empty keeps
# the historical ungrouped behaviour; a repository opts in per task through
# DEVICE_GROUP_AFFINITY in its task-submit.conf.
DEVICE_GROUPS="${DEVICE_GROUPS:-}"
DEVICE_GROUPS="${DEVICE_GROUPS//[[:space:]]/}"
if ! scheduler_device_groups_valid "$DEVICE_GROUPS"; then
    echo "error: DEVICE_GROUPS must be semicolon-separated groups of comma-separated card ids with no card in two groups, e.g. \"0,1;2,3\"" >&2
    exit 1
fi

# must run as root (或显式允许普通用户，用于本地测试)
if [ "$(id -u)" -ne 0 ] && [ -z "${TASKQUEUE_ALLOW_USER:-}" ]; then
    echo "error: must run as root (set TASKQUEUE_ALLOW_USER=1 to run as current user)" >&2
    exit 1
fi

# 单例保护：防止多个 daemon 同时运行
PID_FILE="$STATE_DIR/task-daemon.pid"
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "error: task-daemon already running (pid=$old_pid)" >&2
        exit 1
    fi
fi
echo $$ > "$PID_FILE"

mkdir -p "$FIFO_DIR"
chmod 1777 "$FIFO_DIR" 2>/dev/null

log "task-daemon started (pid=$$)"
log "scheduler loaded: mode=$SCHEDULER_MODE api=$SCHEDULER_MODULE_API_VERSION"
log "device groups: ${DEVICE_GROUPS:-<none>}"

RUNNING=true
cleanup() {
    RUNNING=false
    log "stopping, killing running jobs"
    # Kill setsid'd task process groups (read TASK_PID from running files)。
    # 只发 SIGTERM 不等：systemd 的 stop timeout 有限，宽限交给下次启动的 reconcile。
    # 除进程组外还按 marker 扫一遍，捞回自己 setsid 出去的后代（见 marked_pids）。
    for task_file in "$RUNNING_DIR"/task_*; do
        [ -f "$task_file" ] || continue
        case "$task_file" in *.env) continue;; esac
        local tpid task_id
        task_id=$(basename "$task_file")
        tpid=$(read_field TASK_PID "$task_file")
        [ -n "$tpid" ] && kill -TERM -- -"$tpid" 2>/dev/null
        kill -TERM $(task_pids "$task_id" "$tpid") 2>/dev/null
    done
    # Also kill subshell PIDs
    for pid in "${JOB_PIDS[@]}"; do
        kill -TERM -- -"$pid" 2>/dev/null
    done
    rm -f "$PID_FILE"
}
trap cleanup SIGTERM SIGINT
trap 'reload_runtime_config' SIGHUP

# 启动时加载一次设备白名单到内存
load_runtime_devices

# 回收上次遗留的 running 任务，释放被永久占用的设备
reconcile_running

reap_jobs() {
    local new_pids=()
    for pid in "${JOB_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            new_pids+=("$pid")
        else
            wait "$pid" 2>/dev/null
        fi
    done
    JOB_PIDS=("${new_pids[@]}")
}

# 权威的并发计数：扫 running/，包含本 daemon 启动的任务和上一次 reconcile 留下的任务。
# 仅靠 ${#JOB_PIDS[@]} 会漏算 reconciled tasks，重启后短时间内可能超出 MAX_CONCURRENT。
count_running_tasks() {
    local n=0 rf
    for rf in "$RUNNING_DIR"/task_*; do
        case "$rf" in *.env) continue;; esac
        [ -f "$rf" ] && n=$((n+1))
    done
    echo "$n"
}

JOB_PIDS=()
declare -A REAP_SEEN   # task_id -> 连续观察到 leader 已死的轮数

# 周期回收：扫描 running/，leader 已死但没人收尾的任务（监管它的 run_task 已消失，
# 例如 daemon 曾被 systemd cgroup 整组杀过）→ 扫会话 + 收尾，释放调度槽和 NPU。
# 正常完成时 run_task 会在 leader 退出后立刻收尾、删 running，故给若干轮宽限以避开竞态。
reap_orphans() {
    local rf task_id tpid
    for rf in "$RUNNING_DIR"/task_*; do
        [ -f "$rf" ] || continue
        case "$rf" in *.env) continue;; esac
        task_id=$(basename "$rf")
        tpid=$(read_field TASK_PID "$rf")
        [ -z "$tpid" ] && continue                 # 尚未写入 pid，跳过
        if kill -0 "$tpid" 2>/dev/null; then
            unset 'REAP_SEEN[$task_id]'            # leader 存活，正常运行
            continue
        fi
        REAP_SEEN[$task_id]=$(( ${REAP_SEEN[$task_id]:-0} + 1 ))
        [ "${REAP_SEEN[$task_id]}" -lt 5 ] && continue   # 给 run_task 收尾的机会
        log "reap: $task_id leader $tpid dead with no owner, sweeping + finalizing"
        sweep_task "$task_id" "$tpid" reap
        finalize_interrupted "$task_id" 137
        unset 'REAP_SEEN[$task_id]'
    done
    # 清除已消失任务的计数标记
    local k
    for k in "${!REAP_SEEN[@]}"; do
        [ -f "$RUNNING_DIR/$k" ] || unset 'REAP_SEEN[$k]'
    done
}

# 兜底：清理没有状态文件的孤儿 .env 环境快照。
# reap_orphans 按 TASK_PID 判活，但 .env 里没有 pid，它一律跳过 *.env；而
# finalize_interrupted 开头是 [ -f "$rf" ] || return 0，状态文件先没了它就撒手不管。
# 于是任何"删状态文件却漏删 .env"的路径都会在 running/ 里留下永久垃圾。
# 判据安全性：入队时状态文件先 mv 落地、.env 后 mv（见调度循环），故"有 .env 无状态
# 文件"不是合法中间态；仍留 60s 宽限以避开任何未预见的竞态。
reap_orphan_envs() {
    local ef task_id mt now=""
    for ef in "$RUNNING_DIR"/task_*.env; do
        [ -f "$ef" ] || continue
        task_id=$(basename "$ef" .env)
        [ -f "$RUNNING_DIR/$task_id" ] && continue    # 状态文件在 → 任务正常，勿动
        [ -z "$now" ] && now=$(date +%s)              # 仅在有候选时才 fork
        mt=$(stat -c %Y "$ef" 2>/dev/null) || continue
        [ $(( now - mt )) -lt 60 ] && continue
        rm -f "$ef"
        log "reap: removed orphan env snapshot ${task_id}.env"
    done
}

process_kills() {
    local now
    now=$(date +%s)
    for kill_file in "$KILL_DIR"/task_*; do
        [ -f "$kill_file" ] || continue
        local task_id
        task_id=$(basename "$kill_file")

        if [ ! -f "$RUNNING_DIR/$task_id" ]; then
            rm -f "$kill_file"
            log "kill: $task_id not in running/ (stale marker removed)"
            continue
        fi

        local task_pid
        task_pid=$(read_field TASK_PID "$RUNNING_DIR/$task_id")

        if [ -z "$task_pid" ]; then
            log "kill: $task_id has no TASK_PID yet, will retry"
            continue
        fi

        # 进程组已消失：run_task 的 wait 会负责收尾，移除标记即可
        if ! kill -0 "$task_pid" 2>/dev/null; then
            rm -f "$kill_file"
            log "kill: $task_id (pid $task_pid) already gone"
            continue
        fi

        # 保留 kill 标记直到进程真正退出，按标记 mtime（即请求时间）计算时长：
        # 宽限期内每轮重发 SIGTERM，超过 KILL_GRACE 升级到 SIGKILL，杜绝忽略 SIGTERM 的任务杀不掉。
        local req_time age
        req_time=$(stat -c %Y "$kill_file" 2>/dev/null || echo "$now")
        age=$((now - req_time))
        # 按 session ∪ marker 杀，而非只打 leader 的进程组。
        # 这里原先只按 session 杀，注释还写着"覆盖重 setsid 的后代"—— 并没有：后代
        # 一旦自己 setsid，SID 就不再是 TASK_PID，session_pids 根本看不见它。marker
        # 才真正覆盖这种逃逸（见 marked_pids）。
        local victims
        victims=$(task_pids "$task_id" "$task_pid")
        if [ "$age" -lt "$KILL_GRACE" ]; then
            log "kill: SIGTERM $task_id (pids=$victims age=${age}s)"
            kill -TERM $victims 2>/dev/null
        else
            log "kill: SIGKILL $task_id (pids=$victims age=${age}s, grace expired)"
            kill -KILL $victims 2>/dev/null
        fi
    done
}

while $RUNNING; do
    reap_jobs
    process_kills
    reap_orphans
    reap_orphan_envs

    # 权威并发数：扫 running/，正确包含 reconciled tasks
    CURRENT_JOBS=$(count_running_tasks)

    # 刷新本轮的"设备占用快照"，调度 for-loop 内 O(1) 查询
    update_in_use_set

    # 维护模式：跳过调度，但继续处理 kill 和 reap
    if [ -f "$MAINT_FILE" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    scheduler_schedule_tick

    sleep "$POLL_INTERVAL"
done

# 等待子进程退出（最多 5s，之后 SIGKILL）
for pid in "${JOB_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
        for i in {1..5}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 -- -"$pid" 2>/dev/null
    fi
done
# Also SIGKILL setsid'd tasks that survived
for task_file in "$RUNNING_DIR"/task_*; do
    [ -f "$task_file" ] || continue
    case "$task_file" in *.env) continue;; esac
    tpid=$(read_field TASK_PID "$task_file")
    [ -n "$tpid" ] && kill -0 "$tpid" 2>/dev/null && kill -9 -- -"$tpid" 2>/dev/null
done

log "task-daemon stopped"
