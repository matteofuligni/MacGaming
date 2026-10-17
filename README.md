# MacGaming

An experimental native macOS app and command-line tool for managing Windows Steam
environments on Apple Silicon. MacGaming manages game configurations, save backups,
recovery and local diagnostics around separately installed compatibility runtimes.

**Alpha software.** There is no general game-compatibility guarantee. The included
configuration examples contain no personal test records and start as **Not tested**.
Automatic unit tests exercise the manager, not gameplay compatibility.

## Features

- Native SwiftUI library and CLI.
- Independent game configurations for each runtime and renderer.
- Per-game emulator and renderer variables (for example FEX's x87 precision); Play restarts
  Windows Steam with them when needed, because games inherit Steam's environment.
- Version-aware compatibility records and explicit manual checks.
- Save backups with integrity checks and a safety backup before restoring.
- Journaled configuration changes with rollback and recovery.
- External data-volume registration, identified by UUID rather than its name.
- Explicit local diagnostic exports; no automatic uploads or telemetry.

## Build and test

Use macOS with the Swift 6 toolchain and Xcode command-line tools:

```sh
source/build.sh test
source/build.sh build
```

Unit tests use generated temporary fixtures. No Steam login, installed games,
pre-existing storage registration or Wine runtime is needed. Optional runtime
integration checks are skipped when their external dependencies are absent.

Running games requires an Apple Silicon Mac, a registered external volume, a
separately obtained runtime and games you are licensed to use. The pinned Hadron
runtime targets macOS 27; the app package's macOS 14 minimum does not imply that
this runtime works there. See [development and setup](docs/DEVELOPMENT.md).

## What is included

The repository contains manager source code, tests, original icon source,
configuration examples, license notices and documentation. It includes no games,
Steam client, account data, saves, prefixes, runtime binaries or compiler toolchain.

The graphics and Windows-compatibility work is provided by external projects,
including [Hadron](https://github.com/Broyojo/hadron),
[Wine](https://www.winehq.org/), [FEX](https://github.com/FEX-Emu/FEX),
[DXMT](https://github.com/3Shain/dxmt), [mtld3d](https://github.com/athei/mtld3d),
[Mesa](https://mesa3d.org/) and [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton).

MacGaming is unofficial and is not affiliated with or endorsed by Apple, Valve,
CodeWeavers or those projects. Product and game names belong to their owners.

## License and support

MacGaming's original work is **GPL-3.0-or-later**; see [COPYRIGHT](COPYRIGHT),
[LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
External components retain their own terms; see the [license review](docs/LICENSING.md).

Voluntary donations and sponsorships may be added later. No payment account is
configured. See [funding](FUNDING.md) and [contributing](CONTRIBUTING.md).

The [publication review](docs/PUBLICATION.md) explains the source-only release scope
and how the sanitized publication copy was prepared.
