#!/bin/bash
# deploy.sh: 一键同步所有文件到部署位置
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root 权限，请用: sudo bash deploy.sh"
    exit 1
fi

CONF_DIR="$SCRIPT_DIR/conf"
LIVE_CONF="/etc/taskqueue.conf"

# 读某个 conf 文件里的一个键，剥引号
read_conf_key() {
    local key="$1" file="$2" v
    [ -f "$file" ] || return 1
    v=$(grep -m1 "^${key}=" "$file") || return 1
    v="${v#*=}"
    v="${v%\"}" ; v="${v#\"}"
    v="${v%\'}" ; v="${v#\'}"
    [ -n "$v" ] && printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# BASE_DIR 是每台机器自己的（由 setup.sh --base-dir 决定），部署不得改写。
# 曾经这里是无条件 `cp conf/taskqueue.conf /etc/taskqueue.conf`：一旦仓库里的
# 值和本机不一致，一次例行更新就把队列指向了另一个目录 —— pending/running/done
# 和锁全留在旧路径，daemon 要到重启才切、客户端立刻就切，且下一行 cp 会因新目录
# 不存在而在 set -e 下中止，脚本停在“已装新代码 + 已改指 conf + 没重启”的半途。
# 现在：本机 conf 的 BASE_DIR 优先，仓库值只作全新安装的兜底。
# ---------------------------------------------------------------------------
BASE_DIR=$(read_conf_key BASE_DIR "$LIVE_CONF" || true)
if [ -n "$BASE_DIR" ]; then
    repo_base=$(read_conf_key BASE_DIR "$CONF_DIR/taskqueue.conf" || true)
    if [ -n "$repo_base" ] && [ "$repo_base" != "$BASE_DIR" ]; then
        echo ">>> BASE_DIR 沿用本机值: $BASE_DIR （仓库里的 $repo_base 仅作新装兜底，不同步）"
    fi
else
    BASE_DIR=$(read_conf_key BASE_DIR "$CONF_DIR/taskqueue.conf" || true)
    BASE_DIR="${BASE_DIR:-/var/lib/taskqueue}"
    echo ">>> 本机无 $LIVE_CONF，按仓库默认值部署: BASE_DIR=$BASE_DIR"
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "错误: BASE_DIR=$BASE_DIR 不存在，本机可能尚未安装。" >&2
    echo "      首次安装请用: sudo bash setup.sh --base-dir $BASE_DIR --max-concurrent N" >&2
    exit 1
fi

# 生成新的 /etc/taskqueue.conf：仓库内容 + 本机 BASE_DIR + 本机独有的自定义键
merge_conf() {
    local src="$1" tmp key line
    tmp=$(mktemp)
    sed "s|^BASE_DIR=.*|BASE_DIR=\"$BASE_DIR\"|" "$src" > "$tmp"
    grep -q '^BASE_DIR=' "$tmp" || printf 'BASE_DIR="%s"\n' "$BASE_DIR" >> "$tmp"
    # 保留本机 conf 里仓库没有的键（如 KILL_GRACE），别让部署把它们抹掉
    if [ -f "$LIVE_CONF" ]; then
        while IFS= read -r line; do
            case "$line" in ''|\#*) continue ;; esac
            key="${line%%=*}"
            case "$key" in ''|"$line"|*[!A-Za-z0-9_]*) continue ;; esac
            grep -q "^${key}=" "$tmp" || { printf '%s\n' "$line" >> "$tmp"; echo "    保留本机配置项: $key"; }
        done < "$LIVE_CONF"
    fi
    install -m 644 "$tmp" "$LIVE_CONF"
    rm -f "$tmp"
}

echo ">>> 同步脚本"
cp "$SCRIPT_DIR/task-daemon.sh"  /usr/local/sbin/task-daemon
cp "$SCRIPT_DIR/task-submit.sh"  /usr/local/bin/task-submit
cp "$SCRIPT_DIR/npu_lock.sh"     /usr/local/bin/npu-lock
chmod +x /usr/local/sbin/task-daemon /usr/local/bin/task-submit /usr/local/bin/npu-lock

echo ">>> 同步 systemd 服务"
cp "$SCRIPT_DIR/taskqueue.service" /etc/systemd/system/
systemctl daemon-reload

echo ">>> 同步 udev 规则"
cp "$SCRIPT_DIR/99-npu-taskqueue.rules" /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger

echo ">>> 同步 profile.d 脚本"
cp "$SCRIPT_DIR/taskqueue-npu.sh" /etc/profile.d/

echo ">>> 同步配置文件"
merge_conf "$CONF_DIR/taskqueue.conf"
cp "$CONF_DIR/available_devices"  "$BASE_DIR/available_devices"
if [ -f "$CONF_DIR/restricted-users" ]; then
    cp "$CONF_DIR/restricted-users"   /etc/taskqueue-restricted-users
else
    echo "    警告: conf/restricted-users 不存在（已被 .gitignore 排除），"
    echo "          用 restricted-users.example 占位。请复制并填入真实名单后重新部署。"
    cp "$CONF_DIR/restricted-users.example" /etc/taskqueue-restricted-users
fi
chmod 644 "$BASE_DIR/available_devices" /etc/taskqueue-restricted-users

echo ">>> 重启 daemon"
systemctl restart taskqueue

echo ">>> 当前状态"
systemctl status taskqueue --no-pager

echo ""
echo "=== 部署完成 ==="
echo "注意：用户需要重新登录才能生效环境变量变更"
