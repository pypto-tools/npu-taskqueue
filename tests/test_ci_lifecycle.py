#!/usr/bin/env python3
"""CI cancellation against an isolated real queue; no device access or services."""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


def fields(path):
    try:
        return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
    except FileNotFoundError:
        return {}


def process_identity(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()


class CiLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state'
        self.logs = self.root / 'logs'
        self.logs.mkdir()
        for name in ('pending', 'running', 'done', 'locks', 'kill', 'fifo', 'usage'):
            (self.state / name).mkdir(parents=True)
        config = self.root / 'config'
        config.mkdir(mode=0o755)
        self.config = config / 'taskqueue.conf'
        self.config.write_text(
            f'STATE_DIR={shlex.quote(str(self.state))}\nLOGS_DIR={shlex.quote(str(self.logs))}\n'
            'MAX_CONCURRENT=1\nSCHEDULER_MODE=backfill\nTASK_EXECUTION_MODE=root\n'
            'AVAILABLE_DEVICES=0\nKILL_GRACE=1\nMAX_TIME_HARD_CAP=0\n')
        self.config.chmod(0o644)
        fake = self.root / 'bin'
        fake.mkdir()
        # Match the existing unprivileged daemon fixtures. These shims only
        # satisfy startup ownership checks; all tasks still run as this user.
        (fake / 'id').write_text(
            '#!/bin/bash\nif [[ "$*" == -u ]]; then echo 0; else exec /usr/bin/id "$@"; fi\n')
        (fake / 'stat').write_text(
            '#!/bin/bash\nif [[ "$1" == -c && "$2" == %u && '
            '( "$3" == "$CI_TEST_ROOT/config" || "$3" == "$CI_TEST_ROOT/config/taskqueue.conf" ) ]]; '
            'then echo 0; else exec /usr/bin/stat "$@"; fi\n')
        for path in fake.iterdir():
            path.chmod(0o755)
        self.env = dict(os.environ, TASKQUEUE_CONF=str(self.config), CI_TEST_ROOT=str(self.root),
                        PATH=str(fake) + ':' + os.environ['PATH'])
        for key in ('GITHUB_ACTIONS', 'TASKQUEUE_INSIDE', 'TASKQUEUE_DEVICE_POOL', 'TASKQUEUE_DEVICE_CONF'):
            self.env.pop(key, None)
        self.processes = []
        self.handles = []
        self.daemon = None

    def tearDown(self):
        # Each client/daemon has its own process group. Also let daemon cleanup
        # sweep task sessions, including descendants which created a new SID.
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
        for process in reversed(self.processes):
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for handle in self.handles:
            handle.close()
        self.temporary.cleanup()

    def spawn(self, args, env=None):
        output = (self.root / f'process-{len(self.processes)}.log').open('w+')
        self.handles.append(output)
        process = subprocess.Popen(args, env=env or self.env, cwd=self.root,
                                   stdout=output, stderr=output, start_new_session=True)
        self.processes.append(process)
        return process

    def start_daemon(self, **extra_env):
        self.daemon = self.spawn(['bash', str(REPO / 'task-daemon.sh')], dict(self.env, **extra_env))
        self.wait_for(lambda: (self.state / 'task-daemon.pid').exists())

    def wait_for(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            if self.daemon is not None and self.daemon.poll() is not None:
                self.fail('daemon exited: ' + '\n'.join(p.read_text() for p in self.root.glob('process-*.log')))
            time.sleep(.05)
        self.fail('condition timed out: ' + '\n'.join(p.read_text() for p in self.root.glob('process-*.log')))

    def submit(self, command='sleep 60', ci=True, run=True):
        before = {p.name for directory in ('pending', 'running', 'done')
                  for p in (self.state / directory).glob('task_*') if p.suffix != '.env'}
        args = ['bash', str(REPO / 'task-submit.sh'), '--no-device', '--max-time', '0']
        if run:
            args.append('--run')
        args.append(command)
        client = self.spawn(args, dict(self.env, GITHUB_ACTIONS='true' if ci else 'false'))

        def submitted():
            for directory in ('pending', 'running', 'done'):
                for path in (self.state / directory).glob('task_*'):
                    if path.suffix != '.env' and path.name not in before:
                        return path.name
            return None

        return client, self.wait_for(submitted)

    def done(self, task):
        path = self.state / 'done' / task
        self.wait_for(lambda: path.exists() and not (self.state / 'running' / task).exists()
                      and 'EXIT_CODE' in fields(path))
        return fields(path)

    def assert_canceled_before_start(self, task):
        result = self.done(task)
        self.assertEqual(result['EXIT_CODE'], '143')
        self.assertEqual(result['CANCEL_REASON'], 'client_lost')
        self.assertEqual(result['ACCOUNTING_STATE'], 'not_started')
        self.assertNotIn('START_TIME', result)
        for directory in ('pending', 'running'):
            self.assertFalse((self.state / directory / (task + '.env')).exists())
        self.assertFalse((self.root / 'unexpected-start').exists())

    def test_killed_pending_client_in_maintenance(self):
        client, task = self.submit('touch unexpected-start')
        metadata = fields(self.state / 'pending' / task)
        self.assertEqual(metadata['CI_CLIENT_PID'], str(client.pid))
        self.assertEqual(metadata['CI_CLIENT_START_TICKS'], process_identity(client.pid)[19])
        self.assertEqual(metadata['CI_CLIENT_BOOT_ID'], Path('/proc/sys/kernel/random/boot_id').read_text().strip())
        client.kill()
        client.wait(timeout=5)
        (self.state / 'maintenance').touch()
        self.start_daemon()
        self.assert_canceled_before_start(task)

    def test_running_client_loss_sweeps_detached_term_ignoring_child(self):
        # File locks model a held resource without touching an NPU. The child
        # creates its own session and ignores TERM, exercising marker cleanup
        # and SIGKILL escalation rather than only killing the task leader.
        script = self.root / 'workload.py'
        script.write_text(
            'import fcntl, os, pathlib, signal, subprocess, sys, time\n'
            'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            'code = "import fcntl,os,pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
            'f=open(\'resource.lock\',\'w\'); fcntl.flock(f,fcntl.LOCK_EX); '
            'pathlib.Path(\'child.pid\').write_text(str(os.getpid())); time.sleep(60)"\n'
            'subprocess.Popen([sys.executable, "-c", code], start_new_session=True)\n'
            'time.sleep(60)\n')
        self.start_daemon()
        client, task = self.submit(f'python3 {shlex.quote(str(script))}')
        self.wait_for(lambda: (self.root / 'child.pid').exists())
        child = int((self.root / 'child.pid').read_text())
        client.kill()
        client.wait(timeout=5)
        result = self.done(task)
        self.assertNotEqual(result['EXIT_CODE'], '0')
        self.assertEqual(result['CANCEL_REASON'], 'client_lost')
        self.assertTrue(not Path(f'/proc/{child}/stat').exists() or process_identity(child)[0] in ('Z', 'X'))
        completed = subprocess.run(['flock', '-n', str(self.root / 'resource.lock'), 'true'], timeout=2)
        self.assertEqual(completed.returncode, 0, 'resource lock leaked after cancellation')
        following, following_task = self.submit('true')
        self.assertEqual(self.done(following_task)['EXIT_CODE'], '0')
        self.assertEqual(following.wait(timeout=5), 0)

    def test_pending_loss_while_all_slots_are_busy(self):
        self.start_daemon()
        _, busy = self.submit('touch busy; while [[ ! -f release ]]; do sleep .05; done', run=False)
        self.wait_for(lambda: (self.root / 'busy').exists())
        client, task = self.submit('touch unexpected-start')
        client.kill()
        client.wait(timeout=5)
        self.assert_canceled_before_start(task)
        self.assertTrue((self.state / 'running' / busy).exists())
        (self.root / 'release').touch()
        self.assertEqual(self.done(busy)['EXIT_CODE'], '0')

    def test_live_ci_client_and_exit_code_survive_submission_subshell(self):
        self.start_daemon()
        client, task = self.submit('sleep 1; exit 7')
        result = self.done(task)
        self.assertEqual(client.wait(timeout=5), 7)
        self.assertEqual(result['EXIT_CODE'], '7')
        self.assertEqual(result['CI_CLIENT_PID'], str(client.pid))
        self.assertNotIn('CANCEL_REASON', result)

    def test_done_is_published_only_after_result_is_complete(self):
        # Stop the result writer after its heredoc but before lifecycle fields
        # and chmod. Clients must not see done/ until all those steps finish.
        cat = self.root / 'bin/cat'
        cat.write_text(
            '#!/bin/bash\n/usr/bin/cat "$@" || exit $?\n'
            'target=$(readlink "/proc/$$/fd/1")\n'
            'if [[ "$target" == "$CI_TEST_ROOT/state/done/"* ]]; then\n'
            '  touch "$CI_TEST_ROOT/writing-result"\n'
            '  while [[ ! -f "$CI_TEST_ROOT/release-result" ]]; do sleep .05; done\n'
            'fi\n')
        cat.chmod(0o755)
        self.start_daemon()
        client, task = self.submit('true')
        try:
            self.wait_for(lambda: (self.root / 'writing-result').exists())
            self.assertFalse((self.state / 'done' / task).exists(), 'incomplete done record was published')
            self.assertIsNone(client.poll(), 'client consumed an incomplete result')
        finally:
            (self.root / 'release-result').touch()
        result = self.done(task)
        self.assertEqual(result['CI_CLIENT_PID'], str(client.pid))
        self.assertEqual(client.wait(timeout=5), 0)

    def test_sigkill_does_not_leave_a_log_follower(self):
        self.start_daemon()
        client, task = self.submit('sleep 60')

        def tail_child():
            children = Path(f'/proc/{client.pid}/task/{client.pid}/children').read_text().split()
            for child in children:
                try:
                    if Path(f'/proc/{child}/comm').read_text().strip() == 'tail':
                        return int(child)
                except FileNotFoundError:
                    pass
            return None

        tail = self.wait_for(tail_child)
        client.kill()
        client.wait(timeout=5)
        self.wait_for(lambda: not Path(f'/proc/{tail}/stat').exists()
                      or process_identity(tail)[0] in ('Z', 'X'), timeout=3)
        self.assertEqual(self.done(task)['CANCEL_REASON'], 'client_lost')

    def test_daemon_restart_recovers_lost_client_binding(self):
        self.start_daemon()
        client, task = self.submit('touch started; sleep 60')
        self.wait_for(lambda: (self.root / 'started').exists())
        old_daemon = self.daemon
        old_daemon.kill()
        old_daemon.wait(timeout=5)
        self.daemon = None
        client.kill()
        client.wait(timeout=5)
        self.start_daemon()
        result = self.done(task)
        self.assertEqual(result['CANCEL_REASON'], 'client_lost')
        self.assertNotEqual(result['EXIT_CODE'], '0')

    def test_canceling_one_client_does_not_cancel_another(self):
        self.start_daemon()
        first, first_task = self.submit('touch started; sleep 60')
        self.wait_for(lambda: (self.root / 'started').exists())
        second, second_task = self.submit('touch completed')
        first.kill()
        first.wait(timeout=5)
        self.assertEqual(self.done(first_task)['CANCEL_REASON'], 'client_lost')
        result = self.done(second_task)
        self.assertEqual(second.wait(timeout=5), 0)
        self.assertEqual(result['EXIT_CODE'], '0')
        self.assertNotIn('CANCEL_REASON', result)

    def test_repeated_cancel_requests_do_not_reset_grace_deadline(self):
        self.start_daemon()
        client, task = self.submit('touch started; sleep 60')
        self.wait_for(lambda: (self.root / 'started').exists())
        marker = self.state / 'kill' / task
        # Freeze daemon while checking CLI retries, so a real task cannot finish
        # between the two requests. The existing request must retain its mtime.
        self.daemon.send_signal(signal.SIGSTOP)
        try:
            self.wait_for(lambda: process_identity(self.daemon.pid)[0] == 'T')
            marker.write_text('CANCEL_REASON=user_cancel\n')
            os.utime(marker, (1, 1))
            for _ in range(2):
                result = subprocess.run(['bash', str(REPO / 'task-submit.sh'), '--kill', task],
                                        env=self.env, cwd=self.root, capture_output=True, text=True, timeout=7)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(marker.stat().st_mtime_ns, 1_000_000_000)
        finally:
            self.daemon.send_signal(signal.SIGCONT)
        self.assertEqual(self.done(task)['CANCEL_REASON'], 'user_cancel')
        client.wait(timeout=5)

    def test_non_ci_run_remains_detached_after_sigkill(self):
        client, task = self.submit('touch completed', ci=False)
        self.assertNotIn('CI_CLIENT_BOUND', fields(self.state / 'pending' / task))
        client.kill()
        client.wait(timeout=5)
        self.start_daemon()
        self.assertEqual(self.done(task)['EXIT_CODE'], '0')
        self.assertTrue((self.root / 'completed').exists())

    def test_ci_async_submission_remains_detached(self):
        client, task = self.submit('touch completed', run=False)
        self.assertEqual(client.wait(timeout=5), 0)
        self.assertNotIn('CI_CLIENT_BOUND', fields(self.state / 'pending' / task))
        self.start_daemon()
        self.assertEqual(self.done(task)['EXIT_CODE'], '0')

    def test_pid_reuse_and_boot_change_do_not_authenticate_owner(self):
        for field in ('CI_CLIENT_START_TICKS', 'CI_CLIENT_BOOT_ID'):
            with self.subTest(field=field):
                client, task = self.submit('touch unexpected-start')
                path = self.state / 'pending' / task
                path.write_text('\n'.join(f'{k}={"0" if k == field else v}'
                                         for k, v in fields(path).items()) + '\n')
                if self.daemon is None:
                    self.start_daemon()
                self.assert_canceled_before_start(task)
                client.wait(timeout=5)

    def test_zombie_client_is_not_alive(self):
        client, task = self.submit('touch unexpected-start')
        zombie = self.spawn(['bash', '-c', 'sleep .2'])
        ticks = process_identity(zombie.pid)[19]
        path = self.state / 'pending' / task
        metadata = fields(path)
        metadata.update(CI_CLIENT_PID=str(zombie.pid), CI_CLIENT_START_TICKS=ticks)
        path.write_text(''.join(f'{k}={v}\n' for k, v in metadata.items()))
        self.wait_for(lambda: process_identity(zombie.pid)[0] == 'Z')
        self.start_daemon()
        self.assert_canceled_before_start(task)
        client.wait(timeout=5)

    def test_signals_preserve_exit_code_and_durable_request(self):
        for sig, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 143)):
            with self.subTest(signal=sig):
                client, task = self.submit('touch unexpected-start')
                # Wait for handler installation, rather than racing task publication.
                self.wait_for(lambda: any(f'等待任务执行: {task}' in p.read_text()
                                          for p in self.root.glob('process-*.log')))
                client.send_signal(sig)
                self.assertEqual(client.wait(timeout=7), expected)
                self.assertEqual(fields(self.state / 'kill' / task)['CANCEL_REASON'], 'signal')
                self.assertFalse((self.state / 'pending' / task).exists())
                self.assertFalse((self.state / 'pending' / (task + '.env')).exists())

    def test_cancel_marker_during_atomic_claim_prevents_launch(self):
        client, task = self.submit('touch unexpected-start')
        # Inject a cancellation exactly inside the daemon's mv, after its
        # pre-claim check and before its post-claim check. No timing-based race.
        mv = self.root / 'bin/mv'
        mv.write_text(
            '#!/bin/bash\n/usr/bin/mv "$@" || exit $?\n'
            'if [[ "$1" == "$CI_TEST_ROOT/state/pending/$CI_TEST_TASK" ]]; then\n'
            '  printf "CANCEL_REASON=user_cancel\\n" > "$CI_TEST_ROOT/state/kill/$CI_TEST_TASK"\n'
            'fi\n')
        mv.chmod(0o755)
        self.start_daemon(CI_TEST_TASK=task)
        result = self.done(task)
        self.assertEqual(result['EXIT_CODE'], '143')
        self.assertEqual(result['CANCEL_REASON'], 'user_cancel')
        self.assertEqual(result['ACCOUNTING_STATE'], 'not_started')
        self.assertFalse((self.root / 'unexpected-start').exists())
        client.wait(timeout=5)

    def test_signal_during_pending_claim_keeps_marker_and_environment(self):
        client, task = self.submit('touch unexpected-start')
        rm = self.root / 'bin/rm'
        rm.write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == -f && "$2" == "$CI_TEST_ROOT/state/pending/"task_* && "$2" != *.env ]]; then\n'
            '  task=${2##*/}\n'
            '  /usr/bin/mv "$2" "$CI_TEST_ROOT/state/running/$task"\n'
            '  /usr/bin/mv "$2.env" "$CI_TEST_ROOT/state/running/$task.env"\n'
            'fi\nexec /usr/bin/rm "$@"\n')
        rm.chmod(0o755)
        self.wait_for(lambda: any(f'等待任务执行: {task}' in p.read_text()
                                  for p in self.root.glob('process-*.log')))
        client.terminate()
        self.assertEqual(client.wait(timeout=7), 143)
        self.assertEqual(fields(self.state / 'kill' / task)['CANCEL_REASON'], 'signal')
        self.assertTrue((self.state / 'running' / (task + '.env')).exists())
        self.assertFalse((self.root / 'unexpected-start').exists())


if __name__ == '__main__':
    unittest.main()
