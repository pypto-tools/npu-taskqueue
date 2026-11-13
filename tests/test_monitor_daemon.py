#!/usr/bin/env python3
"""Isolated daemon integration: real scheduler, tasks, locks and public CLI."""
import json
import os
from pathlib import Path
import pwd
import signal
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class DaemonMonitorTests(unittest.TestCase):
    def test_scheduler_lifecycle_and_activation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'app'
            app.mkdir()
            (root / 'state').mkdir()  # public snapshot always lives here
            queue = root / 'custom-queue'  # preserved administrator state override
            logs = root / 'logs'
            logs.mkdir()
            for name in ('pending', 'running', 'done', 'locks', 'kill', 'fifo'):
                (queue / name).mkdir(parents=True)
            for name in ('task-daemon.sh', 'task-submit.sh', 'npu_lock.sh'):
                shutil.copy(REPO / name, app / name)
            shutil.copytree(REPO / 'schedulers', app / 'schedulers')
            (app / 'schedulers').chmod(0o755)
            for path in (app / 'schedulers').iterdir():
                path.chmod(0o644)
            # Hardware fixture only in this private application copy. Production
            # has no environment variable or CLI override for device enumeration.
            dev = root / 'dev'
            dev.mkdir()
            for device in (2, 5, 9, 12):
                (dev / f'davinci{device}').touch()
            (app / 'monitor.py').write_text((REPO / 'monitor.py').read_text().replace("Path('/dev')", f'Path({str(dev)!r})'))
            (app / '.pto-task-release').write_text('running-v1\n')
            config = root / 'config'
            config.mkdir()
            config.chmod(0o755)
            (config / 'taskqueue.conf').write_text(
                f'STATE_DIR="{queue}"\nLOGS_DIR="{logs}"\nMAX_CONCURRENT=4\n'
                'SCHEDULER_MODE=pool_aware_reservation\nTASK_EXECUTION_MODE=root\n'
                'AVAILABLE_DEVICES=2,5,9\nDEVICE_GROUPS="2;5,9;12"\nMAX_TIME_HARD_CAP=0\n')
            (config / 'taskqueue.conf').chmod(0o644)
            # Exercise root-only daemon startup as an ordinary test account,
            # following the repository's existing scheduler integration fixtures.
            fake = root / 'bin'
            fake.mkdir()
            (fake / 'id').write_text('#!/bin/bash\nif [[ "$*" == -u ]]; then echo 0; else exec /usr/bin/id "$@"; fi\n')
            (fake / 'stat').write_text(
                '#!/bin/bash\nif [[ "$1" == -c && "$2" == %u && "$3" == "$MONITOR_TEST_ROOT"/* ]]; '
                'then echo 0; else exec /usr/bin/stat "$@"; fi\n')
            for path in fake.iterdir():
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'], MONITOR_TEST_ROOT=str(root))
            env.pop('TASKQUEUE_CONF', None)
            release = root / 'release'
            release_wait = root / 'release-wait'
            daemon = None
            stderr = (root / 'daemon.stderr').open('w+')

            def task(name, request, marker, unlock, pool=''):
                (queue / 'pending' / name).write_text(
                    f'SUBMIT_USER={pwd.getpwuid(os.getuid()).pw_name}\nSUBMIT_TIME=2026-01-01T00:00:00Z\n'
                    f'WORK_DIR={root}\nCOMMAND=touch {marker}; while [[ ! -f {unlock} ]]; do sleep .05; done\n'
                    f'DEVICE={request}\nDEVICE_POOL={pool}\nMAX_TIME=0\n')

            def start():
                return subprocess.Popen(['bash', str(app / 'task-daemon.sh')], env=env,
                                        stdout=subprocess.DEVNULL, stderr=stderr)

            def wait_snapshot(predicate):
                deadline = time.monotonic() + 10
                last = None
                while time.monotonic() < deadline:
                    self.assertIsNone(daemon.poll(), (root / 'daemon.stderr').read_text())
                    try:
                        last = json.loads((root / 'state/monitor.json').read_text())
                        if predicate(last):
                            return last
                    except (FileNotFoundError, json.JSONDecodeError):
                        pass
                    time.sleep(.05)
                stderr.flush()
                self.fail(f'snapshot timeout: {last}; stderr={(root / "daemon.stderr").read_text()}')

            try:
                task('task_01', '5', root / 'started', release)
                task('task_02', 'auto:2', root / 'wait-started', release_wait, '5,9')
                daemon = start()
                value = wait_snapshot(lambda v: v['status'] == 'ok' and v['summary']['reserved'] == 1)
                self.assertEqual(value['scheduler']['running_tasks'], 1)
                self.assertEqual(value['scheduler']['pending_tasks'], 1)
                devices = {d['id']: d for d in value['devices']}
                self.assertEqual(devices['5']['allocation']['task_id'], 'task_01')
                self.assertEqual(devices['5']['reservation']['task_id'], 'task_02')
                self.assertEqual(devices['9']['state'], 'reserved')
                self.assertEqual(devices['12']['state'], 'disabled')
                boot = value['boot_id']
                seq = value['snapshot_seq']
                (app / '.pto-task-release').write_text('installed-v2\n')
                newer = wait_snapshot(lambda v: v['snapshot_seq'] > seq)
                self.assertEqual(newer['producer']['version'], 'running-v1')
                self.assertEqual(newer['boot_id'], boot)
                # Cancel a pending reservation: exported state comes from the
                # next real scheduling tick, never from replayed log messages.
                (queue / 'pending/task_02').unlink()
                wait_snapshot(lambda v: v['status'] == 'ok' and v['summary']['reserved'] == 0
                              and v['scheduler']['pending_tasks'] == 0)
                task('task_02', 'auto:2', root / 'wait-started', release_wait, '5,9')
                wait_snapshot(lambda v: v['status'] == 'ok' and v['summary']['reserved'] == 1)
                (queue / 'maintenance').touch()
                value = wait_snapshot(lambda v: v['scheduler']['state'] == 'maintenance')
                self.assertFalse(value['scheduler']['accepting_submissions'])
                self.assertFalse(value['scheduler']['dispatching'])
                self.assertIsNotNone({d['id']: d for d in value['devices']}['5']['allocation'])
                (queue / 'maintenance').unlink()
                wait_snapshot(lambda v: v['scheduler']['state'] == 'running' and v['summary']['reserved'] == 1)
                release.touch()
                value = wait_snapshot(lambda v: v['status'] == 'ok' and v['summary']['allocated'] == 2
                                      and v['summary']['reserved'] == 0)
                self.assertEqual(value['scheduler']['running_tasks'], 1)
                self.assertEqual(value['summary']['occupying_users'], 1)
                # The actual public CLI ignores a poisoned config and finds the
                # summary even when the real queue lives outside default state/.
                result = subprocess.run(['bash', str(app / 'task-submit.sh'), '--monitor', '--json'],
                                        env=dict(os.environ, TASKQUEUE_CONF='/missing', TASKQUEUE_DEVICE_POOL='123'),
                                        capture_output=True, text=True, timeout=1)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['boot_id'], boot)
                release_wait.touch()
                wait_snapshot(lambda v: v['status'] == 'ok' and v['scheduler']['running_tasks'] == 0)
                (queue / 'available_devices').write_text('5,9,12\n')
                with (config / 'taskqueue.conf').open('a') as conf:
                    conf.write('MAX_CONCURRENT=2\n')
                daemon.send_signal(signal.SIGHUP)
                changed = wait_snapshot(lambda v: v['scheduler']['max_concurrent'] == 2)
                devices = {d['id']: d for d in changed['devices']}
                self.assertEqual(devices['2']['state'], 'disabled')
                self.assertEqual(devices['12']['state'], 'free')
                # Whitespace between the value and an inline comment is part of
                # the config vocabulary, not part of the value.
                with (config / 'taskqueue.conf').open('a') as conf:
                    conf.write('MAX_CONCURRENT=3     # spaced reload comment\n')
                daemon.send_signal(signal.SIGHUP)
                wait_snapshot(lambda v: v['scheduler']['max_concurrent'] == 3)
                daemon.terminate()
                daemon.wait(timeout=10)
                result = subprocess.run(['bash', str(app / 'task-submit.sh'), '--monitor', '--json'],
                                        capture_output=True, text=True, timeout=1)
                self.assertEqual(json.loads(result.stdout)['scheduler']['state'], 'stopped')
                daemon = start()
                restarted = wait_snapshot(lambda v: v['boot_id'] != boot and v['status'] == 'ok')
                self.assertEqual(restarted['producer']['version'], 'installed-v2')
                self.assertEqual(restarted['snapshot_seq'], 1)
            finally:
                release.touch()
                release_wait.touch()
                if daemon is not None and daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=10)
                stderr.close()


if __name__ == '__main__':
    unittest.main()
