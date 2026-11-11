import importlib.util
from datetime import timezone
import json
import os
import sqlite3
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from zoneinfo import ZoneInfo


module_path = Path(__file__).resolve().parents[1] / 'usage_report.py'
spec = importlib.util.spec_from_file_location('usage_report', module_path)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class UsageReportTest(unittest.TestCase):
    def test_archive_migration_preserves_uid_and_unknown_history(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            done = root / 'done'
            done.mkdir()
            db_path = root / 'usage.sqlite3'
            with sqlite3.connect(db_path) as old:
                old.execute('CREATE TABLE tasks(task_id TEXT PRIMARY KEY, username TEXT NOT NULL, started REAL NOT NULL, finished REAL NOT NULL, devices TEXT NOT NULL, exit_code INTEGER)')
                old.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?)', ('task_old', 'alice', 0, 1, '0', 0))
            db = usage.database(db_path)
            self.addCleanup(db.close)
            self.assertIsNone(db.execute('SELECT uid FROM tasks').fetchone()[0])
            now = usage.ts('2026-11-04T12:00:00+00:00')
            record = done / 'task_new'
            text = ('SUBMIT_USER=alice\nSTART_TIME=2026-11-04T10:00:00+00:00\n'
                    'FINISH_TIME=2026-11-04T11:00:00+00:00\nDEVICE=0\n')
            record.write_text(text + 'SUBMIT_UID=1109\n')
            record.chmod(0o644)
            usage.collect(db, root, '', now=now)
            self.assertEqual(db.execute('SELECT uid FROM tasks WHERE task_id="task_new"').fetchone()[0], 1109)
            record.write_text(text + 'SUBMIT_UID=2000\n')
            with patch('sys.stderr'):
                self.assertEqual(usage.collect(db, root, '', now=now+1)[0], 0)
            self.assertEqual(db.execute('SELECT uid FROM tasks WHERE task_id="task_new"').fetchone()[0], 1109)
            record.write_text(text)
            usage.collect(db, root, '', now=now+2)
            self.assertEqual(db.execute('SELECT uid FROM tasks WHERE task_id="task_new"').fetchone()[0], 1109)

    def test_collect_retains_recent_records_and_prunes_old_ones(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            done = root / 'done'
            done.mkdir()
            old = done / 'task_old'
            old.write_text('\n'.join([
                'SUBMIT_USER=alice', 'START_TIME=2026-09-30T00:00:00+00:00',
                'FINISH_TIME=2026-09-30T01:00:00+00:00', 'DEVICE=0',
            ]))
            recent = done / 'task_recent'
            recent.write_text('\n'.join([
                'SUBMIT_USER=alice', 'START_TIME=2026-11-03T00:00:00+00:00',
                'FINISH_TIME=2026-11-03T01:00:00+00:00', 'DEVICE=0,1',
            ]))
            now = usage.ts('2026-11-04T12:00:00+00:00')
            os.utime(old, (now - 35 * 86400, now - 35 * 86400))
            db = usage.database(root / 'usage.sqlite3')
            db.execute('INSERT INTO tasks (task_id,username,started,finished,devices,exit_code) VALUES (?,?,?,?,?,?)',
                       ('old_db_task', 'alice', now - 40 * 86400,
                        now - 39 * 86400, '0', 0))
            db.execute('INSERT INTO collections VALUES (?)', (now - 35 * 86400,))
            db.commit()
            last_output = '\n'.join([
                'alice pts/1 2026-09-30T00:00:00+00:00 - 2026-09-30T01:00:00+00:00 (01:00)',
                'alice pts/2 2026-11-03T00:00:00+00:00 - 2026-11-03T01:00:00+00:00 (01:00)',
            ])
            self.assertEqual(usage.collect(db, root, last_output, now=now), (1, 1))
            self.assertEqual(db.execute('SELECT task_id FROM tasks').fetchall(), [('task_recent',)])
            self.assertEqual(db.execute('SELECT tty FROM sessions').fetchall(), [('pts/2',)])
            self.assertEqual(db.execute('SELECT collected FROM collections').fetchall(), [(now,)])
            self.assertEqual(db.execute('PRAGMA auto_vacuum').fetchone()[0], 1)

    def test_dst_day_uses_local_calendar_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            db = usage.database(Path(temp) / 'usage.sqlite3')
            db.execute('INSERT INTO tasks (task_id,username,started,finished,devices,exit_code) VALUES (?,?,?,?,?,?)',
                       ('task_dst', 'alice', usage.ts('2026-11-01T07:00:00+00:00'),
                        usage.ts('2026-11-02T08:00:00+00:00'), '0', 0))
            db.commit()
            row = usage.day_report(db, '2026-11-01', '686',
                                   ZoneInfo('America/Los_Angeles'))['users']['alice']
            self.assertEqual(row['task_hours'], 25)
            self.assertEqual(row['card_hours'], 25)

    def test_cross_midnight_multicard_and_overlapping_sessions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            done = root / 'done'
            done.mkdir()
            (done / 'task_1').write_text('\n'.join([
                'SUBMIT_USER=alice',
                'START_TIME=2026-11-01T23:30:00+00:00',
                'FINISH_TIME=2026-11-02T00:30:00+00:00',
                'DEVICE=2,3',
                'EXIT_CODE=0',
            ]))
            last_output = '\n'.join([
                'alice pts/1 2026-11-01T23:00:00+00:00 - 2026-11-02T00:30:00+00:00 (01:30)',
                'alice pts/2 2026-11-01T23:45:00+00:00 - 2026-11-02T00:15:00+00:00 (00:30)',
                'wtmp begins 2026-11-01T00:00:00+00:00',
            ])
            db = usage.database(root / 'usage.sqlite3')
            now = usage.ts('2026-11-03T12:00:00+00:00')
            usage.collect(db, root, last_output, now=now)
            usage.collect(db, root, last_output, now=now + 1)
            first = usage.day_report(db, '2026-11-01', '686', timezone.utc)['users']['alice']
            second = usage.day_report(db, '2026-11-02', '686', timezone.utc)['users']['alice']
            self.assertEqual(first['tasks'], 1)
            self.assertEqual(first['task_hours'], 0.5)
            self.assertEqual(first['card_hours'], 1.0)
            self.assertEqual(first['login_hours'], 1.0)
            self.assertEqual(second['card_hours'], 1.0)
            self.assertEqual(second['login_hours'], 0.5)

    def test_publish_updates_one_week_document_on_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = usage.database(root / 'usage.sqlite3')
            db.execute('INSERT INTO tasks (task_id,username,started,finished,devices,exit_code) VALUES (?,?,?,?,?,?)',
                       ('task_1', 'alice', usage.ts('2026-11-02T10:00:00+00:00'),
                        usage.ts('2026-11-02T11:00:00+00:00'), '2,3', 0))
            db.commit()

            class FakeFeishu:
                docs = {}
                sequence = 0

                def __init__(self, _config):
                    pass

                def create(self, title):
                    self.__class__.sequence += 1
                    doc = f'doc-{self.sequence}'
                    self.docs[doc] = []
                    return doc

                def content(self, doc):
                    return '\n'.join(self.docs[doc])

                def append(self, doc, texts):
                    self.docs[doc].extend(texts)

                def ensure_link(self, doc, url, label):
                    if url not in self.content(doc):
                        self.append(doc, [f'{label} → {url}'])

                def replace(self, doc, texts):
                    self.docs[doc] = list(texts)

            args = SimpleNamespace(db=root / 'usage.sqlite3', feishu_config=root / 'fake',
                                   hub_state_file=None, usage_index='', date='2026-11-02')
            with patch.object(usage, 'Feishu', FakeFeishu):
                usage.publish(db, args, '686', timezone.utc)
                usage.publish(db, args, '686', timezone.utc)
                state_file = root / 'publish-state.json'
                state = json.loads(state_file.read_text())
                period_doc = state['periods']['2026-W45']
                self.assertEqual(len(FakeFeishu.docs[period_doc]), 1)
                self.assertIn('任务 1', FakeFeishu.docs[period_doc][0])
                self.assertIn('卡时 2.00', FakeFeishu.docs[period_doc][0])
                self.assertNotIn('alice', FakeFeishu.docs[period_doc][0])
                state['days']['2026-11-02'] = '2026-11-02 任务 1\nalice | 1 | 1.00 | 2.00'
                state.pop('remote_format')
                state_file.write_text(json.dumps(state))
                FakeFeishu.docs[period_doc] = state['days']['2026-11-02'].splitlines()
                args.date = '2026-11-03'
                usage.publish(db, args, '686', timezone.utc)
            self.assertEqual(FakeFeishu.sequence, 3)
            state = json.loads((root / 'publish-state.json').read_text())
            self.assertEqual(list(state['periods']), ['2026-W45'])
            self.assertEqual(state['remote_format'], 'daily-summary-v1')
            lines = FakeFeishu.docs[state['periods']['2026-W45']]
            self.assertEqual(len(lines), 2)
            self.assertEqual(sum('2026-11-02' in line for line in lines), 1)
            self.assertEqual(sum('2026-11-03' in line for line in lines), 1)
            self.assertTrue(all('alice' not in line and '\n' not in line for line in lines))
            self.assertIn('alice |', usage.render_day(usage.day_report(db, '2026-11-02', '686', timezone.utc)))


if __name__ == '__main__':
    unittest.main()
