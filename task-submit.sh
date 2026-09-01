#!/bin/bash
# task-submit: 普通用户提交任务到 root 队列
# 用法:
#   task-submit "command to run"                    提交任务，返回 task-id
#   task-submit --run "command"                     提交并等待完成（一步到位）
#   task-submit --device 0 "command"                提交并自动锁 NPU 设备
#   task-submit --wait <task-id>                    等待任务完成并输出结果
#   task-submit --timeout 600 --wait <task-id>      自定义超时
#   task-submit --status <task-id>                  查看任务状态
#   task-submit --log <task-id>                     查看任务日志
#   task-submit --cancel <task-id>                  取消 pending 任务
#   task-submit --list                              列出所有任务
#   task-submit --clean [--days N]                  清理已完成任务（默认 7 天前）
#   task-submit --maintenance [on|off|status]       维护模式管理

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -n "${TASKQUEUE_CONF:-}" ]]; then
    CONF_FILE="$TASKQUEUE_CONF"
elif [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then
    # Installed layout: <tool>/app/task-submit, <tool>/config/taskqueue.conf.
    CONF_FILE="$SCRIPT_DIR/../config/taskqueue.conf"
else
    # Source layout keeps all mutable files below the ignored runtime/ tree.
    CONF_FILE="$SCRIPT_DIR/runtime/config/taskqueue.conf"
fi
STATE_DIR=""
LOGS_DIR=""
# The installed config provides the server default, while an explicitly
# exported submitter value takes precedence for hosts with another PTOAS tree.
SUBMITTER_PTOAS_BASE="${PTOAS_BASE:-}"
unset PTOAS_BASE
PTOAS_BASE="/usr/local/ptoas"
# HCCS plane topology is host truth owned by the root-installed config. Drop any
# inherited value so a submitter cannot present a fake partition to the checks.
unset DEVICE_GROUPS
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
fi
if [[ -n "$SUBMITTER_PTOAS_BASE" ]]; then
    export PTOAS_BASE="$SUBMITTER_PTOAS_BASE"
fi
unset SUBMITTER_PTOAS_BASE
if [[ -z "$STATE_DIR" ]]; then
    if [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then
        STATE_DIR="$SCRIPT_DIR/../state"
    else
        STATE_DIR="$SCRIPT_DIR/runtime/state"
    fi
fi
LOGS_DIR="${LOGS_DIR:-${STATE_DIR%/state}/logs}"
PENDING_DIR="$STATE_DIR/pending"
RUNNING_DIR="$STATE_DIR/running"
DONE_DIR="$STATE_DIR/done"
KILL_DIR="$STATE_DIR/kill"
FIFO_DIR="$STATE_DIR/fifo"
MAINT_FILE="$STATE_DIR/maintenance"
UPDATE_LOCK="$STATE_DIR/locks/update-reservation.lock"
TIMEOUT=600
LOCK_DEVICE=""
DEVICE_NUM=""
RUN_MODE=false
CLEAN_DAYS=1
MAX_TIME=300    # 任务最大执行时间（秒），0=不限
MAX_CONCURRENT_8_CARD_TASKS=${MAX_CONCURRENT_8_CARD_TASKS:-0}
INTERACTIVE=false # --interactive 交互式模式
EXTRA_ENVS=()    # --env 收集的额外环境变量
ENV_FILES=()     # --env-file 收集的环境变量文件
PTOAS_VERSION=""
# 卡组：限定 --device auto 的自动分配范围，来源为环境变量 TASKQUEUE_DEVICE_POOL
# （与全局白名单 available_devices 取交集，白名单为硬上限）
DEVICE_POOL="${TASKQUEUE_DEVICE_POOL:-}"
DEVICE_POOL="${DEVICE_POOL//[[:space:]]/}"
ENV_DEVICE_POOL="$DEVICE_POOL"
GLOBAL_AUTO_POOL=""
GLOBAL_AUTO_POOL_SOURCE=""
RUNTIME_AUTO_POOL=""
CONFIG_AUTO_POOL="${AVAILABLE_DEVICES:-}"
CONFIG_AUTO_POOL="${CONFIG_AUTO_POOL//[[:space:]]/}"
DETECTED_AUTO_POOL=""
DEVICE_REQUEST_RAW=""
DEVICE_REQUEST_ORIGIN="none"
DEVICE_SEQUENCE_SOURCE=""

# 每仓设备策略配置文件（独立文件，仅影响 --device auto 自动选卡）
# 发现方式：从当前目录逐级向上查找，命中第一个即用；可用 TASKQUEUE_DEVICE_CONF 显式指定路径
DEVICE_CONF_NAME="${TASKQUEUE_DEVICE_CONF_NAME:-task-submit.conf}"
DEVICE_CONF_PATH=""
CONF_WHITELIST=""
CONF_BLACKLIST=""
CONF_WHITELIST_RAW=""
CONF_BLACKLIST_RAW=""

# 同 HCCS plane（卡组）约束
# DEVICE_GROUPS 来自本机 taskqueue.conf，形如 "0,1;2,3"，描述哪些卡在同一个
# 通信域；每仓 task-submit.conf 用 DEVICE_GROUP_AFFINITY=1 声明"本仓多卡必须同组"。
# 跨 plane 的多卡通信在 pypto/simpler 上不是报错而是挂起，并把卡楔死到只能靠
# 平台带外 reset，所以这里在提交侧就拦下，不让任务进队列。
DEVICE_GROUPS="${DEVICE_GROUPS:-}"
DEVICE_GROUPS="${DEVICE_GROUPS//[[:space:]]/}"
CONF_GROUP_AFFINITY_RAW=""
CONF_GROUP_AFFINITY=0
GROUP_AFFINITY_EFFECTIVE=0
declare -A DEVICE_GROUP_OF=()
DEVICE_GROUP_MAP_LOADED=0
# 关闭同组约束：供确实需要跨 plane 的负载（如 torch_npu 纯 HCCL collective 加
# RoCE）放行。触发：--ignore-group-affinity 或 TASKQUEUE_IGNORE_GROUP_AFFINITY=1。
IGNORE_GROUP_AFFINITY=0
case "${TASKQUEUE_IGNORE_GROUP_AFFINITY:-}" in
    1|true|TRUE|yes|YES|on|ON) IGNORE_GROUP_AFFINITY=1 ;;
esac

# 白名单超限开关：置位后 --device auto 忽略每仓 DEVICE_WHITELIST 上限，
# 回退到全局 available_devices（黑名单 DEVICE_BLACKLIST 仍然排除）。
# 供某些仓库 daily CI 跑 8 卡用例时临时突破每仓白名单。
# 触发：环境变量 TASKQUEUE_IGNORE_WHITELIST=1，或命令行 --ignore-whitelist。
IGNORE_WHITELIST=0
case "${TASKQUEUE_IGNORE_WHITELIST:-}" in
    1|true|TRUE|yes|YES|on|ON) IGNORE_WHITELIST=1 ;;
esac

# 颜色（仅终端）
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM="" C_BOLD="" C_RESET=""
fi

usage() {
    cat <<'EOF'
task-submit — 昇腾共享机的任务队列：统一排队、按需占卡

  禁止裸跑占卡：所有要用 NPU 的命令都必须经 task-submit 提交，由队列分配卡并在
  任务结束后释放。不用 NPU 的命令（编译、CPU 测试等）同样可以提交，
  但不要占卡——占着卡不用会让别人白排队。

  任务以什么身份执行，由部署时的 TASK_EXECUTION_MODE 决定（见 config/taskqueue.conf）:
    HwHiAiUser (默认)  仍以提交者自己的 UID 运行，只临时补上 HwHiAiUser 组以获得 NPU
                       设备访问权限——不是 root，文件属主、家目录权限都还是你自己的
    root               任务直接以 root 执行；仅在所有提交者都可信时才这么配
  用 task-submit --no-device --run 'id' 可以看到当前这台机器实际是哪种模式。

  占不占卡，看命令本身要不要真的跑在卡上:
    --no-device        不占卡（也是默认行为）。编译、CPU 任务用这个
    --device auto      需要在卡上跑时才分配；作业内用 $TASK_DEVICE 拿到卡号

提交:
  task-submit --no-device --run "command"      不占卡执行（编译 / CPU 测试）
  task-submit "command"                        提交任务，返回 task-id（默认不分配 NPU 卡）
  task-submit --run "command"                  提交并等待完成（一步到位，默认不分配 NPU 卡）
  task-submit --device auto --run "..."        自动分配空闲 NPU 卡
  task-submit --device auto --device-num 2 --run "..."  自动分配 2 张空闲 NPU 卡
  task-submit --device N --run "..."           指定 NPU 卡号
  task-submit -i --run "command"               交互式执行（可向任务输入 stdin）

查询:
  task-submit --version                        显示已安装源码 revision
  task-submit --wait <task-id>                 等待任务完成并实时输出日志
  task-submit --timeout N --wait <task-id>     自定义等待超时(秒，默认 600)
  task-submit --status <task-id>               查看任务状态
  task-submit --log <task-id>                  查看任务日志（已完成或运行中）
  task-submit --stats [--days N]               查看 NPU 使用统计（默认近 7 天）

管理:
  task-submit --list                           列出所有任务
  task-submit --cancel <task-id>               取消尚未执行的任务
  task-submit --kill <task-id>                 终止运行中的任务
  task-submit --clean [--days N]               清理 N 天前的过期任务（默认 1，含 done 和 pending）
  task-submit --maintenance [on|off|status]    维护模式管理
  task-submit --find <子串>                     按完整命令匹配，只输出 task-id（供脚本/CI 用）
                                               --list 的命令列会被截断，不可用于脚本匹配
  task-submit --devices [list|reset|status]    查询/设置可用设备白名单
                                               status/list 同时显示 auto 策略来源、交集与冲突
                                               设备列表形如 "2,3,4,5"，reset 清除运行时覆盖

选项:
  --no-device     不分配 NPU 卡（默认行为，写出来更明确）。与 --device-num 同用会报错；
                  也别和 --device 混写（后写的生效）
  --timeout N     设置等待超时(秒)，可放在任意子命令前
  --device auto   自动分配空闲 NPU 卡（需要 NPU 时必须指定）
  --device-num N  自动分配 N 张空闲 NPU 卡（需配合 --device auto，或单独使用）
                  若每仓 task-submit.conf 配了 DEVICE_SEQ_<N>，则改为固定使用该卡号
                  序列（精确锁，等价于 --device <序列>；卡忙则排队等这几张）。
                  该序列须落在 DEVICE_WHITELIST 内，越界需加 --ignore-whitelist
  --device N      指定 NPU 卡号（N 为整数或逗号分隔多卡）
                  若每仓配了 DEVICE_GROUP_AFFINITY=1，多卡卡号须同属一个
                  DEVICE_GROUPS 卡组，跨组会被拒绝（见 --devices status）
  --ignore-whitelist  忽略每仓 task-submit.conf 的 DEVICE_WHITELIST 上限，
                  --device auto 回退到全局可用设备（黑名单仍排除）；
                  等价于环境变量 TASKQUEUE_IGNORE_WHITELIST=1，供 daily CI 跑多卡用例超限
  --ignore-group-affinity  关闭同组（HCCS plane）约束，允许多卡跨组分配。
                  仅当负载确实能跨 plane 通信时使用（如 torch_npu 纯 HCCL
                  collective 加 RoCE）；pypto/simpler 跨组会挂起并楔死卡。
                  等价于环境变量 TASKQUEUE_IGNORE_GROUP_AFFINITY=1
  --interactive/-i 交互模式：转发终端 stdin 到任务进程（需搭配 --run）
  --env VAR       捕获当前 shell 的环境变量（可重复使用）
  --env VAR=VAL   传递指定值的环境变量
  --env-file FILE 从文件读取环境变量（支持 KEY=VAL / export KEY=VAL）
  --ptoas VERSION 从 PTOAS_BASE 选择版本；已有 PTOAS_ROOT 时以环境为准
  --max-time N    任务最大执行时间(秒，默认 300，0=不限)

示例:
  # 不占卡：编译、CPU 测试
  task-submit --no-device --run "make build"

  # NPU 任务（自动分配卡）
  task-submit --device auto --run "python train.py"

  # 自动分配 2 张卡
  task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"

  # daily CI 超限：跑 8 卡用例，突破每仓白名单（黑名单仍排除）
  task-submit --ignore-whitelist --device auto --device-num 8 --run "bash run_daily_ci.sh"
  # 或在 workflow 的 env 段统一开：TASKQUEUE_IGNORE_WHITELIST=1

  # 指定卡号
  task-submit --device 0 --run "python train.py"

  # 传递自定义环境变量
  task-submit --device auto --env WANDB_PROJECT --env SEED=42 --run "python train.py"

  # 指定 PTOAS 版本
  task-submit --ptoas 0.54 --device auto --run "python train.py"

  # 交互式任务（可在执行过程中输入 prompt）
  task-submit -i --device auto --run "python interactive_train.py"

  # 分步操作
  id=$(task-submit --device auto "python test.py")
  task-submit --wait "$id"

  # 维护模式
  sudo task-submit --maintenance on "升级 CANN 驱动"
  sudo task-submit --maintenance off
EOF
    exit 1
}

# 防止嵌套提交（在 task-daemon 内部禁止再次提交）
if [[ -n "${TASKQUEUE_INSIDE:-}" ]]; then
    echo "${C_RED}错误: 禁止在 task-daemon 内部嵌套提交任务${C_RESET}" >&2
    echo "${C_DIM}提示: 当前命令已在 task-daemon 中执行，直接运行即可${C_RESET}" >&2
    exit 1
fi

# 解析前置选项
while [[ "${1:-}" == --* || "${1:-}" == "-i" ]]; do
    case "$1" in
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --device)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "${C_RED}错误: --device 需要参数（auto / 卡号 / 卡号列表）${C_RESET}" >&2
                echo "${C_DIM}示例: task-submit --device auto --run \"...\"${C_RESET}" >&2
                echo "${C_DIM}      task-submit --device 2,3 --run \"...\"${C_RESET}" >&2
                exit 1
            fi
            LOCK_DEVICE="$2"; shift 2 ;;
        --device-num) DEVICE_NUM="$2"; shift 2 ;;
        --no-device) LOCK_DEVICE=none; shift ;;
        --ignore-whitelist) IGNORE_WHITELIST=1; shift ;;
        --ignore-group-affinity) IGNORE_GROUP_AFFINITY=1; shift ;;
        --run)       RUN_MODE=true; shift ;;
        --interactive|-i) INTERACTIVE=true; shift ;;
        --days)    CLEAN_DAYS="$2"; shift 2 ;;
        --env)     EXTRA_ENVS+=("$2"); shift 2 ;;
        --env-file) ENV_FILES+=("$2"); shift 2 ;;
        --ptoas)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "${C_RED}错误: --ptoas 需要版本号（例如 0.54）${C_RESET}" >&2
                exit 1
            fi
            PTOAS_VERSION="$2"; shift 2 ;;
        --max-time) MAX_TIME="$2"; shift 2 ;;
        # 子命令：不在此处消费，留给下面的主 case 分派
        --version|--wait|--status|--log|--cancel|--kill|--list|--clean|--maintenance|--devices|--find|--stats|--help|-h)
            break ;;
        # 未知选项必须硬失败。此处曾是 `*) break`，会把未识别的 flag 连同其后的
        # --run/--timeout 一起当作任务命令提交，且 RUN_MODE 未置位时静默 exit 0
        # —— CI 因此看不出测试根本没跑。
        --*)
            echo "${C_RED}错误: 未知选项 '$1'${C_RESET}" >&2
            echo "${C_DIM}如果这是新版本的选项，说明本机 task-submit 过旧，请重新部署${C_RESET}" >&2
            echo "${C_DIM}可用选项见 task-submit --help${C_RESET}" >&2
            exit 1 ;;
        *) break ;;
    esac
done

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

normalize_device_request() {
    if [[ -n "$DEVICE_NUM" ]] && ! is_positive_int "$DEVICE_NUM"; then
        echo "${C_RED}错误: --device-num 必须为正整数${C_RESET}" >&2
        exit 1
    fi

    if [[ -z "$LOCK_DEVICE" && -n "$DEVICE_NUM" ]]; then
        LOCK_DEVICE="auto"
    fi

    if [[ "$LOCK_DEVICE" == "none" && -n "$DEVICE_NUM" ]]; then
        echo "${C_RED}错误: --no-device 不能与 --device-num 同时使用${C_RESET}" >&2
        exit 1
    fi

    if [[ -n "$DEVICE_NUM" && -n "$LOCK_DEVICE" && "$LOCK_DEVICE" != "auto" && "$LOCK_DEVICE" != "none" ]]; then
        echo "${C_RED}错误: --device-num 仅支持与 --device auto 搭配使用${C_RESET}" >&2
        exit 1
    fi
}

build_device_request() {
    if [[ "$LOCK_DEVICE" != "auto" ]]; then
        echo "$LOCK_DEVICE"
        return
    fi

    local count="${DEVICE_NUM:-1}"
    if [[ "$count" == "1" ]]; then
        echo "auto"
    else
        echo "auto:$count"
    fi
}

is_auto_device_request() {
    local request
    request="$(build_device_request)"
    [[ "$request" == "auto" || "$request" == auto:* ]]
}

# Count distinct physical devices represented by DEVICE/auto:N. This mirrors
# the daemon's scheduler-side check and is used only for user-facing notices;
# the daemon remains authoritative under concurrent submissions.
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
            for id in "${ids[@]}"; do seen["$id"]=1; done
            printf '%s' "${#seen[@]}"
            ;;
    esac
}

eight_card_policy_enabled() {
    [[ "$MAX_CONCURRENT_8_CARD_TASKS" =~ ^[1-9][0-9]*$ ]]
}

show_eight_card_policy_notice() {
    local request="$1"
    eight_card_policy_enabled || return 0
    [[ "$(device_request_count "$request")" -eq 8 ]] || return 0
    if [[ "$MAX_CONCURRENT_8_CARD_TASKS" -eq 1 ]]; then
        echo "${C_YELLOW}提示: 当前服务器同时只运行一个 8 卡用例；如已有 8 卡用例运行，本任务会继续排队，不阻塞后续小卡任务。${C_RESET}" >&2
    else
        echo "${C_YELLOW}提示: 当前服务器同时最多运行 ${MAX_CONCURRENT_8_CARD_TASKS} 个 8 卡用例；超出时任务会继续排队。${C_RESET}" >&2
    fi
}

detect_auto_device_pool() {
    local n
    n=$(ls -1 /dev/davinci[0-9]* 2>/dev/null | wc -l)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [[ $n -lt 1 ]] && n=2
    seq -s, 0 $((n - 1))
}

# Resolve the same global auto-allocation pool as task-daemon:
# runtime override > installed AVAILABLE_DEVICES > device detection.
load_global_auto_pool() {
    local include_detection_detail="${1:-0}"
    local runtime_file="$STATE_DIR/available_devices"
    RUNTIME_AUTO_POOL=""
    [[ -f "$runtime_file" ]] && RUNTIME_AUTO_POOL="$(tr -d '[:space:]' < "$runtime_file" 2>/dev/null)"
    DETECTED_AUTO_POOL=""
    if [[ "$include_detection_detail" == "1" ||
          ( -z "$RUNTIME_AUTO_POOL" && -z "$CONFIG_AUTO_POOL" ) ]]; then
        DETECTED_AUTO_POOL="$(detect_auto_device_pool)"
    fi

    if [[ -n "$RUNTIME_AUTO_POOL" ]]; then
        GLOBAL_AUTO_POOL="$RUNTIME_AUTO_POOL"
        GLOBAL_AUTO_POOL_SOURCE="runtime:$runtime_file"
    elif [[ -n "$CONFIG_AUTO_POOL" ]]; then
        GLOBAL_AUTO_POOL="$CONFIG_AUTO_POOL"
        GLOBAL_AUTO_POOL_SOURCE="config:$CONF_FILE"
    else
        GLOBAL_AUTO_POOL="$DETECTED_AUTO_POOL"
        GLOBAL_AUTO_POOL_SOURCE="detected:/dev/davinci*"
    fi
}

device_list_intersection() {
    local left="$1" right="$2" item
    local -a left_arr result=()
    IFS=',' read -ra left_arr <<< "$left"
    for item in "${left_arr[@]}"; do
        [[ -n "$item" && ",$right," == *",$item,"* ]] && result+=("$item")
    done
    (IFS=,; echo "${result[*]}")
}

device_list_subtract() {
    local base="$1" removed="$2" item
    local -a base_arr result=()
    IFS=',' read -ra base_arr <<< "$base"
    for item in "${base_arr[@]}"; do
        [[ -z "$item" ]] && continue
        [[ -n "$removed" && ",$removed," == *",$item,"* ]] && continue
        result+=("$item")
    done
    (IFS=,; echo "${result[*]}")
}

device_list_difference() {
    local left="$1" right="$2"
    device_list_subtract "$left" "$right"
}

device_list_count() {
    local list="$1" item count=0
    local -a items
    local -A seen=()
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]}"; do
        [[ -n "$item" && -z "${seen[$item]:-}" ]] || continue
        seen["$item"]=1
        count=$((count + 1))
    done
    echo "$count"
}

device_list_is_valid() {
    local list="$1"
    [[ -z "$list" || "$list" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

device_list_duplicates() {
    local list="$1" item
    local -a items duplicates=()
    local -A seen=() reported=()
    IFS=',' read -ra items <<< "$list"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] || continue
        if [[ -n "${seen[$item]:-}" && -z "${reported[$item]:-}" ]]; then
            duplicates+=("$item")
            reported["$item"]=1
        fi
        seen["$item"]=1
    done
    (IFS=,; echo "${duplicates[*]}")
}

show_device_list_health() {
    local indent="$1" label="$2" list="$3" duplicates
    [[ -n "$list" ]] || return 0
    if ! device_list_is_valid "$list"; then
        echo "${indent}${C_RED}INVALID${C_RESET}: $label 格式无效，应为逗号分隔的非负整数"
        return 1
    fi
    duplicates="$(device_list_duplicates "$list")"
    if [[ -n "$duplicates" ]]; then
        echo "${indent}${C_YELLOW}警告${C_RESET}: $label 包含重复卡号 [$duplicates]"
    fi
    return 0
}

format_device_pool() {
    local list="$1"
    printf '[%s] (%s 张)' "$list" "$(device_list_count "$list")"
}

# 校验卡组（TASKQUEUE_DEVICE_POOL）：格式 + 与全局白名单是否有交集
# 仅 --device auto 时才真正约束分配；提前拦截"卡组与白名单无交集 → 任务永远排队"
validate_device_pool() {
    is_auto_device_request || return 0
    [[ -z "$DEVICE_POOL" ]] && return 0
    if [[ ! "$DEVICE_POOL" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "${C_RED}错误: TASKQUEUE_DEVICE_POOL 格式无效: '$DEVICE_POOL'${C_RESET}" >&2
        echo "${C_DIM}应为逗号分隔的非负整数，如 TASKQUEUE_DEVICE_POOL=2,3,4,5${C_RESET}" >&2
        exit 1
    fi
    local allow="$GLOBAL_AUTO_POOL"
    [[ -z "$allow" ]] && return 0
    local p
    local -a _pool
    IFS=',' read -ra _pool <<< "$DEVICE_POOL"
    for p in "${_pool[@]}"; do
        [[ ",$allow," == *",$p,"* ]] && return 0
    done
    echo "${C_RED}错误: 卡组 [$DEVICE_POOL] 与系统可用设备白名单 [$allow] 无交集，任务无法分配${C_RESET}" >&2
    echo "${C_DIM}全局池来源: $GLOBAL_AUTO_POOL_SOURCE；请调整卡组，或用 task-submit --devices status 查看详情${C_RESET}" >&2
    exit 1
}

# 从当前目录逐级向上查找每仓配置文件（命中第一个即用）
find_device_conf() {
    if [[ -n "${TASKQUEUE_DEVICE_CONF:-}" ]]; then
        [[ -f "$TASKQUEUE_DEVICE_CONF" ]] && { echo "$TASKQUEUE_DEVICE_CONF"; return 0; }
        return 1
    fi
    local dir
    dir="$(pwd)"
    while [[ -n "$dir" ]]; do
        if [[ -f "$dir/$DEVICE_CONF_NAME" ]]; then
            echo "$dir/$DEVICE_CONF_NAME"
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

# 只取指定键的值，不 source（避免任意代码执行）；剥注释/空白/引号
read_conf_field() {
    local key="$1" file="$2" line
    line=$(grep -m1 "^[[:space:]]*${key}=" "$file" 2>/dev/null) || return 0
    line="${line#*=}"
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    line="${line#\"}" ; line="${line%\"}"
    line="${line#\'}" ; line="${line%\'}"
    echo "$line"
}

# 加载每仓设备策略（白名单/黑名单）
load_device_conf() {
    local conf
    conf="$(find_device_conf)" || return 0
    DEVICE_CONF_PATH="$conf"
    CONF_WHITELIST_RAW="$(read_conf_field DEVICE_WHITELIST "$conf")"
    CONF_BLACKLIST_RAW="$(read_conf_field DEVICE_BLACKLIST "$conf")"
    CONF_WHITELIST="$CONF_WHITELIST_RAW"
    CONF_BLACKLIST="$CONF_BLACKLIST_RAW"
    CONF_GROUP_AFFINITY_RAW="$(read_conf_field DEVICE_GROUP_AFFINITY "$conf")"
    case "$CONF_GROUP_AFFINITY_RAW" in
        1|true|TRUE|yes|YES|on|ON) CONF_GROUP_AFFINITY=1 ;;
        ""|0|false|FALSE|no|NO|off|OFF) CONF_GROUP_AFFINITY=0 ;;
        *)
            echo "${C_RED}错误: $conf 中 DEVICE_GROUP_AFFINITY 取值无效: '$CONF_GROUP_AFFINITY_RAW'${C_RESET}" >&2
            echo "${C_DIM}应为 1/0（或 true/false、yes/no、on/off）${C_RESET}" >&2
            exit 1
            ;;
    esac
}

# --- 卡组工具（与 schedulers/_core.sh 的判定口径保持一致） ---

device_groups_valid() {
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

load_device_group_map() {
    (( DEVICE_GROUP_MAP_LOADED )) && return 0
    DEVICE_GROUP_MAP_LOADED=1
    local group id index=0
    local -a groups ids
    [[ -n "$DEVICE_GROUPS" ]] || return 0
    IFS=';' read -ra groups <<< "$DEVICE_GROUPS"
    for group in "${groups[@]}"; do
        [[ -n "$group" ]] || continue
        IFS=',' read -ra ids <<< "$group"
        for id in "${ids[@]}"; do
            [[ -n "$id" ]] && DEVICE_GROUP_OF["$id"]="$index"
        done
        index=$((index + 1))
    done
}

# 未被任何卡组覆盖的卡不与其它卡共享 plane，只能满足单卡请求。
device_group_of() {
    local id="$1"
    load_device_group_map
    if [[ -n "${DEVICE_GROUP_OF[$id]:-}" ]]; then
        printf 'g%s' "${DEVICE_GROUP_OF[$id]}"
    else
        printf 'solo%s' "$id"
    fi
}

# 卡 $1 所在组的成员列表，用于错误信息里指出"它跟谁同组"。
device_group_members() {
    local id="$1" group members
    group="$(device_group_of "$id")"
    case "$group" in
        solo*) printf '%s' "$id"; return ;;
    esac
    members="$(cut -d';' -f"$(( ${group#g} + 1 ))" <<< "$DEVICE_GROUPS")"
    printf '%s' "$members"
}

device_list_same_group() {
    local devices="$1" id group first=""
    local -a ids
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        group="$(device_group_of "$id")"
        if [[ -z "$first" ]]; then
            first="$group"
        elif [[ "$group" != "$first" ]]; then
            return 1
        fi
    done
    return 0
}

# 候选卡按组切分后每组各有几张，形如 "[0,1] (2 张)  [2,3] (2 张)"。
format_group_breakdown() {
    local list="$1" id group out=""
    local -a ids order=()
    local -A members=()
    IFS=',' read -ra ids <<< "$list"
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        group="$(device_group_of "$id")"
        if [[ -z "${members[$group]:-}" ]]; then
            order+=("$group")
            members["$group"]="$id"
        else
            members["$group"]="${members[$group]},$id"
        fi
    done
    for group in "${order[@]}"; do
        out+="  $(format_device_pool "${members[$group]}")"
    done
    printf '%s' "${out#  }"
}

# 单个卡组最多能贡献几张候选卡：同组约束下这才是多卡请求的真实上限。
device_group_max_size() {
    local list="$1" id group max=0
    local -a ids
    local -A tally=()
    IFS=',' read -ra ids <<< "$list"
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        group="$(device_group_of "$id")"
        tally["$group"]=$(( ${tally[$group]:-0} + 1 ))
        (( tally[$group] > max )) && max=${tally[$group]}
    done
    printf '%s' "$max"
}

show_device_policy_sources() {
    local runtime_file="$STATE_DIR/available_devices"
    local base effective outside git_root seq_key seq outside_seq seq_n duplicates
    local base_valid=1
    local runtime_valid=1 config_valid=1 detected_valid=1 global_valid=1
    local env_valid=1 whitelist_valid=1 blacklist_valid=1 groups_valid=0

    echo ""
    echo "${C_BOLD}=== Auto 设备策略来源 ===${C_RESET}"
    if [[ -n "$RUNTIME_AUTO_POOL" ]]; then
        echo "  ${C_GREEN}运行时覆盖${C_RESET} $(format_device_pool "$RUNTIME_AUTO_POOL")  $runtime_file"
        show_device_list_health "    " "运行时覆盖" "$RUNTIME_AUTO_POOL" || runtime_valid=0
    else
        echo "  ${C_DIM}运行时覆盖${C_RESET} 未设置  $runtime_file"
    fi
    if [[ -n "$CONFIG_AUTO_POOL" ]]; then
        if [[ -n "$RUNTIME_AUTO_POOL" ]]; then
            echo "  ${C_DIM}静态配置${C_RESET}   $(format_device_pool "$CONFIG_AUTO_POOL")  $CONF_FILE（被运行时覆盖）"
        else
            echo "  ${C_GREEN}静态配置${C_RESET}   $(format_device_pool "$CONFIG_AUTO_POOL")  $CONF_FILE"
        fi
        show_device_list_health "    " "AVAILABLE_DEVICES" "$CONFIG_AUTO_POOL" || config_valid=0
    else
        echo "  ${C_DIM}静态配置${C_RESET}   未设置  $CONF_FILE"
    fi
    if [[ "$GLOBAL_AUTO_POOL_SOURCE" == detected:* ]]; then
        echo "  ${C_GREEN}自动探测${C_RESET}   $(format_device_pool "$DETECTED_AUTO_POOL")  /dev/davinci*"
    else
        echo "  ${C_DIM}自动探测${C_RESET}   $(format_device_pool "$DETECTED_AUTO_POOL")  /dev/davinci*（当前未采用）"
    fi
    show_device_list_health "    " "自动探测设备列表" "$DETECTED_AUTO_POOL" || detected_valid=0
    case "$GLOBAL_AUTO_POOL_SOURCE" in
        runtime:*) global_valid="$runtime_valid" ;;
        config:*) global_valid="$config_valid" ;;
        detected:*) global_valid="$detected_valid" ;;
    esac
    echo "  ${C_BOLD}全局生效池${C_RESET} $(format_device_pool "$GLOBAL_AUTO_POOL")  来源=$GLOBAL_AUTO_POOL_SOURCE"

    if [[ -n "$DEVICE_GROUPS" ]]; then
        if device_groups_valid "$DEVICE_GROUPS"; then
            echo "  ${C_CYAN}卡组拓扑${C_RESET}   $(format_group_breakdown "$GLOBAL_AUTO_POOL")  DEVICE_GROUPS@$CONF_FILE"
            groups_valid=1
        else
            echo "  ${C_CYAN}卡组拓扑${C_RESET}   $DEVICE_GROUPS  DEVICE_GROUPS@$CONF_FILE"
            echo "    ${C_RED}INVALID${C_RESET}: 应为分号分隔的卡组、组内逗号分隔、同一张卡不得出现在两个组，如 \"0,1;2,3\""
        fi
    else
        echo "  ${C_DIM}卡组拓扑${C_RESET}   未设置  DEVICE_GROUPS@$CONF_FILE（同组约束无从生效）"
    fi

    if [[ -n "$ENV_DEVICE_POOL" ]]; then
        echo "  ${C_CYAN}环境卡组${C_RESET}   $(format_device_pool "$ENV_DEVICE_POOL")  TASKQUEUE_DEVICE_POOL"
        show_device_list_health "    " "TASKQUEUE_DEVICE_POOL" "$ENV_DEVICE_POOL" || env_valid=0
    else
        echo "  ${C_DIM}环境卡组${C_RESET}   未设置"
    fi

    if [[ -n "$DEVICE_CONF_PATH" ]]; then
        echo "  ${C_CYAN}仓库配置${C_RESET}   $DEVICE_CONF_PATH"
        echo "    DEVICE_WHITELIST=$(format_device_pool "$CONF_WHITELIST_RAW")"
        show_device_list_health "      " "DEVICE_WHITELIST" "$CONF_WHITELIST_RAW" || whitelist_valid=0
        echo "    DEVICE_BLACKLIST=$(format_device_pool "$CONF_BLACKLIST_RAW")"
        show_device_list_health "      " "DEVICE_BLACKLIST" "$CONF_BLACKLIST_RAW" || blacklist_valid=0
        echo "    DEVICE_GROUP_AFFINITY=${CONF_GROUP_AFFINITY_RAW:-未设置}"
        if [[ "$CONF_GROUP_AFFINITY" == "1" ]]; then
            if [[ -z "$DEVICE_GROUPS" ]]; then
                echo "      ${C_RED}多卡被拒${C_RESET}: 本机未配置 DEVICE_GROUPS，无从判断同组；多卡任务提交即报错（单卡不受影响）"
            elif [[ "$IGNORE_GROUP_AFFINITY" == "1" ]]; then
                echo "      ${C_YELLOW}已放行${C_RESET}: --ignore-group-affinity/TASKQUEUE_IGNORE_GROUP_AFFINITY 关闭了同组约束"
            else
                echo "      ${C_GREEN}生效${C_RESET}: 多卡任务的卡必须同组，否则提交即报错"
            fi
        fi
        if git_root=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null); then
            case "$DEVICE_CONF_PATH" in
                "$git_root"|"$git_root"/*) ;;
                *) echo "  ${C_YELLOW}警告${C_RESET}: 配置位于当前 Git 仓库根目录之外，由向上搜索继承" ;;
            esac
        fi
    elif [[ -n "${TASKQUEUE_DEVICE_CONF:-}" ]]; then
        echo "  ${C_YELLOW}仓库配置${C_RESET}   显式路径不存在: $TASKQUEUE_DEVICE_CONF"
    else
        echo "  ${C_DIM}仓库配置${C_RESET}   从 $(pwd) 向上搜索，未找到 $DEVICE_CONF_NAME"
    fi

    # Preserve the existing policy precedence for compatibility. Only require
    # the selected base source to be valid: an invalid but overridden env pool,
    # or a whitelist explicitly ignored by the user, does not affect allocation.
    if [[ "$IGNORE_WHITELIST" == "1" || -z "$CONF_WHITELIST_RAW" ]]; then
        base="${ENV_DEVICE_POOL:-$GLOBAL_AUTO_POOL}"
        [[ -z "$ENV_DEVICE_POOL" || "$env_valid" == "1" ]] || base_valid=0
    else
        base="$CONF_WHITELIST_RAW"
        [[ "$whitelist_valid" == "1" ]] || base_valid=0
        if [[ -n "$ENV_DEVICE_POOL" ]]; then
            echo "  ${C_YELLOW}兼容提示${C_RESET}: 仓库白名单优先于 TASKQUEUE_DEVICE_POOL；当前未改动该历史行为"
        fi
    fi

    if [[ "$global_valid" == "1" && "$base_valid" == "1" && "$blacklist_valid" == "1" ]]; then
        base="$(device_list_subtract "$base" "$CONF_BLACKLIST_RAW")"
        effective="$(device_list_intersection "$GLOBAL_AUTO_POOL" "$base")"
        outside="$(device_list_difference "$base" "$GLOBAL_AUTO_POOL")"
        echo "  ${C_BOLD}最终 auto 候选${C_RESET} $(format_device_pool "$effective")"
        [[ -z "$outside" ]] || echo "  ${C_YELLOW}冲突${C_RESET}: 项目/环境策略中的 $(format_device_pool "$outside") 不在全局生效池，daemon 不会分配"
        [[ -n "$effective" ]] || echo "  ${C_RED}冲突${C_RESET}: 各层策略交集为空，auto 任务无法获得设备"
        if [[ "$CONF_GROUP_AFFINITY" == "1" && "$IGNORE_GROUP_AFFINITY" != "1" &&
              "$groups_valid" == "1" && -n "$effective" ]]; then
            echo "  ${C_BOLD}同组候选${C_RESET}   $(format_group_breakdown "$effective")"
            echo "  ${C_BOLD}多卡上限${C_RESET}   $(device_group_max_size "$effective") 张（单次 --device-num 的最大值；跨组不分配）"
        fi
    else
        echo "  ${C_RED}最终 auto 候选无法计算${C_RESET}: 请先修复上面的 INVALID 设备列表"
    fi

    if [[ -n "$DEVICE_CONF_PATH" ]]; then
        while IFS= read -r seq_key; do
            [[ -n "$seq_key" ]] || continue
            seq="$(read_conf_field "$seq_key" "$DEVICE_CONF_PATH")"
            echo "    $seq_key=$(format_device_pool "$seq")"
            if ! device_list_is_valid "$seq"; then
                echo "      ${C_RED}INVALID${C_RESET}: $seq_key 格式无效，应为逗号分隔的非负整数"
                continue
            fi
            seq_n="${seq_key#DEVICE_SEQ_}"
            if [[ "$(device_list_count "$seq")" -ne "$seq_n" ]]; then
                echo "      ${C_RED}INVALID${C_RESET}: 配置了 $(device_list_count "$seq") 张不同的卡，但键名要求 $seq_n 张"
            fi
            duplicates="$(device_list_duplicates "$seq")"
            if [[ -n "$duplicates" ]]; then
                echo "      ${C_RED}INVALID${C_RESET}: 包含重复卡号 [$duplicates]"
            fi
            if [[ "$blacklist_valid" == "1" ]]; then
                outside_seq="$(device_list_intersection "$seq" "$CONF_BLACKLIST_RAW")"
                [[ -z "$outside_seq" ]] || echo "      ${C_RED}INVALID${C_RESET}: 包含黑名单卡 $(format_device_pool "$outside_seq")"
            fi
            if [[ "$whitelist_valid" == "1" && -n "$CONF_WHITELIST_RAW" ]]; then
                outside_seq="$(device_list_difference "$seq" "$CONF_WHITELIST_RAW")"
                if [[ -n "$outside_seq" ]]; then
                    if [[ "$IGNORE_WHITELIST" == "1" ]]; then
                        echo "      ${C_YELLOW}兼容提示${C_RESET}: 其中 $(format_device_pool "$outside_seq") 超出仓库白名单，当前由 --ignore-whitelist 放行"
                    else
                        echo "      ${C_RED}冲突${C_RESET}: 其中 $(format_device_pool "$outside_seq") 超出仓库白名单；提交此固定序列会失败"
                    fi
                fi
            fi
            if [[ "$global_valid" == "1" ]]; then
                outside_seq="$(device_list_difference "$seq" "$GLOBAL_AUTO_POOL")"
            else
                outside_seq=""
            fi
            if [[ -n "$outside_seq" ]]; then
                echo "      ${C_YELLOW}兼容提示${C_RESET}: 其中 $(format_device_pool "$outside_seq") 超出全局 auto 池；固定序列当前仍按显式卡号语义提交"
            fi
        done < <(awk -F= '
            /^[[:space:]]*DEVICE_SEQ_[0-9]+[[:space:]]*=/ {
                key=$1; gsub(/[[:space:]]/, "", key)
                if (!seen[key]++) print key
            }
        ' "$DEVICE_CONF_PATH")
    fi
}

# 每仓“按卡数固定卡号序列”：--device auto --device-num N（含 --device-num N 单用）
# 命中 conf 里的 DEVICE_SEQ_<N> 时，把请求转成显式卡号（精确锁 = 等价于 --device <序列>），
# 不再走 auto 选空闲卡。
# 约束（白名单仍是本仓硬边界，固定序列不得默默越界）：
#   - SEQ 必须落在 DEVICE_WHITELIST 内（白名单非空时）；越界需显式 --ignore-whitelist 放行。
#   - SEQ 不得包含 DEVICE_BLACKLIST 的卡；黑名单是绝对禁用，--ignore-whitelist 也不放行。
# 与显式 --device 不冲突（后者本就不是 auto，走不到这里）。
apply_device_sequence() {
    is_auto_device_request || return 0
    [[ -n "$DEVICE_CONF_PATH" ]] || return 0

    local n="${DEVICE_NUM:-1}"
    is_positive_int "$n" || return 0

    local seq
    seq="$(read_conf_field "DEVICE_SEQ_${n}" "$DEVICE_CONF_PATH")"
    [[ -z "$seq" ]] && return 0

    # 格式校验：逗号分隔的非负整数
    if [[ ! "$seq" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "${C_RED}错误: 配置文件 $DEVICE_CONF_PATH 中 DEVICE_SEQ_${n} 格式无效: '$seq'${C_RESET}" >&2
        echo "${C_DIM}应为逗号分隔的非负整数、个数等于 ${n}，如 DEVICE_SEQ_${n}=0,1,2,3${C_RESET}" >&2
        exit 1
    fi

    # 张数必须与请求卡数一致，否则是配置错误（比如 4 卡只列了 3 张）
    local -a seq_arr
    IFS=',' read -ra seq_arr <<< "$seq"
    if [[ "${#seq_arr[@]}" -ne "$n" ]]; then
        echo "${C_RED}错误: DEVICE_SEQ_${n} 配了 ${#seq_arr[@]} 张卡 [$seq]，与请求的 ${n} 张不一致${C_RESET}" >&2
        echo "${C_DIM}见 $DEVICE_CONF_PATH${C_RESET}" >&2
        exit 1
    fi

    # 卡号不能重复（精确锁重复卡号必然在 daemon 侧锁卡失败）
    local uniq_count
    uniq_count=$(printf '%s\n' "${seq_arr[@]}" | sort -u | wc -l)
    if [[ "$uniq_count" -ne "${#seq_arr[@]}" ]]; then
        echo "${C_RED}错误: DEVICE_SEQ_${n} 存在重复卡号 [$seq]${C_RESET}" >&2
        echo "${C_DIM}见 $DEVICE_CONF_PATH${C_RESET}" >&2
        exit 1
    fi

    # 格式无误的前提下，先按每仓白/黑名单核对再放行。
    local c
    # 黑名单：绝对禁用，即便 --ignore-whitelist 也不放行（与 auto 语义一致：黑名单始终排除）
    if [[ -n "$CONF_BLACKLIST" ]]; then
        local bl=",${CONF_BLACKLIST}," hit=()
        for c in "${seq_arr[@]}"; do
            [[ "$bl" == *",$c,"* ]] && hit+=("$c")
        done
        if [[ ${#hit[@]} -gt 0 ]]; then
            echo "${C_RED}错误: DEVICE_SEQ_${n}=[$seq] 含黑名单卡 [$(IFS=,; echo "${hit[*]}")]，黑名单卡绝不可用${C_RESET}" >&2
            echo "${C_DIM}见 $DEVICE_CONF_PATH（DEVICE_BLACKLIST=$CONF_BLACKLIST）${C_RESET}" >&2
            exit 1
        fi
    fi
    # 白名单：SEQ 必须是白名单子集；越界需 --ignore-whitelist 显式放行
    if [[ -n "$CONF_WHITELIST" ]]; then
        local wl=",${CONF_WHITELIST}," out=()
        for c in "${seq_arr[@]}"; do
            [[ "$wl" == *",$c,"* ]] || out+=("$c")
        done
        if [[ ${#out[@]} -gt 0 ]]; then
            if [[ "$IGNORE_WHITELIST" == "1" ]]; then
                echo "${C_DIM}提示: DEVICE_SEQ_${n} 的卡 [$(IFS=,; echo "${out[*]}")] 超出白名单 [$CONF_WHITELIST]，因 --ignore-whitelist 放行${C_RESET}" >&2
            else
                echo "${C_RED}错误: DEVICE_SEQ_${n}=[$seq] 含超出本仓白名单 [$CONF_WHITELIST] 的卡 [$(IFS=,; echo "${out[*]}")]${C_RESET}" >&2
                echo "${C_DIM}固定序列不得越过本仓白名单；确需越界请加 --ignore-whitelist（或 TASKQUEUE_IGNORE_WHITELIST=1）${C_RESET}" >&2
                echo "${C_DIM}见 $DEVICE_CONF_PATH${C_RESET}" >&2
                exit 1
            fi
        fi
    fi

    # 命中且通过核对：转成显式卡号（精确锁）。清空 DEVICE_NUM 使其不再是 auto 请求，
    # 后续 apply_device_policy / validate_device_* 都会因非 auto 而自然跳过。
    echo "${C_DIM}提示: 命中每仓 DEVICE_SEQ_${n}，固定使用卡 [$seq]（精确锁，忽略 auto 选空闲；卡忙则排队等这几张）${C_RESET}" >&2
    DEVICE_REQUEST_ORIGIN="sequence"
    DEVICE_SEQUENCE_SOURCE="DEVICE_SEQ_${n}@$DEVICE_CONF_PATH"
    LOCK_DEVICE="$seq"
    DEVICE_NUM=""
}

# 把每仓白/黑名单折算进 DEVICE_POOL —— 仅在 --device auto 时生效；显式卡号不受影响
apply_device_policy() {
    is_auto_device_request || return 0

    # 超限开关：忽略每仓白名单上限（黑名单仍生效）。
    # 把 CONF_WHITELIST 清空，后续候选基集自然回退到卡组/全局白名单，
    # 但下面的黑名单扣除逻辑不受影响。
    if [[ "$IGNORE_WHITELIST" == "1" && -n "$CONF_WHITELIST" ]]; then
        echo "${C_DIM}提示: 已开启白名单超限(--ignore-whitelist/TASKQUEUE_IGNORE_WHITELIST)，忽略每仓白名单 [${CONF_WHITELIST}]，回退到全局可用设备${CONF_BLACKLIST:+（黑名单 [${CONF_BLACKLIST}] 仍排除）}${C_RESET}" >&2
        CONF_WHITELIST=""
    fi

    [[ -z "$CONF_WHITELIST" && -z "$CONF_BLACKLIST" ]] && return 0

    local v
    for v in "$CONF_WHITELIST" "$CONF_BLACKLIST"; do
        if [[ -n "$v" && ! "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            echo "${C_RED}错误: 配置文件 $DEVICE_CONF_PATH 中设备列表格式无效: '$v'${C_RESET}" >&2
            echo "${C_DIM}应为逗号分隔的非负整数，如 DEVICE_WHITELIST=0,1,2,3${C_RESET}" >&2
            exit 1
        fi
    done

    # 候选基集：白名单 > 现有环境卡组 > daemon 同口径的全局 auto 池。
    local base=""
    if [[ -n "$CONF_WHITELIST" ]]; then
        base="$CONF_WHITELIST"
    elif [[ -n "$DEVICE_POOL" ]]; then
        base="$DEVICE_POOL"
    else
        base="$GLOBAL_AUTO_POOL"
    fi

    # 扣除黑名单
    local -a base_arr result=()
    local c bl=",${CONF_BLACKLIST},"
    IFS=',' read -ra base_arr <<< "$base"
    for c in "${base_arr[@]}"; do
        [[ -z "$c" ]] && continue
        [[ -n "$CONF_BLACKLIST" && "$bl" == *",$c,"* ]] && continue
        result+=("$c")
    done

    if [[ ${#result[@]} -eq 0 ]]; then
        echo "${C_RED}错误: 配置文件 $DEVICE_CONF_PATH 的白/黑名单排除了所有卡，auto 无卡可分配${C_RESET}" >&2
        echo "${C_DIM}白名单=[${CONF_WHITELIST:-未设}] 黑名单=[${CONF_BLACKLIST:-未设}]${C_RESET}" >&2
        exit 1
    fi
    DEVICE_POOL="$(IFS=,; echo "${result[*]}")"
}

# 校验请求卡数：auto:N 时若"可分配候选卡数 < N"必然永远排队，提交侧当场拦截。
# 候选口径与 daemon find_free_devices 一致：全局白名单(或自动探测) ∩ 卡组 DEVICE_POOL。
validate_device_count() {
    is_auto_device_request || return 0
    local need="${DEVICE_NUM:-1}"
    is_positive_int "$need" || return 0

    # 全局候选与 daemon 完全一致。
    local -a global_arr=()
    IFS=',' read -ra global_arr <<< "$GLOBAL_AUTO_POOL"

    # 与卡组取交集（卡组为空则候选=全局）
    local -a cand=()
    if [[ -n "$DEVICE_POOL" ]]; then
        local -a pool_arr
        local c p
        IFS=',' read -ra pool_arr <<< "$DEVICE_POOL"
        for c in "${global_arr[@]}"; do
            for p in "${pool_arr[@]}"; do
                [[ "$c" == "$p" ]] && { cand+=("$c"); break; }
            done
        done
    else
        cand=("${global_arr[@]}")
    fi

    local avail="${#cand[@]}"
    if [[ "$avail" -lt "$need" ]]; then
        local joined
        joined=$(IFS=,; echo "${cand[*]}")
        echo "${C_RED}错误: 请求 ${need} 张卡，但可分配范围内只有 ${avail} 张 [${joined}]，任务无法满足${C_RESET}" >&2
        if [[ -n "$DEVICE_CONF_PATH" && ( -n "$CONF_WHITELIST" || -n "$CONF_BLACKLIST" ) ]]; then
            echo "${C_DIM}白名单=[${CONF_WHITELIST:-未设}] 黑名单=[${CONF_BLACKLIST:-未设}]（见 $DEVICE_CONF_PATH）${C_RESET}" >&2
        fi
        echo "${C_DIM}请减小 --device-num，或扩大白名单/全局可用设备(task-submit --devices)${C_RESET}" >&2
        exit 1
    fi
}

# 同组校验：本仓 DEVICE_GROUP_AFFINITY=1 时，多卡任务的卡必须落在同一个 HCCS
# plane 卡组内。auto 只要求"存在"一个容得下的组（选哪组交给 daemon，避免提交时
# 就钉死一组、另一组空着也排队）；显式卡号与 DEVICE_SEQ 命中的固定序列则必须整体同组。
# 满足不了就在提交侧报错：跨 plane 通信不会失败返回，而是挂起并把卡楔死。
validate_device_group_affinity() {
    GROUP_AFFINITY_EFFECTIVE=0
    [[ "$CONF_GROUP_AFFINITY" == "1" ]] || return 0

    if [[ -n "$DEVICE_GROUPS" ]] && ! device_groups_valid "$DEVICE_GROUPS"; then
        echo "${C_RED}错误: $CONF_FILE 中 DEVICE_GROUPS 格式无效: '$DEVICE_GROUPS'${C_RESET}" >&2
        echo "${C_DIM}应为分号分隔的卡组、组内逗号分隔、同一张卡不得出现在两个组，如 DEVICE_GROUPS=\"0,1;2,3\"${C_RESET}" >&2
        exit 1
    fi

    # 本次请求要几张卡。单卡（及不占卡）无所谓同不同组，全程不受本约束影响。
    local need=0
    if is_auto_device_request; then
        need="${DEVICE_NUM:-1}"
        is_positive_int "$need" || need=1
    elif [[ -n "$LOCK_DEVICE" && "$LOCK_DEVICE" != "none" &&
            "$LOCK_DEVICE" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        need="$(device_request_count "$LOCK_DEVICE")"
    fi

    if [[ "$IGNORE_GROUP_AFFINITY" == "1" ]]; then
        (( need > 1 )) &&
            echo "${C_YELLOW}警告: --ignore-group-affinity 已关闭同组约束；跨 HCCS plane 的多卡通信会挂起并楔死卡${C_RESET}" >&2
        return 0
    fi

    # 本机没声明拓扑时对多卡 fail-closed。空值表示"拓扑未知"，不等于"所有卡同
    # plane"——后者要管理员显式写成一个大组。猜"全连接"猜错的代价是卡被楔死到
    # 只能等平台带外 reset，报错的代价只是一次带修复指令的提交失败；本仓既然
    # 声明了 DEVICE_GROUP_AFFINITY=1，就是在说它的负载担不起前者。
    if [[ -z "$DEVICE_GROUPS" ]]; then
        (( need > 1 )) || return 0
        echo "${C_RED}错误: 本仓要求同组借卡，但本机未声明卡组拓扑，无法保证 ${need} 张卡落在同一个 HCCS plane${C_RESET}" >&2
        echo "${C_DIM}请在 $CONF_FILE 配置 DEVICE_GROUPS：单 plane 机器写成一个大组（如 \"0,1,2,3\"），${C_RESET}" >&2
        echo "${C_DIM}多 plane 机器按 plane 分组（如 \"0,1;2,3\"）；空值表示拓扑未知，不等于所有卡同 plane${C_RESET}" >&2
        echo "${C_DIM}本仓的要求来自 $DEVICE_CONF_PATH 的 DEVICE_GROUP_AFFINITY=1${C_RESET}" >&2
        echo "${C_DIM}确认本机可跨 plane 时用 --ignore-group-affinity（或 TASKQUEUE_IGNORE_GROUP_AFFINITY=1）临时放行${C_RESET}" >&2
        exit 1
    fi
    GROUP_AFFINITY_EFFECTIVE=1
    (( need > 1 )) || return 0

    local candidates largest
    if is_auto_device_request; then
        candidates="$(device_list_intersection "$GLOBAL_AUTO_POOL" "${DEVICE_POOL:-$GLOBAL_AUTO_POOL}")"
        largest="$(device_group_max_size "$candidates")"
        if (( largest < need )); then
            echo "${C_RED}错误: 请求 ${need} 张同组卡，但候选范围内最大的卡组只有 ${largest} 张，任务无法满足${C_RESET}" >&2
            echo "${C_DIM}本机卡组: $(format_group_breakdown "$GLOBAL_AUTO_POOL")（DEVICE_GROUPS，见 $CONF_FILE）${C_RESET}" >&2
            echo "${C_DIM}本仓候选: $(format_group_breakdown "$candidates")${C_RESET}" >&2
            echo "${C_DIM}$DEVICE_CONF_PATH 设了 DEVICE_GROUP_AFFINITY=1：跨 plane 通信会挂起并楔死卡，故不跨组分配${C_RESET}" >&2
            echo "${C_DIM}请减小 --device-num，或确需跨组时加 --ignore-group-affinity（风险自负）${C_RESET}" >&2
            exit 1
        fi
        return 0
    fi

    if ! device_list_same_group "$LOCK_DEVICE"; then
        local id
        if [[ -n "$DEVICE_SEQUENCE_SOURCE" ]]; then
            echo "${C_RED}错误: 固定序列 [$LOCK_DEVICE] 跨越了 HCCS plane 卡组，多卡通信会挂起并楔死卡${C_RESET}" >&2
            echo "${C_DIM}来源: $DEVICE_SEQUENCE_SOURCE${C_RESET}" >&2
        else
            echo "${C_RED}错误: --device $LOCK_DEVICE 跨越了 HCCS plane 卡组，多卡通信会挂起并楔死卡${C_RESET}" >&2
        fi
        for id in ${LOCK_DEVICE//,/ }; do
            echo "${C_DIM}  卡 $id 属于卡组 [$(device_group_members "$id")]${C_RESET}" >&2
        done
        echo "${C_DIM}本机卡组: $(format_group_breakdown "$GLOBAL_AUTO_POOL")（DEVICE_GROUPS，见 $CONF_FILE）${C_RESET}" >&2
        echo "${C_DIM}请改用同组卡号，或用 --device auto --device-num ${need} 让调度器在组内选${C_RESET}" >&2
        echo "${C_DIM}确需跨组（如 torch_npu 纯 HCCL collective 加 RoCE）请加 --ignore-group-affinity${C_RESET}" >&2
        exit 1
    fi
}

normalize_device_request
DEVICE_REQUEST_RAW="$(build_device_request)"
if is_auto_device_request; then
    DEVICE_REQUEST_ORIGIN="auto"
elif [[ -n "$LOCK_DEVICE" && "$LOCK_DEVICE" != "none" ]]; then
    DEVICE_REQUEST_ORIGIN="explicit"
fi
if [[ "${1:-}" == "--devices" ]]; then
    load_global_auto_pool 1
else
    load_global_auto_pool 0
fi
load_device_conf
apply_device_sequence
apply_device_policy
validate_device_pool
validate_device_count
validate_device_group_affinity

# --interactive 必须搭配 --run（需要实时终端）
if [[ "$INTERACTIVE" == "true" && "$RUN_MODE" != "true" ]]; then
    echo "${C_RED}错误: --interactive 必须搭配 --run 使用${C_RESET}" >&2
    echo "${C_DIM}示例: task-submit -i --run \"python train.py\"${C_RESET}" >&2
    exit 1
fi
if [[ "$INTERACTIVE" == "true" ]] && ! [[ -t 0 ]]; then
    echo "${C_RED}错误: --interactive 需要终端 stdin（当前 stdin 不是终端）${C_RESET}" >&2
    exit 1
fi

# 校验 task-id 格式，防止路径穿越
validate_task_id() {
    local id="$1"
    if [[ ! "$id" =~ ^task_[0-9]{8}_[0-9]{6}_[0-9]+$ ]]; then
        echo "${C_RED}错误: 无效的 task-id 格式${C_RESET}" >&2
        exit 1
    fi
}

# 危险命令过滤（提交时即拦截）
BLOCKED_COMMANDS=(
    "^rm -rf /"
    "mkfs"
    "dd if=.* of=/dev/"
    "> /dev/sd"
    "passwd"
    "userdel"
    "groupdel"
    "visudo"
    "shutdown"
    "reboot"
    "init [0-6]"
)

check_command() {
    local cmd="$1"
    for pattern in "${BLOCKED_COMMANDS[@]}"; do
        if [[ "$cmd" =~ $pattern ]]; then
            return 1
        fi
    done
    return 0
}

canonical_ptoas_dir() {
    local candidate="$1" base_real candidate_real
    base_real="$(readlink -e -- "$PTOAS_BASE" 2>/dev/null)" || return 1
    candidate_real="$(readlink -e -- "$candidate" 2>/dev/null)" || return 1
    case "$candidate_real" in
        "$base_real"/*) ;;
        *) return 1 ;;
    esac
    [[ -x "$candidate_real/ptoas" || -x "$candidate_real/bin/ptoas" ]] || return 1
    printf '%s\n' "$candidate_real"
}

list_ptoas_versions() {
    [[ -d "$PTOAS_BASE" ]] || return 0
    local d version
    for d in "$PTOAS_BASE"/*/; do
        version="${d%/}"
        version="${version##*/}"
        [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || continue
        canonical_ptoas_dir "$d" >/dev/null || continue
        echo "$version"
    done | sort -V
}

resolve_ptoas() {
    [[ -z "$PTOAS_VERSION" ]] && return 0
    if [[ -n "${PTOAS_ROOT:-}" ]]; then
        echo "${C_YELLOW}提示: 已设置 PTOAS_ROOT=$PTOAS_ROOT，忽略 --ptoas $PTOAS_VERSION${C_RESET}" >&2
        return 0
    fi
    if [[ ! "$PTOAS_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
        echo "${C_RED}错误: PTOAS 版本必须是数字版本号（例如 0.54）${C_RESET}" >&2
        exit 1
    fi

    local requested_dir="$PTOAS_BASE/$PTOAS_VERSION"
    local ptoas_dir
    if ! ptoas_dir="$(canonical_ptoas_dir "$requested_dir")"; then
        echo "${C_RED}错误: 未找到可用的 PTOAS 版本 '$PTOAS_VERSION'（需要 $requested_dir/ptoas 或 bin/ptoas）${C_RESET}" >&2
        local available
        available="$(list_ptoas_versions | paste -sd, -)"
        echo "${C_DIM}可用版本: ${available:-（无）}${C_RESET}" >&2
        exit 1
    fi

    EXTRA_ENVS+=("PTOAS_ROOT=$ptoas_dir")
    # 旧版在版本根目录提供包装脚本，由它注入对应 lib/；新版把入口放在
    # bin/。根目录优先、bin/ 兜底可同时兼容两种安装布局。
    EXTRA_ENVS+=("PATH=$ptoas_dir:$ptoas_dir/bin:$PATH")
}

# 提交任务
submit_task() {
    local cmd="$1"

    # Submissions share this lock; the updater takes it exclusively from its
    # final idle check through installation.
    exec 8>"$UPDATE_LOCK" || {
        echo "${C_RED}错误: 无法打开更新协调锁${C_RESET}" >&2
        exit 1
    }
    flock -s 8 || exit 1
    check_maintenance

    # 危险命令在提交侧拦截
    if ! check_command "$cmd"; then
        echo "${C_RED}错误: 命令被拒绝（包含危险操作）${C_RESET}" >&2
        exit 1
    fi

    local device_request
    device_request="$(build_device_request)"

    # auto 模式下检测命令中是否已包含 npu-lock → 报错
    if is_auto_device_request || [[ -z "$LOCK_DEVICE" ]]; then
        if [[ "$cmd" =~ (^|[;&|[:space:]])npu-lock[[:space:]] ]]; then
            echo "${C_RED}错误: 请勿在命令中手动使用 npu-lock，改用 --device N 或 --device auto${C_RESET}" >&2
            exit 1
        fi
    fi

    local task_id="task_$(date +%Y%m%d_%H%M%S)_${$}${RANDOM}"
    local task_file="$PENDING_DIR/$task_id"
    local task_file_tmp="$PENDING_DIR/.${task_id}.task.tmp"
    local env_snapshot="$PENDING_DIR/.${task_id}.env.tmp"

    cat > "$task_file_tmp" <<EOF
SUBMIT_USER=$(whoami)
SUBMIT_TIME=$(date -Iseconds)
WORK_DIR=$(pwd)
COMMAND=$cmd
DEVICE=$device_request
DEVICE_AUTO=$(is_auto_device_request && echo 1 || echo 0)
DEVICE_POOL=$DEVICE_POOL
DEVICE_REQUEST_RAW=$DEVICE_REQUEST_RAW
DEVICE_REQUEST_ORIGIN=$DEVICE_REQUEST_ORIGIN
DEVICE_SEQUENCE_SOURCE=$DEVICE_SEQUENCE_SOURCE
DEVICE_POLICY_CONF=$DEVICE_CONF_PATH
DEVICE_POLICY_WHITELIST=$CONF_WHITELIST_RAW
DEVICE_POLICY_BLACKLIST=$CONF_BLACKLIST_RAW
DEVICE_POLICY_IGNORE_WHITELIST=$IGNORE_WHITELIST
DEVICE_POLICY_ENV_POOL=$ENV_DEVICE_POOL
DEVICE_GLOBAL_POOL=$GLOBAL_AUTO_POOL
DEVICE_GLOBAL_POOL_SOURCE=$GLOBAL_AUTO_POOL_SOURCE
DEVICE_GROUP_AFFINITY=$GROUP_AFFINITY_EFFECTIVE
MAX_TIME=$MAX_TIME
INTERACTIVE=$([[ "$INTERACTIVE" == "true" ]] && echo 1 || echo 0)
EOF
    if [[ $? -ne 0 ]]; then
        echo "${C_RED}错误: 无法写入任务文件${C_RESET}" >&2
        exit 1
    fi
    # 任务元数据需要被所有队列用户读取（例如 task-submit --list），不能继承
    # 提交用户可能设置的严格 umask。
    chmod 644 "$task_file_tmp" || {
        rm -f "$task_file_tmp"
        echo "${C_RED}错误: 无法设置任务文件权限${C_RESET}" >&2
        exit 1
    }

    # 自动快照用户完整环境（黑名单过滤危险/无意义变量）
    # 环境快照可能含敏感信息，始终以 600 创建，不能依赖提交用户的 umask。
    (
        umask 077
        env -0 | while IFS= read -r -d '' line; do
            local key="${line%%=*}"
            case "$key" in
                BASH_*|BASHOPTS|SHELLOPTS|SHELL|SHLVL|_|OLDPWD|PWD) continue ;;
                SSH_*|DISPLAY|TERM|TERMINAL|XDG_*|DBUS_*|WINDOWID|COLORTERM) continue ;;
                LD_PRELOAD|TASKQUEUE_INSIDE) continue ;;
                ASCEND_RT_VISIBLE_DEVICES) continue ;;  # 由 auto 分配管理，不透传用户侧设置
            esac
            printf '%s\0' "$line"
        done > "$env_snapshot"
    )

    # 来源1: TASKQUEUE_ENV_VARS_FILE（每行一个变量名）。不默认读取用户
    # home 下的文件，避免运行依赖于某个账户的 HOME 布局。
    local env_vars_file="${TASKQUEUE_ENV_VARS_FILE:-}"
    if [[ -f "$env_vars_file" ]]; then
        while IFS= read -r varname; do
            [[ -z "$varname" || "$varname" == \#* ]] && continue
            varname="${varname%%[[:space:]]*}"
            if [[ -n "${!varname+x}" ]]; then
                printf '%s=%s\0' "$varname" "${!varname}" >> "$env_snapshot"
            fi
        done < "$env_vars_file"
    fi

    # 来源2: --env 参数（支持 VAR 和 VAR=VAL）
    for entry in "${EXTRA_ENVS[@]}"; do
        if [[ "$entry" == *=* ]]; then
            printf '%s\0' "$entry" >> "$env_snapshot"
        else
            if [[ -n "${!entry+x}" ]]; then
                printf '%s=%s\0' "$entry" "${!entry}" >> "$env_snapshot"
            else
                echo "${C_YELLOW}警告: 环境变量 $entry 未定义，已跳过${C_RESET}" >&2
            fi
        fi
    done

    # 来源3: --env-file 文件（支持 KEY=VAL / export KEY=VAL / # 注释）
    for envfile in "${ENV_FILES[@]}"; do
        if [[ ! -f "$envfile" ]]; then
            echo "${C_YELLOW}警告: 环境变量文件 $envfile 不存在，已跳过${C_RESET}" >&2
            continue
        fi
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            line="${line#export }"
            if [[ "$line" == *=* ]]; then
                local key="${line%%=*}"
                local val="${line#*=}"
                val="${val#\"}" ; val="${val%\"}"
                val="${val#\'}" ; val="${val%\'}"
                printf '%s=%s\0' "$key" "$val" >> "$env_snapshot"
            fi
        done < "$envfile"
    done

    # 先发布私有环境快照，最后原子发布 task_* 文件；daemon 只会看到完整任务，
    # 不会在环境快照尚未写完时提前接管。
    if ! mv "$env_snapshot" "$PENDING_DIR/${task_id}.env" || ! mv "$task_file_tmp" "$task_file"; then
        rm -f "$env_snapshot" "$task_file_tmp" "$PENDING_DIR/${task_id}.env"
        echo "${C_RED}错误: 无法发布任务文件${C_RESET}" >&2
        exit 1
    fi

    echo "$task_id"
}

# 查看任务状态
get_status() {
    local task_id="$1"
    validate_task_id "$task_id"
    if [[ -f "$DONE_DIR/$task_id" ]]; then
        local exit_code
        exit_code=$(grep "^EXIT_CODE=" "$DONE_DIR/$task_id" | cut -d= -f2-)
        if [[ "$exit_code" == "0" ]]; then
            echo "${C_GREEN}completed (exit=0)${C_RESET}"
        else
            echo "${C_RED}completed (exit=${exit_code})${C_RESET}"
        fi
    elif [[ -f "$RUNNING_DIR/$task_id" ]]; then
        echo "${C_YELLOW}running${C_RESET}"
    elif [[ -f "$PENDING_DIR/$task_id" ]]; then
        echo "${C_CYAN}pending${C_RESET}"
    else
        echo "${C_DIM}not_found${C_RESET}"
    fi
}

# 查看日志
show_log() {
    local task_id="$1"
    validate_task_id "$task_id"
    local log_file="$LOGS_DIR/${task_id}.log"
    if [[ -f "$log_file" ]]; then
        cat "$log_file"
    else
        echo "${C_DIM}日志不存在（任务可能尚未开始执行）${C_RESET}" >&2
        exit 1
    fi
}

# 等待任务完成，输出日志
wait_task() {
    local task_id="$1"
    validate_task_id "$task_id"
    local elapsed_ms=0
    local timeout_ms=$((TIMEOUT * 1000))
    local log_file="$LOGS_DIR/${task_id}.log"
    local tail_pid=""

    local fifo_path="$FIFO_DIR/$task_id"
    local stdin_fwd_pid=""
    local _sig_exit=130   # 由 trap 覆写：INT→130，TERM/HUP→143

    # Ctrl+C: 终止远端任务
    _wait_cleanup() {
        [[ -n "$stdin_fwd_pid" ]] && kill "$stdin_fwd_pid" 2>/dev/null && wait "$stdin_fwd_pid" 2>/dev/null
        [[ -n "$tail_pid" ]] && kill "$tail_pid" 2>/dev/null && wait "$tail_pid" 2>/dev/null
        if [[ -f "$PENDING_DIR/$task_id" ]]; then
            # 连同环境快照一并删除：pending/ 是 1777，.env 是提交时的完整 env，
            # 只删任务文件会把它永久遗留在世界可读的目录里。
            rm -f "$PENDING_DIR/$task_id" "$PENDING_DIR/${task_id}.env"
            echo ""
            echo "${C_GREEN}已取消排队中的任务: $task_id${C_RESET}" >&2
        elif [[ -f "$RUNNING_DIR/$task_id" ]]; then
            touch "$KILL_DIR/$task_id" 2>/dev/null
            echo ""
            echo "${C_YELLOW}已发送终止请求: $task_id，等待确认...${C_RESET}" >&2
            local w=0
            while [[ $w -lt 5 ]]; do
                if [[ -f "$DONE_DIR/$task_id" ]]; then
                    echo "${C_GREEN}任务已终止${C_RESET}" >&2
                    exit "$_sig_exit"
                fi
                sleep 1
                w=$((w + 1))
            done
            echo "${C_DIM}任务可能仍在终止中，稍后用 --status 查看${C_RESET}" >&2
        fi
        exit "$_sig_exit"
    }
    # 必须同时捕获 TERM/HUP，不能只捕 INT：CI 取消或重跑 job 时，runner 对整个进程组
    # 发的是 SIGTERM 而非 SIGINT。只捕 INT 的话，客户端被直接打死，_wait_cleanup 不执行，
    # pending 里的任务就成了无主僵尸，日后突然被调度、独占整机的卡跑一个没人要的结果。
    # （2026-07-14：CI 重试 4 次，队列里堆了多个 auto:8 的僵尸任务。）
    trap '_sig_exit=130; _wait_cleanup' INT
    trap '_sig_exit=143; _wait_cleanup' TERM HUP

    # 等待超时：客户端就此退出，任务必须一并了结，否则会变成无主僵尸继续排队 ——
    # 它可能在几十分钟后突然被调度，独占整机的卡去跑一个早已无人认领的结果。
    # （2026-07-14：两个 auto:8 的 CI 任务超时后又排了 47 分钟，随后自行启动并抢走全部 8 张卡。）
    # 仍在 pending 则取消；已经 running 则交给 daemon 的 max-time watchdog，不在此强杀，
    # 以免破坏 “断开后可用 --wait 重连” 的语义。
    _wait_timeout() {
        [[ -n "$stdin_fwd_pid" ]] && kill "$stdin_fwd_pid" 2>/dev/null && wait "$stdin_fwd_pid" 2>/dev/null
        [[ -n "$tail_pid" ]] && kill "$tail_pid" 2>/dev/null && wait "$tail_pid" 2>/dev/null
        echo "${C_RED}错误: 等待超时 (${TIMEOUT}s)${C_RESET}" >&2
        if [[ -f "$PENDING_DIR/$task_id" ]]; then
            rm -f "$PENDING_DIR/$task_id" "$PENDING_DIR/${task_id}.env"
            echo "${C_YELLOW}已取消仍在排队的任务: $task_id（超时前未分配到设备）${C_RESET}" >&2
        elif [[ -f "$RUNNING_DIR/$task_id" ]]; then
            echo "${C_YELLOW}任务仍在运行，将由 daemon 在 --max-time 到期后终止${C_RESET}" >&2
            echo "${C_DIM}重连: task-submit --wait $task_id    立即终止: task-submit --kill $task_id${C_RESET}" >&2
        fi
        trap - INT TERM HUP
        exit 1
    }

    # 快速检查：任务是否已经完成
    if [[ -f "$DONE_DIR/$task_id" ]]; then
        [[ -f "$log_file" ]] && cat "$log_file"
        local exit_code
        exit_code=$(grep "^EXIT_CODE=" "$DONE_DIR/$task_id" | cut -d= -f2-)
        echo "=== 任务已完成 (exit=$exit_code) ==="
        trap - INT TERM HUP
        exit "${exit_code:-1}"
    fi

    echo "${C_DIM}等待任务执行: $task_id (Ctrl+C 终止任务)${C_RESET}" >&2
    while [[ ! -f "$log_file" ]] && [[ $TIMEOUT -eq 0 || $elapsed_ms -lt $timeout_ms ]]; do
        sleep 0.2
        elapsed_ms=$((elapsed_ms + 200))
        # 也可能在等待中就完成了
        if [[ -f "$DONE_DIR/$task_id" ]]; then
            break
        fi
    done

    if [[ ! -f "$log_file" ]] && [[ $TIMEOUT -ne 0 && $elapsed_ms -ge $timeout_ms ]]; then
        _wait_timeout
    fi

    # 实时跟踪日志。必须 -n +1：tail 默认只从最后 10 行开始跟随，而 tail 挂上来之前
    # 任务往往已经输出了几十行（8 卡任务光 npu-lock 就有 16 行），开头会被静默吞掉 ——
    # 表现为“显示获取的卡和实际获取的对不上”，实际锁全拿到了，只是前几行没显示。
    tail -n +1 -f "$log_file" 2>/dev/null &
    tail_pid=$!

    # 等待任务完成
    if [[ "$INTERACTIVE" == "true" ]]; then
        # 交互模式：前台转发 stdin，用 read -t 超时轮询任务状态
        # 等待 FIFO 出现
        while [[ ! -p "$fifo_path" ]] && [[ ! -f "$DONE_DIR/$task_id" ]]; do
            sleep 0.2
        done
        if [[ -p "$fifo_path" ]] && [[ -t 0 ]]; then
            # 前台：每秒超时检查任务是否完成，有输入则立刻转发
            while true; do
                [[ -f "$DONE_DIR/$task_id" ]] && break
                if read -t 1 -r line; then
                    printf '%s\n' "$line" > "$fifo_path" 2>/dev/null || break
                fi
            done
        fi
    else
        while [[ ! -f "$DONE_DIR/$task_id" ]] && [[ $TIMEOUT -eq 0 || $elapsed_ms -lt $timeout_ms ]]; do
            sleep 0.2
            elapsed_ms=$((elapsed_ms + 200))
        done
    fi

    # 等一小段让 tail 输出完毕
    sleep 0.2
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
    tail_pid=""

    if [[ -f "$DONE_DIR/$task_id" ]]; then
        local exit_code
        exit_code=$(grep "^EXIT_CODE=" "$DONE_DIR/$task_id" | cut -d= -f2-)
        if [[ "$exit_code" == "0" ]]; then
            echo "=== ${C_GREEN}任务完成 (exit=0)${C_RESET} ==="
        elif [[ "$exit_code" == "143" ]]; then
            echo "=== ${C_YELLOW}任务已终止 (killed)${C_RESET} ==="
        else
            echo "=== ${C_RED}任务失败 (exit=$exit_code)${C_RESET} ==="
        fi
        trap - INT TERM HUP
        exit "${exit_code:-1}"
    else
        _wait_timeout
    fi
}

# 取消任务
cancel_task() {
    local task_id="$1"
    validate_task_id "$task_id"
    if [[ -f "$PENDING_DIR/$task_id" ]]; then
        rm -f "$PENDING_DIR/$task_id" "$PENDING_DIR/${task_id}.env"
        echo "${C_GREEN}已取消: $task_id${C_RESET}"
    elif [[ -f "$RUNNING_DIR/$task_id" ]]; then
        echo "${C_YELLOW}任务正在执行中，使用 --kill 终止${C_RESET}" >&2
        exit 1
    elif [[ -f "$DONE_DIR/$task_id" ]]; then
        echo "${C_DIM}任务已完成，无需取消${C_RESET}" >&2
    else
        echo "${C_RED}任务不存在: $task_id${C_RESET}" >&2
        exit 1
    fi
}

# 按命令子串查找任务，只输出 task-id，一行一个（供脚本/CI 使用）
#
# 存在的理由：--list 是给人看的，命令列被截断到 77 字符（见 list_tasks），
# 拿它当机器接口解析必然出错 —— CI 的 kill-orphaned-tasks 就 grep 了完整的
# workspace 路径，而该路径的尾段恰好在截断点之后，导致 guard 长期静默失效。
# 这里匹配的是任务文件里的完整 COMMAND，不截断。
find_tasks() {
    local pattern="$1"
    if [[ -z "$pattern" ]]; then
        echo "${C_RED}错误: --find 需要一个匹配子串${C_RESET}" >&2
        echo "${C_DIM}示例: task-submit --find \"\$GITHUB_WORKSPACE/dist-checkout\"${C_RESET}" >&2
        exit 1
    fi
    local d f cmd tid
    for d in "$PENDING_DIR" "$RUNNING_DIR"; do
        for f in "$d"/task_*; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.env ]] && continue
            cmd=$(grep -m1 "^COMMAND=" "$f" 2>/dev/null | cut -d= -f2-)
            [[ "$cmd" == *"$pattern"* ]] || continue
            tid=$(basename "$f")
            echo "$tid"
        done
    done
}

# 终止任务
kill_task() {
    local task_id="$1"
    validate_task_id "$task_id"

    if [[ -f "$DONE_DIR/$task_id" ]]; then
        echo "${C_DIM}任务已完成，无需终止${C_RESET}" >&2
        return 0
    fi

    if [[ -f "$PENDING_DIR/$task_id" ]]; then
        rm -f "$PENDING_DIR/$task_id" "$PENDING_DIR/${task_id}.env"
        echo "${C_GREEN}已取消 (pending): $task_id${C_RESET}"
        return 0
    fi

    if [[ ! -f "$RUNNING_DIR/$task_id" ]]; then
        echo "${C_RED}任务不存在: $task_id${C_RESET}" >&2
        exit 1
    fi

    touch "$KILL_DIR/$task_id"
    echo "${C_YELLOW}已发送终止请求: $task_id，等待确认...${C_RESET}"
    local w=0
    while [[ $w -lt 5 ]]; do
        if [[ -f "$DONE_DIR/$task_id" ]]; then
            echo "${C_GREEN}任务已终止${C_RESET}"
            return 0
        fi
        sleep 1
        w=$((w + 1))
    done
    echo "${C_DIM}任务可能仍在终止中，稍后用 --status 查看${C_RESET}"
}

# 清理过期任务（done + pending）
clean_tasks() {
    local count=0
    for dir in "$DONE_DIR" "$PENDING_DIR"; do
        for f in "$dir"/task_*; do
            [[ -f "$f" ]] || continue
            local task_id
            task_id=$(basename "$f")
            # 跳过 .env 文件，随主文件一起清理
            [[ "$task_id" == *.env ]] && continue
            # 用 -mmin 精确按 N*24h 判定；-mtime +N 会因整日取整而实际保留约 N+1 天
            if [[ $(find "$f" -mmin +"$((CLEAN_DAYS * 1440))" 2>/dev/null) ]]; then
                rm -f "$f" "${f}.env" "$LOGS_DIR/${task_id}.log" "$LOGS_DIR/${task_id}.sh" "$FIFO_DIR/${task_id}"
                count=$((count + 1))
            fi
        done
    done
    echo "已清理 ${count} 个任务（${CLEAN_DAYS} 天前）"
}

# ====== 维护模式 ======

# 检查是否处于维护模式（给提交流程用）
check_maintenance() {
    if [[ -f "$MAINT_FILE" ]]; then
        local reason
        reason=$(head -1 "$MAINT_FILE" 2>/dev/null)
        local since
        since=$(stat -c '%y' "$MAINT_FILE" 2>/dev/null | cut -d. -f1)
        echo ""
        echo "${C_RED}系统维护中，暂停任务提交${C_RESET}"
        [[ -n "$reason" ]] && echo "${C_DIM}原因: $reason${C_RESET}"
        [[ -n "$since" ]]  && echo "${C_DIM}开始: $since${C_RESET}"
        echo "${C_DIM}维护结束后使用: task-submit --maintenance off${C_RESET}"
        echo ""
        exit 1
    fi
}

# 可用设备白名单管理（写入 $BASE_DIR/available_devices）
# 用法:
#   task-submit --devices                  显示当前白名单
#   task-submit --devices status           同上
#   task-submit --devices list             同上（兼容别名）
#   task-submit --devices "2,3,4,5"        设置白名单
#   task-submit --devices reset            清除运行时覆盖（回退静态配置或自动探测）
#
# 写入/清除后通过 SIGHUP 通知 daemon 重新加载到内存，
# 运行时零开销（daemon 不会每次分配设备都读文件）。
notify_daemon_reload() {
    local pid_file="$STATE_DIR/task-daemon.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -HUP "$pid" 2>/dev/null && return 0
        fi
    fi
    return 1
}

devices_cmd() {
    local devices_file="$STATE_DIR/available_devices"
    local action="${1:-status}"

    case "$action" in
        ""|status|list)
            if [[ -f "$devices_file" ]]; then
                local cur
                cur=$(tr -d '[:space:]' < "$devices_file" 2>/dev/null)
                if [[ -n "$cur" ]]; then
                    echo "${C_GREEN}当前可用设备白名单: ${cur}${C_RESET}"
                elif [[ -n "$CONFIG_AUTO_POOL" ]]; then
                    echo "${C_GREEN}当前可用设备白名单: ${CONFIG_AUTO_POOL}${C_RESET} ${C_DIM}(运行时文件为空，回退静态配置 $CONF_FILE)${C_RESET}"
                else
                    echo "${C_DIM}白名单文件存在但为空，按自动探测处理${C_RESET}"
                fi
            elif [[ -n "$CONFIG_AUTO_POOL" ]]; then
                echo "${C_GREEN}当前可用设备白名单: ${CONFIG_AUTO_POOL}${C_RESET} ${C_DIM}(静态配置 $CONF_FILE)${C_RESET}"
            else
                echo "${C_DIM}未设置白名单（自动探测 /dev/davinci*）${C_RESET}"
            fi
            show_device_policy_sources
            ;;
        reset|clear|none)
            if [[ ! -f "$devices_file" ]]; then
                echo "${C_DIM}运行时白名单未设置，无需清除；当前使用 $GLOBAL_AUTO_POOL_SOURCE${C_RESET}"
                return 0
            fi
            if ! rm -f "$devices_file" 2>/dev/null; then
                echo "${C_RED}错误: 无法删除 $devices_file，请使用 sudo${C_RESET}" >&2
                echo "${C_DIM}  sudo task-submit --devices reset${C_RESET}" >&2
                exit 1
            fi
            if notify_daemon_reload; then
                echo "${C_GREEN}运行时白名单已清除，已通知 daemon 回退到 ${CONFIG_AUTO_POOL:+静态配置 }${CONFIG_AUTO_POOL:-自动探测}${C_RESET}"
            else
                echo "${C_GREEN}运行时白名单已清除，将回退到 ${CONFIG_AUTO_POOL:+静态配置 }${CONFIG_AUTO_POOL:-自动探测}${C_RESET}"
                echo "${C_YELLOW}警告: 未能通知 daemon（可能未运行），重启 daemon 后生效${C_RESET}"
            fi
            ;;
        *)
            # 校验格式：逗号分隔的非负整数
            local cleaned
            cleaned=$(echo "$action" | tr -d '[:space:]')
            if [[ ! "$cleaned" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo "${C_RED}错误: 设备列表格式无效: $action${C_RESET}" >&2
                echo "${C_DIM}示例: task-submit --devices \"2,3,4,5\"${C_RESET}" >&2
                exit 1
            fi
            if ! echo "$cleaned" > "$devices_file" 2>/dev/null; then
                echo "${C_RED}错误: 无法写入 $devices_file，请使用 sudo${C_RESET}" >&2
                echo "${C_DIM}  sudo task-submit --devices \"$cleaned\"${C_RESET}" >&2
                exit 1
            fi
            chmod 644 "$devices_file" 2>/dev/null
            if notify_daemon_reload; then
                echo "${C_GREEN}可用设备白名单已更新: ${cleaned}（daemon 已重新加载）${C_RESET}"
            else
                echo "${C_GREEN}可用设备白名单已更新: ${cleaned}${C_RESET}"
                echo "${C_YELLOW}警告: 未能通知 daemon（可能未运行），重启 daemon 后生效${C_RESET}"
            fi
            ;;
    esac
}

# 维护模式管理
maintenance_cmd() {
    local action="${1:-}"
    shift 2>/dev/null || true
    local reason="$*"

    case "$action" in
        on)
            if [[ -f "$MAINT_FILE" ]]; then
                echo "${C_YELLOW}维护模式已处于开启状态${C_RESET}"
                local cur_reason
                cur_reason=$(head -1 "$MAINT_FILE" 2>/dev/null)
                [[ -n "$cur_reason" ]] && echo "${C_DIM}原因: $cur_reason${C_RESET}"
                return 0
            fi
            echo "${reason:-系统维护}" > "$MAINT_FILE" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                echo "${C_RED}错误: 无法创建维护标记文件，请使用 sudo${C_RESET}" >&2
                echo "${C_DIM}  sudo task-submit --maintenance on${C_RESET}" >&2
                exit 1
            fi
            chmod 644 "$MAINT_FILE"
            echo "${C_GREEN}维护模式已开启${C_RESET}"
            [[ -n "$reason" ]] && echo "${C_DIM}原因: $reason${C_RESET}"
            echo ""
            echo "${C_DIM}已提交的 pending 任务将暂停调度，running 任务继续执行${C_RESET}"
            echo "${C_DIM}完成维护后执行: task-submit --maintenance off${C_RESET}"
            ;;
        off)
            if [[ ! -f "$MAINT_FILE" ]]; then
                echo "${C_DIM}维护模式未开启${C_RESET}"
                return 0
            fi
            rm -f "$MAINT_FILE" 2>/dev/null
            if [[ $? -ne 0 ]]; then
                echo "${C_RED}错误: 无法删除维护标记文件，请使用 sudo${C_RESET}" >&2
                echo "${C_DIM}  sudo task-submit --maintenance off${C_RESET}" >&2
                exit 1
            fi
            echo "${C_GREEN}维护模式已关闭，任务调度恢复${C_RESET}"
            ;;
        ""|status)
            if [[ -f "$MAINT_FILE" ]]; then
                local cur_reason
                cur_reason=$(head -1 "$MAINT_FILE" 2>/dev/null)
                local since
                since=$(stat -c '%y' "$MAINT_FILE" 2>/dev/null | cut -d. -f1)
                echo "${C_YELLOW}维护模式: 开启${C_RESET}"
                [[ -n "$cur_reason" ]] && echo "${C_DIM}原因: $cur_reason${C_RESET}"
                [[ -n "$since" ]]  && echo "${C_DIM}开始: $since${C_RESET}"
            else
                echo "${C_GREEN}维护模式: 关闭${C_RESET}"
            fi
            ;;
        *)
            echo "${C_RED}用法: task-submit --maintenance [on [原因] | off | status]${C_RESET}" >&2
            exit 1
            ;;
    esac
}

# 格式化时间差
format_age() {
    local file="$1"
    local now
    now=$(date +%s)
    local mtime
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return
    local diff=$((now - mtime))
    if [[ $diff -lt 60 ]]; then
        echo "${diff}s"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60))m"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600))h"
    else
        echo "$((diff / 86400))d"
    fi
}

# 从 COMMAND 中去掉 npu-lock 包装，还原用户原始命令
strip_npu_lock() {
    local cmd="$1"
    # 去掉 npu-lock N -c "..." 包装
    if [[ "$cmd" =~ ^npu-lock\ [0-9,]+\ -c\ \"(.*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
    # 去掉 npu-lock N -- bash -c "..." 包装（旧格式）
    elif [[ "$cmd" =~ ^npu-lock\ [0-9,]+\ --\ bash\ -c\ \"(.*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
    # 去掉 npu-lock N -- ... 包装（旧格式，无 bash -c）
    elif [[ "$cmd" =~ ^npu-lock\ [0-9,]+\ --\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$cmd"
    fi
}

# 设备占用总览：锁文件由 npu-lock 以 666 权限维护，普通用户无需读取
# 他人的私有任务元数据，也能准确看到队列当前锁定的卡及其提交用户。
show_device_occupancy() {
    local total d p u lf
    total=$(ls -1 /dev/davinci[0-9]* 2>/dev/null | wc -l)
    [[ "$total" =~ ^[0-9]+$ ]] || total=0

    local -A held by_user
    local occupied=0
    for ((d = 0; d < total; d++)); do
        lf="$STATE_DIR/locks/npu_device_${d}.lock"
        [[ -f "$lf" ]] || continue
        p=$(grep -oP 'pid=\K[0-9]+' "$lf" 2>/dev/null)
        # /proc is traversable to all users; unlike kill -0 it does not report
        # EPERM for a live task owned by another submitter.
        [[ -n "$p" && -d "/proc/$p" ]] || continue
        u=$(grep -oP 'user=\K[^ ]+' "$lf" 2>/dev/null)
        held[$d]="${u:-?}"
        occupied=$((occupied + 1))
    done

    echo "${C_BOLD}=== 设备占用 (${occupied}/${total}) ===${C_RESET}"
    if [[ $occupied -eq 0 ]]; then
        echo "  ${C_GREEN}全部空闲${C_RESET}"
    else
        for d in "${!held[@]}"; do
            by_user[${held[$d]}]+="$d "
        done
        local user cards free=""
        for user in "${!by_user[@]}"; do
            cards=$(printf '%s\n' ${by_user[$user]} | sort -n | paste -sd, -)
            echo "  ${C_RED}占用${C_RESET} [$cards] → $user"
        done
        for ((d = 0; d < total; d++)); do
            [[ -z "${held[$d]:-}" ]] && free+="$d,"
        done
        echo "  ${C_GREEN}空闲${C_RESET} [${free%,}]"
    fi
    echo ""
}

# 列出任务（增强版）
list_tasks() {
    local has_any=false

    show_device_occupancy

    # 维护模式横幅
    if [[ -f "$MAINT_FILE" ]]; then
        local reason
        reason=$(head -1 "$MAINT_FILE" 2>/dev/null)
        echo "${C_RED}${C_BOLD}*** 维护模式 — 任务提交与调度已暂停 ***${C_RESET}"
        [[ -n "$reason" ]] && echo "${C_DIM}    原因: $reason${C_RESET}"
        echo ""
    fi

    # Pending
    local pending_files=("$PENDING_DIR"/task_*)
    echo "${C_BOLD}=== Pending ===${C_RESET}"
    if [[ -f "${pending_files[0]}" ]]; then
        for f in "${pending_files[@]}"; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.env ]] && continue
            has_any=true
            local tid
            tid=$(basename "$f")
            local cmd
            cmd=$(strip_npu_lock "$(grep "^COMMAND=" "$f" | cut -d= -f2-)")
            local dev
            dev=$(grep "^DEVICE=" "$f" | cut -d= -f2-)
            local age
            age=$(format_age "$f")
            local dev_tag=""
            [[ -n "$dev" ]] && dev_tag="${C_BOLD}[NPU:${dev}]${C_RESET} "
            [[ ${#cmd} -gt 80 ]] && cmd="${cmd:0:77}..."
            printf "  ${C_CYAN}%-38s${C_RESET} %4s  %s%s\n" "$tid" "$age" "$dev_tag" "$cmd"
        done
        echo ""
    fi

    # Running
    local running_files=("$RUNNING_DIR"/task_*)
    echo "${C_BOLD}=== Running ===${C_RESET}"
    if [[ -f "${running_files[0]}" ]]; then
        for f in "${running_files[@]}"; do
            [[ -f "$f" ]] || continue
            has_any=true
            local tid
            tid=$(basename "$f")
            local cmd
            cmd=$(strip_npu_lock "$(grep "^COMMAND=" "$f" | cut -d= -f2-)")
            local dev
            dev=$(grep "^DEVICE=" "$f" | cut -d= -f2-)
            local age
            age=$(format_age "$f")
            local dev_tag=""
            [[ -n "$dev" ]] && dev_tag="${C_BOLD}[NPU:${dev}]${C_RESET} "
            [[ ${#cmd} -gt 80 ]] && cmd="${cmd:0:77}..."
            printf "  ${C_YELLOW}%-38s${C_RESET} %4s  %s%s\n" "$tid" "$age" "$dev_tag" "$cmd"
        done
        echo ""
    fi

    # Done (最近 20 个)
    local done_files
    done_files=$(ls -t "$DONE_DIR"/task_* 2>/dev/null | head -20)
    echo "${C_BOLD}=== Done (recent 20) ===${C_RESET}"
    if [[ -n "$done_files" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            has_any=true
            local tid
            tid=$(basename "$f")
            local exit_code
            exit_code=$(grep "^EXIT_CODE=" "$f" | cut -d= -f2-)
            local cmd
            cmd=$(strip_npu_lock "$(grep "^COMMAND=" "$f" | cut -d= -f2-)")
            local submit_time finish_time
            submit_time=$(grep "^SUBMIT_TIME=" "$f" | cut -d= -f2-)
            finish_time=$(grep "^FINISH_TIME=" "$f" | cut -d= -f2-)
            local duration=""
            if [[ -n "$submit_time" && -n "$finish_time" ]]; then
                local t0 t1
                t0=$(date -d "$submit_time" +%s 2>/dev/null)
                t1=$(date -d "$finish_time" +%s 2>/dev/null)
                if [[ -n "$t0" && -n "$t1" ]]; then
                    local diff=$((t1 - t0))
                    if [[ $diff -lt 60 ]]; then
                        duration="${diff}s"
                    elif [[ $diff -lt 3600 ]]; then
                        duration="$((diff / 60))m$((diff % 60))s"
                    else
                        duration="$((diff / 3600))h$((diff % 3600 / 60))m"
                    fi
                fi
            fi
            local age
            age=$(format_age "$f")
            [[ ${#cmd} -gt 80 ]] && cmd="${cmd:0:77}..."
            local status_color="$C_GREEN"
            local status_text="ok"
            if [[ "$exit_code" != "0" ]]; then
                status_color="$C_RED"
                status_text="exit=$exit_code"
            fi
            printf "  %-38s %4s  ${C_DIM}%7s${C_RESET}  ${status_color}%-10s${C_RESET} %s\n" "$tid" "$age" "$duration" "$status_text" "$cmd"
        done <<< "$done_files"
        echo ""
    fi

    if [[ "$has_any" == "false" ]]; then
        echo "${C_DIM}(无任务)${C_RESET}"
    fi
}

# 主逻辑
case "${1:-}" in
    --version)
        revision="$(cat "$SCRIPT_DIR/.pto-task-release" 2>/dev/null || true)"
        if [[ -z "$revision" ]] && command -v git >/dev/null 2>&1; then
            revision="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
        fi
        printf 'pto-task revision %s\n' "${revision:-unknown}"
        ;;
    --wait)
        [[ -z "${2:-}" ]] && usage
        wait_task "$2"
        ;;
    --status)
        [[ -z "${2:-}" ]] && usage
        get_status "$2"
        ;;
    --log)
        [[ -z "${2:-}" ]] && usage
        show_log "$2"
        ;;
    --cancel)
        [[ -z "${2:-}" ]] && usage
        cancel_task "$2"
        ;;
    --kill)
        [[ -z "${2:-}" ]] && usage
        kill_task "$2"
        ;;
    --list)
        list_tasks
        ;;
    --clean)
        # 前置选项循环遇到 --clean 即 break，故这里再解析尾随的 --days，使
        # `task-submit --clean --days N`（cron 用法）也能正确生效
        shift
        while [[ "${1:-}" == --* ]]; do
            case "$1" in
                --days) CLEAN_DAYS="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        clean_tasks
        ;;
    --maintenance)
        maintenance_cmd "${@:2}"
        ;;
    --devices)
        devices_cmd "${@:2}"
        ;;
    --find)
        find_tasks "${2:-}"
        ;;
    --stats)
        if [[ -x "$SCRIPT_DIR/pto-task-stats" ]]; then
            exec "$SCRIPT_DIR/pto-task-stats" "${@:2}"
        else
            exec bash "$SCRIPT_DIR/pto-task-stats.sh" "${@:2}"
        fi
        ;;
    --help|-h|"")
        usage
        ;;
    *)
        # 兜底：任务命令不应以 -- 开头。走到这里说明选项解析出了问题，
        # 提交下去只会得到一个必然失败的任务（且可能已锁卡），故直接拒绝。
        if [[ "$1" == --* ]]; then
            echo "${C_RED}错误: 无法把 '$1' 当作任务命令执行${C_RESET}" >&2
            echo "${C_DIM}命令请用引号包裹，例如: task-submit --run \"python train.py\"${C_RESET}" >&2
            exit 1
        fi
        resolve_ptoas
        task_id=$(submit_task "$1")
        show_eight_card_policy_notice "$(build_device_request)"
        if [[ "$RUN_MODE" == "true" ]]; then
            echo "${C_DIM}任务已提交: $task_id (断开后可用 task-submit --wait $task_id 重连)${C_RESET}" >&2
            wait_task "$task_id"
        else
            echo "$task_id"
        fi
        ;;
esac
