# MacGaming source

See the [project README](../README.md), [setup guide](../docs/DEVELOPMENT.md),
[license review](../docs/LICENSING.md) and [contributing guide](../CONTRIBUTING.md).

`Package.swift` builds the `MacGamingCore` library, `macgaming` CLI and
`MacGamingDesktop` SwiftUI executable. Tests use isolated fixtures and do not
require a developer's storage registration, account, games or runtime installation.

Use `./build.sh test`, `./build.sh build` or, after registering your own external
data folder and acquiring dependencies, `./build.sh app`.

The `icon/make-icon.swift` drawing is the editable source for the original app
icon. The probes and game-local compatibility shims contain no game executables
or assets. Compatibility remains experimental and must be checked on your system.
