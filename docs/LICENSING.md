# License review — 17 October 2026

## Decision and scope

The prepared **source-only** publication can use GPL-3.0-or-later for MacGaming's
original work, preserve the adapted Steam wrapper's MIT notice, and allow voluntary
donations or sponsorships. The source release excludes external runtime binaries,
Steam, games, SDKs and downloaded research sources. It does not claim that every
file in a third-party runtime is under GPL or that all runtime binaries may be
repackaged without additional work.

The chosen license is stated in `COPYRIGHT`, the full GPLv3 text in `LICENSE`,
and SPDX headers on the original code. “Or later” permits recipients to choose a
later GNU GPL version published by the Free Software Foundation. GPL does not
require private modifications to be published; distribution of a covered derived
work carries source and license obligations. A source-only GitHub repository is
different from distributing an app with an entire runtime inside it.

GPL permits charging for copies and support. MIT also permits sale. Donations do
not remove attribution, copyleft or proprietary-license requirements. References:
[GPLv3 text](https://www.gnu.org/licenses/gpl-3.0.html),
[SPDX GPL-3.0-or-later](https://spdx.org/licenses/GPL-3.0-or-later.html),
[MIT text](https://opensource.org/license/mit),
[GitHub Sponsors](https://docs.github.com/en/sponsors/getting-started-with-github-sponsors/about-github-sponsors).
No payment account is activated by this preparation.

## Included third-party code and assets

The explicitly adapted source is the Steam browser helper wrapper. Upstream's MIT
license was fetched from the public repository and retained with its copyright,
permission and disclaimer. The exact fetched file is recorded by its Git blob ID
in `LICENSES/upstream-evidence.json`. MIT permits this adaptation and distribution
of the combined wrapper under GPL while retaining the upstream notice.

The original Swift sources, test code, C probes and game-local shims have been
reviewed for declared imports and references. The shims operate on public COM and
Direct3D interfaces and contain no embedded game image, game source file, fixed
game code addresses or proprietary SDK implementation. Downloaded Wine, mtld3d and
gta-reversed reference files are excluded. No redistribution permission was inferred
from the mere public visibility of gta-reversed (no top-level license was found).

The source icon is an AppKit drawing. The previously generated `.icns` contains
embedded PNG EXIF metadata and is excluded; builds regenerate it locally. No font,
SF Symbol export, screenshot or game artwork is shipped as an icon.

Apple Foundation, AppKit, SwiftUI, Darwin and other system interfaces are supplied
by the operating system/SDK. `Package.swift` has no third-party Swift package
dependencies. It does not copy Apple's frameworks into this source release.

## External runtime review

The [machine-readable inventory](dependency-license-inventory.json) hashes **195**
license/notice files supplied with Hadron 0.3.0 and **24** license files supplied with
llvm-mingw. There are 105 distinct file hashes across the 219 inventory entries.
Family hints are search aids, not SPDX conclusions for every binary. A notice file
can cover multiple components, and a directory can contain license texts for code
not actually linked into the shipped runtime.

Hadron's supplied notice identifies source commit
`2faae2af7dbcd0b6448bea5c86c20c33548a792c`; its `sources.conf`, patch queues and build
scripts identify the constituent source revisions. The exact 0.3.0 top-level license
and `packaging/third-party.conf` were also checked upstream:
[Hadron licensing](https://github.com/Broyojo/hadron/blob/v0.3.0/LICENSE),
[component declaration](https://github.com/Broyojo/hadron/blob/v0.3.0/packaging/third-party.conf).

| Component/group | Terms found | Consequence for a future binary release |
|---|---|---|
| Hadron's own files | BSD-3-Clause | Retain notices; do not imply author endorsement |
| Wine, Hadron DXMT, vkd3d-proton, decoding-only FFmpeg | LGPL-2.1-or-later | Retain notices and meet corresponding-source/modification and applicable replacement/relinking obligations |
| DXMT 0.80 add-on | MIT, confirmed at the exact tag | Retain MIT notice; later DXMT licenses must not be inferred from this tag |
| FEX and vendored material | MIT, Apache, BSD, ISC-style and Unlicense notices | Retain exact applicable notices and review which vendored pieces are built |
| mtld3d and Rust crates | zlib, MIT/Apache alternatives, BSD, ISC, Unlicense, BSL-1.0 and Unicode terms | Use appropriate permitted alternatives and retain the full relevant notices |
| Mesa / KosmicKrisp / Zink | Per-file MIT/BSD/GPL texts and Linux-syscall exception | Determine the actual built files; do not label the whole closure MIT from a README |
| DXVK DXGI | zlib plus component notices | Retain relevant notices and identify modifications |
| LLVM 15 and llvm-mingw LLVM components | Apache-2.0 with LLVM exceptions | Check code-generation exceptions and included runtime notices |
| NotProton | GPL-3.0 plus separately licensed pieces | Supply corresponding source for covered binary parts; GPL does not override SDK terms |
| lsteamclient / Steamworks-derived material | Steamworks SDK agreement | Not an open-source grant; review eligibility and the exact permitted redistribution scope separately |
| Steam shim, Dobby, cJSON, Sparkle | BSD-3-Clause / Apache-2.0 / MIT as declared | Preserve their own notices; do not treat the entire group as GPL-only |
| FreeType | Choice of FTL or GPL-2.0-or-later; license index also names module terms | Supplied license index refers to further texts not present in its license directory; collect the chosen complete grant before repackaging |
| gettext, GMP, GnuTLS, libidn2, libtasn1, libunistring, libusb, nettle, p11-kit | GPL/LGPL texts, including v2.1/v3, and Unicode notices as applicable | Identify actual library grants and corresponding sources; COPYING alone may describe a different part of a package |
| libpng, SDL2 compatibility, SDL3 | Permissive component licenses, including libpng/zlib | Preserve applicable notices and modification markings |
| SPIR-V Tools, Vulkan loader | Apache-2.0 and component notices | Preserve notices and applicable license text |
| Gcenx Wine Stable 11.0_1 | Wine's upstream LGPL; no license files found in the acquired app bundle | Full bundled-library/source inventory is missing: do not redistribute that bundle as reviewed |

Two concrete gaps prevent blanket approval of external runtime repackaging:
the Steamworks SDK agreement is a separate proprietary grant, and the acquired
Gcenx bundle does not supply a component/license inventory. FreeType's supplied
index also points to additional grant texts that must be collected for redistribution.
Disabling an SDK-related runtime feature does not remove SDK files from a bundle.
The source publication avoids conveying these payloads; this does not waive the
user's obligations when acquiring or using them separately.

The Hadron notice-file inventory is evidence of supplied license material, not
proof that every shipped library matches its advertised sources or that every
notice required by every transitive dependency is present. A future complete app
release needs a binary-to-source inventory and verification of actual build options.

## Other excluded payloads

- Steam installers and games remain proprietary. Source manifests contain public
  download locations and digests only; login and game rights remain with the user.
- Ultimate ASI Loader is MIT in the inspected upstream `license` file; no loader
  source or binary is shipped here.
- Microsoft Visual C++ redistributables, Windows SDKs and game installers are not included.
- Rosetta is provided by Apple; it is not an asset to copy into this repository.
- D3DMetal/GPTK, CrossOver and GameToMac are not part of the published sources.
  No commercial or noncommercial redistribution conclusion is made for those payloads.

## Release rule

Publish the sanitized source copy with its notices. Do not upload the private
development folder, a Git bundle, raw diagnostics or the old Git history. Before
shipping executables, assemble the exact corresponding source, preserve generated
code notices, package user-independent resources, and verify signing/notarization.
Any unresolved proprietary grant or license conflict needs qualified legal review
before that payload is distributed. This review records evidence and engineering
decisions; it is not a legal opinion or a guarantee of third-party compliance.
