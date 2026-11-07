#!/usr/bin/env python3
"""Benchmark synthetic usage accounting; never reads host queue/configuration.

Example: python3 tests/benchmark_usage_monitor.py --history-tasks 50000 --done-files 1000
Core times exclude interpreter/database startup; worker times include both.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import usage_monitor as usage


def cycle(db, state, now, running=False):
    live = dict(status='ok', inventory_complete=True, scheduler={'state': 'running'}, age_ms=0, devices=[])
    if running:
        live['devices'] = [dict(id=str(i), state='allocated', allocation=dict(
            task_id='task_live', started_at=usage.monitor.utc(now-1800), user='user0', uid=1000)) for i in range(2)]
    wall, cpu = time.perf_counter(), time.process_time()
    active, errors = usage.collect(db, state, live, now)
    collected = time.perf_counter()
    value = usage.report(db, now, ZoneInfo('UTC'), active, errors)
    usage.validate(value)
    value.update(kernel_boot_id=usage.monitor.kernel_boot_id(), observed_monotonic_ns=time.monotonic_ns())
    usage.monitor.atomic_json(state / 'usage-monitor.json', value)
    return [time.perf_counter()-wall, time.process_time()-cpu, collected-wall]


def fixture(state, count, files, now):
    (state / 'done').mkdir()
    (state / 'usage-report').mkdir()
    with sqlite3.connect(state / 'usage-report/usage.sqlite3') as old:
        old.execute('CREATE TABLE tasks(task_id TEXT, username TEXT, started REAL, finished REAL, devices TEXT)')
        old.executemany('INSERT INTO tasks VALUES(?,?,?,?,?)',
            ((f'task_archive_{i}', f'user{i%16}', now-60-i*30-1800, now-60-i*30, '0,1') for i in range(count)))
    for i in range(files):
        path = state / 'done' / f'task_done_{i}'
        path.write_text(f'SUBMIT_USER=user{i%16}\nSTART_TIME={usage.monitor.utc(now-1800)}\n'
                        f'FINISH_TIME={usage.monitor.utc(now-60)}\nDEVICE=0,1\n')
        path.chmod(0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history-tasks', type=int, default=50000)
    parser.add_argument('--done-files', type=int, default=1000)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--worker', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--now', type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.repeat < 1 or args.history_tasks < 0 or args.done_files < 0:
        parser.error('counts must be nonnegative and repeat must be positive')
    os.nice(10)
    if args.worker:
        db = usage.database(args.worker / 'usage-monitor/usage.sqlite3', args.now)
        try:
            cycle(db, args.worker, args.now)
        finally:
            db.close()
        return
    with tempfile.TemporaryDirectory(prefix='pto-usage-bench-') as tmp:
        state, now = Path(tmp), int(time.time())
        fixture(state, args.history_tasks, args.done_files, now)
        db = usage.database(state / 'usage-monitor/usage.sqlite3', now-35*86400)
        first = cycle(db, state, now)
        # Let freshly created fixture files leave the conservative filesystem
        # timestamp guard, then warm the directory cache outside measurement.
        time.sleep(1.05)
        cycle(db, state, now)
        steady = [cycle(db, state, now) for _ in range(args.repeat)]
        live = [cycle(db, state, now, running=True) for _ in range(args.repeat)]
        db.close()
        workers = []
        for i in range(args.repeat):
            start = time.perf_counter()
            subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()), '--worker', str(state),
                            '--now', str(now + 30*(i+1))], check=True, stdout=subprocess.DEVNULL)
            workers.append(time.perf_counter()-start)
        # Force periodic content reconciliation, then one new completion.
        db = usage.database(state / 'usage-monitor/usage.sqlite3', now)
        reconciled = cycle(db, state, now+usage.RECONCILE_SECONDS)
        path = state / 'done/task_new'
        path.write_text(f'SUBMIT_USER=user0\nSTART_TIME={usage.monitor.utc(now-1800)}\n'
                        f'FINISH_TIME={usage.monitor.utc(now)}\nDEVICE=0,1\n')
        path.chmod(0o644)
        added = cycle(db, state, now+usage.RECONCILE_SECONDS+30)
        query_start = time.perf_counter()
        for _ in range(10):
            assert usage.query(state / 'usage-monitor.json')[1] == 0
        query_ms = (time.perf_counter()-query_start)*100
        db.close()
        print(json.dumps(dict(
            history_tasks=args.history_tasks, done_files=args.done_files,
            first_cycle_ms=round(first[0]*1000, 2),
            steady_cycle_ms=round(statistics.median(x[0] for x in steady)*1000, 2),
            steady_cpu_ms=round(statistics.median(x[1] for x in steady)*1000, 2),
            live_cycle_ms=round(statistics.median(x[0] for x in live)*1000, 2),
            worker_process_ms=round(statistics.median(workers)*1000, 2),
            reconciliation_ms=round(reconciled[0]*1000, 2),
            new_task_cycle_ms=round(added[0]*1000, 2),
            peak_rss_mib=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024, 1),
            query_ms=round(query_ms, 2),
            snapshot_kib=round((state/'usage-monitor.json').stat().st_size/1024, 1)), sort_keys=True))


if __name__ == '__main__':
    main()
