# Development and local setup

## Build without a game environment

The repository can have any folder name and can be checked out on any local volume.
Install the Swift 6 toolchain and Xcode command-line tools, then run from its root:

```sh
source/build.sh test
source/build.sh build
python3 -m unittest discover -s source/tools/publication-tests
python3 source/tools/publication.py check
```

Build products, package/compiler caches and test fixtures are created under this
checkout's ignored `build/`, `cache/` and `tmp/` directories. The tests generate a
filesystem identity and use a POSIX registry stub; they never start Steam or games.
Tests that inspect actual renderer binaries skip when those binaries are absent.

## Prepare your own game data

Game operations still require an external volume. For the initial alpha, place
the checkout on that volume so source, manifests, runtime and data share one root.
No particular volume name, username or directory hierarchy is required.

```sh
python3 source/tools/initialize-data.py
source/build.sh build
build/native/debug/macgaming register-storage "$PWD"
```

Initialization copies missing files from `examples/` only; it does not overwrite
existing profiles or manifests. Registration records the current external volume's
UUID and relative folder path in ignored `manifests/storage.json`. It does not
format a disk or install software. An internal volume is rejected for game data.

An app packaged by `source/build.sh app` carries that user's registration. A CLI
in the checkout discovers the registration by walking up from its executable.
A separately copied CLI can use `MACGAMING_DATA_ROOT` with an absolute data path.
Without registration the app stops; it never guesses a development folder.

## External dependencies

Acquire the exact releases identified in `examples/manifests/` from their upstream
projects. Verify archive digests before extracting them into the relative paths
listed in those manifests. MacGaming does not bundle or automatically download them.

- Hadron 0.3.0: FEX/ARM64 runtime; requires its supported macOS version (27 for this pin).
- Gcenx Wine Stable 11.0_1: optional Intel/Rosetta environment with known DX11 limits.
- DXMT 0.80: optional MIT-licensed add-on for the Rosetta environment. It does not
  fix that Wine build's missing Metal bridge by itself.
- llvm-mingw 20261006 UCRT: optional toolchain for the Windows helper/probes/shims.
- SteamSetup.exe: obtain only from Valve. The pinned digest may become stale when
  Valve updates the installer. A digest mismatch must be reviewed; do not bypass it.

Keep upstream license material with each external installation. Neither a release
URL nor an integrity hash grants redistribution rights. See [LICENSING.md](LICENSING.md).

```sh
source/build.sh wrapper
source/build.sh preload
source/build.sh app
build/MacGaming.app/Contents/Helpers/macgaming doctor
```

`preload` builds the host library that Hadron's Wine loader receives through
`DYLD_INSERT_LIBRARIES` (`source/preload/image-reserve.c`). Hadron has no Wine
preloader, so macOS malloc can occupy part of a fixed-base executable's address
range before Wine maps it; the library restarts the loader until the range is free.
`app` builds it too. Restart Steam from MacGaming after rebuilding it: running Wine
processes keep the environment they started with.

The app is signed ad hoc for local development. Public executable releases require
a separate packaging review, appropriate notices and corresponding sources, and
testing of signing/notarization. The source publication prepared here is not an
approval to redistribute the external runtime or proprietary payloads.

## Configuration and privacy

`examples/profiles/` contains settings only, with every compatibility check pending.
Live `profiles/`, `manifests/`, prefixes, games, account files, saves, backups, caches,
logs, trace files, downloads, toolchains and generated builds are private and ignored.

Changing renderer settings invalidates the configuration's previous test evidence.
A configuration's environment accepts only emulator and renderer variables (`FEX_`, `DXMT_`,
`MTLD3D_`, `VKD3D_`, `DXVK_`, `MESA_`). MacGaming records the variables it started Steam with in
the prefix and restarts Steam on Play when a game needs others; it refuses while a game runs.
Configuration changes are applied on Play with a journal, verification and rollback.
Restoring saves requires an integrity check and a backup of current data first.

Reports are generated locally only. Review and redact any report before sharing it.
The app's redaction is a convenience, not permission to publish unreviewed free text.

For an optional bounded game-memory trial, see
[`source/tools/horizon-trial/README.md`](../source/tools/horizon-trial/README.md).
