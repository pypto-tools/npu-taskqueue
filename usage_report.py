#!/usr/bin/env python3
"""Independent, read-only collector and daily publisher for task-submit usage."""
import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import subprocess
import sys
import urllib.request
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from task_identity import parse_uid

ISO = re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d')
ROOT = Path(__file__).resolve().parent.parent
if not (ROOT / 'config' / 'taskqueue.conf').exists():
    ROOT = Path(__file__).resolve().parent
DEFAULT_DB = ROOT / 'state' / 'usage-report' / 'usage.sqlite3'
DEFAULT_CONFIG = ROOT / 'config' / 'taskqueue.conf'


def config_value(path, key, default=''):
    if not path.exists():
        return default
    for line in path.read_text().splitlines():
        match = re.match(r'^\s*' + re.escape(key) + r'=(.*?)(?:\s+#.*)?$', line)
        if match:
            return match.group(1).strip().strip('"\'')
    return default


def ts(value):
    return datetime.fromisoformat(value).timestamp() if value else None


def report_timezone(config):
    name = config_value(config, 'USAGE_TIMEZONE')
    if not name:
        localtime = Path('/etc/localtime')
        target = str(localtime.resolve()) if localtime.exists() else ''
        marker = '/zoneinfo/'
        if marker in target:
            name = target.split(marker, 1)[1]
    if not name:
        name = 'UTC'
    return ZoneInfo(name)


def database(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    os.chmod(path, 0o600)
    if db.execute('PRAGMA auto_vacuum').fetchone()[0] != 1:
        db.execute('PRAGMA auto_vacuum=FULL')
        db.execute('VACUUM')
    db.executescript('''
        CREATE TABLE IF NOT EXISTS tasks (
            task_id TEXT PRIMARY KEY, username TEXT NOT NULL, started REAL NOT NULL,
            finished REAL NOT NULL, devices TEXT NOT NULL, exit_code INTEGER);
        CREATE TABLE IF NOT EXISTS sessions (
            username TEXT NOT NULL, tty TEXT NOT NULL, started REAL NOT NULL,
            finished REAL, state TEXT NOT NULL,
            PRIMARY KEY(username,tty,started));
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS collections (collected REAL PRIMARY KEY);
    ''')
    if 'uid' not in {row[1] for row in db.execute('PRAGMA table_info(tasks)')}:
        db.execute('ALTER TABLE tasks ADD COLUMN uid INTEGER')
    return db


def collect(db, state_dir, last_output=None, retention_days=30, now=None):
    now = datetime.now().timestamp() if now is None else now
    cutoff = now - retention_days * 86400
    tasks = sessions = 0
    for path in (state_dir / 'done').glob('task_*'):
        if not path.is_file() or path.suffix == '.env':
            continue
        fields = {}
        try:
            if path.stat().st_mtime < cutoff:
                continue
            for line in path.read_text(errors='replace').splitlines():
                key, sep, value = line.partition('=')
                if sep and key in ('SUBMIT_USER', 'SUBMIT_UID', 'START_TIME', 'FINISH_TIME', 'DEVICE', 'EXIT_CODE'):
                    if key in fields:
                        raise ValueError('duplicate accounting field')
                    fields[key] = value
            if not all(fields.get(k) for k in ('SUBMIT_USER', 'START_TIME', 'FINISH_TIME')):
                continue
            finished = ts(fields['FINISH_TIME'])
            if finished < cutoff:
                continue
            uid = parse_uid(fields.get('SUBMIT_UID'))
            if uid is not None:
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                    raise ValueError('untrusted submitter identity')
                previous = db.execute('SELECT username,started,uid FROM tasks WHERE task_id=?',
                                      (path.name,)).fetchone()
                if (previous and previous[:2] == (fields['SUBMIT_USER'], ts(fields['START_TIME']))
                        and previous[2] is not None and previous[2] != uid):
                    raise ValueError('conflicting submitter UID for the same task')
            db.execute('''INSERT INTO tasks (task_id,username,started,finished,devices,exit_code,uid)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(task_id) DO UPDATE SET username=excluded.username,
                started=excluded.started, finished=excluded.finished,
                devices=excluded.devices, exit_code=excluded.exit_code,
                uid=CASE WHEN tasks.username=excluded.username AND tasks.started=excluded.started
                         THEN coalesce(excluded.uid,tasks.uid) ELSE excluded.uid END''',
                (path.name, fields['SUBMIT_USER'], ts(fields['START_TIME']),
                 finished, fields.get('DEVICE', ''),
                 int(fields['EXIT_CODE']) if fields.get('EXIT_CODE', '').lstrip('-').isdigit() else None, uid))
            tasks += 1
        except (OSError, ValueError) as exc:
            print(f'skip task {path.name}: {exc}', file=sys.stderr)
    if last_output is None:
        last_output = subprocess.run(['last', '--time-format', 'iso', '-w', '-R'],
                                     check=True, capture_output=True, text=True).stdout
    for line in last_output.splitlines():
        if line.startswith('wtmp begins '):
            date = ISO.search(line)
            if date:
                db.execute('INSERT OR REPLACE INTO metadata VALUES (?,?)', ('wtmp_begin', date.group()))
            continue
        parts = line.split()
        if len(parts) < 3 or not (parts[1].startswith('pts/') or parts[1].startswith('tty')):
            continue
        dates = ISO.findall(line)
        if not dates:
            continue
        finish = ts(dates[1]) if len(dates) > 1 else None
        state = 'closed' if finish else ('open' if 'still logged in' in line else 'unknown')
        started = ts(dates[0])
        if (finish is not None and finish < cutoff) or (state == 'unknown' and started < cutoff):
            continue
        db.execute('''INSERT INTO sessions VALUES (?,?,?,?,?)
            ON CONFLICT(username,tty,started) DO UPDATE SET
            finished=excluded.finished,state=excluded.state''',
            (parts[0], parts[1], started, finish, state))
        sessions += 1
    db.execute('DELETE FROM tasks WHERE finished < ?', (cutoff,))
    db.execute('DELETE FROM sessions WHERE finished < ? OR (state = ? AND started < ?)',
               (cutoff, 'unknown', cutoff))
    db.execute('DELETE FROM collections WHERE collected < ?', (cutoff,))
    db.execute('INSERT OR REPLACE INTO metadata VALUES (?,?)',
               ('collected_at', datetime.fromtimestamp(now, timezone.utc).isoformat()))
    db.execute('INSERT INTO collections VALUES (?)', (now,))
    db.commit()
    return tasks, sessions


def overlap(start, end, lo, hi):
    return max(0, min(end, hi) - max(start, lo))


def union(intervals):
    total = 0
    previous_end = float('-inf')
    for start, end in sorted(intervals):
        total += max(0, end - max(start, previous_end))
        previous_end = max(previous_end, end)
    return total


def day_report(db, day, label, tz):
    lo = datetime.fromisoformat(day).replace(tzinfo=tz).timestamp()
    hi = (datetime.fromisoformat(day).replace(tzinfo=tz) + timedelta(days=1)).timestamp()
    users = defaultdict(lambda: {'tasks': 0, 'task_hours': 0.0, 'card_hours': 0.0,
                                 'login_hours': 0.0, 'unknown_sessions': 0, '_intervals': []})
    for user, start, end, devices in db.execute('SELECT username,started,finished,devices FROM tasks WHERE started < ? AND finished > ?', (hi, lo)):
        row = users[user]
        seconds = overlap(start, end, lo, hi)
        cards = len([x for x in devices.split(',') if x.strip().isdigit()])
        row['tasks'] += 1
        row['task_hours'] += seconds / 3600
        row['card_hours'] += seconds * cards / 3600
    for user, start, end, state in db.execute('SELECT username,started,finished,state FROM sessions WHERE started < ? AND (finished IS NULL OR finished > ?)', (hi, lo)):
        row = users[user]
        if state == 'unknown':
            if lo <= start < hi:
                row['unknown_sessions'] += 1
        elif state == 'open' and hi <= datetime.now().timestamp():
            row['unknown_sessions'] += 1
        else:
            row['_intervals'].append((max(start, lo), min(end or datetime.now().timestamp(), hi)))
    for row in users.values():
        row['login_hours'] = union(row.pop('_intervals')) / 3600
    collection_count = db.execute('SELECT count(*) FROM collections WHERE collected >= ? AND collected < ?', (lo, hi)).fetchone()[0]
    return {'server': label, 'date': day, 'timezone': str(tz),
            'users': dict(sorted(users.items())),
            'task_count': sum(x['tasks'] for x in users.values()),
            'card_hours': sum(x['card_hours'] for x in users.values()),
            'collections': collection_count}


def render_day(report):
    lines = [f"{report['date']} 任务 {report['task_count']}，卡时 {report['card_hours']:.2f}",
             f"当日采集次数：{report['collections']}（0 表示无采集，不能当作零用量）",
             '用户 | 任务数 | 任务运行小时 | 卡时 | 登录小时 | 登出不明会话']
    for user, row in report['users'].items():
        lines.append(f"{user} | {row['tasks']} | {row['task_hours']:.2f} | {row['card_hours']:.2f} | {row['login_hours']:.2f} | {row['unknown_sessions']}")
    if not report['users']:
        lines.append('无记录')
    return '\n'.join(lines)


def render_remote_day(report):
    users = report['users'].values()
    task_hours = sum(row['task_hours'] for row in users)
    login_hours = sum(row['login_hours'] for row in report['users'].values())
    return (f"{report['date']} | 用户 {len(report['users'])} | 任务 {report['task_count']} | "
            f"运行 {task_hours:.2f} 小时 | 卡时 {report['card_hours']:.2f} | "
            f"登录 {login_hours:.2f} 小时")


def week_for_day(day):
    year, week, _ = datetime.fromisoformat(day).date().isocalendar()
    return f'{year}-W{week:02d}'


class Feishu:
    def __init__(self, config):
        self.base = 'https://open.feishu.cn/open-apis'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        app_id = config_value(config, 'FEISHU_APP_ID')
        secret = config_value(config, 'FEISHU_APP_SECRET')
        if not app_id or not secret:
            raise ValueError('Feishu application credentials are missing')
        self.token = self.call('POST', '/auth/v3/tenant_access_token/internal',
                               {'app_id': app_id, 'app_secret': secret}, auth=False)['tenant_access_token']

    def call(self, method, path, body=None, auth=True):
        headers = {'Content-Type': 'application/json; charset=utf-8'}
        if auth:
            headers['Authorization'] = 'Bearer ' + self.token
        request = urllib.request.Request(self.base + path,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers=headers, method=method)
        with self.opener.open(request, timeout=15) as response:
            result = json.load(response)
        if result.get('code', 0):
            raise RuntimeError(f"Feishu API error {result['code']}: {result.get('msg', '')}")
        return result.get('data', result)

    def create(self, title):
        doc = self.call('POST', '/docx/v1/documents', {'title': title})['document']['document_id']
        self.call('PATCH', f'/drive/v2/permissions/{doc}/public?type=docx',
                  {'link_share_entity': 'tenant_readable'})
        return doc

    def content(self, doc):
        return self.call('GET', f'/docx/v1/documents/{doc}/raw_content')['content']

    def blocks(self, doc):
        items, page = [], ''
        while True:
            suffix = f'&page_token={page}' if page else ''
            data = self.call('GET', f'/docx/v1/documents/{doc}/blocks/{doc}/children?page_size=500{suffix}')
            items.extend(data.get('items', []))
            if not data.get('has_more'):
                return items
            page = data['page_token']

    def append(self, doc, texts):
        children = [{'block_type': 2, 'text': {'elements': [{'text_run': {'content': text}}]}} for text in texts]
        self.call('POST', f'/docx/v1/documents/{doc}/blocks/{doc}/children',
                  {'index': len(self.blocks(doc)), 'children': children})

    def ensure_link(self, doc, url, label):
        desired = f'{label} → {url}'
        for block in self.blocks(doc):
            if block.get('block_type') != 2:
                continue
            contents = ''.join(item.get('text_run', {}).get('content', '')
                               for item in block.get('text', {}).get('elements', []))
            if url not in contents:
                continue
            if contents != desired:
                self.call('PATCH', f'/docx/v1/documents/{doc}/blocks/{block["block_id"]}',
                          {'update_text_elements': {'elements': [{'text_run': {'content': desired}}]}})
            return
        self.append(doc, [desired])

    def replace(self, doc, texts):
        count = len(self.blocks(doc))
        while count:
            start = max(0, count - 50)
            self.call('DELETE', f'/docx/v1/documents/{doc}/blocks/{doc}/children/batch_delete',
                      {'start_index': start, 'end_index': count})
            count = start
        for i in range(0, len(texts), 50):
            self.append(doc, texts[i:i + 50])


def publish(db, args, label, tz):
    if not args.feishu_config:
        raise ValueError('set USAGE_FEISHU_CONFIG to an existing credential file')
    client = Feishu(args.feishu_config)
    state_file = args.db.parent / 'publish-state.json'
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    def save():
        state_file.write_text(json.dumps(state, indent=2, ensure_ascii=False) + '\n')
        os.chmod(state_file, 0o600)
    if not state.get('server_index'):
        state['server_index'] = client.create(f'服务器 {label} · 使用情况')
        save()
    if not state.get('usage_index'):
        state['usage_index'] = args.usage_index or client.create('服务器使用情况 · 索引')
        save()
    if args.hub_state_file:
        args.hub_state_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.hub_state_file.with_suffix('.tmp')
        temporary.write_text(json.dumps({'usage_index_doc': state['usage_index']}) + '\n')
        os.chmod(temporary, 0o644)
        temporary.replace(args.hub_state_file)
    server_url = f'https://hw-native-sys.feishu.cn/docx/{state["server_index"]}'
    client.ensure_link(state['usage_index'], server_url, f'服务器 {label}')
    yesterday = datetime.now(tz).date() - timedelta(days=1)
    if args.date:
        days = [args.date]
    elif state.get('latest_day'):
        first = datetime.fromisoformat(state['latest_day']).date()
        days = [(first + timedelta(days=i)).isoformat() for i in range((yesterday - first).days + 1)]
    else:
        days = [yesterday.isoformat()]
    state.setdefault('periods', {})
    state.setdefault('days', {})
    migration_pending = state.get('remote_format') != 'daily-summary-v1'
    dirty_periods = set()
    if migration_pending:
        for day in state['days']:
            state['days'][day] = render_remote_day(day_report(db, day, label, tz))
            dirty_periods.add(week_for_day(day))
        save()
    for day in days:
        period = week_for_day(day)
        if period not in state['periods']:
            state['periods'][period] = client.create(f'服务器 {label} · {period}')
            save()
        period_url = f'https://hw-native-sys.feishu.cn/docx/{state["periods"][period]}'
        client.ensure_link(state['server_index'], period_url, period)
        state['days'][day] = render_remote_day(day_report(db, day, label, tz))
        dirty_periods.add(period)
        save()
    for period in sorted(dirty_periods):
        lines = [state['days'][day] for day in sorted(state['days'])
                 if week_for_day(day) == period]
        client.replace(state['periods'][period], lines)
    if not args.date and days:
        state['latest_day'] = days[-1]
    state['remote_format'] = 'daily-summary-v1'
    save()
    print(json.dumps({'usage_index': state['usage_index'], 'server_index': state['server_index'],
                      'period_doc': state['periods'][week_for_day(days[-1])] if days else None,
                      'dates': days}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('collect', 'day', 'publish', 'status'))
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--db', type=Path, default=DEFAULT_DB)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--date')
    parser.add_argument('--usage-index')
    args = parser.parse_args()
    enabled = config_value(args.config, 'USAGE_REPORT_ENABLED', 'false').lower() in ('true', '1', 'yes')
    retention_text = config_value(args.config, 'USAGE_RETENTION_DAYS', '30')
    if not retention_text.isdigit() or not 7 <= int(retention_text) <= 90:
        raise SystemExit('USAGE_RETENTION_DAYS must be between 7 and 90')
    retention_days = int(retention_text)
    label = config_value(args.config, 'USAGE_SERVER_LABEL') or socket.gethostname()
    args.feishu_config = Path(config_value(args.config, 'USAGE_FEISHU_CONFIG')) if config_value(args.config, 'USAGE_FEISHU_CONFIG') else None
    args.usage_index = args.usage_index or config_value(args.config, 'USAGE_INDEX_DOCX_TOKEN')
    hub_path = config_value(args.config, 'USAGE_HUB_STATE_FILE')
    args.hub_state_file = Path(hub_path) if hub_path else None
    if args.command == 'status':
        print(json.dumps({'enabled': enabled, 'server_label': label, 'database': str(args.db),
                          'feishu_configured': bool(args.feishu_config),
                          'retention_days': retention_days}, ensure_ascii=False))
        return
    if args.command in ('collect', 'publish') and not enabled:
        raise SystemExit('usage collection is disabled (USAGE_REPORT_ENABLED=false)')
    if args.command == 'day' and not args.db.exists():
        raise SystemExit('no usage data collected yet')
    tz = report_timezone(args.config)
    db = database(args.db)
    if args.command in ('collect', 'publish'):
        state_dir = args.state_dir or ROOT / 'state'
        print('collected tasks/sessions:', *collect(db, state_dir, retention_days=retention_days))
    if args.command == 'day':
        day = args.date or (datetime.now(tz).date() - timedelta(days=1)).isoformat()
        print(render_day(day_report(db, day, label, tz)))
    elif args.command == 'publish':
        publish(db, args, label, tz)


if __name__ == '__main__':
    main()
