#!/usr/bin/env python3
"""Local queue monitor. No task execution, lock acquisition or hardware probes.

Only the daemon calls publish(). The public CLI reads a bounded, atomic JSON
file at an installation-relative path; it never loads queue/project config.
"""
import datetime as dt
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from task_identity import parse_uid, submitted_uid

SCHEMA = 1
MAX_BYTES = 256 * 1024
MAX_DEVICES = 256
MAX_AGE_MS = 15000
STATES = ('free', 'allocated', 'reserved', 'disabled', 'external', 'error', 'unknown')
FIELDS = {'SUBMIT_USER', 'SUBMIT_UID', 'DEVICE', 'START_TIME', 'RUN_TASK_PID', 'RUN_TASK_START_TICKS'}


class Incomplete(Exception):
    pass


def utc(timestamp):
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def process_identity(pid):
    # comm may contain spaces and parentheses. Never read cmdline or environ.
    path = Path('/proc') / str(int(pid))
    fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
    if fields[0] in ('Z', 'X'):
        raise ProcessLookupError(pid)
    return {'pid': int(pid), 'start_ticks': int(fields[19]), 'uid': path.stat().st_uid}


def kernel_boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def public_path(app):
    return app.parent / 'state/monitor.json' if app.name == 'app' else app / 'runtime/state/monitor.json'


def bounded_read(path, limit=MAX_BYTES):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError('not a bounded regular file')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('file too large')
        return data


def atomic_json(path, value):
    data = json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False).encode() + b'\n'
    if len(data) > MAX_BYTES:
        raise ValueError('snapshot exceeds size limit')
    fd, name = tempfile.mkstemp(prefix='.monitor-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def signature(path):
    s = path.lstat()
    return s.st_ino, s.st_mtime_ns, s.st_ctime_ns, s.st_size


def queue_records(state):
    """Read active metadata only, excluding .env and all unlisted fields.

    Retain signatures to detect concurrent submit/cancel/start/cleanup writes.
    The reader never visits done/, logs, task scripts, or environment files.
    """
    signatures, records = {}, {}
    for kind in ('running', 'pending'):
        directory = state / kind
        signatures[directory] = signature(directory)
        records[kind] = {}
        for path in sorted(directory.iterdir()):
            if not path.name.startswith('task_') or path.name.endswith('.env'):
                continue
            signatures[path] = signature(path)
            values = {}
            for line in bounded_read(path, 1024 * 1024).decode('utf-8', errors='replace').splitlines():
                key, sep, value = line.partition('=')
                if sep and key in FIELDS:
                    if key in ('SUBMIT_USER', 'SUBMIT_UID') and key in values:
                        raise Incomplete('duplicate_submitter_field')
                    values[key] = value
            if 'SUBMIT_UID' in values:
                info = path.lstat()
                try:
                    if kind == 'pending':
                        submitted_uid(values, info.st_uid)
                    elif info.st_uid != os.geteuid() or info.st_mode & 0o022:
                        raise ValueError('untrusted persisted identity')
                    parse_uid(values['SUBMIT_UID'])
                except ValueError:
                    values['SUBMIT_UID'] = ''
            records[kind][path.name] = values
    return records, signatures


def device_ids(root):
    # scandir reports access failure, unlike a glob silently returning [].
    with os.scandir(root) as entries:
        return sorted({m.group(1) for entry in entries
                       if (m := re.fullmatch(r'davinci(0|[1-9][0-9]*)', entry.name))}, key=int)


def lock_state(state, ids):
    """Match live kernel locks by device + inode, never by saved PID text.

    No flock(LOCK_NB) probe: even a successful probe would acquire a lock.
    Unknown holders are not attributed to users or asserted to be external.
    """
    inodes, unsafe = {}, set()
    for device in ids:
        path = state / 'locks' / ('npu_device_' + device + '.lock')
        try:
            s = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            unsafe.add(device)
            continue
        inodes[(os.major(s.st_dev), os.minor(s.st_dev), s.st_ino)] = device
    held = set()
    for line in Path('/proc/locks').read_text().splitlines():
        fields = line.split()
        if '->' in fields:  # waiting request, not a held lock
            continue
        if len(fields) < 8:
            raise Incomplete('lock_table_unreadable')
        major, minor, inode = fields[5].split(':')
        device = inodes.get((int(major, 16), int(minor, 16), int(inode)))
        if device is not None:
            held.add(device)
    return held, unsafe, inodes


def owner(task_id, record, now, reservation=False):
    user = record.get('SUBMIT_USER') or None
    try:
        uid = (parse_uid(record['SUBMIT_UID']) if 'SUBMIT_UID' in record
               else pwd.getpwnam(user).pw_uid if user else None)
    except (KeyError, ValueError):
        uid = None
    result = {'task_id': task_id, 'user': user, 'uid': uid}
    if reservation:
        request = record.get('DEVICE', '')
        if request == 'auto':
            count = 1
        elif re.fullmatch(r'auto:[1-9][0-9]*', request):
            count = int(request[5:])
        elif re.fullmatch(r'[0-9]+(,[0-9]+)*', request):
            count = len(set(request.split(',')))
        else:
            count = None
        result['requested_devices'] = count
    else:
        try:
            started = dt.datetime.fromisoformat(record['START_TIME'].replace('Z', '+00:00'))
            if started.tzinfo is None:
                raise ValueError('timezone missing')
            result.update(started_at=utc(started.timestamp()), elapsed_seconds=max(0, int(now - started.timestamp())))
        except (KeyError, ValueError, OverflowError):
            result.update(started_at=None, elapsed_seconds=None)
    return result


def summary(devices, complete=True):
    if not complete:
        return dict.fromkeys(('total', *STATES, 'occupying_users'))
    result = {name: sum(d['state'] == name for d in devices) for name in STATES}
    result['total'] = len(devices)
    owners = [d['allocation']['uid'] for d in devices if d['allocation'] is not None]
    result['occupying_users'] = len(set(owners)) if None not in owners and not result['unknown'] else None
    return result


def empty_snapshot(reason):
    return {'schema_version': SCHEMA, 'producer': {'name': 'pto-task', 'version': None},
            'boot_id': None, 'snapshot_seq': None, 'observed_at': None, 'age_ms': None,
            'status': 'unavailable', 'reason': reason,
            'scheduler': dict(state='unknown', mode=None, accepting_submissions=None,
                              dispatching=None, running_tasks=None, pending_tasks=None,
                              max_concurrent=None, reason=reason),
            'devices': [], 'summary': summary([], False), 'external_detection': 'unsupported'}


def collect(context, device_root=Path('/dev')):
    state = Path(context['state_dir'])
    now = time.time()
    observed_ns = time.monotonic_ns()
    records, signatures = queue_records(state)
    if (state / 'maintenance').exists() != context['maintenance']:
        raise Incomplete('maintenance_changed')
    ids = device_ids(device_root)
    if len(ids) > MAX_DEVICES:
        raise Incomplete('device_limit_exceeded')
    locks = lock_state(state, ids)
    pool_spec = context['pool']
    pool = set(pool_spec.split(',')) - {''}
    groups = {device: 'g' + str(index) for index, group in enumerate(context['groups'].split(';'))
              for device in group.split(',') if device}
    complete = pool.issubset(set(ids))
    reasons = set() if complete else {'pool_devices_not_enumerated'}
    allocations, uncertain = {}, set()
    for task_id, record in records['running'].items():
        if 'DEVICE' not in record:
            raise Incomplete('allocation_metadata_missing')
        request = record.get('DEVICE', '')
        if request in ('', 'none'):
            continue
        if not re.fullmatch(r'[0-9]+(,[0-9]+)*', request):
            raise Incomplete('allocation_unresolved')
        allocation = owner(task_id, record, now)
        try:
            identity = process_identity(record['RUN_TASK_PID'])
            verified = identity['start_ticks'] == int(record['RUN_TASK_START_TICKS'])
        except (KeyError, ValueError, OSError):
            verified = False
        if allocation['uid'] is None or allocation['started_at'] is None:
            reasons.add('allocation_metadata_incomplete')
        for device in set(request.split(',')):
            if device not in ids:
                complete = False
                reasons.add('allocated_device_not_enumerated')
            if not verified or device in allocations:
                uncertain.add(device)
            allocations[device] = allocation
    reserved = set(context['reservation_devices'].split(',')) - {''}
    reservation = None
    if context['reservation_task']:
        task = records['pending'].get(context['reservation_task'])
        if task is None:
            raise Incomplete('reservation_changed')
        reservation = owner(context['reservation_task'], task, now, reservation=True)
        if reservation['uid'] is None or reservation['requested_devices'] is None:
            reasons.add('reservation_metadata_incomplete')
        if not reserved.issubset(set(ids)):
            complete = False
            reasons.add('reserved_device_not_enumerated')
    devices = []
    for device in ids:
        allocation = allocations.get(device)
        r = reservation if device in reserved else None
        codes = []
        if allocation:
            codes.append('allocated')
        if r:
            codes.append('reservation_pool')
        if device not in pool:
            codes.append('outside_auto_pool')
        if device in uncertain:
            codes.append('allocation_process_unverified')
        if device in locks[1]:
            codes.append('unsafe_lock_file')
        if device in locks[0] and allocation is None:
            codes.append('lock_holder_unattributed')
        if device in uncertain or device in locks[1] or (device in locks[0] and allocation is None):
            status = 'unknown'
            reasons.add('device_state_unknown')
        else:
            status = 'allocated' if allocation else 'disabled' if device not in pool else 'reserved' if r else 'free'
        devices.append(dict(id=device, group_id=groups.get(device), pool_eligible=device in pool,
                            state=status, reason_codes=codes, allocation=allocation, reservation=r, health='unknown'))
    # No mixed queue generations or lock transitions are presented as complete.
    if (any(signature(path) != sig for path, sig in signatures.items())
            or locks != lock_state(state, ids) or ids != device_ids(device_root)):
        raise Incomplete('concurrent_state_change')
    maintenance = context['maintenance']
    scheduler = dict(state='maintenance' if maintenance else 'running', mode=context['mode'],
                     accepting_submissions=not maintenance, dispatching=not maintenance,
                     running_tasks=len(records['running']), pending_tasks=len(records['pending']),
                     max_concurrent=context['max_concurrent'], reason='maintenance' if maintenance else None)
    if context['scheduler_failed']:
        scheduler.update(dispatching=False, reason='scheduler_tick_failed')
        reasons.add('scheduler_tick_failed')
    return dict(schema_version=SCHEMA, producer={'name': 'pto-task', 'version': context['version']},
                boot_id=context['boot_id'], snapshot_seq=context['seq'], observed_at=utc(now),
                observed_monotonic_ns=observed_ns, age_ms=0, status='partial' if reasons else 'ok',
                reason=','.join(sorted(reasons)) or None, scheduler=scheduler, devices=devices,
                summary=summary(devices, complete), inventory_complete=complete,
                external_detection='unsupported', daemon=context['daemon'], kernel_boot_id=context['kernel_boot_id'])


def publish(context, output, device_root=Path('/dev')):
    for _ in range(3):
        try:
            value = collect(context, device_root)
            break
        except (OSError, ValueError, Incomplete) as error:
            reason = str(error) if isinstance(error, Incomplete) else 'collection_failed'
    else:
        value = empty_snapshot(reason)
        value.update(producer={'name': 'pto-task', 'version': context['version']},
                     boot_id=context['boot_id'], snapshot_seq=context['seq'], observed_at=utc(time.time()),
                     observed_monotonic_ns=time.monotonic_ns(), age_ms=0, daemon=context['daemon'],
                     kernel_boot_id=context['kernel_boot_id'], inventory_complete=False)
    atomic_json(output, value)


def validate(value):
    # Validate the contract before using cached numbers. Invalid/unsupported
    # snapshots never turn into a successful empty machine.
    if type(value['schema_version']) is not int or value['schema_version'] != SCHEMA:
        raise ValueError('unsupported schema')
    if value['status'] not in ('ok', 'partial', 'unavailable'):
        raise ValueError('invalid status')
    if not isinstance(value['reason'], (str, type(None))) or value['external_detection'] != 'unsupported':
        raise ValueError('invalid capability/reason')
    for key in ('boot_id', 'observed_at', 'kernel_boot_id'):
        if not isinstance(value[key], str) or not value[key]:
            raise ValueError('missing identity/time')
    if not value['observed_at'].endswith('Z'):
        raise ValueError('observation must be UTC')
    dt.datetime.fromisoformat(value['observed_at'].replace('Z', '+00:00'))
    for key in ('snapshot_seq', 'observed_monotonic_ns'):
        if type(value[key]) is not int or value[key] < 0:
            raise ValueError('invalid sequence/time')
    if value['producer']['name'] != 'pto-task' or not isinstance(value['producer']['version'], str):
        raise ValueError('invalid producer')
    for key in ('pid', 'uid', 'start_ticks'):
        if type(value['daemon'][key]) is not int or value['daemon'][key] < 0:
            raise ValueError('invalid daemon identity')
    scheduler = value['scheduler']
    if not isinstance(scheduler['mode'], (str, type(None))) or not isinstance(scheduler['reason'], (str, type(None))):
        raise ValueError('invalid scheduler metadata')
    if scheduler['state'] not in ('running', 'maintenance', 'stopped', 'unknown'):
        raise ValueError('invalid scheduler')
    for key in ('accepting_submissions', 'dispatching'):
        if scheduler[key] is not None and type(scheduler[key]) is not bool:
            raise ValueError('invalid scheduler flag')
    for key in ('running_tasks', 'pending_tasks', 'max_concurrent'):
        if scheduler[key] is not None and (type(scheduler[key]) is not int or scheduler[key] < 0):
            raise ValueError('invalid task count')
    if value['status'] == 'ok' and (scheduler['state'] == 'unknown' or any(
            scheduler[key] is None for key in ('running_tasks', 'pending_tasks', 'max_concurrent',
                                               'accepting_submissions', 'dispatching'))):
        raise ValueError('incomplete successful scheduler')
    devices = value['devices']
    if not isinstance(devices, list) or len(devices) > MAX_DEVICES:
        raise ValueError('device limit')
    seen = set()
    for device in devices:
        if not isinstance(device['id'], str) or not re.fullmatch(r'0|[1-9][0-9]*', device['id']) or device['id'] in seen:
            raise ValueError('invalid/duplicate device')
        seen.add(device['id'])
        if device['state'] not in STATES or not isinstance(device['reason_codes'], list):
            raise ValueError('invalid device state')
        if not all(isinstance(code, str) for code in device['reason_codes']):
            raise ValueError('invalid reason codes')
        if not isinstance(device['group_id'], (str, type(None))) or device['health'] != 'unknown':
            raise ValueError('invalid device metadata')
        if device['pool_eligible'] is not None and type(device['pool_eligible']) is not bool:
            raise ValueError('invalid pool eligibility')
        for key in ('allocation', 'reservation'):
            item = device[key]
            if item is None:
                continue
            if not isinstance(item['task_id'], str) or not isinstance(item['user'], (str, type(None))):
                raise ValueError('invalid owner')
            if item['uid'] is not None and (type(item['uid']) is not int or item['uid'] < 0):
                raise ValueError('invalid UID')
            if key == 'allocation':
                if not isinstance(item['started_at'], (str, type(None))):
                    raise ValueError('invalid start time')
                number = item['elapsed_seconds']
            else:
                number = item['requested_devices']
            if number is not None and (type(number) is not int or number < 0):
                raise ValueError('invalid owner count')
        if device['state'] == 'free' and (device['allocation'] or device['reservation'] or device['pool_eligible'] is not True):
            raise ValueError('invalid free device')
        if device['state'] == 'allocated' and not device['allocation']:
            raise ValueError('missing allocation')
        if device['state'] == 'reserved' and not device['reservation']:
            raise ValueError('missing reservation')
        if device['state'] in ('reserved', 'disabled') and device['allocation']:
            raise ValueError('allocation hidden by device state')
    for count in value['summary'].values():
        if count is not None and (type(count) is not int or count < 0):
            raise ValueError('invalid summary count')
    if type(value['inventory_complete']) is not bool or value['summary'] != summary(devices, value['inventory_complete']):
        raise ValueError('summary mismatch')
    if value['status'] == 'ok' and (not value['inventory_complete'] or any(d['state'] == 'unknown' for d in devices)):
        raise ValueError('incomplete successful snapshot')


def invalidate(value, reason, stopped=False):
    value.update(status='unavailable', reason=reason, cached=True)
    value['scheduler'].update(state='stopped' if stopped else 'unknown', accepting_submissions=False if stopped else None,
                              dispatching=False if stopped else None, running_tasks=None, pending_tasks=None, reason=reason)
    for device in value['devices']:
        device['state'] = 'unknown'
        device['reason_codes'] = list(dict.fromkeys(device['reason_codes'] + [reason, 'last_observation']))
    value['summary'] = summary(value['devices'], value['inventory_complete'])
    value['summary']['occupying_users'] = None


def query(path):
    try:
        value = json.loads(bounded_read(path))
        validate(value)
        age = (time.monotonic_ns() - value['observed_monotonic_ns']) // 1_000_000
        value['age_ms'] = max(0, age)
        if value['kernel_boot_id'] != kernel_boot_id() or age < 0:
            value['age_ms'] = None  # clocks from different boots are incomparable
            invalidate(value, 'host_restarted')
            return value, 1
        try:
            alive = process_identity(value['daemon']['pid']) == value['daemon']
        except (FileNotFoundError, ProcessLookupError):
            alive = False
        except (OSError, ValueError):
            invalidate(value, 'daemon_identity_unreadable')
            return value, 1
        if not alive:
            invalidate(value, 'daemon_stopped', stopped=True)
            return value, 0 if age <= MAX_AGE_MS else 1
        if age > MAX_AGE_MS:
            invalidate(value, 'snapshot_expired')
            return value, 1
        return value, 1 if value['status'] == 'unavailable' else 0
    except PermissionError:
        return empty_snapshot('permission_denied'), 1
    except FileNotFoundError:
        return empty_snapshot('snapshot_missing'), 1
    except (OSError, ValueError, KeyError, TypeError, OverflowError, RecursionError, AttributeError):
        return empty_snapshot('snapshot_invalid'), 1


def main():
    if sys.argv[1:2] == ['read']:
        if sys.argv[2:] != ['--monitor', '--json'] and sys.argv[2:] != ['--json', '--monitor']:
            value, code = empty_snapshot('usage: --monitor --json'), 2
        else:
            value, code = query(public_path(Path(__file__).resolve().parent))
        try:
            encoded = json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False)
            if len(encoded) + 1 > MAX_BYTES:
                raise ValueError('response too large')
        except ValueError:
            value, code = empty_snapshot('snapshot_invalid'), 1
            encoded = json.dumps(value, separators=(',', ':'))
        print(encoded)
        if code:
            print('task-submit monitor: ' + value['reason'], file=sys.stderr)
        return code
    if sys.argv[1:2] == ['identity']:
        print(json.dumps(dict(daemon=process_identity(sys.argv[2]), kernel_boot_id=kernel_boot_id(), boot_id=str(uuid.uuid4()))))
        return 0
    if sys.argv[1:2] == ['publish']:
        context = json.loads(sys.argv[2])
        keys = ('state_dir', 'version', 'seq', 'mode', 'max_concurrent', 'pool', 'groups',
                'reservation_task', 'reservation_devices', 'maintenance', 'scheduler_failed')
        context.update(zip(keys, sys.argv[3:]))
        for key in ('seq', 'max_concurrent'):
            context[key] = int(context[key])
        for key in ('maintenance', 'scheduler_failed'):
            context[key] = context[key] == '1'
        app = Path(__file__).resolve().parent
        output = public_path(app) if app.name == 'app' else Path(context['state_dir']) / 'monitor.json'
        publish(context, output)
        return 0
    return 2


if __name__ == '__main__':
    sys.exit(main())
