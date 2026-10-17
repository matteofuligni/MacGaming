# Third-party notices

MacGaming's original work is GPL-3.0-or-later. This does not replace any upstream
license or grant permission to redistribute a game, proprietary SDK or runtime.

## Code included in this source release

`source/wrapper/steamwebhelper-wrapper.c` is adapted from
[notpop/steam-on-m1-wine](https://github.com/notpop/steam-on-m1-wine).
Copyright (c) 2026 notpop. The original MIT permission and disclaimer are retained
verbatim in [LICENSES/steam-on-m1-wine-MIT.txt](LICENSES/steam-on-m1-wine-MIT.txt).
MacGaming modifications are GPL-3.0-or-later. The original permission includes
modification, sublicensing and sale subject to retaining the upstream notice.

The app icon is generated from the original AppKit drawing in
`source/icon/make-icon.swift`; no SF Symbol, third-party icon, game artwork or
pre-generated icon binary is included in the source release.

## External software, not included

| Component | Applicable pin / terms | Source release treatment |
|---|---|---|
| Hadron's own code | 0.3.0, BSD-3-Clause | External runtime, not bundled |
| Wine | LGPL-2.1-or-later | External runtime, not bundled |
| DXMT within Hadron | Exact revision in Hadron 0.3.0, LGPL-2.1-or-later | External runtime, not bundled |
| DXMT add-on | 0.80, MIT | No DLLs included; license copy in LICENSES |
| FEX | MIT plus vendored notices | External runtime, not bundled |
| mtld3d | zlib plus Rust/library notices | External runtime, not bundled |
| Mesa / KosmicKrisp / Zink | Multiple per-file licenses, including MIT | External runtime, not bundled |
| vkd3d-proton | LGPL-2.1-or-later | External runtime, not bundled |
| DXVK's DXGI | zlib | External runtime, not bundled |
| FFmpeg and support libraries | Component-specific copyleft/permissive terms | External runtime, not bundled |
| NotProton and lsteamclient | GPL-3.0 and separate Steamworks SDK/BSD/Apache/MIT terms | Not bundled; no blanket redistribution approval |
| Gcenx Wine Stable | 11.0_1, upstream and bundled-library terms | Not bundled; supplied bundle lacks license inventory |
| llvm-mingw | 20261006 UCRT, component-specific compiler/runtime licenses | Toolchain not bundled; code-generation notices retained |
| Ultimate ASI Loader | Separately acquired, MIT in inspected upstream | Not bundled; no loader source copied |
| Valve Steam and games | Proprietary client/store/game terms | Neither source nor binaries included |
| Apple frameworks / Rosetta | Supplied by Apple under Apple terms | Not copied or relicensed |

The full external notice-file inventory and the remaining binary-distribution
questions are in [docs/LICENSING.md](docs/LICENSING.md). Public upstream copyright
notices must remain intact; they are distinct from private developer identity.

## Compiler-generated code

Compiling the C helpers can incorporate LLVM compiler-rt/libc++ and mingw-w64
runtime material. Relevant license copies are retained in
`LICENSES/LLVM-Apache-2.0-with-exceptions.txt` and `LICENSES/mingw-w64-runtime.txt`.
The LLVM exceptions include permissions concerning embedded compiler/runtime code;
preserve applicable license and attribution material when distributing binaries.
These texts do not certify a future binary's complete dependency closure.

No D3DMetal/GPTK, CrossOver or GameToMac payload, Microsoft redistributable, game
asset or reverse-engineered GTA source is included. Downloaded research references
are not part of this source release.
