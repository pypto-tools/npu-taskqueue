#!/usr/bin/env bash
# Read-only aggregate report for task metadata and independent usage samples.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -f "$APP_DIR/../config/taskqueue.conf" ]]; then
    TOOL_ROOT="$(dirname "$APP_DIR")"
    CONF_FILE="${TASKQUEUE_CONF:-$TOOL_ROOT/config/taskqueue.conf}"
else
    TOOL_ROOT="$APP_DIR/runtime"
    CONF_FILE="${TASKQUEUE_CONF:-$TOOL_ROOT/config/taskqueue.conf}"
fi
[ -f "$CONF_FILE" ] && source "$CONF_FILE"
STATE_DIR="${STATE_DIR:-$TOOL_ROOT/state}"
days=7
while [[ $# -gt 0 ]]; do
    case "$1" in --days) days="${2:?--days needs a value}"; shift 2 ;; *) echo "usage: pto-task-stats [--days N]" >&2; exit 2;; esac
done
[[ "$days" =~ ^[0-9]+$ ]] || { echo '--days must be a non-negative integer' >&2; exit 2; }
files=()
for f in "$STATE_DIR/done"/task_* "$STATE_DIR/running"/task_* "$STATE_DIR/usage"/*.csv; do
    [[ -f "$f" && -r "$f" && "$f" != *.env ]] && files+=("$f")
done
if [[ ${#files[@]} -eq 0 ]]; then
    echo '(无任务记录)'
    exec python3 -I "$APP_DIR/device_usage.py" stats "$STATE_DIR" "$days"
fi
now=$(date +%s)
report_user="$(id -un)"
[[ "$(id -u)" -eq 0 ]] && report_user=""
awk -v now="$now" -v days="$days" -v report_user="$report_user" '
function epoch(s, p) { p=substr(s,1,19); gsub(/[-T:]/," ",p); return mktime(p) }
function value() { return substr($0,index($0,"=")+1) }
function flush( s,e,d,n,a) {
  if(!have) return; s=epoch(start); if(!s) s=epoch(submit); e=epoch(finish); if(!e) e=now
  if((report_user!="" && user!=report_user) || !s || e<=s || (days>0 && e<now-days*86400)) return
  if(days>0 && s<now-days*86400) s=now-days*86400; d=e-s; n=(dev==""||dev=="none")?0:split(dev,a,",")
  tasks[user]++; card[user]+=d*n; total+=d*n
}
BEGIN { print "NPU 使用统计" }
FILENAME ~ /\/usage\// { split($0,a,","); if((report_user=="" || a[7]==report_user) && (a[1] >= now-days*86400 || days==0)) { util[a[7]]+=a[3]; samples[a[7]]++ }; next }
FNR==1 { flush(); have=1; user="?"; submit=start=finish=dev="" }
/^SUBMIT_USER=/ {user=value()} /^SUBMIT_TIME=/ {submit=value()} /^START_TIME=/ {start=value()} /^FINISH_TIME=/ {finish=value()} /^DEVICE=/ {dev=value()}
END { flush(); printf "总卡时: %.1f h\n\n", total/3600; printf "%-16s %6s %10s %10s %8s\n", "用户","任务","卡时(h)","利用率","采样"; for(u in tasks) printf "%-16s %6d %10.1f %9s %8s\n",u,tasks[u],card[u]/3600,(samples[u]?sprintf("%.0f%%",util[u]/samples[u]):"-"),(samples[u]?samples[u]:"-") }
' "${files[@]}"

# This separate table includes new in-task probes; legacy CSV totals above remain readable.
python3 -I "$APP_DIR/device_usage.py" stats "$STATE_DIR" "$days"
