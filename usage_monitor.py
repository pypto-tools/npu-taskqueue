#!/usr/bin/env python3
"""Card accounting publisher and bounded, unprivileged snapshot reader.

The publisher alone reads task metadata. No session data, command lines or
environments enter the accounting database or its public snapshot.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True

# -I deliberately excludes the caller's Python path and user site packages.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import monitor
from usage_report import config_value

MAX_AGE_MS = 120000
MAX_USERS = 512
MAX_SECONDS = 10**12
RECONCILE_SECONDS = 300
RETENTION_DAYS = 35
FIELDS = {'SUBMIT_USER', 'SUBMIT_TIME', 'START_TIME', 'FINISH_TIME', 'DEVICE', 'EXIT_CODE', 'ACCOUNTING_STATE'}


def root_path():
    app = Path(__file__).resolve().parent
    return app.parent if app.name == 'app' else app / 'runtime'


def timestamp(value):
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if dt.tzinfo is None:
        raise ValueError('timestamp requires timezone')
    return int(dt.timestamp())


def empty(reason):
    return dict(schema_version=1, status='unavailable', reason=reason,
                observed_at=None, age_ms=None, cached=False, timezone='UTC',
                covered_from=None, windows=[])


def database(path, now):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('accounting directory must be private and owned by publisher')
    if path.is_symlink():
        raise ValueError('accounting database must not be a symlink')
    # Keep accounting private even when invoked with a permissive umask.
    previous = os.umask(0o077)
    try:
        db = sqlite3.connect(path, timeout=5)
    finally:
        os.umask(previous)
    os.chmod(path, 0o600)
    db.executescript('''
        CREATE TABLE IF NOT EXISTS tasks (
            task_id TEXT NOT NULL, started INTEGER NOT NULL, username TEXT NOT NULL,
            uid INTEGER, ended INTEGER NOT NULL, cards INTEGER NOT NULL,
            final INTEGER NOT NULL, PRIMARY KEY(task_id, started));
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER);
    ''')
    if 'source_rank' not in {row[1] for row in db.execute('PRAGMA table_info(tasks)')}:
        db.execute('ALTER TABLE tasks ADD COLUMN source_rank INTEGER NOT NULL DEFAULT 0')
    db.executescript("""
        CREATE INDEX IF NOT EXISTS tasks_ended ON tasks(ended);
        CREATE INDEX IF NOT EXISTS tasks_final ON tasks(final);
        CREATE TABLE IF NOT EXISTS cache_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS done_files (name TEXT PRIMARY KEY, fingerprint TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS dirty_tasks (
            task_id TEXT NOT NULL, started INTEGER NOT NULL, PRIMARY KEY(task_id, started));
        CREATE TABLE IF NOT EXISTS rolled_tasks (
            task_id TEXT NOT NULL, started INTEGER NOT NULL, username TEXT NOT NULL,
            uid INTEGER, ended INTEGER NOT NULL, cards INTEGER NOT NULL,
            PRIMARY KEY(task_id, started));
        CREATE INDEX IF NOT EXISTS rolled_ended ON rolled_tasks(ended);
        CREATE TABLE IF NOT EXISTS daily_usage (
            day TEXT NOT NULL, username TEXT NOT NULL, uid INTEGER NOT NULL,
            card_seconds INTEGER NOT NULL, task_count INTEGER NOT NULL,
            PRIMARY KEY(day, username, uid));
        CREATE TRIGGER IF NOT EXISTS usage_insert AFTER INSERT ON tasks BEGIN
            INSERT INTO dirty_tasks VALUES (NEW.task_id, NEW.started) ON CONFLICT DO NOTHING;
        END;
        CREATE TRIGGER IF NOT EXISTS usage_update AFTER UPDATE ON tasks
        WHEN OLD.username IS NOT NEW.username OR OLD.uid IS NOT NEW.uid
          OR OLD.ended != NEW.ended OR OLD.cards != NEW.cards OR OLD.final != NEW.final
        BEGIN
            INSERT INTO dirty_tasks VALUES (NEW.task_id, NEW.started) ON CONFLICT DO NOTHING;
        END;
        CREATE TRIGGER IF NOT EXISTS usage_delete AFTER DELETE ON tasks BEGIN
            INSERT INTO dirty_tasks VALUES (OLD.task_id, OLD.started) ON CONFLICT DO NOTHING;
        END;
    """)
    db.execute("INSERT OR IGNORE INTO meta VALUES ('covered_from', ?)", (now,))
    db.commit()
    return db


def put(db, task, final, source_rank=2):
    task_id, start, user, uid, end, cards = task
    if not user or len(user.encode()) > 256 or not 0 <= start <= end or not 0 <= cards <= 256:
        raise ValueError('invalid task accounting')
    # Final metadata beats running observations and the older hourly archive.
    # Unchanged values must not dirty the daily cache or rewrite the ledger.
    db.execute("""INSERT INTO tasks
        (task_id,started,username,uid,ended,cards,final,source_rank) VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(task_id,started) DO UPDATE SET
          username=excluded.username,
          uid=CASE WHEN tasks.username=excluded.username
                   THEN coalesce(tasks.uid,excluded.uid) ELSE excluded.uid END,
          ended=excluded.ended, cards=excluded.cards, final=excluded.final,
          source_rank=excluded.source_rank
        WHERE excluded.final >= tasks.final
          AND (tasks.final != 1 OR excluded.source_rank >= tasks.source_rank)
          AND (tasks.username IS NOT excluded.username
            OR (tasks.uid IS NULL AND excluded.uid IS NOT NULL)
            OR tasks.ended != excluded.ended OR tasks.cards != excluded.cards
            OR tasks.final != excluded.final OR tasks.source_rank != excluded.source_rank)
        """, (task_id, start, user, uid, end, cards, int(final), source_rank if final else 0))


def cache_get(db, key):
    row = db.execute('SELECT value FROM cache_state WHERE key=?', (key,)).fetchone()
    return row[0] if row else None


def cache_set(db, key, value):
    db.execute('INSERT OR REPLACE INTO cache_state VALUES (?,?)', (key, str(value)))


def fingerprint(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            info.st_mode, info.st_uid]


def read_done(path):
    """Read trusted accounting fields, excluding explicit and legacy rejections."""
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_mode & 0o022:
        raise ValueError('untrusted task record')
    values = {}
    for line in monitor.bounded_read(path, 1024 * 1024).decode('utf-8', 'replace').splitlines():
        key, sep, value = line.partition('=')
        if sep and key in FIELDS:
            values[key] = value
    after = path.lstat()
    fields = ('st_dev', 'st_ino', 'st_mtime_ns', 'st_ctime_ns', 'st_size', 'st_mode', 'st_uid')
    if any(getattr(before, key) != getattr(after, key) for key in fields):
        raise ValueError('task changed while reading')
    if values.get('ACCOUNTING_STATE') == 'not_started':
        return None
    if 'DEVICE' not in values or 'FINISH_TIME' not in values:
        raise ValueError('unfinished task record')
    # Before ACCOUNTING_STATE existed, write_reject emitted EXIT_CODE=126 and
    # omitted START_TIME entirely. Interrupted/started tasks include that key,
    # even when empty; a missing start alone is not evidence of a rejection.
    if ('ACCOUNTING_STATE' not in values and 'START_TIME' not in values
            and values.get('EXIT_CODE') == '126' and values.get('SUBMIT_USER')
            and values.get('SUBMIT_TIME')):
        if timestamp(values['FINISH_TIME']) < timestamp(values['SUBMIT_TIME']):
            raise ValueError('invalid rejection interval')
        return None
    devices = values['DEVICE']
    if devices in ('', 'none'):
        return None
    ids = devices.split(',')
    if any(not x.isdigit() for x in ids) or len(set(ids)) != len(ids):
        raise ValueError('unresolved device assignment')
    return (path.name, timestamp(values['START_TIME']), values['SUBMIT_USER'], None,
            timestamp(values['FINISH_TIME']), len(ids))


def archive_record(db, path):
    task = read_done(path)
    if task:
        put(db, task, True)
    db.commit()


def import_archive(db, path):
    # The old database has no change sequence and updates rows in place. Check
    # its file/WAL generation, never a rowid/high-water mark that can miss edits.
    def header_stamp(file, size):
        try:
            with file.open('rb') as stream:
                return [fingerprint(file), stream.read(size).hex()]
        except FileNotFoundError:
            return None
    def generation():
        # Header change counters / WAL salts also catch same-size updates within
        # one filesystem timestamp tick. Only fixed-size headers are read here.
        return json.dumps([header_stamp(path, 100), header_stamp(Path(str(path) + '-wal'), 32)])
    before = generation()
    if cache_get(db, 'archive_generation') == before:
        return
    if path.is_file():
        # Never initialize, migrate, chmod or query sessions in the old archive.
        with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=1) as old:
            for task_id, user, start, end, devices in old.execute(
                    'SELECT task_id,username,started,finished,devices FROM tasks'):
                ids = [x for x in devices.split(',') if x]
                if not all(x.isdigit() for x in ids) or len(ids) != len(set(ids)):
                    raise ValueError('invalid archived devices')
                if ids:
                    put(db, (task_id, int(start), user, None, int(end), len(ids)), True, source_rank=1)
    if generation() == before:
        cache_set(db, 'archive_generation', before)


def collect_done(db, directory, now):
    scanned_ns = time.time_ns()
    directory_stamp = fingerprint(directory)
    before = json.dumps(directory_stamp)
    last = cache_get(db, 'done_verified_at')
    verify_contents = last is None or not 0 <= now - int(last) < RECONCILE_SECONDS
    if cache_get(db, 'done_generation') == before and not verify_contents:
        return set()
    errors = set()
    known = dict(db.execute('SELECT name,fingerprint FROM done_files'))
    for path in directory.iterdir():
        if not path.name.startswith('task_') or path.name.endswith('.env'):
            continue
        previous = known.pop(path.name, None)
        try:
            stamp = json.dumps(fingerprint(path))
            if verify_contents or stamp != previous:
                task = read_done(path)
                if stamp != json.dumps(fingerprint(path)):
                    raise ValueError('task changed while importing')
                if task:
                    put(db, task, True)
                db.execute('INSERT OR REPLACE INTO done_files VALUES (?,?)', (path.name, stamp))
        except (OSError, ValueError, KeyError):
            errors.add('task_record_incomplete')
    db.executemany('DELETE FROM done_files WHERE name=?', ((name,) for name in known))
    # Retry incomplete/concurrently written records on the next sample. Every
    # 5 minutes verify contents too: same-size edits within one filesystem clock
    # tick can have identical stat fingerprints. Only changed tasks dirty totals.
    if not errors and json.dumps(fingerprint(directory)) == before:
        # Do not cache a directory changed in the current filesystem timestamp
        # tick: another completion in that tick could leave its stat unchanged.
        if directory_stamp and max(directory_stamp[3:5]) < scanned_ns - 1_000_000_000:
            cache_set(db, 'done_generation', before)
        else:
            db.execute("DELETE FROM cache_state WHERE key='done_generation'")
        if verify_contents:
            cache_set(db, 'done_verified_at', now)
    else:
        db.execute("DELETE FROM cache_state WHERE key='done_generation'")
    return errors


def collect(db, state, live, now):
    errors = set()
    previous = db.execute("SELECT value FROM meta WHERE key='last_collected'").fetchone()
    if previous and (now < previous[0] or now - previous[0] > 120):
        errors.add('collector_gap')
    try:
        import_archive(db, state / 'usage-report/usage.sqlite3')
    except (OSError, ValueError, sqlite3.Error):
        errors.add('archive_unreadable')
    try:
        errors.update(collect_done(db, state / 'done', now))
    except OSError:
        errors.add('done_unreadable')
    active = defaultdict(int)
    active_ids = set()
    fresh = (live.get('status') in ('ok', 'partial') and live.get('inventory_complete') is True
             and live.get('scheduler', {}).get('state') in ('running', 'maintenance')
             and isinstance(live.get('age_ms'), int) and live['age_ms'] <= 15000
             and not live.get('cached', False))
    if fresh:
        tasks = {}
        for device in live['devices']:
            allocation = device.get('allocation')
            if not allocation:
                if device['state'] == 'unknown':
                    errors.add('live_usage_incomplete')
                continue
            try:
                key = (allocation['task_id'], timestamp(allocation['started_at']))
                user, uid = allocation['user'], allocation['uid']
                if not user or key[1] > now:
                    raise ValueError('unknown owner or invalid clock')
                item = tasks.setdefault(key, [user, uid, set()])
                if item[:2] != [user, uid]:
                    raise ValueError('inconsistent task owner')
                item[2].add(device['id'])
            except (KeyError, TypeError, ValueError, AttributeError):
                errors.add('live_usage_incomplete')
        for (task_id, start), (user, uid, devices) in tasks.items():
            put(db, (task_id, start, user, uid, max(start, now - live["age_ms"] // 1000), len(devices)), False)
            final = db.execute('SELECT final FROM tasks WHERE task_id=? AND started=?', (task_id, start)).fetchone()[0]
            if not final:
                active[(user, uid)] += len(devices)
                active_ids.add((task_id, start))
    else:
        errors.add('live_usage_unavailable')
    # A disappeared task without a final record is frozen at last observation.
    # Do not invent a completion timestamp or keep accruing after daemon loss.
    for task_id, start in list(db.execute('SELECT task_id,started FROM tasks WHERE final=0')):
        if (task_id, start) not in active_ids:
            errors.add('task_end_unknown')
            db.execute('UPDATE tasks SET final=-1 WHERE task_id=? AND started=?', (task_id, start))
    if errors:
        # Completeness is conservative: after a gap, only future windows can
        # become complete. Imported history is useful but has unverified coverage.
        db.execute("UPDATE meta SET value=? WHERE key='covered_from'", (now,))
    db.execute('DELETE FROM tasks WHERE ended < ?', (now - RETENTION_DAYS * 86400,))
    db.execute("INSERT OR REPLACE INTO meta VALUES ('last_collected', ?)", (now,))
    db.commit()
    return active if fresh and 'live_usage_incomplete' not in errors else None, errors


def day_start(day, tz):
    return int(datetime.combine(day, datetime.min.time(), tz).timestamp())


def daily_parts(start, end, cards, tz, first):
    """Clip before splitting, so even a years-long task costs at most 36 days."""
    if cards <= 0 or end <= start:
        return
    day = max(first, datetime.fromtimestamp(start, tz).date())
    last = datetime.fromtimestamp(end - 1, tz).date()
    while day <= last:
        seconds = max(0, min(end, day_start(day + timedelta(days=1), tz))
                      - max(start, day_start(day, tz))) * cards
        if seconds:
            # Each completed task counts once, on its last charged date. Every
            # public window ends today, so summing these counts is a distinct
            # task count even when a task spans several days.
            yield day.isoformat(), seconds, int(day == last)
        day += timedelta(days=1)


def adjust_daily(db, task, sign, tz, first):
    _, start, user, uid, end, cards = task
    for day, seconds, count in daily_parts(start, end, cards, tz, first):
        db.execute("""INSERT INTO daily_usage VALUES (?,?,?,?,?)
            ON CONFLICT(day,username,uid) DO UPDATE SET
              card_seconds=daily_usage.card_seconds+excluded.card_seconds,
              task_count=daily_usage.task_count+excluded.task_count""",
            (day, user, -1 if uid is None else uid, seconds * sign, count * sign))


def sync_rollups(db, now, tz):
    first = datetime.fromtimestamp(now, tz).date() - timedelta(days=RETENTION_DAYS)
    previous = cache_get(db, 'rollup_now')
    # Rebuild derived data once for existing ledgers or a timezone change. Raw
    # accounting and its coverage evidence survive the migration unchanged.
    if (cache_get(db, 'rollup_timezone') != str(tz)
            or (cache_get(db, 'rollup_first') or first.isoformat()) > first.isoformat()):
        db.execute('DELETE FROM daily_usage')
        db.execute('DELETE FROM rolled_tasks')
        db.execute('INSERT OR IGNORE INTO dirty_tasks SELECT task_id,started FROM tasks')
        cache_set(db, 'rollup_timezone', str(tz))
    elif previous is not None:
        previous = int(previous)
        if now >= previous:
            # Future-dated finals stay in the live overlay until their end time.
            db.execute("""INSERT OR IGNORE INTO dirty_tasks
                SELECT task_id,started FROM tasks WHERE ended>? AND ended<=? AND final!=0""",
                (previous, now))
        else:
            db.execute("""INSERT OR IGNORE INTO dirty_tasks
                SELECT task_id,started FROM rolled_tasks WHERE ended>?""", (now,))
    db.execute('DELETE FROM daily_usage WHERE day<?', (first.isoformat(),))
    # Never rescan tasks here: only inserted/changed/deleted identities are dirty.
    for task_id, start in list(db.execute('SELECT task_id,started FROM dirty_tasks')):
        old = db.execute('SELECT * FROM rolled_tasks WHERE task_id=? AND started=?', (task_id, start)).fetchone()
        if old:
            adjust_daily(db, old, -1, tz, first)
            db.execute('DELETE FROM rolled_tasks WHERE task_id=? AND started=?', (task_id, start))
        current = db.execute("""SELECT task_id,started,username,uid,ended,cards,final
            FROM tasks WHERE task_id=? AND started=?""", (task_id, start)).fetchone()
        if current and current[-1] != 0 and current[4] <= now:
            adjust_daily(db, current[:6], 1, tz, first)
            db.execute('INSERT INTO rolled_tasks VALUES (?,?,?,?,?,?)', current[:6])
    db.execute('DELETE FROM dirty_tasks')
    db.execute('DELETE FROM daily_usage WHERE card_seconds=0 AND task_count=0')
    cache_set(db, 'rollup_now', now)
    cache_set(db, 'rollup_first', first.isoformat())
    return first


def report(db, now, tz, active, errors):
    # A single transaction commits dirty identities, daily totals and the cache
    # watermark together; interruption cannot double-charge a completed task.
    with db:
        first = sync_rollups(db, now, tz)
        daily_users = {(day, user, uid): [seconds, count] for day, user, uid, seconds, count in
                       db.execute('SELECT * FROM daily_usage')}
        # Running/future-final observations are the only tasks recomputed each
        # sample. Frozen or final tasks already live in the daily aggregate.
        rows = db.execute("""SELECT username,uid,started,ended,cards FROM tasks WHERE final=0
            UNION ALL SELECT username,uid,started,ended,cards FROM tasks WHERE final!=0 AND ended>?""", (now,))
        for user, uid, start, end, cards in rows:
            for day, seconds, count in daily_parts(start, min(end, now), cards, tz, first):
                item = daily_users.setdefault((day, user, -1 if uid is None else uid), [0, 0])
                item[0] += seconds
                item[1] += count
    covered = db.execute("SELECT value FROM meta WHERE key='covered_from'").fetchone()[0]
    today = datetime.fromtimestamp(now, tz).date()
    windows = []
    for name, days in (('today', 1), ('7d', 7), ('30d', 30)):
        first_day = today - timedelta(days=days - 1)
        start = day_start(first_day, tz)
        users = {}
        daily = []
        for offset in range(days):
            day = first_day + timedelta(days=offset)
            daily.append(dict(date=day.isoformat(), card_seconds=0,
                              complete=covered <= day_start(day, tz) and not errors))
        daily_by_date = {row['date']: row for row in daily}
        for (date, user, uid_key), (seconds, count) in daily_users.items():
            if date not in daily_by_date or seconds <= 0:
                continue
            uid = None if uid_key == -1 else uid_key
            row = users.setdefault((user, uid), dict(user=user, uid=uid, card_seconds=0, task_count=0,
                                                    active_cards=active.get((user, uid), 0) if active is not None else None))
            row['card_seconds'] += seconds
            row['task_count'] += count
            daily_by_date[date]['card_seconds'] += seconds
        if len(users) > MAX_USERS:
            raise ValueError('user limit exceeded')
        items = sorted(users.values(), key=lambda r: (-r['card_seconds'], r['user'], r['uid'] or -1))
        windows.append(dict(id=name, start=start, end=now, complete=covered <= start and not errors,
                            card_seconds=sum(r['card_seconds'] for r in items), task_count=sum(r['task_count'] for r in items),
                            users=items, daily=daily))
    reasons = set(errors)
    if any(not w['complete'] for w in windows):
        reasons.add('history_partial')
    return dict(schema_version=1, status='partial' if reasons else 'ok', reason=','.join(sorted(reasons)) or None,
                observed_at=monitor.utc(now), age_ms=0, cached=False, timezone=str(tz), covered_from=covered, windows=windows)


def validate(value):
    if value['schema_version'] != 1 or type(value['schema_version']) is not int:
        raise ValueError('unsupported schema')
    if value['status'] not in ('ok', 'partial', 'unavailable') or type(value['cached']) is not bool:
        raise ValueError('invalid status')
    if not isinstance(value['timezone'], str) or len(value['timezone']) > 128:
        raise ValueError('invalid timezone')
    if not isinstance(value['reason'], (str, type(None))) or len(value['reason'] or '') > 4096:
        raise ValueError('invalid reason')
    def natural(n, maximum=MAX_SECONDS):
        return type(n) is int and 0 <= n <= maximum
    if value['covered_from'] is not None and not natural(value['covered_from']):
        raise ValueError('invalid coverage')
    windows = value['windows']
    if not windows and value['status'] == 'unavailable':
        return
    if [w['id'] for w in windows] != ['today', '7d', '30d']:
        raise ValueError('invalid windows')
    timestamp(value['observed_at'])
    for w, days in zip(windows, (1, 7, 30)):
        if not all(natural(w[k]) for k in ('start', 'end', 'card_seconds', 'task_count')) or w['start'] > w['end']:
            raise ValueError('invalid totals')
        if value['status'] == 'ok' and w['complete'] is not True:
            raise ValueError('incomplete successful window')
        if type(w['complete']) is not bool or len(w['users']) > MAX_USERS or len(w['daily']) != days:
            raise ValueError('invalid completeness/count')
        seen = set()
        for row in w['users']:
            if not isinstance(row['user'], str) or not row['user'] or len(row['user'].encode()) > 256:
                raise ValueError('invalid user')
            if row['uid'] is not None and not natural(row['uid'], 2**32-1):
                raise ValueError('invalid uid')
            key = (row['user'], row['uid'])
            if key in seen or not all(natural(row[k]) for k in ('card_seconds', 'task_count')):
                raise ValueError('invalid user totals')
            seen.add(key)
            if row['active_cards'] is not None and not natural(row['active_cards'], 256):
                raise ValueError('invalid allocation count')
        dates = []
        for row in w['daily']:
            datetime.strptime(row['date'], '%Y-%m-%d')
            dates.append(row['date'])
            if not natural(row['card_seconds']) or type(row['complete']) is not bool:
                raise ValueError('invalid daily total')
        if w['complete'] and any(not row['complete'] for row in w['daily']):
            raise ValueError('incomplete successful daily coverage')
        if dates != sorted(set(dates)):
            raise ValueError('invalid daily dates')
        if w['card_seconds'] != sum(r['card_seconds'] for r in w['users']) or w['task_count'] != sum(r['task_count'] for r in w['users']):
            raise ValueError('user sum mismatch')
        if w['card_seconds'] != sum(r['card_seconds'] for r in w['daily']):
            raise ValueError('daily sum mismatch')
        if w['complete'] and (value['covered_from'] is None or value['covered_from'] > w['start']):
            raise ValueError('invalid coverage claim')


def query(path):
    try:
        value = json.loads(monitor.bounded_read(path))
        validate(value)
        age = (time.monotonic_ns() - value['observed_monotonic_ns']) // 1_000_000
        value['age_ms'] = max(0, age)
        if value['kernel_boot_id'] != monitor.kernel_boot_id() or age < 0 or age > MAX_AGE_MS:
            value.update(status='unavailable', reason='snapshot_expired', cached=True,
                         age_ms=None if age < 0 or value['kernel_boot_id'] != monitor.kernel_boot_id() else age)
        value.pop('observed_monotonic_ns', None)
        value.pop('kernel_boot_id', None)
        return value, 1 if value['status'] == 'unavailable' else 0
    except (OSError, ValueError, KeyError, TypeError, OverflowError, AttributeError, RecursionError):
        return empty('snapshot_missing_or_invalid'), 1


def main():
    root = root_path()
    if sys.argv[1:2] == ['read']:
        value, code = query(root / 'state/usage-monitor.json') if sys.argv[2:] == ['--usage-monitor', '--json'] else (empty('usage: --usage-monitor --json'), 2)
        print(json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False))
        return code
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('publish', 'archive'))
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--record', type=Path)
    args = parser.parse_args()
    config = root / 'config/taskqueue.conf'
    state = args.state_dir or Path(config_value(config, 'STATE_DIR') or root / 'state')
    now = int(time.time())
    observed_ns = time.monotonic_ns()
    path = state / 'usage-monitor/usage.sqlite3'
    if args.command == 'archive' and (not path.exists() or
            config_value(config, 'USAGE_MONITOR_ENABLED', 'true').lower() in ('false', '0', 'no', 'off')):
        return 0  # Accounting not enabled yet; retain the previous cleanup policy.
    db = database(path, now)
    try:
        if args.command == 'archive':
            if args.record is None or args.record.parent.resolve() != (state / 'done').resolve():
                raise ValueError('archive requires a done record')
            archive_record(db, args.record)
            return 0
        live, _ = monitor.query(root / 'state/monitor.json')
        active, errors = collect(db, state, live, now)
        tz = ZoneInfo(config_value(config, 'USAGE_MONITOR_TIMEZONE', 'UTC'))
        value = report(db, now, tz, active, errors)
        validate(value)
        value.update(kernel_boot_id=monitor.kernel_boot_id(), observed_monotonic_ns=observed_ns)
        monitor.atomic_json(root / 'state/usage-monitor.json', value)
    finally:
        db.close()
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        print('usage accounting failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
