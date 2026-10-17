# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
"""Stream a diagnostic tool through a strict byte budget; never signal its target."""
import os
import re
import selectors
import subprocess
import time


def capture(command, output, target_alive, limit=2 * 1024 * 1024, seconds=15):
    total = 0
    reason = None
    # Open first: a duplicate output must not leave an unattached diagnostic running.
    with output.open('xb') as handle:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + seconds
                while True:
                    if not target_alive():
                        reason = 'target_or_guard_ended'
                        break
                    if time.monotonic() >= deadline:
                        reason = 'time_budget'
                        break
                    if selector.select(.1):
                        chunk = os.read(child.stdout.fileno(), min(16384, limit - total))
                        if not chunk:
                            break
                        handle.write(chunk)
                        total += len(chunk)
                        if total >= limit:
                            reason = 'top_output_budget'
                            break
                    elif child.poll() is not None:
                        break
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            else:
                child.wait()
            child.stdout.close()
    return {'file': str(output), 'bytesCaptured': total, 'stopReason': reason,
            'toolExitCode': child.returncode, 'completeReport': reason is None and child.returncode == 0}


def parse_stacks(text):
    records = []
    # Ignore the last record when a budget cuts its line.
    for line in text.splitlines(keepends=True):
        match = re.match(r'^(\d+) calls? for (\d+) bytes: (.*)\n$', line)
        if not match:
            continue
        stack = match[3].strip()
        leaf = stack.rsplit('|', 1)[-1].strip()
        records.append({'calls': int(match[1]), 'bytes': int(match[2]), 'stack': stack,
                        'leaf': leaf, 'nativeMalloc': '(libsystem_malloc.dylib)' in leaf})
    return records
