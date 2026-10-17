# Optional bounded game-memory trial

`MemoryGuard.swift` is an explicit diagnostic tool, separate from normal Play.
It waits for a manually launched game in the registered FEX prefix. It does not
start Steam or a game. Horizon Zero Dawn and Hogwarts Legacy are supported targets;
running the compiled tool without arguments prints its usage. This tool does not
fix renderer memory growth.

From a registered external checkout:

```sh
source/tools/horizon-trial/prepare-horizon-trial.sh
```

The script uses its checkout root, an explicit absolute first argument or
`MACGAMING_DATA_ROOT`; it does not search a developer-specific directory layout.
It compiles the guard, runs its self-test, verifies the external volume identity
and waits. Start the game only after the `ARMED` message.

The guard samples memory and process identity. It stops only its identified game
at 24 GiB of footprint (or half physical RAM when smaller), critical memory
pressure, or 15 minutes after detection. Reaching a threshold can interrupt a
session and lose unsaved progress. It verifies PID birth time, executable and
prefix before signalling the process. It sends SIGTERM first, then SIGKILL if
that same process remains after three seconds. It never intentionally targets
Steam or a different game's process. No game within 30 minutes ends the wait.

Logs and per-trial state stay under ignored `logs/`. They can contain local paths
and process identifiers and must not be committed or uploaded unreviewed. The
independent allocation tools collect bounded diagnostic stacks, not memory contents.
They require deliberate setup of their local state files and, for native stack
attribution, an explicitly enabled `MallocStackLogging=lite` session. They are
advanced diagnostics, not part of the standard install procedure.

The guard is a periodic check, not an allocator-enforced memory limit: spikes,
helper processes or an unresponsive system can still exceed the threshold.
Ctrl-C during a detected trial also stops that identified game. Keep the guard
terminal open while a monitored game runs.

Self-test without arming a trial:

```sh
source/build.sh guard-test
```

CPU counters are absolute ticks accompanied by the Mach timebase. Convert with
`nanoseconds = ticks * numerator / denominator`; do not treat ticks as nanoseconds.
No local measurement, device identity or private trial history is distributed.
