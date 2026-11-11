"""Submitter identity validation and persistence, without live machine state."""
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import task_identity as identity
import usage_monitor as usage


class SubmitterIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'task_example'
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.text = f'SUBMIT_USER={self.user}\nDEVICE=auto:2\nCOMMAND=echo test\n'
        self.path.write_text(self.text)

    def test_legacy_task_is_frozen_and_old_descriptor_cannot_rewrite_it(self):
        inode = self.path.stat().st_ino
        with self.path.open('w') as held:
            held.write(self.text)
            held.flush()
            identity.freeze(self.path, '0,1')
            held.seek(0)
            held.write('SUBMIT_UID=9999\n')
            held.flush()
        self.assertNotEqual(self.path.stat().st_ino, inode)
        self.assertEqual(self.path.stat().st_uid, os.geteuid())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.path.read_text(),
                         f'SUBMIT_USER={self.user}\nCOMMAND=echo test\nSUBMIT_UID={os.getuid()}\nDEVICE=0,1\n')

    def test_new_task_keeps_uid_and_unknown_fields(self):
        self.path.write_text(self.text + f'SUBMIT_UID={os.getuid()}\nFUTURE_FIELD=kept')
        identity.freeze(self.path, 'none')
        self.assertIn('FUTURE_FIELD=kept\n', self.path.read_text())
        self.assertEqual(self.path.read_text().count('SUBMIT_UID='), 1)

    def test_bad_uid_duplicate_or_mismatched_owner_is_rejected(self):
        for suffix in (f'SUBMIT_UID={os.getuid()+1}\n', 'SUBMIT_UID=-1\n', 'SUBMIT_UID=\n',
                       f'SUBMIT_UID={os.getuid()}\nSUBMIT_UID={os.getuid()}\n',
                       f'SUBMIT_USER={self.user}\n'):
            self.path.write_text(self.text + suffix)
            with self.assertRaises(ValueError):
                identity.freeze(self.path, '0')
            self.assertEqual(self.path.read_text(), self.text + suffix)
        self.path.write_text(self.text)
        with patch.object(identity.pwd, 'getpwnam') as lookup:
            lookup.return_value.pw_uid = os.getuid()+1
            with self.assertRaises(ValueError):
                identity.freeze(self.path, '0')

    def test_links_and_special_files_are_rejected(self):
        link = self.path.with_name('link')
        link.symlink_to(self.path)
        with self.assertRaises(OSError):
            identity.freeze(link, '0')
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(ValueError):
            identity.freeze(link, '0')
        link.unlink()
        os.mkfifo(link)
        with self.assertRaises(ValueError):
            identity.freeze(link, '0')

    def test_uid_parser_accepts_root_but_not_malformed_values(self):
        self.assertEqual(identity.parse_uid('0'), 0)
        self.assertIsNone(identity.parse_uid(None))
        for value in ('-1', '01', '1.0', ' 1', '１', '4294967295', True, 1000):
            with self.assertRaises(ValueError):
                identity.parse_uid(value)


@unittest.skipUnless(os.geteuid() == 0, 'run in an isolated root container')
class RootSubmitterLifecycleTests(unittest.TestCase):
    def test_root_execution_keeps_nonroot_submitter_across_all_exit_paths(self):
        repo = Path(__file__).resolve().parents[1]
        account = pwd.getpwnam('nobody')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o755)
            app, state, logs = (root / name for name in ('app', 'state', 'logs'))
            for path in (app, state, logs, root / 'config'):
                path.mkdir(mode=0o755)
            for kind in ('pending', 'running', 'done', 'locks', 'kill', 'fifo'):
                path = state / kind
                path.mkdir()
                path.chmod(0o1777 if kind in ('pending', 'locks', 'kill', 'fifo') else 0o755)
            for name in ('task-daemon.sh', 'task-submit.sh', 'npu_lock.sh', 'task_identity.py', 'monitor.py'):
                shutil.copy(repo / name, app / name)
            shutil.copytree(repo / 'schedulers', app / 'schedulers')
            (app / 'schedulers').chmod(0o755)
            for path in (app / 'schedulers').iterdir():
                path.chmod(0o644)
            config = root / 'config/taskqueue.conf'
            config.write_text(f'STATE_DIR="{state}"\nLOGS_DIR="{logs}"\n'
                              'TASK_EXECUTION_MODE=root\nSCHEDULER_MODE=backfill\n'
                              'AVAILABLE_DEVICES=0\nMAX_CONCURRENT=1\nKILL_GRACE=1\nMAX_TIME_HARD_CAP=0\n')
            config.chmod(0o644)
            env = dict(os.environ, TASKQUEUE_CONF=str(config))
            env.pop('TASKQUEUE_INSIDE', None)
            daemon = None
            stderr = (root / 'daemon.stderr').open('w+')

            def submit(command, max_time=0):
                result = subprocess.run(['runuser', '-u', 'nobody', '--', 'env', 'TASKQUEUE_CONF='+str(config),
                                         'bash', str(app / 'task-submit.sh'), '--device', '0',
                                         '--max-time', str(max_time), command],
                                        cwd=root, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            def wait_record(kind, task, field):
                deadline = time.monotonic()+15
                while time.monotonic() < deadline:
                    if daemon is not None:
                        self.assertIsNone(daemon.poll(), (root / 'daemon.stderr').read_text())
                    try:
                        values = dict(line.split('=', 1) for line in (state / kind / task).read_text().splitlines()
                                      if '=' in line)
                        if values.get(field):
                            return values
                    except FileNotFoundError:
                        pass
                    time.sleep(.05)
                self.fail('task did not reach '+kind+': '+(root / 'daemon.stderr').read_text())

            try:
                first = submit('id -u; sleep 1')
                pending = wait_record('pending', first, 'SUBMIT_UID')
                self.assertEqual(pending['SUBMIT_UID'], str(account.pw_uid))
                forged = submit('touch '+str(root / 'must-not-run'))
                forged_path = state / 'pending' / forged
                subprocess.run(['runuser', '-u', 'nobody', '--', sys.executable, '-c',
                                'from pathlib import Path; import sys; p=Path(sys.argv[1]); '
                                'p.write_text(p.read_text().replace("SUBMIT_UID="+sys.argv[2], "SUBMIT_UID=0"))',
                                str(forged_path), str(account.pw_uid)], check=True, timeout=5)
                # A task left by a previous daemon must retain its frozen UID
                # during startup recovery, even though no submitter lookup runs.
                stale = state / 'running/task_restart_fixture'
                stamp = usage.monitor.utc(time.time()-10)
                stale.write_text(f'SUBMIT_USER=nobody\nSUBMIT_UID={account.pw_uid}\nDEVICE=0\n'
                                 f'START_TIME={stamp}\nCOMMAND=true\n')
                daemon = subprocess.Popen(['bash', str(app / 'task-daemon.sh')], cwd=root, env=env,
                                          stdout=subprocess.DEVNULL, stderr=stderr)
                recovered = wait_record('done', stale.name, 'EXIT_CODE')
                self.assertEqual(recovered['SUBMIT_UID'], str(account.pw_uid))
                finished = wait_record('done', first, 'EXIT_CODE')
                self.assertEqual(finished['EXIT_CODE'], '0')
                self.assertEqual(finished['SUBMIT_UID'], str(account.pw_uid))
                self.assertIn('0', (logs / (first+'.log')).read_text().splitlines())
                rejected = wait_record('done', forged, 'EXIT_CODE')
                self.assertEqual(rejected['ACCOUNTING_STATE'], 'not_started')
                self.assertEqual(rejected['SUBMIT_UID'], '')
                self.assertFalse((root / 'must-not-run').exists())
                self.assertFalse((state / 'pending' / (forged+'.env')).exists())
                # npu-lock handles TERM with exit 130; the CPU-only watchdog
                # regression separately checks its direct shell exit 143.
                for command, max_time, expected in (('sleep 1; exit 7', 0, '7'), ('sleep 10', 1, '130')):
                    task = submit(command, max_time)
                    values = wait_record('done', task, 'EXIT_CODE')
                    self.assertEqual(values['EXIT_CODE'], expected)
                    self.assertEqual(values['SUBMIT_UID'], str(account.pw_uid))
                    if max_time:
                        self.assertLess(usage.timestamp(values['FINISH_TIME'])-usage.timestamp(values['START_TIME']), 10)
                task = submit('sleep 30')
                wait_record('running', task, 'TASK_PID')
                (state / 'kill' / task).touch()
                values = wait_record('done', task, 'EXIT_CODE')
                self.assertEqual(values['SUBMIT_UID'], str(account.pw_uid))
                self.assertNotEqual(values['EXIT_CODE'], '0')
                # Deliberately never sampled any running allocations. Final
                # records alone must retain submitter identity, including the
                # short task, across repeated imports.
                now = int(time.time())
                db = usage.database(state / 'usage-monitor/usage.sqlite3', now)
                try:
                    for _ in range(2):
                        _, errors = usage.collect(db, state, {'status': 'unavailable'}, now)
                        self.assertNotIn('task_record_incomplete', errors)
                    self.assertEqual(db.execute('SELECT DISTINCT username,uid FROM tasks').fetchall(),
                                     [('nobody', account.pw_uid)])
                    self.assertEqual(db.execute('SELECT count(*) FROM tasks').fetchone()[0], 5)
                finally:
                    db.close()
            finally:
                if daemon is not None and daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=15)
                stderr.close()


if __name__ == '__main__':
    unittest.main()
