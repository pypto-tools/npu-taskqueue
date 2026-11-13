"""Behavioral fixtures; no test invokes the host's npu-smi or real device API."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('device_usage', REPO / 'device_usage.py')
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)

# Legacy and 950 mapping layouts are deliberately different. Physical-ID remap:
# https://www.hiascend.com/document/detail/zh/Atlas%20200I%20A2/253RC1/re/npu/npusmi_059.html
# 950 mapping and no-chip query:
# https://github.com/SwanHubX/SwanLab/blob/main/swanlab/sdk/internal/probe_python/hardware_vendor/accelerator/huawei.py
A3_TABLE = 'NPU ID  Chip ID  Chip Logic ID  Chip Name\n3 0 0 Ascend 910\n3 1 1 Ascend 910\n'
A3_PHYSICAL_TABLE = ('NPU ID  Chip ID  Chip Logic ID  Chip Phy-ID  Chip Name\n'
                     '7 0 0 11 Ascend910\n7 1 1 12 Ascend910\n7 2 - - Mcu\n')
A5_TABLE = 'NPU ID  Slot ID  Chip ID  Chip Phy-ID  Chip Name\n7 5 0 12 Ascend950PR\n9 6 0 15 Ascend950DT\n'


class ClassificationTests(unittest.TestCase):
    def card(self):
        return usage.Card(started=0, interval=15, grace=60, threshold=120)

    def test_grace_threshold_and_recovery(self):
        card = self.card()
        zero = {'compute': 0}
        for now in range(0, 180, 15):
            card.observe(now, zero)
            self.assertNotEqual(card.data['state'], 'suspected_idle')
        card.observe(180, zero)
        self.assertEqual(card.data['state'], 'suspected_idle')
        self.assertEqual(card.data['idle_seconds'], 120)
        card.observe(195, zero)
        self.assertEqual(card.data['idle_seconds'], 135)
        card.observe(210, {'compute': .1})
        self.assertEqual(card.data['state'], 'active')
        self.assertEqual(card.data['events'][0]['ended_at'], 195)
        self.assertEqual(card.data['events'][0]['end_reason'], 'activity')

    def test_failure_and_gap_break_zero_streak(self):
        for failure in (True, False):
            with self.subTest(failure=failure):
                card = self.card()
                for now in range(60, 166, 15):
                    card.observe(now, {'compute': 0})
                if failure:
                    card.observe(180, reason='query_timeout')
                    self.assertEqual(card.data['state'], 'unknown')
                card.observe(210, {'compute': 0})
                self.assertEqual(card.data['event_count'], 0)
                self.assertEqual(card.data['idle_seconds'], 0)

    def test_unknown_closes_event_without_charging_gap(self):
        card = self.card()
        for now in range(60, 196, 15):
            card.observe(now, {'compute': 0})
        card.observe(210, reason='query_failed')
        self.assertEqual(card.data['idle_seconds'], 135)
        self.assertEqual(card.data['events'][0]['ended_at'], 195)
        self.assertEqual(card.data['state'], 'unknown')

    def test_events_are_bounded_but_totals_survive(self):
        card = usage.Card(0, 1, 0, 1)
        for now in range(90):
            card.observe(now, {'compute': 10 if now % 3 == 2 else 0})
        self.assertEqual(card.data['event_count'], 30)
        self.assertEqual(len(card.data['events']), usage.MAX_EVENTS)
        self.assertEqual(card.data['idle_seconds'], 30)

    def test_metrics_do_not_turn_unknown_into_zero(self):
        for output in ('HBM Usage Rate(%): 0', 'Aicore Usage Rate(%): N/A',
                       'Aicore Usage Rate(%): -1', 'Aicore Usage Rate(%): 101',
                       'Aicore Usage Rate(%): nan', 'Aicore Usage Rate(%): 0\nNPU Utilization: N/A',
                       'Aicore Usage Rate(%): 0\nAivector Utilization(%): 50',
                       'Aicore Usage Rate(%): 0\nAicore Usage Rate(%): 50'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                usage.metrics(output)
        values = usage.metrics('Aicore Usage Rate(%): 0\nAiv Usage Rate(%): 5.5\nHBM Usage Rate(%): 90')
        self.assertEqual(values['compute'], 5.5)
        self.assertEqual(values['hbm'], 90)

    def test_platform_mappings(self):
        self.assertIsNone(usage.physical_mapping(A3_TABLE))
        self.assertEqual(usage.physical_mapping(A3_PHYSICAL_TABLE)['12'],
                         {'npu': '7', 'chip': '1', 'profile': 'legacy'})
        self.assertEqual(usage.physical_mapping(A5_TABLE)['12'],
                         {'npu': '7', 'chip': None, 'profile': 'ascend950'})
        remap = 'Chip Physical ID: 12\nChip Logic ID: 0\nNPU ID: 7\nChip ID: 1'
        self.assertEqual(usage.remapped_device(remap, '12')['chip'], '1')
        with self.assertRaises(ValueError):
            usage.remapped_device(remap, '0')
        with self.assertRaises(ValueError):
            usage.physical_mapping('NPU ID  Slot ID  Chip ID  Chip Name\n7 5 0 Ascend950PR')

    def test_invalid_timeouts_are_finite(self):
        for value in ('0', '-1', 'nan', 'inf', '99999', 'bad'):
            self.assertEqual(usage.number(value, 2, .05, 5), 2)

    def test_multicard_partial_idle_and_compute_activity(self):
        sampler = usage.Sampler(['12', '15'], grace=0, threshold=1, interval=1)
        start = sampler.started
        for offset in (0, 1):
            sampler.cards['12'].observe(start + offset, {'compute': 0})
            sampler.cards['15'].observe(start + offset, {'compute': 1})
        data = sampler.snapshot('task_1', 'example', start + 1)
        self.assertIn('部分卡', usage.describe(data))
        self.assertEqual(data['devices']['15']['idle_seconds'], 0)

    def test_describe_keeps_idle_history_alongside_current_state(self):
        sampler = usage.Sampler(['12'], grace=0, threshold=1, interval=1)
        start = sampler.started
        sampler.cards['12'].observe(start, {'compute': 0})
        sampler.cards['12'].observe(start + 1, {'compute': 0})
        data = sampler.snapshot('task_1', 'example', start + 1)
        self.assertEqual(usage.describe(data),
                         '曾疑似占卡空闲 12=1s；当前：疑似占卡空闲（全部卡）: 12=1s')
        sampler.cards['12'].observe(start + 2, {'compute': 5})
        data = sampler.snapshot('task_1', 'example', start + 2)
        self.assertEqual(usage.describe(data), '曾疑似占卡空闲 12=1s；当前：未标记空闲')

    def test_uninterruptible_probe_is_bounded_and_not_replaced(self):
        probes = usage.Probes(timeout=2, concurrency=1)
        proc = mock.Mock(pid=12345)
        proc.poll.return_value = None  # Models D-state: even SIGKILL has no effect.
        reader, writer = os.pipe()
        os.close(writer)
        output = os.fdopen(reader, 'rb')
        os.set_blocking(reader, False)
        probes.jobs['inventory'] = dict(proc=proc, output=output, buffer=bytearray(), overflow=False,
                                       started=0, terminated=None, reported=False)
        with mock.patch.object(usage.os, 'killpg') as signals:
            self.assertEqual(probes.poll(2), [('inventory', '', 'query_timeout')])
            self.assertEqual(probes.poll(3), [])
            self.assertFalse(probes.start(('usage', '12'), [], 4))
            probes.stop()
            self.assertEqual(signals.call_args_list[-1].args[1], signal.SIGKILL)
        proc.wait.assert_not_called()

    def test_canceled_successful_exit_is_not_a_valid_sample(self):
        probes = usage.Probes()
        reader, writer = os.pipe()
        os.close(writer)
        output = os.fdopen(reader, 'rb')
        os.set_blocking(reader, False)
        proc = mock.Mock(pid=12345)
        proc.poll.return_value = 0
        probes.jobs[('usage', '12')] = dict(proc=proc, output=output,
            buffer=bytearray(b'Aicore Usage Rate(%): 0'), overflow=False,
            started=0, terminated=None, reported=False)
        with mock.patch.object(usage.os, 'killpg'):
            probes.cancel(('usage', '12'), 1)
            result = probes.poll(1.1)
        self.assertEqual(result[0][2], 'query_timeout')
        self.assertFalse(probes.jobs)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.fake = self.root / 'bin'
        self.fake.mkdir()
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.task = 'task_20260101_000001_1'
        self.output = self.state / 'usage/tasks' / (self.task + '.json')
        self.trace = self.root / 'trace'
        usage.prepare(self.state, self.task, self.user, ['12'])
        # Fake device binary also asserts allocation and noninheritance of locks.
        self.binary = self.fake / 'npu-smi'
        self.binary.write_text('''#!/usr/bin/env python3
import fcntl, json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
assert os.environ['TASKQUEUE_INSIDE'] == '1'
for fd in Path('/proc/self/fd').iterdir():
    try:
        assert 'npu_device_' not in os.readlink(fd)
    except FileNotFoundError:
        pass
with open(os.environ['TRACE'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
mode = os.environ.get('PROBE_MODE', 'a3')
if os.environ.get('EXTRA_DRIVER_LOG'):
    Path(os.environ['EXTRA_DRIVER_LOG']).write_bytes(b'x' * 131072)
if mode == 'excess_output':
    os.write(1, b'x' * 100000)
    sys.exit(0)
if mode == 'hang':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), file=open(os.environ['PROBE_PID'], 'a'), flush=True)
    while True: time.sleep(1)
if args == ['info', '-m']:
    print(os.environ['TABLE'])
elif args[:3] == ['info', '-t', 'phyid-remap']:
    assert args[3:] == ['-p', '12']
    print('Chip Physical ID: 12\\nChip Logic ID: 0\\nNPU ID: 7\\nChip ID: 1')
else:
    expected = ['info', '-t', 'usages', '-i', '7']
    if mode == 'a3': expected += ['-c', '1']
    assert args == expected, args
    print('Aicore Usage Rate(%): 0\\nHBM Usage Rate(%): 75')
''')
        self.binary.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.fake) + ':' + os.environ['PATH'],
                        TASKQUEUE_INSIDE='1', TASK_DEVICE='12', TRACE=str(self.trace),
                        TASKQUEUE_LOCK_STATE_DIR=str(self.state),
                        TABLE=A3_TABLE, PROBE_PID=str(self.root / 'probe-pid'))

    def execute(self, command, **overrides):
        env = dict(self.env, **overrides)
        return subprocess.run(['bash', str(REPO / 'npu_lock.sh'), '12', '--timeout', '1', '--',
                               sys.executable, '-I', str(REPO / 'device_usage.py'), 'run',
                               '--output', str(self.output), '--task-id', self.task,
                               '--user', self.user, '--devices', '12', '--interval', '.3',
                               '--timeout', '.15', '--round-timeout', '.5',
                               '--grace', '0', '--threshold', '.3', '--', *command],
                              env=env, capture_output=True, text=True, timeout=8)

    def test_a3_and_a5_query_correct_card_and_preserve_exit(self):
        for profile, table in (('a3', A3_TABLE), ('a3', A3_PHYSICAL_TABLE), ('a5', A5_TABLE)):
            with self.subTest(profile=profile):
                self.trace.unlink(missing_ok=True)
                result = self.execute(['bash', '-c', 'sleep 1.3; echo result; exit 7'],
                                      TABLE=table, PROBE_MODE=profile)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertIn('result', result.stdout)
                data = usage.read_snapshot(self.state, self.task)
                self.assertIsNotNone(data['finished_at'])
                self.assertGreater(data['devices']['12']['valid_samples'], 1)
                self.assertGreater(data['devices']['12']['event_count'], 0)
                trace = [json.loads(line) for line in self.trace.read_text().splitlines()]
                queries = [line for line in trace if 'usages' in line]
                self.assertTrue(queries)
                self.assertEqual('-c' in queries[0], profile == 'a3')

    def test_workload_finish_does_not_wait_for_stuck_query(self):
        started = time.monotonic()
        result = self.execute(['sleep', '.4'], PROBE_MODE='hang')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 1.5)
        data = usage.read_snapshot(self.state, self.task)
        self.assertEqual(data['devices']['12']['state'], 'unknown')
        self.assertEqual(data['devices']['12']['idle_seconds'], 0)
        self.assertLessEqual(len(self.trace.read_text().splitlines()), 2)
        for pid in (self.root / 'probe-pid').read_text().splitlines():
            deadline = time.monotonic() + 1
            while Path('/proc', pid).exists() and time.monotonic() < deadline:
                if ') Z ' in Path('/proc', pid, 'stat').read_text():
                    break
                time.sleep(.02)
            if Path('/proc', pid, 'stat').exists():
                self.assertIn(') Z ', Path('/proc', pid, 'stat').read_text())

    def test_driver_log_size_is_not_limited(self):
        log = self.root / 'driver.log'
        result = self.execute(['sleep', '.8'], EXTRA_DRIVER_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.stat().st_size, 131072)
        data = usage.read_snapshot(self.state, self.task)
        self.assertGreater(data['devices']['12']['valid_samples'], 0)

    def test_excess_query_output_is_unknown_and_bounded(self):
        started = time.monotonic()
        result = self.execute(['sleep', '.8'], PROBE_MODE='excess_output')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 2)
        card = usage.read_snapshot(self.state, self.task)['devices']['12']
        self.assertEqual(card['state'], 'unknown')
        self.assertEqual(card['reason'], 'query_output_limit')
        self.assertEqual(card['idle_seconds'], 0)

    def test_refuses_sampling_without_matching_allocation(self):
        result = self.execute(['true'], TASK_DEVICE='13')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.trace.exists())

    def test_no_hardware_queries_from_readers(self):
        self.execute(['sleep', '.7'])
        previous = self.trace.read_text()
        env = dict(self.env, TASKQUEUE_CONF=str(self.root / 'taskqueue.conf'))
        env.pop('TASKQUEUE_INSIDE', None)
        (self.root / 'taskqueue.conf').write_text('STATE_DIR=' + str(self.state) + '\n')
        result = subprocess.run(['bash', str(REPO / 'task-submit.sh'), '--device-usage', self.task, '--json'],
                                env=env, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['task_id'], self.task)
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            usage.report(self.state, 7)
        self.assertIn(self.user, captured.getvalue())
        subprocess.run(['bash', str(REPO / 'pto-task-usage-sampler.sh')], env=env, check=True,
                       capture_output=True, timeout=3)
        self.assertEqual(self.trace.read_text(), previous)

    def test_public_ranking_cli_is_read_only(self):
        self.execute(['sleep', '.8'])
        before = self.trace.read_text()
        config = self.root / 'ranking.conf'
        config.write_text('STATE_DIR=' + str(self.state) + '\n')
        env = dict(self.env, TASKQUEUE_CONF=str(config))
        env.pop('TASKQUEUE_INSIDE', None)
        for metric in ('utilization', 'coverage'):
            result = subprocess.run(['bash', str(REPO / 'task-submit.sh'), '--usage-ranking',
                                     '--days', '0', '--sort', metric, '--json'],
                                    env=env, capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data['sort'], metric)
            self.assertEqual(data['ranking'][0]['user'], self.user)
            self.assertNotIn(self.task, result.stdout)
        self.assertEqual(self.trace.read_text(), before)

    def test_unknown_mapping_never_queries_wrong_card(self):
        result = self.execute(['sleep', '.7'], TABLE='Unsupported driver output')
        self.assertEqual(result.returncode, 0)
        data = usage.read_snapshot(self.state, self.task)
        self.assertEqual(data['devices']['12']['state'], 'unknown')
        self.assertEqual(data['devices']['12']['event_count'], 0)
        self.assertTrue(all(json.loads(line) == ['info', '-m'] for line in self.trace.read_text().splitlines()))

    def test_stale_and_malformed_files_are_not_idle(self):
        sampler = usage.Sampler(['12'])
        data = sampler.snapshot(self.task, self.user, sampler.started)
        now = time.time()
        data['started_at'] = now - 120
        data['devices']['12'].update(state='suspected_idle', observed_at=now - 100,
            event_count=1, events=[dict(started_at=now-110, last_observed_at=now-100,
                                       ended_at=None, end_reason=None)])
        self.output.write_text(json.dumps(data))
        self.assertEqual(usage.read_snapshot(self.state, self.task)['devices']['12']['state'], 'unknown')
        self.output.write_text('{')
        with self.assertRaises(ValueError):
            usage.read_snapshot(self.state, self.task)

    def test_corrupt_records_cannot_crash_public_queries(self):
        config = self.root / 'corrupt.conf'
        config.write_text('STATE_DIR=' + str(self.state) + '\n')
        env = dict(self.env, TASKQUEUE_CONF=str(config))
        env.pop('TASKQUEUE_INSIDE', None)
        sampler = usage.Sampler(['12'])
        missing_event = sampler.snapshot(self.task, self.user, sampler.started, final=True)
        missing_event['devices']['12']['state'] = 'suspected_idle'
        invalid_event = json.loads(json.dumps(missing_event))
        invalid_event['devices']['12']['events'] = [dict(started_at=float('nan'),
            last_observed_at=0, ended_at=None, end_reason=None)]
        for payload in ('[' * 2000 + '0' + ']' * 2000, json.dumps(missing_event), json.dumps(invalid_event)):
            with self.subTest(payload=payload[:30]):
                self.output.write_text(payload)
                ranked = subprocess.run(['bash', str(REPO / 'task-submit.sh'), '--usage-ranking', '--json'],
                                        env=env, capture_output=True, text=True, timeout=3)
                self.assertEqual(ranked.returncode, 0, ranked.stderr)
                result = json.loads(ranked.stdout)
                self.assertEqual(result['status'], 'partial')
                self.assertEqual(result['skipped_records'], 1)
                detail = subprocess.run(['bash', str(REPO / 'task-submit.sh'), '--device-usage', self.task, '--json'],
                                        env=env, capture_output=True, text=True, timeout=3)
                self.assertEqual(detail.returncode, 1)
                self.assertEqual(json.loads(detail.stdout)['status'], 'unknown')
                self.assertNotIn('Traceback', detail.stderr)

    def test_oversized_allocation_disables_only_telemetry(self):
        devices = ','.join(str(i) for i in range(usage.MAX_DEVICES + 1))
        result = subprocess.run([sys.executable, '-I', str(REPO / 'device_usage.py'), 'run',
            '--output', str(self.output), '--task-id', self.task, '--user', self.user,
            '--devices', devices, '--', sys.executable, '-c', 'raise SystemExit(7)'],
            env=dict(self.env, TASK_DEVICE=devices), capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn('telemetry disabled', result.stderr)
        self.assertFalse(self.trace.exists())

    def test_safe_files_and_prepare_collision(self):
        with self.assertRaises(FileExistsError):
            usage.prepare(self.state, self.task, self.user)
        self.output.unlink()
        target = self.root / 'untouched'
        target.write_text('unchanged')
        self.output.symlink_to(target)
        result = self.execute(['true'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(), 'unchanged')
        with self.assertRaises(OSError):
            usage.read_snapshot(self.state, self.task)

    def test_probe_guard_blocks_replacements_across_tasks(self):
        guard = (self.state / 'usage/probe-locks/inventory.lock').open('r+')
        self.addCleanup(guard.close)
        usage.fcntl.flock(guard.fileno(), usage.fcntl.LOCK_EX)
        result = self.execute(['sleep', '.5'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertEqual(usage.read_snapshot(self.state, self.task)['devices']['12']['state'], 'unknown')
        usage.fcntl.flock(guard.fileno(), usage.fcntl.LOCK_UN)
        result = self.execute(['sleep', '.7'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.trace.exists())

    def test_daemon_integration_and_cpu_task_has_no_probes(self):
        app = self.root / 'app'
        app.mkdir()
        for name in ('device_usage.py', 'monitor.py', 'npu_lock.sh'):
            shutil.copy(REPO / name, app / name)
        shutil.copytree(REPO / 'schedulers', app / 'schedulers')
        (app / 'schedulers').chmod(0o755)
        for path in (app / 'schedulers').iterdir():
            path.chmod(0o644)
        # Match existing daemon fixtures: simulate administrative startup without
        # privileges in a private application copy, never a production override.
        daemon_source = (REPO / 'task-daemon.sh').read_text().replace(
            'sample_user=root', 'sample_user=' + self.user)
        (app / 'task-daemon.sh').write_text(daemon_source)
        (self.fake / 'id').write_text('#!/bin/bash\nif [[ "$*" == -u ]]; then echo 0; else exec /usr/bin/id "$@"; fi\n')
        (self.fake / 'stat').write_text(
            '#!/bin/bash\nif [[ "$1" == -c && "$2" == %u && "$3" == "$USAGE_TEST_ROOT"/* ]]; '
            'then echo 0; else exec /usr/bin/stat "$@"; fi\n')
        for path in self.fake.iterdir():
            path.chmod(0o755)
        config = self.root / 'config'
        config.mkdir()
        logs = self.root / 'logs'
        logs.mkdir()
        for name in ('pending', 'running', 'done', 'locks', 'kill', 'fifo'):
            (self.state / name).mkdir(exist_ok=True)
        (config / 'taskqueue.conf').write_text(
            f'STATE_DIR="{self.state}"\nLOGS_DIR="{logs}"\n'
            'TASK_EXECUTION_MODE=root\nAVAILABLE_DEVICES=12\nMAX_CONCURRENT=1\n'
            'USAGE_SAMPLING_ENABLED=true\nUSAGE_SAMPLE_INTERVAL=.3\nUSAGE_IDLE_GRACE=0\n'
            'USAGE_IDLE_SECONDS=.3\nKILL_GRACE=1\n')
        env = dict(self.env, USAGE_TEST_ROOT=str(self.root), TASKQUEUE_CONF=str(config / 'taskqueue.conf'))
        env.pop('TASKQUEUE_INSIDE', None)
        env.pop('TASK_DEVICE', None)
        stderr = (self.root / 'daemon.stderr').open('w+')
        self.addCleanup(stderr.close)
        daemon = subprocess.Popen(['bash', str(app / 'task-daemon.sh')], env=env,
                                  stdout=subprocess.DEVNULL, stderr=stderr)
        try:
            client = ['bash', str(REPO / 'task-submit.sh')]
            try:
                result = subprocess.run([*client, '--device', '12', '--run', 'sleep 1.1; exit 7'],
                                        env=env, capture_output=True, text=True, timeout=12)
            except subprocess.TimeoutExpired as exc:
                self.fail(f'client timeout: {exc.stdout!r} {exc.stderr!r}; '
                          f'daemon={daemon.poll()}; stderr={(self.root / "daemon.stderr").read_text()}; '
                          f'log={(logs / "taskqueue.log").read_text() if (logs / "taskqueue.log").exists() else "missing"}')
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr +
                             (self.root / 'daemon.stderr').read_text())
            records = list((self.state / 'usage/tasks').glob('*.json'))
            samples = [p for p in records if p != self.output]
            self.assertEqual(len(samples), 1)
            data = usage.read_snapshot(self.state, samples[0].stem)
            self.assertGreater(data['devices']['12']['valid_samples'], 0)
            before = self.trace.read_text()
            result = subprocess.run([*client, '--no-device', '--run', 'true'], env=env,
                                    capture_output=True, text=True, timeout=12)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.trace.read_text(), before)
            listed = subprocess.run([*client, '--stats'], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(listed.returncode, 0, listed.stderr)
            self.assertIn('疑似空闲', listed.stdout)
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=2)


class RankingTests(unittest.TestCase):
    def snapshot(self, user, duration=100, samples=10, compute=50, coverage=.5, age=0):
        now = 1_000_000
        return dict(user=user, task_id='task_private_id', command='private command',
                    started_at=now - duration - age, updated_at=now - age, finished_at=now - age,
                    devices={'12': dict(idle_seconds=0., valid_seconds=duration * coverage,
                        compute_sum=samples * compute, valid_samples=samples, samples=samples,
                        event_count=0)})

    def test_weighted_ranking_and_unknown_last(self):
        snapshots = [self.snapshot('alice', samples=10, compute=100, coverage=1),
                     self.snapshot('alice', duration=900, samples=90, compute=0, coverage=0),
                     self.snapshot('bob', samples=20, compute=50),
                     self.snapshot('unknown', samples=0)]
        with mock.patch.object(usage, 'records', return_value=(snapshots, {'skipped_records': 0})), \
             mock.patch.object(usage.time, 'time', return_value=1_000_000):
            data = usage.ranking(Path('/unused'), days=0)
        self.assertEqual([row['user'] for row in data['ranking']], ['alice', 'bob', 'unknown'])
        self.assertEqual(data['ranking'][0]['mean_compute_utilization_pct'], 10)
        self.assertEqual(data['ranking'][0]['valid_coverage_pct'], 10)
        self.assertIsNone(data['ranking'][2]['mean_compute_utilization_pct'])
        self.assertIsNone(data['ranking'][2]['rank'])
        self.assertNotIn('private command', json.dumps(data))
        self.assertNotIn('task_private_id', json.dumps(data))

    def test_coverage_sort_limit_and_window(self):
        snapshots = [self.snapshot('alice', compute=10, coverage=.9),
                     self.snapshot('bob', compute=90, coverage=.2),
                     self.snapshot('older', age=8*86400, compute=100, coverage=1)]
        with mock.patch.object(usage, 'records', return_value=(snapshots, {'skipped_records': 1})), \
             mock.patch.object(usage.time, 'time', return_value=1_000_000):
            data = usage.ranking(Path('/unused'), days=7, sort='coverage', limit=1)
        self.assertEqual(data['total_users'], 2)
        self.assertEqual(len(data['ranking']), 1)
        self.assertEqual(data['ranking'][0]['user'], 'bob')
        self.assertEqual(data['status'], 'partial')
        self.assertEqual(data['skipped_records'], 1)

    def test_stats_filter_stays_separate_from_public_ranking(self):
        snapshots = [self.snapshot('alice'), self.snapshot('bob')]
        rows = usage.aggregate(snapshots, 0, 1_000_000, user='alice')
        self.assertEqual([row['user'] for row in rows], ['alice'])
        self.assertEqual(len(usage.aggregate(snapshots, 0, 1_000_000)), 2)

    def test_empty_ranking_and_deterministic_ties(self):
        with mock.patch.object(usage, 'records', return_value=([], {'skipped_records': 0})):
            data = usage.ranking(Path('/unused'))
        self.assertEqual(data['status'], 'empty')
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            usage.print_ranking(data)
        self.assertIn('暂无', captured.getvalue())
        with mock.patch.object(usage, 'records', return_value=(
                [self.snapshot('bob'), self.snapshot('alice')], {'skipped_records': 0})), \
             mock.patch.object(usage.time, 'time', return_value=1_000_000):
            data = usage.ranking(Path('/unused'), days=0)
        self.assertEqual([row['user'] for row in data['ranking']], ['alice', 'bob'])


if __name__ == '__main__':
    unittest.main()
