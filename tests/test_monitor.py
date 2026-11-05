#!/usr/bin/env python3
"""Monitor contract, kernel-lock, read-only CLI and failure-path tests."""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('monitor', REPO / 'monitor.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        for name in ('running', 'pending', 'locks'):
            (self.state / name).mkdir(parents=True)
        self.dev = self.root / 'dev'
        self.dev.mkdir()
        self.ids = ['2', '5', '9', '12']
        for device in self.ids:
            (self.dev / ('davinci' + device)).touch()
        (self.dev / 'davinci_manager').touch()
        self.context = dict(state_dir=str(self.state), version='running-revision', boot_id='daemon-boot', seq=1,
                            mode='pool_aware_reservation', max_concurrent=8, pool='2,5,9', groups='2,5;9,12',
                            reservation_task='', reservation_devices='', maintenance=False, scheduler_failed=False,
                            daemon=monitor.process_identity(os.getpid()), kernel_boot_id=monitor.kernel_boot_id())
        self.output = self.state / 'monitor.json'
        self.user = pwd.getpwuid(os.getuid()).pw_name

    def task(self, name, devices, user=None, kind='running'):
        identity = monitor.process_identity(os.getpid())
        (self.state / kind / name).write_text(
            f'SUBMIT_USER={user or self.user}\nDEVICE={devices}\n'
            f'RUN_TASK_PID={os.getpid()}\nRUN_TASK_START_TICKS={identity["start_ticks"]}\n'
            'START_TIME=2026-01-01T00:00:00+00:00\n'
            'COMMAND=SECRET_COMMAND\nWORK_DIR=SECRET_DIRECTORY\nPASSWORD=SECRET_PASSWORD\n')
        # This must never be opened (infinite character stream).
        (self.state / kind / (name + '.env')).symlink_to('/dev/zero')

    def collect(self):
        return monitor.collect(self.context, self.dev)

    def write(self, value=None):
        monitor.atomic_json(self.output, value if value is not None else self.collect())

    def test_empty_non_contiguous_and_disabled(self):
        value = self.collect()
        monitor.validate(value)
        self.assertEqual([d['id'] for d in value['devices']], self.ids)
        self.assertEqual([d['group_id'] for d in value['devices']], ['g0', 'g0', 'g1', 'g1'])
        self.assertEqual(value['scheduler']['running_tasks'], 0)
        self.assertEqual(value['summary'], dict(total=4, free=3, allocated=0, reserved=0, disabled=1,
                                               external=0, error=0, unknown=0, occupying_users=0))

    def test_no_hardware_and_failed_enumeration(self):
        for p in self.dev.iterdir():
            p.unlink()
        self.context['pool'] = ''
        self.assertEqual(self.collect()['summary']['total'], 0)
        self.context['pool'] = '2'
        self.assertEqual(self.collect()['status'], 'partial')
        self.assertIsNone(self.collect()['summary']['total'])
        with patch.object(monitor, 'device_ids', side_effect=PermissionError()):
            monitor.publish(self.context, self.output, self.dev)
        value, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertIsNone(value['scheduler']['running_tasks'])
        self.assertIsNone(value['summary']['free'])

    def test_multicard_cpu_tasks_uid_dedup_and_overlap(self):
        self.task('task_a', '2,5', 'root')
        self.task('task_b', '9', 'root')
        self.task('task_cpu', 'none', self.user)
        self.task('task_wait', 'auto:2', 'nobody', 'pending')
        self.context.update(reservation_task='task_wait', reservation_devices='5,12')
        value = self.collect()
        self.assertEqual(value['scheduler']['running_tasks'], 3)
        self.assertEqual(value['scheduler']['pending_tasks'], 1)
        self.assertEqual(value['summary']['allocated'], 3)
        self.assertEqual(value['summary']['occupying_users'], 1)
        overlap = value['devices'][1]
        self.assertEqual(overlap['state'], 'allocated')
        self.assertEqual(overlap['allocation']['user'], 'root')
        self.assertEqual(overlap['allocation']['uid'], 0)
        self.assertEqual(overlap['reservation']['user'], 'nobody')
        self.assertEqual(overlap['reservation']['requested_devices'], 2)
        self.assertEqual(value['devices'][3]['state'], 'disabled')
        self.context['pool'] = '2,5,9,12'
        self.assertEqual(self.collect()['devices'][3]['state'], 'reserved')
        data = json.dumps(value)
        self.assertNotIn('SECRET', data)
        self.assertNotIn('COMMAND', data)
        monitor.validate(value)

    def test_stale_lock_metadata_real_locks_and_pid_reuse(self):
        lock = self.state / 'locks/npu_device_2.lock'
        lock.write_text(f'pid={os.getpid()} user=root time=old\n')
        self.assertEqual(self.collect()['devices'][0]['state'], 'free')
        with lock.open('r') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            value = self.collect()
            self.assertEqual(value['devices'][0]['state'], 'unknown')
            self.assertIsNone(value['summary']['occupying_users'])
            self.assertIn('lock_holder_unattributed', value['devices'][0]['reason_codes'])
            self.task('task_a', '2')
            self.assertEqual(self.collect()['devices'][0]['state'], 'allocated')
            with (self.state / 'running/task_a').open('a') as task:
                task.write('RUN_TASK_START_TICKS=1\n')
            self.assertEqual(self.collect()['devices'][0]['state'], 'unknown')
        # A claimed, verified allocation remains occupied before lock acquisition
        # and after lock release during cleanup.
        with (self.state / 'running/task_a').open('a') as task:
            task.write(f'RUN_TASK_START_TICKS={monitor.process_identity(os.getpid())["start_ticks"]}\n')
        self.assertEqual(self.collect()['devices'][0]['state'], 'allocated')

    def test_unreadable_lock_table_never_free(self):
        with patch.object(monitor, 'lock_state', side_effect=PermissionError()):
            monitor.publish(self.context, self.output, self.dev)
        value, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertIsNone(value['summary']['free'])

    def test_maintenance_and_cancelled_reservation(self):
        self.context['maintenance'] = True
        (self.state / 'maintenance').write_text('private administrator text')
        value = self.collect()
        self.assertEqual(value['scheduler']['state'], 'maintenance')
        self.assertFalse(value['scheduler']['accepting_submissions'])
        self.assertFalse(value['scheduler']['dispatching'])
        self.assertNotIn('private administrator', json.dumps(value))
        self.context.update(reservation_task='task_gone', reservation_devices='2,5')
        monitor.publish(self.context, self.output, self.dev)
        value, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertEqual(value['reason'], 'reservation_changed')

    def test_age_restart_pid_reuse_and_stopped(self):
        value = self.collect()
        self.write(value)
        before, code = monitor.query(self.output)
        self.assertEqual(code, 0)
        time.sleep(.02)
        after, _ = monitor.query(self.output)
        self.assertGreater(after['age_ms'], before['age_ms'])
        self.assertEqual(after['observed_at'], before['observed_at'])
        value['observed_monotonic_ns'] -= 16_000_000_000
        self.write(value)
        stale, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertEqual(stale['reason'], 'snapshot_expired')
        self.assertTrue(all(d['state'] == 'unknown' for d in stale['devices']))
        self.assertIsNone(stale['scheduler']['running_tasks'])
        value = self.collect()
        value['daemon']['start_ticks'] -= 1
        self.write(value)
        stopped, code = monitor.query(self.output)
        self.assertEqual(code, 0)
        self.assertEqual(stopped['scheduler']['state'], 'stopped')
        self.assertFalse(stopped['scheduler']['dispatching'])
        self.context['daemon'] = monitor.process_identity(os.getpid())
        self.context.update(boot_id='next-daemon-boot', seq=1)
        self.write()
        restarted, code = monitor.query(self.output)
        self.assertEqual(code, 0)
        self.assertEqual(restarted['boot_id'], 'next-daemon-boot')
        value = self.collect()
        value['kernel_boot_id'] = 'previous-kernel'
        self.write(value)
        old_boot, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertIsNone(old_boot['age_ms'])

    def test_corruption_permission_size_and_counts(self):
        value, code = monitor.query(self.output)
        self.assertEqual(value['reason'], 'snapshot_missing')
        self.assertEqual(code, 1)
        for raw in ('{', '[]', '{}', 'null', '{"schema_version":999}', '[' * 1100,
                    'x' * (monitor.MAX_BYTES + 1)):
            self.output.write_text(raw)
            self.assertEqual(monitor.query(self.output)[1], 1)
        good = self.collect()
        for mutate in (lambda v: v['summary'].update(free=999),
                       lambda v: v.update(schema_version=2),
                       lambda v: v.update(summary=[]),
                       lambda v: v.update(observed_at='invalid'),
                       lambda v: v['devices'].append(v['devices'][0]),
                       lambda v: v['devices'][0].update(allocation={'task_id': 'bad'}),
                       lambda v: v['scheduler'].update(running_tasks=None),
                       lambda v: v['scheduler'].update(running_tasks=-1)):
            value = copy.deepcopy(good)
            mutate(value)
            self.write(value)
            self.assertEqual(monitor.query(self.output)[1], 1)
        self.write()
        with patch.object(monitor, 'bounded_read', side_effect=PermissionError()):
            self.assertEqual(monitor.query(self.output)[0]['reason'], 'permission_denied')
        if os.getuid() != 0:
            self.output.chmod(0)
            self.assertEqual(monitor.query(self.output)[0]['reason'], 'permission_denied')
            self.output.chmod(0o644)
        self.output.unlink()
        os.mkfifo(self.output)
        self.assertEqual(monitor.query(self.output)[1], 1)

    def test_racing_generation_is_not_published_as_free(self):
        with patch.object(monitor, 'signature', side_effect=lambda p: time.monotonic_ns()):
            monitor.publish(self.context, self.output, self.dev)
        value, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertEqual(value['reason'], 'concurrent_state_change')
        self.assertIsNone(value['summary']['free'])

    def test_boundaries_and_unknown_owner(self):
        for number in range(257):
            (self.dev / f'davinci{number}').touch()
        monitor.publish(self.context, self.output, self.dev)
        self.assertEqual(monitor.query(self.output)[0]['reason'], 'device_limit_exceeded')
        for path in self.dev.iterdir():
            if path.name not in {'davinci' + d for d in self.ids}:
                path.unlink()
        self.task('task_missing_user', '2', 'no_such_taskqueue_test_user_72318')
        value = self.collect()
        self.assertEqual(value['status'], 'partial')
        self.assertIsNone(value['devices'][0]['allocation']['uid'])
        self.assertIsNone(value['summary']['occupying_users'])
        (self.state / 'running/task_incomplete').write_text('SUBMIT_USER=root\n')
        monitor.publish(self.context, self.output, self.dev)
        unavailable, code = monitor.query(self.output)
        self.assertEqual(code, 1)
        self.assertEqual(unavailable['reason'], 'allocation_metadata_missing')
        self.assertIsNone(unavailable['summary']['free'])

    def test_cli_aliases_cwd_environment_cross_user_and_latency(self):
        app = self.root / 'app'
        app.mkdir()
        shutil.copy(REPO / 'monitor.py', app)
        shutil.copy(REPO / 'task-submit.sh', app / 'task-submit')
        (app / 'task-submit').chmod(0o755)
        (self.root / 'pto-task').symlink_to(app / 'task-submit')
        self.task('task_root', '2,5', 'root')
        self.task('task_nobody', '9', 'nobody')
        self.write()
        before = self.output.read_bytes()
        original_inode = self.output.stat().st_ino
        cwd = self.root / 'project'
        cwd.mkdir()
        (cwd / 'task-submit.conf').write_text('echo SHOULD_NOT_RUN\nDEVICE_WHITELIST=123\n')
        evil = cwd / 'evil.conf'
        evil.write_text('echo SHOULD_NOT_RUN; exit 99\n')
        env = dict(os.environ, TASKQUEUE_CONF=str(evil), TASKQUEUE_DEVICE_POOL='77',
                   TASKQUEUE_DEVICE_CONF=str(evil), STATE_DIR='/does-not-exist', TASKQUEUE_INSIDE='yes',
                   PYTHONPATH=str(cwd), PYTHONSTARTUP=str(evil))
        outputs, timings = [], []
        # Metadata can be inaccessible to the monitor, while the public summary
        # contains both users. No privileged execution is used by these queries.
        (self.state / 'running').chmod(0)
        self.addCleanup((self.state / 'running').chmod, 0o755)
        for command, directory in ((app / 'task-submit', self.root), (self.root / 'pto-task', cwd)):
            started = time.monotonic()
            proc = subprocess.run([str(command), '--monitor', '--json'], cwd=directory, env=env,
                                  capture_output=True, text=True, timeout=1)
            timings.append((time.monotonic() - started) * 1000)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stderr, '')
            result = json.loads(proc.stdout)
            self.assertEqual(result['summary']['occupying_users'], 2)
            result.pop('age_ms')
            outputs.append(result)
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(self.output.read_bytes(), before)
        self.assertEqual(self.output.stat().st_ino, original_inode)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o644)
        self.assertLess(max(timings), 500)
        print('monitor CLI latency (ms):', ', '.join(f'{t:.1f}' for t in timings))
        invalid = subprocess.run([str(app / 'task-submit'), '--monitor', '--json', '--cancel', 'task_root'],
                                 env=env, capture_output=True, text=True, timeout=1)
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(json.loads(invalid.stdout)['status'], 'unavailable')
        self.assertEqual(self.output.read_bytes(), before)

    def test_atomic_publication_preserves_previous_open_reader(self):
        self.write()
        with self.output.open() as previous:
            self.context['seq'] += 1
            self.write()
            self.assertEqual(json.load(previous)['snapshot_seq'], 1)
        self.assertEqual(json.loads(self.output.read_text())['snapshot_seq'], 2)
        self.assertFalse(list(self.state.glob('.monitor-*')))


if __name__ == '__main__':
    unittest.main()
