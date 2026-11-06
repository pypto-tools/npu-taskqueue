import importlib.util
import json
import os
import random
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import usage_monitor as usage


class UsageFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        (self.state / 'done').mkdir(parents=True)
        self.now = usage.timestamp('2026-11-06T01:00:00Z')
        self.db = usage.database(self.state / 'usage-monitor/usage.sqlite3', self.now - 35*86400)
        self.addCleanup(self.db.close)

    def live(self, task='task_a', start='2026-11-05T23:00:00Z', count=4):
        return dict(status='ok', inventory_complete=True, scheduler={'state':'running'}, age_ms=0,
                    devices=[dict(id=str(i), state='allocated', allocation=dict(task_id=task,
                    started_at=start, user='alice', uid=1000)) for i in range(count)])

    def done(self, end='2026-11-06T01:00:00Z'):
        p = self.state / 'done/task_a'
        p.write_text('SUBMIT_USER=alice\nSTART_TIME=2026-11-05T23:00:00Z\nFINISH_TIME='+end+'\nDEVICE=0,1,2,3\nCOMMAND=secret\n')
        p.chmod(0o644)
        return p



class UsageMonitorTest(UsageFixture):
    def test_running_final_archive_and_cleanup_are_idempotent(self):
        active, errors = usage.collect(self.db, self.state, self.live(), self.now)
        report = usage.report(self.db, self.now, ZoneInfo('UTC'), active, errors)
        usage.validate(report)
        self.assertEqual(report['windows'][0]['card_seconds'], 4*3600)
        self.assertEqual(report['windows'][1]['card_seconds'], 8*3600)
        self.assertEqual(report['windows'][0]['users'][0]['active_cards'], 4)
        p = self.done()
        usage.archive_record(self.db, p)
        active, errors = usage.collect(self.db, self.state, self.live(), self.now)
        final = usage.report(self.db, self.now, ZoneInfo('UTC'), active, errors)
        self.assertEqual(final['windows'][1]['card_seconds'], 8*3600)
        self.assertEqual(final['windows'][0]['users'][0]['active_cards'], 0)
        p.unlink()
        active, errors = usage.collect(self.db, self.state, self.live(count=0), self.now+3600)
        kept = usage.report(self.db, self.now+3600, ZoneInfo('UTC'), active, errors)
        self.assertEqual(kept['windows'][1]['card_seconds'], 8*3600)
        self.assertNotIn('secret', json.dumps(kept))

    def test_lost_daemon_freezes_running_time_and_marks_partial(self):
        usage.collect(self.db, self.state, self.live(), self.now)
        active, errors = usage.collect(self.db, self.state, {'status':'unavailable'}, self.now+600)
        value = usage.report(self.db, self.now+600, ZoneInfo('UTC'), active, errors)
        self.assertEqual(value['windows'][0]['card_seconds'], 4*3600)
        self.assertIsNone(value['windows'][0]['users'][0]['active_cards'])
        self.assertFalse(value['windows'][0]['complete'])
        self.assertIn('live_usage_unavailable', value['reason'])

    def test_dst_and_missing_history_are_explicit(self):
        start = usage.timestamp('2026-11-01T00:00:00-07:00')
        end = usage.timestamp('2026-11-02T00:00:00-08:00')
        usage.put(self.db, ('task_dst', start, 'alice', None, end, 1), True)
        value = usage.report(self.db, end, ZoneInfo('America/Los_Angeles'), {}, set())
        self.assertEqual(value['windows'][1]['daily'][-2]['card_seconds'], 25*3600)
        self.db.execute("UPDATE meta SET value=? WHERE key='covered_from'", (end,))
        value = usage.report(self.db, end, ZoneInfo('America/Los_Angeles'), {}, set())
        self.assertFalse(value['windows'][1]['complete'])
        usage.validate(value)

    def test_explicit_rejection_has_no_card_charge(self):
        p = self.state / 'done/task_rejected'
        p.write_text('SUBMIT_USER=alice\nDEVICE=auto\nACCOUNTING_STATE=not_started\n')
        p.chmod(0o644)
        usage.archive_record(self.db, p)
        self.assertEqual(self.db.execute('SELECT count(*) FROM tasks').fetchone()[0], 0)

    def test_metadata_symlinks_and_incomplete_start_are_rejected(self):
        p = self.done()
        q = self.state / 'done/task_link'
        q.symlink_to(p)
        with self.assertRaises(ValueError):
            usage.read_done(q)
        p.write_text('SUBMIT_USER=alice\nSUBMIT_TIME=2026-11-05T23:00:00Z\nFINISH_TIME=2026-11-06T01:00:00Z\nDEVICE=0\n')
        with self.assertRaises(KeyError):
            usage.archive_record(self.db, p)
        self.assertEqual(self.db.execute('SELECT count(*) FROM tasks').fetchone()[0], 0)

    def test_collection_gap_and_reused_ids_do_not_claim_complete_history(self):
        usage.collect(self.db, self.state, self.live(), self.now)
        active, errors = usage.collect(self.db, self.state, self.live(), self.now+180)
        self.assertIn('collector_gap', errors)
        value = usage.report(self.db, self.now+180, ZoneInfo('UTC'), active, errors)
        self.assertFalse(value['windows'][0]['complete'])
        usage.put(self.db, ('task_a', self.now-100, 'bob', 1001, self.now, 1), True)
        self.assertEqual(self.db.execute('SELECT count(*) FROM tasks').fetchone()[0], 2)

    def test_reader_expiry_corruption_and_caller_config_isolation(self):
        value = usage.report(self.db, self.now, ZoneInfo('UTC'), {}, set())
        value.update(kernel_boot_id=usage.monitor.kernel_boot_id(), observed_monotonic_ns=time.monotonic_ns())
        path = self.state / 'usage-monitor.json'
        usage.monitor.atomic_json(path, value)
        self.assertEqual(usage.query(path)[1], 0)
        value['observed_monotonic_ns'] -= 121*10**9
        usage.monitor.atomic_json(path, value)
        old, code = usage.query(path)
        self.assertEqual(code, 1)
        self.assertTrue(old['cached'])
        value['windows'][0]['card_seconds'] = 999
        usage.monitor.atomic_json(path, value)
        self.assertEqual(usage.query(path)[0]['status'], 'unavailable')
        trap = self.root / 'trap.conf'
        marker = self.root / 'executed'
        trap.write_text('touch '+str(marker)+'\n')
        result = subprocess.run(['bash', str(ROOT/'task-submit.sh'), '--usage-monitor', '--json'],
            env={**os.environ, 'TASKQUEUE_CONF':str(trap)}, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertFalse(marker.exists())
        self.assertEqual(json.loads(result.stdout)['schema_version'], 1)


class IncrementalUsageTest(UsageFixture):
    """Compare cached accounting with independently clipped raw intervals."""

    def checked_report(self, now=None, tz='UTC', active=None):
        now = self.now if now is None else now
        tz = ZoneInfo(tz)
        value = usage.report(self.db, now, tz, active or {}, set())
        usage.validate(value)
        rows = list(self.db.execute('SELECT username,uid,started,ended,cards FROM tasks'))
        for window in value['windows']:
            expected = {}
            for user, uid, start, end, cards in rows:
                seconds = max(0, min(end, now) - max(start, window['start'])) * cards
                if seconds:
                    result = expected.setdefault((user, uid), [0, 0])
                    result[0] += seconds
                    result[1] += 1
            self.assertEqual({(r['user'], r['uid']): [r['card_seconds'], r['task_count']]
                              for r in window['users']}, expected)
            for day in window['daily']:
                date = datetime.fromisoformat(day['date']).replace(tzinfo=tz)
                lo, hi = int(date.timestamp()), min(now, int((date + timedelta(days=1)).timestamp()))
                expected_seconds = sum(max(0, min(e, hi) - max(s, lo)) * n for _, _, s, e, n in rows)
                self.assertEqual(day['card_seconds'], expected_seconds)
        return value

    def test_unchanged_sources_survive_restart_without_reopening_records(self):
        self.done()
        usage.collect(self.db, self.state, self.live(count=0), self.now)
        self.checked_report()
        self.db.close()
        self.db = usage.database(self.state / 'usage-monitor/usage.sqlite3', self.now + 30)
        self.addCleanup(self.db.close)
        with patch.object(usage, 'read_done', side_effect=AssertionError('reread unchanged file')), \
             patch.object(usage.sqlite3, 'connect', side_effect=AssertionError('reopen old archive')):
            usage.collect(self.db, self.state, self.live(count=0), self.now + 30)
            self.checked_report(self.now + 30)
        self.assertEqual(self.db.execute('SELECT count(*) FROM dirty_tasks').fetchone()[0], 0)

    def test_done_corrections_new_files_and_cleanup(self):
        path = self.done()
        usage.collect(self.db, self.state, self.live(count=0), self.now)
        self.checked_report()
        # Modify an existing file without touching the directory: the periodic
        # reconciliation catches it; successful records are not reread otherwise.
        self.done(end='2026-11-06T00:30:00Z')
        # Force a same-tick/size fingerprint collision deterministically.
        cached = json.loads(self.db.execute('SELECT fingerprint FROM done_files WHERE name=?', (path.name,)).fetchone()[0])
        real_fingerprint = usage.fingerprint
        with patch.object(usage, 'fingerprint', side_effect=lambda p: cached if p == path else real_fingerprint(p)):
            usage.collect(self.db, self.state, self.live(count=0), self.now + usage.RECONCILE_SECONDS)
        value = self.checked_report(self.now + usage.RECONCILE_SECONDS)
        self.assertEqual(value['windows'][0]['card_seconds'], 2*3600)
        new = self.state / 'done/task_b'
        new.write_text(path.read_text())
        new.chmod(0o644)
        usage.collect(self.db, self.state, self.live(count=0), self.now + 330)
        self.assertEqual(self.checked_report(self.now + 330)['windows'][0]['task_count'], 2)
        usage.archive_record(self.db, path)
        path.unlink()
        usage.collect(self.db, self.state, self.live(count=0), self.now + 360)
        self.assertEqual(self.checked_report(self.now + 360)['windows'][0]['task_count'], 2)

    def test_same_tick_directory_change_does_not_hide_new_completion(self):
        path = self.done()
        directory = self.state / 'done'
        same_stamp = usage.fingerprint(directory)
        real_fingerprint = usage.fingerprint
        with patch.object(usage, 'fingerprint', side_effect=lambda p: same_stamp if p == directory else real_fingerprint(p)):
            usage.collect(self.db, self.state, self.live(count=0), self.now)
            self.checked_report()
            new = directory / 'task_b'
            new.write_text(path.read_text())
            new.chmod(0o644)
            usage.collect(self.db, self.state, self.live(count=0), self.now+30)
            self.assertEqual(self.checked_report(self.now+30)['windows'][0]['task_count'], 2)

    def test_incomplete_record_retried_without_directory_change(self):
        path = self.state / 'done/task_a'
        path.write_text('')  # A publisher can race the daemon creating the file.
        path.chmod(0o644)
        _, errors = usage.collect(self.db, self.state, self.live(count=0), self.now)
        self.assertIn('task_record_incomplete', errors)
        self.done()
        _, errors = usage.collect(self.db, self.state, self.live(count=0), self.now + 30)
        self.assertNotIn('task_record_incomplete', errors)
        self.assertEqual(self.checked_report(self.now + 30)['windows'][0]['card_seconds'], 4*3600)

    def test_old_archive_changes_wal_and_source_priority(self):
        directory = self.state / 'usage-report'
        directory.mkdir()
        old = sqlite3.connect(directory / 'usage.sqlite3')
        self.addCleanup(old.close)
        old.execute('PRAGMA journal_mode=WAL')
        old.execute('CREATE TABLE tasks(task_id TEXT PRIMARY KEY, username TEXT, started REAL, finished REAL, devices TEXT)')
        start = usage.timestamp('2026-11-05T23:00:00Z')
        old.execute('INSERT INTO tasks VALUES (?,?,?,?,?)', ('task_a', 'alice', start, self.now-1800, '0,1,2,3'))
        old.commit()
        usage.collect(self.db, self.state, self.live(count=0), self.now)
        self.assertEqual(self.checked_report()['windows'][0]['card_seconds'], 2*3600)
        old.execute('UPDATE tasks SET finished=?', (self.now,))
        old.commit()
        usage.collect(self.db, self.state, self.live(count=0), self.now + 30)
        self.assertEqual(self.checked_report(self.now+30)['windows'][0]['card_seconds'], 4*3600)
        self.done(end='2026-11-06T00:15:00Z')
        usage.collect(self.db, self.state, self.live(count=0), self.now + 60)
        self.assertEqual(self.checked_report(self.now+60)['windows'][0]['card_seconds'], 3600)
        # A later hourly import must not overwrite corrected final task metadata.
        old.execute('UPDATE tasks SET finished=?', (self.now+30,))
        old.commit()
        usage.collect(self.db, self.state, self.live(count=0), self.now + 90)
        self.assertEqual(self.checked_report(self.now+90)['windows'][0]['card_seconds'], 3600)

    def test_archive_header_detects_same_timestamp_and_size_update(self):
        directory = self.state / 'usage-report'
        directory.mkdir()
        path = directory / 'usage.sqlite3'
        old = sqlite3.connect(path)
        self.addCleanup(old.close)
        old.execute('CREATE TABLE tasks(task_id TEXT, username TEXT, started REAL, finished REAL, devices TEXT)')
        old.execute('INSERT INTO tasks VALUES (?,?,?,?,?)', ('task_old', 'alice', self.now-600, self.now, '0'))
        old.commit()
        same_stamp = usage.fingerprint(path)
        real_fingerprint = usage.fingerprint
        with patch.object(usage, 'fingerprint', side_effect=lambda p: same_stamp if p == path else real_fingerprint(p)):
            usage.collect(self.db, self.state, self.live(count=0), self.now)
            self.assertEqual(self.checked_report()['windows'][0]['card_seconds'], 600)
            old.execute('UPDATE tasks SET finished=?', (self.now-300,))
            old.commit()
            usage.collect(self.db, self.state, self.live(count=0), self.now+30)
            self.assertEqual(self.checked_report(self.now+30)['windows'][0]['card_seconds'], 300)

    def test_migration_from_ledger_without_derived_tables(self):
        legacy_path = self.root / 'legacy/usage.sqlite3'
        legacy_path.parent.mkdir(mode=0o700)
        old = sqlite3.connect(legacy_path)
        old.executescript("""
            CREATE TABLE tasks(task_id TEXT, started INTEGER, username TEXT, uid INTEGER,
                ended INTEGER, cards INTEGER, final INTEGER, PRIMARY KEY(task_id,started));
            CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER);
        """)
        old.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?,?)', ('task_old', self.now-120, 'alice', None, self.now, 2, 1))
        old.execute('INSERT INTO meta VALUES (?,?)', ('covered_from', self.now-86400))
        old.commit()
        old.close()
        migrated = usage.database(legacy_path, self.now)
        try:
            for _ in range(2):
                value = usage.report(migrated, self.now, ZoneInfo('UTC'), {}, set())
                usage.validate(value)
                self.assertEqual(value['windows'][0]['card_seconds'], 240)
                self.assertEqual(value['covered_from'], self.now-86400)
        finally:
            migrated.close()

    def test_rollback_preserves_pending_work_without_double_charge(self):
        usage.put(self.db, ('task_a', self.now-600, 'alice', 1000, self.now, 2), True)
        self.db.commit()
        with patch.object(usage, 'adjust_daily', side_effect=RuntimeError('interrupted')):
            with self.assertRaises(RuntimeError):
                usage.report(self.db, self.now, ZoneInfo('UTC'), {}, set())
        self.assertEqual(self.checked_report()['windows'][0]['card_seconds'], 1200)
        usage.put(self.db, ('task_a', self.now-600, 'alice', 1000, self.now-300, 1), True)
        self.db.commit()
        self.assertEqual(self.checked_report()['windows'][0]['card_seconds'], 300)
        self.assertEqual(self.checked_report()['windows'][0]['task_count'], 1)

    def test_random_history_dst_corrections_retention_and_clock_rollback(self):
        rng = random.Random(1407)
        tasks = []
        for i in range(160):
            end = self.now - rng.randrange(-3600, 40*86400)
            start = end - rng.randrange(1, 12*86400)
            task = (f'task_{i}', start, f'user{i%7}', None if i%3 else 1000+i%7, end, i%5)
            usage.put(self.db, task, i%4 != 0)
            tasks.append(task)
        for tz in ('UTC', 'America/Los_Angeles', 'Asia/Shanghai'):
            self.checked_report(tz=tz)
        # Change owners, known UIDs, card counts and ends, including frozen live
        # records becoming final; corrections subtract their prior contribution.
        for task in tasks[::3]:
            name, start, user, uid, end, cards = task
            usage.put(self.db, (name, start, 'corrected', 2000, end+1800, cards+1), True)
        self.checked_report(tz='America/Los_Angeles')
        self.checked_report(self.now + 86400, tz='America/Los_Angeles')
        self.checked_report(self.now - 2*86400, tz='America/Los_Angeles')
        self.checked_report(self.now + 7200, tz='UTC')
        usage.collect(self.db, self.state, self.live(count=0), self.now+86400)
        self.checked_report(self.now+86400)
        self.assertEqual(self.db.execute('SELECT count(*) FROM tasks WHERE ended<?',
                         (self.now+86400-35*86400,)).fetchone()[0], 0)
        self.assertEqual(self.db.execute('SELECT count(*) FROM daily_usage WHERE card_seconds<0 OR task_count<0').fetchone()[0], 0)

    def test_dst_spring_day_and_multi_day_task_count(self):
        start = usage.timestamp('2026-03-07T00:00:00-08:00')
        end = usage.timestamp('2026-03-09T00:00:00-07:00')
        usage.put(self.db, ('task_dst', start, 'alice', None, end, 2), True)
        value = self.checked_report(end, tz='America/Los_Angeles')
        self.assertEqual(value['windows'][1]['task_count'], 1)
        self.assertEqual(value['windows'][1]['daily'][-2]['card_seconds'], 23*3600*2)
        self.assertEqual(value['windows'][0]['task_count'], 0)


if __name__ == '__main__':
    unittest.main()
