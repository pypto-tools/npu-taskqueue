#!/usr/bin/env bash
# Install the task queue without starting or restarting the main daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="/home/pypto-tools"
TOOL_NAME="pto-task"
INIT_CONFIG=true
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
ENABLE_AUTO_UPDATE=true
MAX_CONCURRENT_OVERRIDE=""
MAX_TIME_HARD_CAP_OVERRIDE=""
AVAILABLE_DEVICES_OVERRIDE=""
AVAILABLE_DEVICES_SET=false
TASK_EXECUTION_MODE_OVERRIDE=""
PTOAS_BASE_OVERRIDE=""
INTERACTIVE_CONFIG="auto"

usage() {
    cat <<'EOF'
Usage: sudo bash setup.sh [OPTIONS]

Install program files below DIR/pto-task/app (default: /home/pypto-tools) and
create config/taskqueue.conf when it is missing. Existing configuration and
queue state are preserved unless a configuration option below is explicitly
passed. The installer never starts the main daemon.
The repository-controlled automatic update timer is enabled by default for
root installations. Use --disable-auto-update to opt out.

  --tools-root DIR             Installation parent directory
  --no-init-config             Do not create a missing configuration
  --max-concurrent N           Set maximum simultaneously running jobs
  --max-time-hard-cap SECONDS  Set server-side task duration cap (0 = unlimited)
  --available-devices LIST     Set the auto-allocation pool (for example 0,1,2,3)
  --task-execution-mode MODE   HwHiAiUser or root
  --ptoas-base DIR             Root containing installed PTOAS versions
  --interactive-config        Prompt for first-install host settings
  --non-interactive           Never prompt; use options/detected defaults
  --enable-auto-update        Enable main-repository rollout control
  --disable-auto-update       Disable repository-controlled automatic updates
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tools-root)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--tools-root needs a directory" >&2; exit 2; }
            TOOLS_ROOT="$2"; shift 2 ;;
        --init-config) INIT_CONFIG=true; shift ;; # Kept for compatibility.
        --no-init-config) INIT_CONFIG=false; shift ;;
        --max-concurrent)
            [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "--max-concurrent needs a positive integer" >&2; exit 2; }
            MAX_CONCURRENT_OVERRIDE="$2"; shift 2 ;;
        --max-time-hard-cap)
            [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--max-time-hard-cap needs a non-negative integer" >&2; exit 2; }
            MAX_TIME_HARD_CAP_OVERRIDE="$2"; shift 2 ;;
        --available-devices)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--available-devices needs a comma-separated list or auto" >&2; exit 2; }
            if [[ "$2" == auto ]]; then
                AVAILABLE_DEVICES_OVERRIDE=""
            elif [[ "$2" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                AVAILABLE_DEVICES_OVERRIDE="$2"
            else
                echo "--available-devices must be auto or comma-separated device numbers" >&2
                exit 2
            fi
            AVAILABLE_DEVICES_SET=true; shift 2 ;;
        --task-execution-mode)
            [[ "${2:-}" == HwHiAiUser || "${2:-}" == root ]] || { echo "--task-execution-mode must be HwHiAiUser or root" >&2; exit 2; }
            TASK_EXECUTION_MODE_OVERRIDE="$2"; shift 2 ;;
        --ptoas-base)
            [[ "${2:-}" == /* ]] || { echo "--ptoas-base needs an absolute path" >&2; exit 2; }
            PTOAS_BASE_OVERRIDE="${2%/}"; shift 2 ;;
        --interactive-config) INTERACTIVE_CONFIG=true; shift ;;
        --non-interactive) INTERACTIVE_CONFIG=false; shift ;;
        --enable-auto-update) ENABLE_AUTO_UPDATE=true; shift ;;
        --disable-auto-update) ENABLE_AUTO_UPDATE=false; shift ;;
        # Compatibility aliases from the short-lived dual-updater interface.
        --enable-repo-auto-update) ENABLE_AUTO_UPDATE=true; shift ;;
        --disable-repo-auto-update) ENABLE_AUTO_UPDATE=false; shift ;;
        --bin-dir) # Test hook; production default is /usr/local/bin.
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"; shift 2 ;;
        --sbin-dir) # Test hook for removing the former daemon alias.
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--sbin-dir needs a directory" >&2; exit 2; }
            SBIN_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TOOL_ROOT="${TOOLS_ROOT%/}/$TOOL_NAME"
APP_DIR="$TOOL_ROOT/app"
SCHEDULER_APP_DIR="$APP_DIR/schedulers"
APP_LIB_DIR="$APP_DIR/lib"
REPO_UPDATE_MODULE_DIR="$APP_LIB_DIR/repo-auto-update"
CONFIG_DIR="$TOOL_ROOT/config"
STATE_DIR="$TOOL_ROOT/state"
LOGS_DIR="$TOOL_ROOT/logs"
TMP_DIR="$TOOL_ROOT/tmp"
UPDATE_DIR="$TOOL_ROOT/update"
CONFIG_FILE="$CONFIG_DIR/taskqueue.conf"
REPO_UPDATE_CONFIG="$CONFIG_DIR/repo-auto-update.env"
PYPTO_CONFIG_FILE="$CONFIG_DIR/pypto-env.conf"
LEGACY_CONFIG_FILE="/etc/taskqueue.conf"
LEGACY_PYPTO_CONFIG_FILE="/etc/pypto-env.conf"

# Read the simple KEY=value format used by the former /etc/taskqueue.conf
# without sourcing shell code as root.
read_simple_config_key() {
    local key="$1" file="$2" line value
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$key="* ]] || continue
        value="${line#*=}"
        value="${value%%[[:space:]]#*}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        printf '%s' "$value"
        return 0
    done < "$file"
    return 1
}

set_config_value() {
    local key="$1" value="$2" rendered tmp
    printf -v rendered '%s=%q' "$key" "$value"
    tmp="$(mktemp "$CONFIG_DIR/.taskqueue.conf.XXXXXX")"
    CONFIG_KEY="$key" CONFIG_RENDERED="$rendered" awk '
        BEGIN { key = ENVIRON["CONFIG_KEY"]; rendered = ENVIRON["CONFIG_RENDERED"] }
        index($0, key "=") == 1 { if (!seen++) print rendered; next }
        { print }
        END { if (!seen) print rendered }
    ' "$CONFIG_FILE" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

detect_device_count() {
    local count=0
    local devices=(/dev/davinci[0-9]*)
    if [[ -e "${devices[0]}" ]]; then
        count="${#devices[@]}"
    elif command -v npu-smi >/dev/null 2>&1; then
        count="$(timeout 5 npu-smi info -l 2>/dev/null | grep -c 'NPU ID' || true)"
    fi
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || count=0
    printf '%s' "$count"
}

device_list_for_count() {
    local count="$1" id list=""
    for ((id = 0; id < count; id++)); do
        list+="${list:+,}$id"
    done
    printf '%s' "$list"
}

prompt_initial_config() {
    local detected_count card_default card_count concurrency_default answer
    detected_count="$(detect_device_count)"
    card_default="$detected_count"
    [[ "$card_default" -gt 0 ]] || card_default=0

    printf '\n首次部署配置（直接回车使用方括号内的值）\n' >&2
    if [[ "$AVAILABLE_DEVICES_SET" == false ]]; then
        if (( card_default > 0 )); then
            read -r -p "NPU 卡数量，卡号按 0..N-1 配置 [$card_default]: " answer
        else
            read -r -p 'NPU 卡数量（0 表示运行时自动探测） [0]: ' answer
        fi
        card_count="${answer:-$card_default}"
        [[ "$card_count" =~ ^[0-9]+$ ]] || {
            echo "error: NPU 卡数量必须是非负整数" >&2
            exit 2
        }
        if (( card_count > 0 )); then
            AVAILABLE_DEVICES_OVERRIDE="$(device_list_for_count "$card_count")"
            AVAILABLE_DEVICES_SET=true
        fi
    else
        card_count="$(awk -F, '{ print NF }' <<< "$AVAILABLE_DEVICES_OVERRIDE")"
    fi

    if [[ -z "$MAX_CONCURRENT_OVERRIDE" ]]; then
        concurrency_default="${card_count:-0}"
        (( concurrency_default > 0 )) || concurrency_default=10
        read -r -p "最大并发任务数 [$concurrency_default]: " answer
        MAX_CONCURRENT_OVERRIDE="${answer:-$concurrency_default}"
        [[ "$MAX_CONCURRENT_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || {
            echo "error: 最大并发任务数必须是正整数" >&2
            exit 2
        }
    fi
    printf '\n' >&2
}

# Reinstalling normally preserves local data and modes. The four client-facing
# state directories are an exception: their sticky, world-writable mode is a
# runtime requirement, so repair it on every install (including migrations
# from older releases that created them with the caller's umask).
ensure_dir() {
    local mode="$1" dir="$2"
    [[ -d "$dir" ]] || install -d -m "$mode" "$dir"
}

# Install managed app files by renaming a fresh inode from the same directory.
# mv -T replaces a leaf symlink itself (including a symlink to a directory)
# instead of following it, while the same-directory rename is atomic.
finish_app_file() {
    local temp="$1" destination="$2" mode="$3"
    if [[ -d "$destination" && ! -L "$destination" ]]; then
        rm -f "$temp"
        echo "error: managed application file is a directory: $destination" >&2
        return 1
    fi
    chmod "$mode" "$temp"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$temp"
    fi
    mv -Tf -- "$temp" "$destination"
}

install_app_file() {
    local source="$1" destination="$2" mode="$3" temp
    temp="$(mktemp "$APP_DIR/.pto-task-install.XXXXXX")"
    if ! install -m "$mode" "$source" "$temp"; then
        rm -f "$temp"
        return 1
    fi
    finish_app_file "$temp" "$destination" "$mode"
}

write_app_file() {
    local destination="$1" mode="$2" content="$3" temp
    temp="$(mktemp "$APP_DIR/.pto-task-write.XXXXXX")"
    if ! printf '%s' "$content" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    finish_app_file "$temp" "$destination" "$mode"
}

# Open lock files without following the final path component, validate the
# opened inode, and change metadata through that descriptor. Existing files
# must be opened without O_CREAT: Linux protected_regular can reject an
# O_CREAT open of another user's file in a sticky directory even for the root
# updater. Missing files are created separately with O_CREAT|O_EXCL. Existing
# inodes are never replaced or truncated, so active flock users stay synced.
repair_lock_metadata() {
    local root_owner=false
    (( $# > 0 )) || return 0
    command -v python3 >/dev/null 2>&1 || {
        echo "error: python3 is required for safe lock-file setup" >&2
        exit 1
    }
    [[ "$(id -u)" -ne 0 ]] || root_owner=true
    python3 -I - "$root_owner" "$@" <<'PY'
import os
import stat
import sys


def fail(path, message):
    print(f"error: unsafe lock file {path}: {message}", file=sys.stderr)
    raise SystemExit(1)


root_owner = sys.argv[1] == "true"
if not hasattr(os, "O_NOFOLLOW"):
    fail("<platform>", "O_NOFOLLOW is unavailable")

base_flags = os.O_WRONLY | os.O_APPEND | os.O_NONBLOCK | os.O_NOFOLLOW
base_flags |= getattr(os, "O_CLOEXEC", 0)
old_umask = os.umask(0)
try:
    for path in sys.argv[2:]:
        parent, name = os.path.split(path)
        if not parent or not name or name in (".", ".."):
            fail(path, "invalid path")
        dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        dir_flags |= getattr(os, "O_CLOEXEC", 0)
        try:
            dir_fd = os.open(parent, dir_flags)
        except OSError as exc:
            fail(path, f"cannot open lock directory: {exc.strerror}")
        try:
            for attempt in range(2):
                try:
                    fd = os.open(name, base_flags, dir_fd=dir_fd)
                    break
                except FileNotFoundError:
                    try:
                        fd = os.open(
                            name,
                            base_flags | os.O_CREAT | os.O_EXCL,
                            0o666,
                            dir_fd=dir_fd,
                        )
                        break
                    except FileExistsError:
                        if attempt == 0:
                            continue
                        fail(path, "path kept changing while creating lock")
                    except OSError as exc:
                        fail(path, f"cannot create lock safely: {exc.strerror}")
                except OSError as exc:
                    fail(path, f"cannot open without following links: {exc.strerror}")
            else:
                fail(path, "cannot open lock after creation race")
            try:
                opened = os.fstat(fd)
                if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
                    fail(path, "must be a regular file with one link")
                try:
                    current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
                except OSError as exc:
                    fail(path, f"cannot verify opened path: {exc.strerror}")
                if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                    fail(path, "path changed while opening")
                if root_owner:
                    os.fchown(fd, 0, 0)
                os.fchmod(fd, 0o666)
                try:
                    current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
                except OSError as exc:
                    fail(path, f"cannot verify repaired path: {exc.strerror}")
                if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                    fail(path, "path changed while repairing metadata")
            finally:
                os.close(fd)
        finally:
            os.close(dir_fd)
finally:
    os.umask(old_umask)
PY
}

prepare_state_layout() {
    local state_dir="$1" lock_file
    local -a device_lock_files=()
    [[ "$state_dir" == /* && "$state_dir" != / ]] || {
        echo "error: STATE_DIR must be an absolute directory other than /" >&2
        exit 1
    }
    for managed_state_dir in "$state_dir" "$state_dir/pending" "$state_dir/locks" \
        "$state_dir/kill" "$state_dir/fifo" "$state_dir/running" \
        "$state_dir/done" "$state_dir/usage"; do
        [[ ! -L "$managed_state_dir" ]] || {
            echo "error: managed state directory must not be a symlink: $managed_state_dir" >&2
            exit 1
        }
    done
    ensure_dir 755 "$state_dir"
    ensure_dir 1777 "$state_dir/pending"
    ensure_dir 1777 "$state_dir/locks"
    ensure_dir 1777 "$state_dir/kill"
    ensure_dir 1777 "$state_dir/fifo"
    ensure_dir 755 "$state_dir/running"
    ensure_dir 755 "$state_dir/done"
    ensure_dir 755 "$state_dir/usage"
    chmod 1777 "$state_dir/pending" "$state_dir/locks" "$state_dir/kill" "$state_dir/fifo"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$state_dir" "$state_dir/pending" "$state_dir/locks" \
            "$state_dir/kill" "$state_dir/fifo" "$state_dir/running" \
            "$state_dir/done" "$state_dir/usage"
    fi

    lock_file="$state_dir/locks/update-reservation.lock"
    repair_lock_metadata "$lock_file"

    # Device locks are intentionally persistent. Older versions could leave a
    # user-owned 0600/0644 file behind, preventing the next submitter from
    # opening the same device lock. The descriptor helper rejects links and
    # other unsafe entries before changing any metadata.
    mapfile -d '' -t device_lock_files < <(
        find "$state_dir/locks" -maxdepth 1 -name 'npu_device_*.lock' -print0
    )
    repair_lock_metadata "${device_lock_files[@]}"
}

precreate_device_locks() {
    local state_dir="$1" configured_devices="$2" count id lock_file
    local -a device_ids=()
    if [[ -n "$configured_devices" ]]; then
        IFS=',' read -r -a device_ids <<< "$configured_devices"
    fi
    # AVAILABLE_DEVICES limits automatic allocation, but users may explicitly
    # request another physical card. Pre-create the union so those legitimate
    # locks also remain root:root instead of being first-created by a user.
    count="$(detect_device_count)"
    for ((id = 0; id < count; id++)); do
        device_ids+=("$id")
    done

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        [[ "$id" =~ ^[0-9]+$ ]] || {
            echo "error: invalid device id in AVAILABLE_DEVICES: $id" >&2
            exit 2
        }
        lock_file="$state_dir/locks/npu_device_${id}.lock"
        repair_lock_metadata "$lock_file"
    done < <(printf '%s\n' "${device_ids[@]}" | sort -n -u)
}

if [[ "$INIT_CONFIG" == true && ! -e "$CONFIG_FILE" ]]; then
    if [[ "$INTERACTIVE_CONFIG" == true ||
          ("$INTERACTIVE_CONFIG" == auto && -t 0) ]]; then
        prompt_initial_config
    fi
fi

# Reject managed-directory symlinks before creating or repairing anything
# below them. setup.sh normally runs as root, so following a legacy
# user-created symlink here could otherwise change metadata outside the
# installation tree.
if [[ "$(id -u)" -eq 0 ]]; then
    for managed_dir in "$TOOL_ROOT" "$APP_DIR" "$SCHEDULER_APP_DIR" "$APP_LIB_DIR" \
        "$REPO_UPDATE_MODULE_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOGS_DIR" "$TMP_DIR" \
        "$UPDATE_DIR"; do
        [[ ! -L "$managed_dir" ]] || {
            echo "error: managed installation directory must not be a symlink: $managed_dir" >&2
            exit 1
        }
    done
fi

ensure_dir 755 "$APP_DIR"
ensure_dir 755 "$SCHEDULER_APP_DIR"
ensure_dir 755 "$APP_LIB_DIR"
ensure_dir 755 "$REPO_UPDATE_MODULE_DIR"
ensure_dir 755 "$CONFIG_DIR"
ensure_dir 755 "$LOGS_DIR"
ensure_dir 755 "$TMP_DIR"
ensure_dir 755 "$UPDATE_DIR"
prepare_state_layout "$STATE_DIR"

# Root system units execute files from APP_DIR, so keep the installed code
# directories root-owned and non-writable by other users.
if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$TOOL_ROOT" "$APP_DIR" "$SCHEDULER_APP_DIR" "$APP_LIB_DIR" \
        "$REPO_UPDATE_MODULE_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$TMP_DIR" "$UPDATE_DIR"
    chmod go-w "$TOOL_ROOT" "$APP_DIR" "$SCHEDULER_APP_DIR" "$APP_LIB_DIR" \
        "$REPO_UPDATE_MODULE_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$TMP_DIR" "$UPDATE_DIR"
fi
install_app_file "$SCRIPT_DIR/task-submit.sh" "$APP_DIR/task-submit" 755
install_app_file "$SCRIPT_DIR/pypto-setup.sh" "$APP_DIR/pypto-setup" 755
# Install the shared core first, then policies, and replace the daemon last.
# Policy modules retain an API-v1 upgrade bridge, so every intermediate state
# remains restartable if a file-by-file installation is interrupted.
install_app_file "$SCRIPT_DIR/schedulers/_core.sh" "$SCHEDULER_APP_DIR/_core.sh" 644
for scheduler_source in "$SCRIPT_DIR"/schedulers/*.sh; do
    [[ -f "$scheduler_source" ]] || continue
    [[ "$(basename "$scheduler_source")" != _core.sh ]] || continue
    install_app_file "$scheduler_source" "$SCHEDULER_APP_DIR/$(basename "$scheduler_source")" 644
done
install_app_file "$SCRIPT_DIR/task-daemon.sh" "$APP_DIR/task-daemon" 755
install_app_file "$SCRIPT_DIR/npu_lock.sh" "$APP_DIR/npu_lock.sh" 755
install_app_file "$SCRIPT_DIR/scripts/repo-auto-update-deploy.sh" \
    "$APP_DIR/pto-task-repo-update-deploy" 755
install_app_file "$SCRIPT_DIR/modules/repo_auto_update/updater.sh" \
    "$REPO_UPDATE_MODULE_DIR/updater.sh" 755
install_app_file "$SCRIPT_DIR/modules/repo_auto_update/manifest.py" \
    "$REPO_UPDATE_MODULE_DIR/manifest.py" 755
install_app_file "$SCRIPT_DIR/scripts/repo-auto-update-adapter.sh" \
    "$APP_DIR/pto-task-repo-update-verify" 755
install_app_file "$SCRIPT_DIR/scripts/repo-auto-update-adapter.sh" \
    "$APP_DIR/pto-task-repo-update-apply" 755
# Remove application artifacts from the retired branch-HEAD updater and the
# short-lived dual-channel unit names. These are managed files, not local state.
for retired_update_file in "$APP_DIR/pto-task-auto-update" \
    "$APP_DIR/pto-task-repo-auto-update.service" \
    "$APP_DIR/pto-task-repo-auto-update.timer" \
    "$APP_DIR/.pto-task-update-repository"; do
    if [[ -d "$retired_update_file" && ! -L "$retired_update_file" ]]; then
        echo "error: retired updater artifact is unexpectedly a directory: $retired_update_file" >&2
        exit 1
    fi
    rm -f -- "$retired_update_file"
done
install_app_file "$SCRIPT_DIR/pto-task-usage-sampler.sh" "$APP_DIR/pto-task-usage-sampler" 755
install_app_file "$SCRIPT_DIR/pto-task-stats.sh" "$APP_DIR/pto-task-stats" 755
rendered_service="$(sed "s|/home/pypto-tools/pto-task/app|$APP_DIR|g" "$SCRIPT_DIR/pto-task.service")"
write_app_file "$APP_DIR/pto-task.service" 644 "$rendered_service"$'\n'
rendered_usage_service="$(sed "s|/home/pypto-tools/pto-task/app|$APP_DIR|g" "$SCRIPT_DIR/pto-task-usage-sampler.service")"
write_app_file "$APP_DIR/pto-task-usage-sampler.service" 644 "$rendered_usage_service"$'\n'
install_app_file "$SCRIPT_DIR/pto-task-usage-sampler.timer" "$APP_DIR/pto-task-usage-sampler.timer" 644
rendered_clean_cron="$(sed "s|/usr/local/bin/task-submit|$BIN_DIR/task-submit|g" "$SCRIPT_DIR/pto-task-clean.cron")"
write_app_file "$APP_DIR/pto-task-clean.cron" 644 "$rendered_clean_cron"$'\n'
# The administrator already chose to execute this checkout as root, so trust
# exactly this path for the read-only revision lookup without changing global
# Git safe.directory configuration.
SOURCE_REVISION="$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
SOURCE_REVISION="${SOURCE_REVISION:-unknown}"
printf -v install_options \
    'BIN_DIR=%q\nSBIN_DIR=%q\nINSTALL_ENABLE_AUTO_UPDATE=%q\n' \
    "$BIN_DIR" "$SBIN_DIR" "$ENABLE_AUTO_UPDATE"
write_app_file "$APP_DIR/.pto-task-install-options" 600 "$install_options"

if [[ ! -e "$REPO_UPDATE_CONFIG" ]]; then
    rendered_repo_update_config="$(sed \
        -e "s|@TOOL_ROOT@|$TOOL_ROOT|g" \
        -e "s|@TMP_DIR@|$TMP_DIR|g" \
        -e "s|@APP_DIR@|$APP_DIR|g" \
        "$SCRIPT_DIR/config/repo-auto-update.env.in")"
    write_app_file "$REPO_UPDATE_CONFIG" 644 "$rendered_repo_update_config"$'\n'
fi

if [[ "$INIT_CONFIG" == true && ! -e "$PYPTO_CONFIG_FILE" ]]; then
    pypto_config_source="$SCRIPT_DIR/config/pypto-env.conf"
    if [[ "$(id -u)" -eq 0 && -e "$LEGACY_PYPTO_CONFIG_FILE" ]]; then
        if [[ -f "$LEGACY_PYPTO_CONFIG_FILE" && ! -L "$LEGACY_PYPTO_CONFIG_FILE" &&
              "$(stat -c %u "$LEGACY_PYPTO_CONFIG_FILE")" -eq 0 &&
              "$(stat -c %h "$LEGACY_PYPTO_CONFIG_FILE")" -eq 1 &&
              $((8#$(stat -c %a "$LEGACY_PYPTO_CONFIG_FILE") & 8#022)) -eq 0 ]]; then
            pypto_config_source="$LEGACY_PYPTO_CONFIG_FILE"
            printf 'Importing legacy pypto environment config from: %s\n' \
                "$LEGACY_PYPTO_CONFIG_FILE"
        else
            printf 'Warning: ignored unsafe legacy configuration: %s\n' \
                "$LEGACY_PYPTO_CONFIG_FILE" >&2
        fi
    fi
    install_app_file "$pypto_config_source" "$PYPTO_CONFIG_FILE" 644
fi

if [[ "$INIT_CONFIG" == true && ! -e "$CONFIG_FILE" ]]; then
    initial_state_dir="$STATE_DIR"
    initial_logs_dir="$LOGS_DIR"
    legacy_max_concurrent=""
    if [[ "$(id -u)" -eq 0 && -f "$LEGACY_CONFIG_FILE" ]]; then
        legacy_config_safe=true
        if [[ -L "$LEGACY_CONFIG_FILE" ]] ||
           [[ "$(stat -c %u "$LEGACY_CONFIG_FILE")" -ne 0 ]] ||
           [[ $((8#$(stat -c %a "$LEGACY_CONFIG_FILE") & 8#022)) -ne 0 ]]; then
            legacy_config_safe=false
            printf 'Warning: ignored unsafe legacy configuration: %s\n' "$LEGACY_CONFIG_FILE" >&2
        fi
        if [[ "$legacy_config_safe" == true ]]; then
            legacy_base_dir="$(read_simple_config_key BASE_DIR "$LEGACY_CONFIG_FILE" || true)"
            if [[ "$legacy_base_dir" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
                initial_state_dir="${legacy_base_dir%/}"
                initial_logs_dir="${legacy_base_dir%/}/logs"
                legacy_max_concurrent="$(read_simple_config_key MAX_CONCURRENT "$LEGACY_CONFIG_FILE" || true)"
                printf 'Importing legacy queue state from: %s\n' "$initial_state_dir"
            fi
        fi
    fi
    umask 077
    {
        printf '# Local taskqueue configuration. Preserved by setup.sh updates.\n'
        printf 'STATE_DIR=%q # 队列持久状态目录\n' "$initial_state_dir"
        printf 'LOGS_DIR=%q # 任务与 daemon 日志目录\n' "$initial_logs_dir"
        sed -n '/^MAX_CONCURRENT=/,$p' "$SCRIPT_DIR/config/default.conf"
    } > "$CONFIG_FILE"
    # Clients source this non-secret queue configuration before submitting a
    # task, so every local user needs read access.  Credentials must never be
    # stored here.
    chmod 644 "$CONFIG_FILE"
    if [[ "$legacy_max_concurrent" =~ ^[1-9][0-9]*$ ]]; then
        set_config_value MAX_CONCURRENT "$legacy_max_concurrent"
    fi
fi

# A root daemon sources this file as shell code. Refuse symlinks and enforce
# administrator-only write access before editing it or installing system units.
if [[ "$(id -u)" -eq 0 && -e "$CONFIG_FILE" ]]; then
    [[ ! -L "$CONFIG_DIR" && ! -L "$CONFIG_FILE" ]] || {
        echo "error: configuration directory and file must not be symlinks" >&2
        exit 1
    }
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE"
    chmod go-w "$CONFIG_DIR" "$CONFIG_FILE"
fi
if [[ "$(id -u)" -eq 0 && -e "$REPO_UPDATE_CONFIG" ]]; then
    [[ ! -L "$REPO_UPDATE_CONFIG" && -f "$REPO_UPDATE_CONFIG" &&
       "$(stat -c %h "$REPO_UPDATE_CONFIG")" -eq 1 ]] || {
        echo "error: unsafe repository-update configuration: $REPO_UPDATE_CONFIG" >&2
        exit 1
    }
    chown root:root "$REPO_UPDATE_CONFIG"
    chmod go-w "$REPO_UPDATE_CONFIG"
fi
if [[ "$(id -u)" -eq 0 && -e "$PYPTO_CONFIG_FILE" ]]; then
    [[ ! -L "$PYPTO_CONFIG_FILE" && -f "$PYPTO_CONFIG_FILE" &&
       "$(stat -c %h "$PYPTO_CONFIG_FILE")" -eq 1 ]] || {
        echo "error: unsafe pypto environment configuration: $PYPTO_CONFIG_FILE" >&2
        exit 1
    }
    chown root:root "$PYPTO_CONFIG_FILE"
    chmod go-w "$PYPTO_CONFIG_FILE"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    [[ -z "$MAX_CONCURRENT_OVERRIDE" ]] || set_config_value MAX_CONCURRENT "$MAX_CONCURRENT_OVERRIDE"
    [[ -z "$MAX_TIME_HARD_CAP_OVERRIDE" ]] || set_config_value MAX_TIME_HARD_CAP "$MAX_TIME_HARD_CAP_OVERRIDE"
    [[ "$AVAILABLE_DEVICES_SET" == false ]] || set_config_value AVAILABLE_DEVICES "$AVAILABLE_DEVICES_OVERRIDE"
    [[ -z "$TASK_EXECUTION_MODE_OVERRIDE" ]] || set_config_value TASK_EXECUTION_MODE "$TASK_EXECUTION_MODE_OVERRIDE"
    [[ -z "$PTOAS_BASE_OVERRIDE" ]] || set_config_value PTOAS_BASE "$PTOAS_BASE_OVERRIDE"
fi

# The unified installation tree is always created above. If an existing or
# migrated configuration deliberately points at a legacy state/log location,
# create and repair that active runtime layout as well.
configured_state_dir="$STATE_DIR"
configured_logs_dir="$LOGS_DIR"
configured_tmp_dir="$TMP_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
    mapfile -t configured_paths < <(bash -c '
        source "$1"
        active_state="${STATE_DIR:-${BASE_DIR:-$2}}"
        active_logs="${LOGS_DIR:-${active_state%/state}/logs}"
        active_tmp="${TMP_DIR:-$3}"
        printf "%s\n%s\n%s\n%s\n" "$active_state" "$active_logs" \
            "$active_tmp" "${AVAILABLE_DEVICES:-}"
    ' _ "$CONFIG_FILE" "$STATE_DIR" "$TMP_DIR")
    configured_state_dir="${configured_paths[0]:-$STATE_DIR}"
    configured_logs_dir="${configured_paths[1]:-$LOGS_DIR}"
    configured_tmp_dir="${configured_paths[2]:-$TMP_DIR}"
    configured_devices="${configured_paths[3]:-}"
    prepare_state_layout "$configured_state_dir"
    [[ "$configured_logs_dir" == /* && "$configured_logs_dir" != / ]] || {
        echo "error: LOGS_DIR must be an absolute directory other than /" >&2
        exit 1
    }
    [[ ! -L "$configured_logs_dir" ]] || {
        echo "error: managed log directory must not be a symlink: $configured_logs_dir" >&2
        exit 1
    }
    ensure_dir 755 "$configured_logs_dir"
    [[ "$configured_tmp_dir" == /* && "$configured_tmp_dir" != / ]] || {
        echo "error: TMP_DIR must be an absolute directory other than /" >&2
        exit 1
    }
    [[ ! -L "$configured_tmp_dir" ]] || {
        echo "error: managed temporary directory must not be a symlink: $configured_tmp_dir" >&2
        exit 1
    }
    ensure_dir 755 "$configured_tmp_dir"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$configured_logs_dir" "$configured_tmp_dir"
        chmod go-w "$configured_logs_dir" "$configured_tmp_dir"
    fi
    precreate_device_locks "$configured_state_dir" "$configured_devices"
fi

# Render the updater after resolving all administrator-selected runtime paths;
# ProtectSystem=strict must still permit the idle lock, log, and scratch paths.
rendered_update_service="$(sed \
    -e 's|@NAME@|pto-task|g' \
    -e "s|@UPDATER@|$REPO_UPDATE_MODULE_DIR/updater.sh|g" \
    -e "s|@CONFIG@|$REPO_UPDATE_CONFIG|g" \
    -e "s|@READ_WRITE_PATHS@|$TOOL_ROOT $configured_state_dir $configured_logs_dir $configured_tmp_dir $BIN_DIR $SBIN_DIR /etc/systemd/system /run/lock|g" \
    -e 's|TimeoutStartSec=20min|TimeoutStartSec=infinity|' \
    "$SCRIPT_DIR/modules/repo_auto_update/repo-auto-update.service.in")"
write_app_file "$APP_DIR/pto-task-auto-update.service" 644 \
    "$rendered_update_service"$'\n'
rendered_update_timer="$(sed \
    -e 's|@NAME@|pto-task|g' \
    -e 's|@SERVICE_NAME@|pto-task-auto-update.service|g' \
    "$SCRIPT_DIR/modules/repo_auto_update/repo-auto-update.timer.in")"
write_app_file "$APP_DIR/pto-task-auto-update.timer" 644 \
    "$rendered_update_timer"$'\n'

ensure_dir 755 "$BIN_DIR"
ln -sfn "$APP_DIR/task-submit" "$BIN_DIR/task-submit"
ln -sfn "$APP_DIR/task-submit" "$BIN_DIR/pto-task"
ln -sfn "$APP_DIR/pypto-setup" "$BIN_DIR/pypto-setup"

# Remove only retired auxiliary aliases. task-submit remains a supported user
# command for compatibility, alongside pto-task.
for legacy in "$BIN_DIR/npu-lock" "$BIN_DIR/pto-taskqueue" "$SBIN_DIR/task-daemon"; do
    [[ ! -e "$legacy" && ! -L "$legacy" ]] || rm -f "$legacy"
done

printf 'Installed application: %s\n' "$APP_DIR"
printf 'User commands: %s/task-submit and %s/pto-task -> %s/task-submit\n' "$BIN_DIR" "$BIN_DIR" "$APP_DIR"
printf 'Environment command: %s/pypto-setup -> %s/pypto-setup\n' "$BIN_DIR" "$APP_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
    printf 'Configuration: %s (preserved)\n' "$CONFIG_FILE"
else
    printf 'Configuration not initialized; rerun setup.sh without --no-init-config.\n'
fi
services_started=false
if [[ -f "$CONFIG_FILE" && "$(id -u)" -eq 0 ]]; then
    usage_sampling_enabled="$(bash -c 'source "$1"; printf "%s" "${USAGE_SAMPLING_ENABLED:-false}"' _ "$CONFIG_FILE")"
    install -d -m 755 /etc/systemd/system
    ln -sfn "$APP_DIR/pto-task.service" /etc/systemd/system/pto-task.service
    # Upgrade path: earlier installs pointed taskqueue.service at the same
    # external file as pto-task.service, which systemd loads as a second,
    # independent unit that restart-loops against the daemon's single-instance
    # lock. Retire that duplicate before relinking. Guard on both conditions:
    # an Id that still reads back as taskqueue.service means systemd has not
    # collapsed it into an alias yet, and an active pto-task.service means the
    # real daemon lives there -- on a pre-migration host taskqueue.service is
    # still the canonical unit running the daemon and must not be stopped.
    if [[ "$(systemctl show -p Id --value taskqueue.service 2>/dev/null)" == taskqueue.service ]] &&
       systemctl is-active --quiet pto-task.service; then
        # Abort rather than relink underneath a duplicate that is still loaded:
        # rewriting the symlink would leave the old unit running or
        # restart-looping while systemd resolves the name somewhere else.
        if ! systemctl stop taskqueue.service; then
            echo 'error: could not stop the duplicate taskqueue.service unit' >&2
            exit 1
        fi
        systemctl reset-failed taskqueue.service >/dev/null 2>&1 || true
    fi
    # Keep the historical service name as a systemd alias during migration.
    # The link target must be the unit *inside* the search path, not
    # "$APP_DIR/pto-task.service": systemd only recognizes an alias when the
    # symlink names another unit it already knows. Pointing both names at the
    # same external file instead loads two independent units, and the extra one
    # restart-loops forever against the daemon's single-instance lock.
    ln -sfn /etc/systemd/system/pto-task.service /etc/systemd/system/taskqueue.service
    if [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
        ln -sfn "$APP_DIR/pto-task-auto-update.service" /etc/systemd/system/pto-task-auto-update.service
        ln -sfn "$APP_DIR/pto-task-auto-update.timer" /etc/systemd/system/pto-task-auto-update.timer
    else
        systemctl disable --now pto-task-auto-update.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/pto-task-auto-update.service /etc/systemd/system/pto-task-auto-update.timer
    fi
    # Retire unit names from the short-lived dual-updater implementation.
    systemctl disable --now pto-task-repo-auto-update.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/pto-task-repo-auto-update.service \
        /etc/systemd/system/pto-task-repo-auto-update.timer
    case "$usage_sampling_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            ln -sfn "$APP_DIR/pto-task-usage-sampler.service" /etc/systemd/system/pto-task-usage-sampler.service
            ln -sfn "$APP_DIR/pto-task-usage-sampler.timer" /etc/systemd/system/pto-task-usage-sampler.timer
            ;;
        *)
            systemctl disable --now pto-task-usage-sampler.timer >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/pto-task-usage-sampler.service /etc/systemd/system/pto-task-usage-sampler.timer
            ;;
    esac
    systemctl daemon-reload
    if [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
        systemctl enable --now pto-task-auto-update.timer
        installed_update_service="$(readlink -f /etc/systemd/system/pto-task-auto-update.service 2>/dev/null || true)"
        installed_update_timer="$(readlink -f /etc/systemd/system/pto-task-auto-update.timer 2>/dev/null || true)"
        if [[ "$installed_update_service" != "$APP_DIR/pto-task-auto-update.service" ||
              "$installed_update_timer" != "$APP_DIR/pto-task-auto-update.timer" ]]; then
            echo 'error: automatic-update systemd units were not linked to the installed application' >&2
            exit 1
        fi
        if ! systemctl is-enabled --quiet pto-task-auto-update.timer ||
           ! systemctl is-active --quiet pto-task-auto-update.timer; then
            echo 'error: automatic-update timer was installed but is not enabled and active' >&2
            exit 1
        fi
        services_started=true
        printf 'Automatic update timer enabled.\n'
    fi
    case "$usage_sampling_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            systemctl enable --now pto-task-usage-sampler.timer
            services_started=true
            printf 'Usage sampling timer enabled.\n'
            ;;
        *) printf 'Usage sampling timer not enabled (USAGE_SAMPLING_ENABLED is false).\n' ;;
    esac
elif [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
    printf 'Update timer not enabled (requires root and initialized config).\n'
fi

# setup.sh deliberately does not restart the daemon. Leave a persistent marker
# so deploy.sh or the idle-only updater can activate these files safely. This
# also bridges upgrades initiated by an older updater that did not restart.
write_app_file "$APP_DIR/.pto-task-restart-required" 600 ""

# Commit the installed revision only after every requested integration step and
# the restart marker have succeeded. If a late step fails, the previous revision
# remains visible and the next updater run will retry the installation.
write_app_file "$APP_DIR/.pto-task-release" 644 "$SOURCE_REVISION"$'\n'

if [[ "$services_started" == true ]]; then
    printf 'The task daemon was not started or restarted.\n'
else
    printf 'No daemon or service was started.\n'
fi
