#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
"""One-shot native allocation snapshots alongside the independent Horizon memory guard."""
import ctypes
import datetime
import json
import os
from pathlib import Path
import signal
import struct
import sys
import time
sys.dont_write_bytecode = True
from BoundedCapture import capture, parse_stacks

lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
lib.proc_pidpath.restype = ctypes.c_int
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
lib.proc_listpids.restype = ctypes.c_int
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
system.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]


def pids():
    needed = lib.proc_listpids(1, 0, None, 0)
    if needed <= 0:
        raise RuntimeError('Process enumeration unavailable')
    values = (ctypes.c_int * (needed // 4 + 256))()
    count = lib.proc_listpids(1, 0, values, ctypes.sizeof(values))
    if count <= 0:
        raise RuntimeError('Process enumeration failed')
    return [pid for pid in values[:count // 4] if pid > 0]


def identity(pid):
    native = ctypes.create_string_buffer(4096)
    usage = ctypes.create_string_buffer(512)
    if lib.proc_pidpath(pid, native, len(native)) <= 0 or lib.proc_pid_rusage(pid, 2, usage) != 0:
        return None
    return {'pid': pid, 'startToken': struct.unpack_from('<Q', usage.raw, 80)[0], 'nativePath': native.value.decode()}


def describe(pid):
    result = identity(pid)
    if result is None:
        return None
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    if system.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 4 < size.value < 4 * 1024 * 1024:
        return None
    data = ctypes.create_string_buffer(size.value)
    if system.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        return None
    raw = data.raw[:size.value]
    argc = struct.unpack_from('<I', raw)[0]
    if not 0 < argc < 8192:
        return None
    index = raw.index(b'\0', 4) + 1
    while index < len(raw) and raw[index] == 0:
        index += 1
    argv = []
    for _ in range(argc):
        end = raw.index(b'\0', index)
        argv.append(raw[index:end].decode(errors='replace'))
        index = end + 1
    environment = {}
    for value in raw[index:].split(b'\0'):
        if value.startswith((b'WINEPREFIX=', b'MallocStackLogging=')):
            key, value = value.split(b'=', 1)
            environment[key.decode()] = value.decode()
    result.update(executable=argv[0].replace('\\', '/').split('/')[-1].lower(), environment=environment)
    return result


def runtime_environment(root, stack_logging=False):
    manifest = json.loads((root / 'manifests/runtime-fex.json').read_text())
    allowed = {'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'LC_CTYPE', '__CF_USER_TEXT_ENCODING', 'SECURITYSESSIONID'}
    env = {key: value for key, value in os.environ.items() if key in allowed}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', WINEPREFIX=str(root / 'prefixes/steam-fex'), WINEARCH='win64', WINEDEBUG='-all',
               TMPDIR=str(root / 'tmp') + '/', TMP=str(root / 'tmp'), TEMP=str(root / 'tmp'), XDG_CACHE_HOME=str(root / 'cache'),
               XDG_CONFIG_HOME=str(root / 'cache/config'), WINESERVER=str(root / manifest['server']), WINELOADER=str(root / manifest['loader']))
    env.update({key: value.replace('${ROOT}', str(root)) for key, value in manifest['environment'].items()})
    if stack_logging:
        env['MallocStackLogging'] = 'lite'
    return env


def matches_game(root, expected):
    current = describe(expected['pid'])
    return (current is not None and current['startToken'] == expected['startToken']
            and current['nativePath'].startswith(str(root / 'runtimes') + '/')
            and current['executable'] == 'horizonzerodawn.exe'
            and Path(current['environment'].get('WINEPREFIX', '/')).resolve() == root / 'prefixes/steam-fex')


def collect(root, directory, guard_pid, guard_log):
    guard_identity = identity(guard_pid)
    if not guard_identity or Path(guard_identity['nativePath']).resolve() != root / 'build/safety/horizon-memory-guard':
        raise RuntimeError('The expected independent memory guard is not running')
    state = {'controllerPID': os.getpid(), 'guardPID': guard_pid, 'snapshots': [], 'gameLaunchedByController': False,
             'snapshotScheduleSeconds': [60, 150, 240], 'stackLoggingMode': 'lite', 'captureMode': 'bounded_allBySize', 'singleOutputLimitBytes': 2 * 1024 * 1024, 'steamNeedsNormalRestartAfterTrial': True}

    def update(status, **fields):
        state.update(status=status, updatedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields)
        temporary = directory / 'capture-state.tmp'
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(directory / 'capture-state.json')

    def guard_alive():
        return identity(guard_pid) == guard_identity

    def cancel_guard():
        if guard_alive():
            # Cancellation is handled by the guard, which verifies Horizon before signalling it.
            os.kill(guard_pid, signal.SIGTERM)

    def tool(command, output):
        return capture(command, output, lambda: guard_alive() and matches_game(root, game))

    guard_state = None
    deadline = time.monotonic() + 10
    while guard_alive() and time.monotonic() < deadline:
        text = guard_log.read_text()
        if 'Logs: ' in text:
            candidate = Path(text.split('Logs: ', 1)[1].splitlines()[0]) / 'state.json'
            if candidate.is_file() and candidate.resolve().is_relative_to(root / 'logs'):
                value = json.loads(candidate.read_text())
                if value.get('guardPID') == guard_pid and value['state'] == 'armed':
                    guard_state = candidate
                    break
        time.sleep(.1)
    if guard_state is None:
        raise RuntimeError('No verified armed state from the memory guard')
    update('ready_waiting_for_horizon', guardStatePath=str(guard_state))
    started = None
    game = None
    completed = set()
    while guard_alive():
        value = json.loads(guard_state.read_text())
        if game is None and value['state'] == 'monitoring':
            events = [json.loads(line) for line in (guard_state.parent / 'memory.ndjson').read_text().splitlines() if line]
            detected = next(event for event in events if event['event'] == 'game_detected')
            game = {'pid': detected['pid'], 'startToken': detected['startToken']}
            description = describe(game['pid'])
            if not matches_game(root, game) or description['environment'].get('MallocStackLogging') != 'lite':
                update('profiling_environment_missing')
                cancel_guard()
                return
            started = time.monotonic()
            update('monitoring', game=game, selectedEnvironment=description['environment'])
        if game is not None:
            if not matches_game(root, game):
                break
            elapsed = time.monotonic() - started
            for due in state['snapshotScheduleSeconds']:
                if due in completed or elapsed < due:
                    continue
                completed.add(due)
                update('capturing', currentSnapshotSeconds=due)
                prefix = directory / ('snapshot-%03ds' % due)
                result = tool(['/usr/bin/malloc_history', str(game['pid']), '-allBySize'], Path(str(prefix) + '-malloc.txt'))
                content = Path(result['file']).read_text(errors='replace')
                records = parse_stacks(content)
                result.update(dueSeconds=due, actualSeconds=time.monotonic() - started,
                              stacksCollected=bool(records), completeTopStackRecords=len(records),
                              unresolvedStackWarnings=content.count('error acquiring stack'))
                if matches_game(root, game) and guard_alive():
                    result['vmmap'] = tool(['/usr/bin/vmmap', '-summary', str(game['pid'])], Path(str(prefix) + '-vmmap.txt'))
                state['snapshots'].append(result)
                update('monitoring')
        time.sleep(.5)
    update('finished', finalGuardState=json.loads(guard_state.read_text()))


if __name__ == '__main__':
    if len(sys.argv) != 5:
        raise SystemExit('Usage: AllocationCapture.py EXTERNAL_ROOT RUN_DIRECTORY GUARD_PID GUARD_STDOUT_LOG')
    root = Path(sys.argv[1]).resolve()
    directory = Path(sys.argv[2]).resolve()
    if not directory.is_relative_to(root / 'logs'):
        raise SystemExit('Capture output must stay on the external data drive')
    try:
        collect(root, directory, int(sys.argv[3]), Path(sys.argv[4]))
    except Exception as error:
        (directory / 'collector-error.json').write_text(json.dumps({'error': str(error), 'timeUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + '\n')
        raise
