# Game-local compatibility shims

These experimental C sources operate through Windows/Direct3D interfaces. They do
not contain or replace game executables, assets, a Windows installation or a global
Wine/renderer DLL. Their original code is covered by the project's GPL-3.0-or-later.

- `winegstreamer-stub.c` implements a minimal COM `IWMSyncReader` availability probe.
  It rejects actual media opens and is **not** a WMA/WMV decoder.
- `gtasa-mtld3d.c` adapts one fixed-function Direct3D 9 `MULTIPLYADD` layout to two
  texture stages supported by mtld3d. It checks the renderer and restores the
  changed state after each draw. Other layouts pass through unchanged.

Build with a separately installed llvm-mingw toolchain:

```sh
source/build.sh shims
```

The synthetic `source/probes/gtasa-multiplyadd-probe.c` reads only its own offscreen
render target. Its binary and any runtime/game files are excluded from Git. Running
it requires a deliberately prepared local environment; compilation does not prove
game compatibility. A separately acquired ASI loader is required by the game-local
ASI approach and is not distributed here.

The diagnosis consulted public Wine, mtld3d and gta-reversed sources as references.
Those downloaded files and the reverse-engineered game source are **not included**
in this publication. No permission to redistribute game code or assets is implied.
See [the license review](../../docs/LICENSING.md) for the scope of this source release.
