#!/usr/bin/env python3
"""Advisory device telemetry, collected only inside an allocated queue job.

The workload and probes are supervised independently. Hardware probes never run
in the daemon or a query command, and no probe is waited for without a deadline.
Submitters can edit their own telemetry; it is not a scheduling/accounting input.
"""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys
import time

MAX_BYTES = 256 * 1024
MAX_DEVICES = 64
MAX_EVENTS = 16


def number(value, default, minimum, maximum):
    try:
        value = float(value)
        return value if math.isfinite(value) and minimum <= value <= maximum else default
    except (TypeError, ValueError):
        return default


def fields(output):
    result = {}
    for line in output.splitlines():
        key, sep, value = line.strip().strip('|').partition(':')
        if sep:
            key = re.sub(r'\s+', ' ', key.strip().lower())
            if key in result:
                raise ValueError('ambiguous metric fields')
            result[key] = value.strip().strip('|').strip()
    return result


def physical_mapping(output):
    """Ascend 950's table identifies physical devices explicitly.

    A3 tables may contain both logic and physical columns. Older logic-only
    tables require phyid-remap for each allocated /dev/davinciN instead.
    """
    lines = [line.strip().strip('|').strip() for line in output.splitlines() if line.strip()]
    header = next((i for i, line in enumerate(lines) if 'NPU ID' in line), None)
    if header is None:
        raise ValueError('mapping header missing')
    if 'Chip Logic ID' in lines[header] and 'Chip Phy-ID' not in lines[header]:
        return None
    is_950 = 'Slot ID' in lines[header]
    if (not all(key in lines[header] for key in ('Chip ID', 'Chip Phy-ID', 'Chip Name'))
            or not is_950 and 'Chip Logic ID' not in lines[header]):
        raise ValueError('unsupported mapping format')
    result = {}
    for line in lines[header + 1:]:
        parts = line.replace('|', ' ').split()
        if len(parts) < 5:
            continue
        if is_950:
            npu, slot, chip, physical, *name = parts
        else:
            npu, chip, logic, physical, *name = parts
        if not all(x.isdigit() for x in (npu, chip, physical)):
            continue  # MCU rows have no physical ID.
        if physical in result or not any(('950' if is_950 else '910') in x for x in name):
            raise ValueError('ambiguous or unsupported physical mapping')
        # The 950 usages query addresses the NPU, without legacy -c.
        result[physical] = {'npu': npu, 'chip': None if is_950 else chip,
                            'profile': 'ascend950' if is_950 else 'legacy'}
    if not result:
        raise ValueError('physical mapping empty')
    return result


def remapped_device(output, device):
    values = fields(output)
    if values.get('chip physical id') != device:
        raise ValueError('physical device mismatch')
    npu, chip = values.get('npu id', ''), values.get('chip id', '')
    if not npu.isdigit() or not chip.isdigit():
        raise ValueError('incomplete physical mapping')
    return {'npu': npu, 'chip': chip, 'profile': 'legacy'}


def metrics(output):
    values = fields(output)
    result = {}
    aliases = {'aicore': ('aicore usage rate', 'ai core usage rate'),
               'aivector': ('aivector usage rate', 'aiv usage rate'),
               'aicpu': ('aicpu usage rate', 'ai cpu usage rate'),
               'aicube': ('aicube usage rate', 'cube usage rate'),
               'npu': ('npu utilization',), 'hbm': ('hbm usage rate',)}
    known = {key for keys in aliases.values() for key in keys}
    for key in values:
        normalized = re.sub(r'\s*\(%\)$', '', key)
        if (re.search(r'usage|utilization', key) and
                re.search(r'aicore|aicpu|aiv|ai core|ai cpu|ai vector|cube|vector|compute', key)
                and normalized not in known):
            raise ValueError('unsupported computation metric')
    for name, keys in aliases.items():
        matches = [value for key, value in values.items()
                   if re.sub(r'\s*\(%\)$', '', key) in keys]
        if len(matches) > 1:
            raise ValueError('ambiguous utilization')
        if matches:
            value = matches[0].rstrip('%').strip()
            if not re.fullmatch(r'\d+(?:\.\d+)?', value) or not 0 <= float(value) <= 100:
                # An unsupported compute metric cannot become zero.
                if name != 'hbm':
                    raise ValueError('unknown computation utilization')
            else:
                result[name] = float(value)
    compute = [result[name] for name in ('aicore', 'aivector', 'aicpu', 'aicube', 'npu') if name in result]
    if not compute:
        raise ValueError('no computation utilization')
    result['compute'] = max(compute)
    return result


class Card:
    def __init__(self, started, interval, grace, threshold):
        self.started, self.interval, self.grace, self.threshold = started, interval, grace, threshold
        self.last = None
        self.zero_since = None
        self.active = None
        self.data = dict(state='unknown', reason='not_sampled', observed_at=None,
                         metrics=None, valid_seconds=0.0, idle_seconds=0.0, active_seconds=0.0,
                         samples=0, valid_samples=0, compute_sum=0.0, event_count=0, events=[])

    def close(self, reason):
        if self.active is not None:
            self.active['ended_at'] = self.active['last_observed_at']
            self.active['end_reason'] = reason
        self.active = None
        self.zero_since = None

    def observe(self, now, values=None, reason=None):
        data = self.data
        previous = self.last
        continuous = previous is not None and 0 < now - previous <= self.interval * 2
        if not continuous:
            self.close('sample_gap')
        data.update(observed_at=now, metrics=values, reason=reason)
        data['samples'] += 1
        self.last = now
        if values is None:
            self.close(reason or 'unknown')
            data['state'] = 'unknown'
            self.last = None
            return
        data['valid_samples'] += 1
        data['compute_sum'] += values['compute']
        if continuous:
            data['valid_seconds'] += now - previous
            # A gap is counted as active when the sample that closes it shows
            # computation, so every second is attributed to at most one sample.
            if values['compute'] > 0:
                data['active_seconds'] += now - previous
        if values['compute'] > 0:
            self.close('activity')
            data['state'] = 'active'
        elif now - self.started < self.grace:
            self.close('startup')
            data['state'] = 'startup'
        else:
            if self.zero_since is None:
                self.zero_since = now
            elapsed = now - self.zero_since
            if elapsed >= self.threshold:
                if self.active is None:
                    self.active = dict(started_at=self.zero_since, last_observed_at=now,
                                       ended_at=None, end_reason=None)
                    data['events'].append(self.active)
                    del data['events'][:-MAX_EVENTS]
                    data['event_count'] += 1
                    data['idle_seconds'] += elapsed
                else:
                    data['idle_seconds'] += now - self.active['last_observed_at']
                    self.active['last_observed_at'] = now
                data['state'] = 'suspected_idle'
            else:
                data['state'] = 'zero'


class Probes:
    """Nonblocking subprocess pool, including children that ignore SIGKILL.

    Drain a bounded amount from nonblocking stdout; never wait for pipe EOF or
    use communicate(). A stuck descendant cannot keep task completion waiting.
    A surviving probe consumes its slot, preventing replacement storms.
    """
    def __init__(self, timeout=2, concurrency=2, guard_dir=None):
        self.timeout, self.concurrency = timeout, concurrency
        self.guard_dir = guard_dir
        self.jobs = {}

    def start(self, key, arguments, now):
        if key in self.jobs or len(self.jobs) >= self.concurrency:
            return False
        guard = None
        if self.guard_dir is not None:
            name = 'inventory' if key == 'inventory' else 'device_' + key[1]
            guard = os.open(self.guard_dir / (name + '.lock'), os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(guard)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError('unsafe probe guard')
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, ValueError):
                os.close(guard)
                raise
        try:
            proc = subprocess.Popen(['npu-smi', 'info', *arguments], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True,
                                    pass_fds=() if guard is None else (guard,),
                                    start_new_session=True)
        finally:
            if guard is not None:
                os.close(guard)
        os.set_blocking(proc.stdout.fileno(), False)
        self.jobs[key] = dict(proc=proc, output=proc.stdout, buffer=bytearray(),
                             overflow=False, started=now, terminated=None, reported=False)
        return True

    @staticmethod
    def signal(job, sig):
        try:
            os.killpg(job['proc'].pid, sig)
        except ProcessLookupError:
            pass

    def cancel(self, key, now):
        job = self.jobs[key]
        if job['terminated'] is None:
            self.signal(job, signal.SIGTERM)
            job['terminated'] = now

    def poll(self, now):
        results = []
        for key, job in list(self.jobs.items()):
            # Bound memory and work per tick. Do not set RLIMIT_FSIZE: it also
            # limits driver log files unrelated to our captured stdout.
            if not job['overflow']:
                while len(job['buffer']) <= 64 * 1024:
                    try:
                        chunk = os.read(job['output'].fileno(), min(16384, 64 * 1024 + 1 - len(job['buffer'])))
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    job['buffer'].extend(chunk)
                job['overflow'] = len(job['buffer']) > 64 * 1024
            if job['overflow'] and not job['reported']:
                self.cancel(key, now)
                results.append((key, '', 'query_output_limit'))
                job['reported'] = True
            rc = job['proc'].poll()
            if rc is not None:
                if not job['reported']:
                    # A canceled query can catch SIGTERM, print a value, and
                    # exit zero. Its result still belongs to an expired round.
                    reason = ('query_timeout' if job['terminated'] is not None
                              else None if rc == 0 else 'query_failed')
                    results.append((key, job['buffer'].decode('utf-8', 'replace'), reason))
                # Kill descendants too, even if the leader exited successfully.
                self.signal(job, signal.SIGKILL)
                job['output'].close()
                del self.jobs[key]
                continue
            if job['terminated'] is None and now - job['started'] >= self.timeout:
                self.cancel(key, now)
            if job['terminated'] is not None:
                if not job['reported']:
                    results.append((key, '', 'query_timeout'))
                    job['reported'] = True
                if now - job['terminated'] >= 1:
                    self.signal(job, signal.SIGKILL)
        return results

    def stop(self):
        # No wait(), even if a driver leaves a child in uninterruptible sleep.
        for job in self.jobs.values():
            self.signal(job, signal.SIGKILL)
            job['proc'].poll()
            job['output'].close()
        self.jobs.clear()


class Sampler:
    def __init__(self, devices, interval=15, timeout=2, grace=0, threshold=60, round_timeout=6,
                 guard_dir=None):
        self.started = time.monotonic()
        self.epoch = time.time() - self.started
        self.interval, self.round_timeout = interval, round_timeout
        self.cards = {device: Card(self.started, interval, grace, threshold) for device in devices}
        self.probes = Probes(timeout, guard_dir=guard_dir)
        self.mapping = None
        self.legacy = False
        self.retry_at = dict.fromkeys(devices, 0)
        self.failures = dict.fromkeys(devices, 0)
        self.resolved = {}
        self.next_round = self.started
        self.deadline = None
        self.todo = []
        self.pending = set()
        self.sequence = 0

    def failed(self, device, now, reason):
        self.cards[device].observe(now, reason=reason)
        self.failures[device] += 1
        self.retry_at[device] = now + min(300, self.interval * 2 ** min(5, self.failures[device] - 1))
        self.resolved.pop(device, None)
        self.pending.discard(device)

    def tick(self, now):
        for key, output, reason in self.probes.poll(now):
            if key == 'inventory':
                try:
                    if reason:
                        raise ValueError(reason)
                    self.mapping = physical_mapping(output)
                    self.legacy = self.mapping is None
                except ValueError:
                    for device in self.cards:
                        self.failed(device, now, reason or 'mapping_unknown')
                    self.deadline = None
                    self.todo.clear()
                    self.pending.clear()
                continue
            stage, device = key
            if device not in self.pending:
                continue
            try:
                if reason:
                    raise ValueError(reason)
                if stage == 'mapping':
                    self.resolved[device] = remapped_device(output, device)
                    self.todo.append(('usage', device))
                else:
                    self.cards[device].observe(now, metrics(output))
                    self.failures[device] = 0
                    self.pending.discard(device)
            except ValueError:
                self.failed(device, now, reason or ('mapping_unknown' if stage == 'mapping' else 'metrics_unknown'))

        if self.deadline is not None and now >= self.deadline:
            for key in list(self.probes.jobs):
                self.probes.cancel(key, now)
            for device in list(self.pending):
                self.failed(device, now, 'round_timeout')
            self.todo.clear()
            self.deadline = None

        if self.deadline is None and now >= self.next_round:
            self.next_round = now + self.interval
            self.deadline = now + self.round_timeout
            devices = list(self.cards)
            offset = self.sequence % len(devices)
            self.sequence += 1
            devices = devices[offset:] + devices[:offset]
            self.pending = {d for d in devices if now >= self.retry_at[d]}
            self.todo = []
            if self.mapping is None and not self.legacy and self.pending:
                try:
                    self.probes.start('inventory', ['-m'], now)
                except OSError:
                    for device in list(self.pending):
                        self.failed(device, now, 'query_unavailable')
            else:
                for device in devices:
                    if device not in self.pending:
                        continue
                    if self.legacy:
                        self.todo.append(('usage' if device in self.resolved else 'mapping', device))
                    elif device in self.mapping:
                        self.resolved[device] = self.mapping[device]
                        self.todo.append(('usage', device))
                    else:
                        self.failed(device, now, 'mapping_missing')

        # Inventory completion initializes per-card stages without another round.
        if self.deadline is not None and self.pending and not self.todo and not self.probes.jobs:
            for device in self.cards:
                if device not in self.pending:
                    continue
                if self.legacy:
                    self.todo.append(('mapping', device))
                elif self.mapping is not None and device in self.mapping:
                    self.resolved[device] = self.mapping[device]
                    self.todo.append(('usage', device))
                else:
                    self.failed(device, now, 'mapping_missing')

        while self.todo and len(self.probes.jobs) < self.probes.concurrency:
            stage, device = self.todo.pop(0)
            if device not in self.pending:
                continue
            if stage == 'mapping':
                args = ['-t', 'phyid-remap', '-p', device]
            else:
                mapped = self.resolved[device]
                args = ['-t', 'usages', '-i', mapped['npu']]
                if mapped['chip'] is not None:
                    args += ['-c', mapped['chip']]
            try:
                self.probes.start((stage, device), args, now)
            except OSError:
                self.failed(device, now, 'query_unavailable')
        if not self.pending:
            self.deadline = None

    def snapshot(self, task_id, user, now, final=False):
        cards = {}
        for device, card in self.cards.items():
            data = dict(card.data)
            data['events'] = [dict(event) for event in data['events']]
            if final:
                card.close('task_finished')
                data['events'] = [dict(event) for event in card.data['events']]
            for event in data['events']:
                for key in ('started_at', 'last_observed_at', 'ended_at'):
                    if event[key] is not None:
                        event[key] += self.epoch
            if data['observed_at'] is not None:
                data['observed_at'] += self.epoch
            data['mapping'] = self.resolved.get(device)
            cards[device] = data
        return dict(schema_version=1, task_id=task_id, user=user, advisory=True,
                    started_at=self.started + self.epoch, updated_at=now + self.epoch,
                    finished_at=now + self.epoch if final else None,
                    interval=self.interval, devices=cards)


def write_snapshot(fd, value):
    data = json.dumps(value, allow_nan=False, separators=(',', ':')).encode()
    if len(data) > MAX_BYTES:
        raise ValueError('telemetry too large')
    os.lseek(fd, 0, os.SEEK_SET)
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]
    os.ftruncate(fd, len(data))


def prepare(state, task_id, user, devices=()):
    directory = state / 'usage' / 'tasks'
    guards = state / 'usage/probe-locks'
    for path in (state / 'usage', directory, guards):
        try:
            path.mkdir(mode=0o755)
            created = True
        except FileExistsError:
            created = False
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('unsafe telemetry directory')
        if created:
            path.chmod(0o755)  # A restrictive daemon umask must not block task traversal.
    for name in ('inventory', *('device_' + d for d in devices)):
        if not re.fullmatch(r'inventory|device_[0-9]+', name):
            raise ValueError('invalid probe guard')
        guard = guards / (name + '.lock')
        try:
            guard_fd = os.open(guard, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666)
        except FileExistsError:
            info = guard.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
                raise ValueError('unsafe probe guard')
        else:
            os.fchmod(guard_fd, 0o666)
            os.close(guard_fd)
    path = directory / (task_id + '.json')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        account = pwd.getpwnam(user)
        os.fchown(fd, account.pw_uid, account.pw_gid)
        os.fchmod(fd, 0o644)
    finally:
        os.close(fd)


def read_snapshot(state, task_id, now=None):
    if not re.fullmatch(r'task_[0-9_]+', task_id):
        raise ValueError('invalid task id')
    fd = os.open(state / 'usage/tasks' / (task_id + '.json'),
                 os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES or info.st_nlink != 1:
            raise ValueError('unsafe telemetry file')
        try:
            data = json.loads(stream.read(MAX_BYTES + 1))
        except RecursionError as exc:
            raise ValueError('telemetry nesting exceeds parser limits') from exc
    if data['schema_version'] != 1 or data['task_id'] != task_id or data['advisory'] is not True:
        raise ValueError('invalid telemetry identity')
    # A submitter can alter its own advisory samples, never attribute them to
    # another user. Root-mode workloads already have administrator privileges.
    if info.st_uid != 0:
        data['user'] = pwd.getpwuid(info.st_uid).pw_name
    if not isinstance(data['user'], str) or not re.fullmatch(r'[A-Za-z0-9_.@-]{1,256}', data['user']):
        raise ValueError('invalid telemetry user')
    if not isinstance(data['devices'], dict) or not 0 < len(data['devices']) <= MAX_DEVICES:
        raise ValueError('invalid device telemetry')
    now = time.time() if now is None else now
    for key in ('started_at', 'updated_at', 'finished_at'):
        value = data[key]
        if value is None and key == 'finished_at':
            continue
        if not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= now + 5:
            raise ValueError('invalid telemetry time')
    if (data['updated_at'] < data['started_at'] or
            data['finished_at'] is not None and data['finished_at'] < data['started_at']):
        raise ValueError('invalid telemetry interval')
    for device, card in data['devices'].items():
        if not device.isdigit() or card['state'] not in ('unknown', 'active', 'startup', 'zero', 'suspected_idle'):
            raise ValueError('invalid telemetry state')
        for key in ('idle_seconds', 'valid_seconds', 'samples', 'valid_samples', 'compute_sum', 'event_count'):
            if not isinstance(card[key], (int, float)) or not math.isfinite(card[key]) or not 0 <= card[key] <= 10**12:
                raise ValueError('invalid telemetry totals')
        if 'active_seconds' in card:
            active = card['active_seconds']
            if (not isinstance(active, (int, float)) or not math.isfinite(active) or
                    not 0 <= active <= card['valid_seconds'] + .001):
                raise ValueError('invalid telemetry activity')
        if (card['valid_samples'] > card['samples'] or
                card['compute_sum'] > 100 * card['valid_samples'] + .001 or
                card['idle_seconds'] > card['valid_seconds'] + .001):
            raise ValueError('inconsistent telemetry totals')
        events = card['events']
        if not isinstance(events, list) or len(events) > MAX_EVENTS:
            raise ValueError('invalid telemetry events')
        for event in events:
            for key in ('started_at', 'last_observed_at', 'ended_at'):
                value = event[key]
                if key == 'ended_at' and value is None:
                    continue
                if (not isinstance(value, (int, float)) or not math.isfinite(value)
                        or not data['started_at'] <= value <= data['updated_at']):
                    raise ValueError('invalid event time')
            if (event['last_observed_at'] < event['started_at'] or
                    event['ended_at'] is not None and event['ended_at'] < event['last_observed_at']):
                raise ValueError('invalid event interval')
        if card['state'] == 'suspected_idle' and not events:
            raise ValueError('idle event missing')
        if data['finished_at'] is None and (not isinstance(card['observed_at'], (int, float))
                or not 0 <= now - card['observed_at'] <= 2 * number(data['interval'], 15, .1, 300)):
            card.update(state='unknown', reason='sample_expired')
    return data


def records(state, now):
    # Stream history so ranking memory grows with users, not task/event count.
    quality = {'skipped_records': 0}

    def scan():
        try:
            with os.scandir(state / 'usage/tasks') as entries:
                for entry in entries:
                    if not entry.name.startswith('task_') or not entry.name.endswith('.json'):
                        continue
                    try:
                        yield read_snapshot(state, entry.name[:-5], now)
                    except (OSError, ValueError, KeyError, TypeError):
                        quality['skipped_records'] += 1
        except FileNotFoundError:
            return
        except OSError:
            quality['skipped_records'] += 1
    return scan(), quality


def aggregate(snapshots, days, now, user=None):
    """Weight usage by card duration and coverage by valid sampled duration."""
    totals = {}
    for data in snapshots:
        if user is not None and data['user'] != user:
            continue
        if days and data['started_at'] < now - days * 86400:
            continue
        row = totals.setdefault(data['user'], dict(user=data['user'], task_count=0,
            suspected_idle_card_seconds=0., valid_card_seconds=0., recorded_card_seconds=0.,
            active_card_seconds=0., valid_samples=0, total_samples=0, idle_events=0))
        row['task_count'] += 1
        elapsed = max(0, (data['finished_at'] or min(now, data['updated_at'])) - data['started_at'])
        for card in data['devices'].values():
            row['suspected_idle_card_seconds'] += card['idle_seconds']
            row['valid_card_seconds'] += card['valid_seconds']
            row['recorded_card_seconds'] += elapsed
            active = card.get('active_seconds')
            if active is None:
                # A record without the counter estimates activity as sampled time
                # outside a suspected idle run.
                active = max(0., card['valid_seconds'] - card['idle_seconds'])
            row['active_card_seconds'] += active
            row['valid_samples'] += card['valid_samples']
            row['total_samples'] += card['samples']
            row['idle_events'] += card['event_count']
    for row in totals.values():
        row['active_time_ratio_pct'] = (
            min(100., 100 * row['active_card_seconds'] / row['recorded_card_seconds'])
            if row['recorded_card_seconds'] and row['valid_samples'] else None)
        row['valid_coverage_pct'] = (min(100., 100 * row['valid_card_seconds'] / row['recorded_card_seconds'])
                                     if row['recorded_card_seconds'] else None)
    return list(totals.values())


def report(state, days):
    now = time.time()
    snapshots, _ = records(state, now)
    user = None if os.geteuid() == 0 else pwd.getpwuid(os.geteuid()).pw_name
    rows = aggregate(snapshots, days, now, user)
    print('\n作业内采样（按任务开始时间筛选；疑似空闲仅供参考）')
    print('用户                疑似空闲卡时(h)  有效覆盖率  用卡时间占比  有效样本  空闲事件')
    for row in sorted(rows, key=lambda row: row['user']):
        coverage = percent(row['valid_coverage_pct'])
        usage_time = percent(row['active_time_ratio_pct'])
        print(f"{row['user']:20s} {row['suspected_idle_card_seconds'] / 3600:10.3f} "
              f"{coverage:>10s} {usage_time:>12s} {int(row['valid_samples']):8d} {int(row['idle_events']):8d}")
    if not rows:
        print('(无作业内采样记录)')


def percent(value):
    return '-' if value is None else f'{value:.1f}%'


def ranking(state, days=2, sort='utilization', limit=20):
    now = time.time()
    snapshots, quality = records(state, now)
    # Public aggregates are intentionally separate from --stats' own-user view.
    # No task IDs, commands, environments, per-card events or sessions are emitted.
    rows = aggregate(snapshots, days, now)
    skipped = quality['skipped_records']
    key = 'active_time_ratio_pct' if sort == 'utilization' else 'valid_coverage_pct'
    rows.sort(key=lambda row: (row[key] is None, row[key] or 0, row['user']))
    for index, row in enumerate(rows, 1):
        row['rank'] = index if row[key] is not None else None
    return dict(schema_version=1, status='partial' if skipped else 'ok' if rows else 'empty',
                advisory=True, generated_at=now, days=days, window_basis='task_started_at',
                coverage_basis='recorded_card_seconds', sort=sort, order='ascending',
                total_users=len(rows), skipped_records=skipped, ranking=rows[:limit])


def print_ranking(data):
    metric = '用卡时间占比' if data['sort'] == 'utilization' else '有效采样覆盖率'
    print(f'采样排名（按用户；{metric}升序，低者在前；按任务开始时间筛选；仅供参考）')
    print('名次  用户                  用卡时间占比  有效覆盖率  有效样本  疑似空闲卡时(h)')
    for row in data['ranking']:
        rank = '-' if row['rank'] is None else str(row['rank'])
        print(f"{rank:>4s}  {row['user']:20s} {percent(row['active_time_ratio_pct']):>12s} "
              f"{percent(row['valid_coverage_pct']):>10s} {int(row['valid_samples']):8d} "
              f"{row['suspected_idle_card_seconds'] / 3600:14.3f}")
    if not data['ranking']:
        print('(未启用采样或暂无可用记录)')
    if data['skipped_records']:
        print(f"跳过 {data['skipped_records']} 条不可用记录，排名可能不完整。")


def describe(data):
    cards = data['devices']
    idle = {device: card for device, card in cards.items() if card['state'] == 'suspected_idle'}
    if idle:
        scope = '全部卡' if len(idle) == len(cards) else '部分卡'
        current = '疑似占卡空闲（' + scope + '）: ' + ', '.join(
            device + '=' + str(int(card['events'][-1]['last_observed_at']
                                  - card['events'][-1]['started_at'])) + 's'
            for device, card in idle.items())
    elif any(card['state'] == 'unknown' for card in cards.values()):
        current = '采样未知'
    else:
        current = '未标记空闲'
    history = [(device, card['idle_seconds']) for device, card in cards.items()
               if card['idle_seconds'] > 0]
    if not history:
        return current
    return ('曾疑似占卡空闲 ' +
            ', '.join(device + '=' + str(int(seconds)) + 's' for device, seconds in history) +
            '；当前：' + current)


def run(args):
    if os.environ.get('TASKQUEUE_INSIDE') != '1' or os.environ.get('TASK_DEVICE') != args.devices:
        raise ValueError('sampling requires the matching queue allocation')
    devices = args.devices.split(',')
    if any(not d.isdigit() for d in devices):
        raise ValueError('invalid allocated devices')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise ValueError('workload command required')
    sampler = None
    if len(devices) <= MAX_DEVICES:
        sampler = Sampler(devices, interval=number(args.interval, 15, .1, 300),
                          timeout=number(args.timeout, 2, .05, 5),
                          grace=number(args.grace, 0, 0, 3600),
                          threshold=number(args.threshold, 60, .1, 3600),
                          round_timeout=number(args.round_timeout, 6, .1, 10),
                          guard_dir=Path(args.output).parent.parent / 'probe-locks')
    else:
        print(f'[taskqueue] device telemetry disabled: more than {MAX_DEVICES} allocated devices', file=sys.stderr)
    fd = None
    if sampler is not None:
        try:
            fd = os.open(args.output, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                raise ValueError('unsafe telemetry output')
        except (OSError, ValueError) as exc:
            if fd is not None:
                os.close(fd)
            fd = None
            print('[taskqueue] device telemetry unavailable: ' + str(exc), file=sys.stderr)
    workload = subprocess.Popen(command, close_fds=True)
    interrupted = None

    def terminate(sig, frame):
        nonlocal interrupted
        interrupted = sig
        # The daemon signals the whole session; a direct wrapper signal should
        # still reach the workload, without an unbounded signal-handler wait.
        if workload.poll() is None:
            workload.send_signal(sig)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, terminate)
    next_write = 0
    try:
        while workload.poll() is None and interrupted is None:
            now = time.monotonic()
            if fd is not None:
                try:
                    sampler.tick(now)
                    if now >= next_write:
                        write_snapshot(fd, sampler.snapshot(args.task_id, args.user, now))
                        next_write = now + .5
                except (OSError, ValueError) as exc:
                    print('[taskqueue] device telemetry stopped: ' + str(exc), file=sys.stderr)
                    sampler.probes.stop()
                    os.close(fd)
                    fd = None
            time.sleep(.05)
    finally:
        if sampler is not None:
            sampler.probes.stop()
        if fd is not None:
            try:
                write_snapshot(fd, sampler.snapshot(args.task_id, args.user, time.monotonic(), final=True))
            except (OSError, ValueError):
                pass
            os.close(fd)
    if interrupted is not None:
        return 128 + interrupted
    return workload.returncode if workload.returncode >= 0 else 128 - workload.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('state', type=Path)
    prep.add_argument('task_id')
    prep.add_argument('user')
    prep.add_argument('devices', nargs='?', default='')
    runner = commands.add_parser('run')
    for name in ('output', 'task-id', 'user', 'devices'):
        runner.add_argument('--' + name, required=True)
    for name, default in (('interval', 15), ('timeout', 2), ('grace', 0), ('threshold', 60), ('round-timeout', 6)):
        runner.add_argument('--' + name, default=str(default))
    runner.add_argument('command', nargs=argparse.REMAINDER)
    reader = commands.add_parser('read')
    reader.add_argument('state', type=Path)
    reader.add_argument('task_id')
    reader.add_argument('--json', action='store_true')
    stats = commands.add_parser('stats')
    stats.add_argument('state', type=Path)
    stats.add_argument('days', type=int)
    ranks = commands.add_parser('ranking', help='read public per-user sampling aggregates')
    ranks.add_argument('state', type=Path)
    ranks.add_argument('--days', type=int, default=2)
    ranks.add_argument('--sort', choices=('utilization', 'coverage'), default='utilization')
    ranks.add_argument('--limit', type=int, default=20)
    ranks.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        if args.mode == 'prepare':
            if not re.fullmatch(r'task_[0-9_]+', args.task_id):
                raise ValueError('invalid task id')
            prepare(args.state, args.task_id, args.user, args.devices.split(',') if args.devices else ())
            return 0
        if args.mode == 'run':
            return run(args)
        if args.mode == 'stats':
            if args.days < 0:
                raise ValueError('days must be nonnegative')
            report(args.state, args.days)
            return 0
        if args.mode == 'ranking':
            if args.days < 0 or not 1 <= args.limit <= 100:
                raise ValueError('days must be nonnegative; limit must be between 1 and 100')
            data = ranking(args.state, args.days, args.sort, args.limit)
            print(json.dumps(data, allow_nan=False)) if args.json else print_ranking(data)
            return 0
        data = read_snapshot(args.state, args.task_id)
        print(json.dumps(data) if args.json else describe(data))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        if args.mode == 'read':
            print(json.dumps({'status': 'unknown', 'reason': 'telemetry_unavailable'})
                  if args.json else '采样未知（未启用、无记录或记录不可用）')
            return 1
        print('device telemetry: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
