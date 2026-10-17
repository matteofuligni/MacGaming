#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
"""Bounded top-by-size allocation stacks for an already guarded Horizon process."""
import datetime
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from AllocationCapture import identity, matches_game
from BoundedCapture import capture, parse_stacks

root = Path(sys.argv[1]).resolve()
validation = json.loads((root / 'logs/horizon-guard-validation.json').read_text())
guard_path = Path(validation['statePath'])
run = Path(validation['allocationStatePath']).parent
state = json.loads((run / 'capture-state.json').read_text())
game = state['game']
guard = identity(validation['guardPID'])
assert guard and Path(guard['nativePath']).resolve() == root / 'build/safety/horizon-memory-guard'
assert json.loads(guard_path.read_text())['state'] == 'monitoring' and matches_game(root, game)
events = [json.loads(line) for line in (guard_path.parent / 'memory.ndjson').read_text().splitlines() if line]
start_sample = next(row for row in reversed(events) if row['event'] == 'sample')
name = 'largest-%03ds' % round(start_sample['elapsedSeconds'])
output = run / (name + '.txt')
metadata = capture(['/usr/bin/malloc_history', str(game['pid']), '-allBySize'], output,
                   lambda: identity(validation['guardPID']) == guard and matches_game(root, game))
text = output.read_text(errors='replace')
records = parse_stacks(text)
metadata.update(timeUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                elapsedSecondsAtStart=start_sample['elapsedSeconds'], footprintBytesAtStart=start_sample['footprintBytes'],
                completeTopStackRecords=len(records), nativeMallocGroups=sum(row['nativeMalloc'] for row in records),
                unresolvedStackWarnings=text.count('error acquiring stack'),
                scope='Largest live stack groups only; VM reservations and malloc groups must not be added together.')
(run / (name + '.json')).write_text(json.dumps({'capture': metadata, 'records': records}, indent=2) + '\n')
with (run / 'bounded-captures.ndjson').open('a') as log: log.write(json.dumps(metadata) + '\n')
state = json.loads((run / 'capture-state.json').read_text())
state.setdefault('boundedCaptures', []).append(metadata)
state.update(updatedAtUTC=metadata['timeUTC'], status='manual_bounded_top_size_collection')
tmp = run / 'capture-state.tmp'; tmp.write_text(json.dumps(state, indent=2) + '\n'); tmp.replace(run / 'capture-state.json')
print(json.dumps(metadata, indent=2))
print('Largest native malloc groups:')
for row in [r for r in records if r['nativeMalloc']][:8]:
    print(json.dumps({'calls': row['calls'], 'MiB': round(row['bytes']/2**20, 2), 'stack': row['stack'][:1000]}))
