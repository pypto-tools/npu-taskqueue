#!/usr/bin/env python3
"""Persist the submitter identity when the daemon claims a queued task."""
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import tempfile


def parse_uid(value):
    if value is None or value == '':
        return None
    if not isinstance(value, str) or not re.fullmatch(r'0|[1-9][0-9]{0,9}', value):
        raise ValueError('invalid submitter UID')
    uid = int(value)
    if uid >= 2**32 - 1:
        raise ValueError('invalid submitter UID')
    return uid


def submitted_uid(fields, file_uid):
    """Check client metadata against the owner of the original queue file."""
    user = fields.get('SUBMIT_USER')
    if not user:
        raise ValueError('missing submitter')
    try:
        uid = pwd.getpwnam(user).pw_uid
    except KeyError as error:
        raise ValueError('unknown submitter') from error
    if uid != file_uid:
        raise ValueError('submitter does not own task metadata')
    if 'SUBMIT_UID' in fields and parse_uid(fields['SUBMIT_UID']) != uid:
        raise ValueError('submitter UID does not match task owner')
    return uid


def freeze(path, device):
    """Replace a claimed file with a daemon-owned snapshot, before executing it.

    Read through one descriptor without following links. Copying to a new inode
    also prevents a client holding an old writable descriptor from changing the
    accepted metadata. No user commands or environment values are evaluated.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 1024 * 1024:
            raise ValueError('unsafe task metadata')
        data = stream.read(1024 * 1024 + 1)
        after = os.fstat(stream.fileno())
    signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_uid, s.st_mode)
    if len(data) > 1024 * 1024 or signature(before) != signature(after) or signature(after) != signature(path.lstat()):
        raise ValueError('task changed during identity validation')
    fields = {}
    lines = data.splitlines(keepends=True)
    for line in lines:
        key, sep, value = line.rstrip(b'\n').partition(b'=')
        if sep and key in (b'SUBMIT_USER', b'SUBMIT_UID'):
            key = key.decode('ascii')
            if key in fields:
                raise ValueError('duplicate submitter field')
            fields[key] = value.decode('utf-8')
    uid = submitted_uid(fields, before.st_uid)
    # DEVICE has already been resolved by the scheduler. Preserve CPU-only and
    # unresolved requests when the caller supplies no concrete assignment.
    replace_device = device not in ('', 'none')
    if replace_device and not re.fullmatch(r'[0-9]+(,[0-9]+)*', device):
        raise ValueError('invalid resolved device assignment')
    data = b''.join(line for line in lines
                    if not line.startswith(b'SUBMIT_UID=')
                    and not (replace_device and line.startswith(b'DEVICE=')))
    if data and not data.endswith(b'\n'):
        data += b'\n'
    data += ('SUBMIT_UID=' + str(uid) + '\n').encode('ascii')
    if replace_device:
        data += ('DEVICE=' + device + '\n').encode('ascii')
    fd, temporary = tempfile.mkstemp(prefix='.identity-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4 or sys.argv[1] != 'freeze':
            raise ValueError('usage: task_identity.py freeze FILE DEVICE')
        freeze(Path(sys.argv[2]), sys.argv[3])
    except (OSError, ValueError) as error:
        print('task identity: ' + str(error), file=sys.stderr)
        sys.exit(1)
