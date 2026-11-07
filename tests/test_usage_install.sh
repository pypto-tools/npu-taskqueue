#!/usr/bin/env bash
# Isolated install, ordinary-user query and cleanup/archival round trip.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
chmod 755 "$test_root"
bash "$REPO_DIR/setup.sh" --no-init-config --tools-root "$test_root/tools" \
    --bin-dir "$test_root/bin" --sbin-dir "$test_root/sbin" > "$test_root/setup.log"
installed="$test_root/tools/pto-task"
test -x "$installed/app/usage_monitor.py"
test -f "$installed/app/pto-task-usage-monitor.timer"
printf 'STATE_DIR="%s/state"\n' "$installed" > "$installed/config/taskqueue.conf"
python3 - "$installed" <<'PY'
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
now = datetime.now(timezone.utc).replace(microsecond=0)
record = root / 'state/done/task_usage_install'
record.write_text('SUBMIT_USER=example\nDEVICE=0,1\nSTART_TIME=' + (now-timedelta(hours=1)).isoformat() + '\nFINISH_TIME=' + now.isoformat() + '\n')
record.chmod(0o644)
os.utime(record, (now.timestamp()-120, now.timestamp()-120))
for suffix, device in (('auto', 'auto:2'), ('numeric', '0,1')):
    rejected = root / ('state/done/task_legacy_reject_' + suffix)
    rejected.write_text('SUBMIT_USER=example\nDEVICE=' + device + '\nSUBMIT_TIME='
                        + (now-timedelta(hours=1)).isoformat() + '\nFINISH_TIME='
                        + now.isoformat() + '\nEXIT_CODE=126\n')
    rejected.chmod(0o644)
    os.utime(rejected, (now.timestamp()-120, now.timestamp()-120))
PY
python3 -I "$installed/app/usage_monitor.py" publish
"$test_root/bin/task-submit" --usage-monitor --json > "$test_root/before.json"
python3 - "$test_root/before.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data['windows'][2]['card_seconds'] == 7200
assert data['status'] == 'partial'  # no live monitor in this isolated fixture
PY
test "$(stat -c %a "$installed/state/usage-monitor/usage.sqlite3")" = 600
test "$(stat -c %a "$installed/state/usage-monitor")" = 700
if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u nobody -- "$test_root/bin/task-submit" --usage-monitor --json > "$test_root/public.json"
    cmp "$test_root/before.json" "$test_root/public.json" >/dev/null || python3 - "$test_root/public.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['windows'][2]['card_seconds'] == 7200
PY
fi
"$test_root/bin/task-submit" --clean --days 0
test ! -f "$installed/state/done/task_usage_install"
test ! -f "$installed/state/done/task_legacy_reject_auto"
test ! -f "$installed/state/done/task_legacy_reject_numeric"
python3 -I "$installed/app/usage_monitor.py" publish
"$test_root/bin/task-submit" --usage-monitor --json > "$test_root/after.json"
python3 - "$test_root/after.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['windows'][2]['card_seconds'] == 7200
PY
echo 'usage installation, public query and cleanup preservation: PASS'
