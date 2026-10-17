#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
# Builds, tests and packages MacGaming. Every build product, cache and temporary file stays on the
# external disk, next to this source folder.
#   ./build.sh test    run the test suite
#   ./build.sh build   debug build of the CLI and the app executable
#   ./build.sh wrapper steamwebhelper wrapper (Windows x86_64) with llvm-mingw from toolchains/
#   ./build.sh preload image range library for Hadron's Wine loader (build/preload)
#   ./build.sh probe   Direct3D 11 and CPUID consistency check programs (build/probes), same toolchain
#   ./build.sh icon    redraws icon/AppIcon.icns from icon/make-icon.swift
#   ./build.sh shims   per-game DLLs/ASI + the synthetic GTA multiply-add probe (build/shims/i686)
#   ./build.sh guard-test  compile and test the memory guard without arming it
#   ./build.sh app     wrapper + preload + release build packaged as build/MacGaming.app (default)
set -eu
SRC="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(dirname "$SRC")"
mkdir -p "$ROOT/tmp" "$ROOT/cache/clang" "$ROOT/cache/swiftpm"
export TMPDIR="$ROOT/tmp/" CLANG_MODULE_CACHE_PATH="$ROOT/cache/clang"
export MACGAMING_TEST_ROOT="$ROOT/tmp/tests"
swiftpm() {
    command="$1"; shift
    swift "$command" --disable-sandbox --package-path "$SRC" --scratch-path "$ROOT/build/native" \
        --cache-path "$ROOT/cache/swiftpm" "$@"
}

mingw() {
    toolchain="$ROOT/toolchains/llvm-mingw-20261006-ucrt-macos-universal/bin"
    [ -x "$toolchain/x86_64-w64-mingw32-clang" ] || { echo "llvm-mingw missing in $toolchain (see manifests/toolchain-llvm-mingw.json)" >&2; exit 1; }
}

wrapper() {
    mingw
    mkdir -p "$ROOT/build/wrapper"
    "$toolchain/x86_64-w64-mingw32-clang" -municode -mwindows -O2 -Wall -Wextra -static \
        -o "$ROOT/build/wrapper/steamwebhelper.exe" "$SRC/wrapper/steamwebhelper-wrapper.c"
    digest="$(shasum -a 256 "$ROOT/build/wrapper/steamwebhelper.exe" | cut -d' ' -f1)"
    # Engine installs the wrapper only if it still matches this digest.
    printf '{\n  "schemaVersion": 1,\n  "path": "build/wrapper/steamwebhelper.exe",\n  "sha256": "%s",\n  "flags": "--disable-gpu --single-process"\n}\n' \
        "$digest" > "$ROOT/manifests/steamwebhelper-wrapper.json"
    echo "$ROOT/build/wrapper/steamwebhelper.exe $digest"
}

preload() {
    mkdir -p "$ROOT/build/preload"
    library="$ROOT/build/preload/macgaming-image-reserve.dylib"
    # Running Wine processes map the library: replace it by rename, never rewrite it in place.
    clang -dynamiclib -arch arm64 -O2 -Wall -Wextra -Werror -o "$library.new" "$SRC/preload/image-reserve.c"
    mv -f "$library.new" "$library"
    digest="$(shasum -a 256 "$library" | cut -d' ' -f1)"
    # Runtime.swift inserts the library only while it still matches this digest.
    printf '{\n  "schemaVersion": 1,\n  "path": "build/preload/macgaming-image-reserve.dylib",\n  "sha256": "%s"\n}\n' \
        "$digest" > "$ROOT/manifests/image-reserve.json"
    echo "$library $digest"
}

probe() {
    mingw
    mkdir -p "$ROOT/build/probes"
    "$toolchain/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -static -o "$ROOT/build/probes/d3d11-probe.exe" \
        "$SRC/probes/d3d11-probe.c" -ld3d11 -ldxgi -luuid
    echo "$ROOT/build/probes/d3d11-probe.exe"
    "$toolchain/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -static -o "$ROOT/build/probes/cpuid-consistency.exe" \
        "$SRC/probes/cpuid-consistency-probe.c"
    echo "$ROOT/build/probes/cpuid-consistency.exe"
    # 32-bit, named after GTA San Andreas so it gets that game's per-executable Wine settings.
    mkdir -p "$ROOT/build/probes/display-modes"
    "$toolchain/i686-w64-mingw32-clang" -O2 -Wall -Wextra -static -o "$ROOT/build/probes/display-modes/gta-sa.exe" \
        "$SRC/probes/display-modes-probe.c" -ld3d9
    echo "$ROOT/build/probes/display-modes/gta-sa.exe"
}

icon() {
    work="$ROOT/tmp/AppIcon.iconset"
    rm -rf "$work"; mkdir -p "$work"
    swift "$SRC/icon/make-icon.swift" "$ROOT/tmp/AppIcon-1024.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ROOT/tmp/AppIcon-1024.png" --out "$work/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ROOT/tmp/AppIcon-1024.png" --out "$work/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$work" -o "$SRC/icon/AppIcon.icns"
    rm -rf "$work" "$ROOT/tmp/AppIcon-1024.png"
    echo "$SRC/icon/AppIcon.icns"
}

shims() {
    toolchain="$ROOT/toolchains/llvm-mingw-20261006-ucrt-macos-universal/bin"
    [ -x "$toolchain/i686-w64-mingw32-clang" ] || { echo "llvm-mingw missing in $toolchain" >&2; exit 1; }
    for arch in i686 x86_64; do
        mkdir -p "$ROOT/build/shims/$arch"
        "$toolchain/$arch-w64-mingw32-clang" -O2 -Wall -Wextra -shared -static -Wl,--kill-at \
            -o "$ROOT/build/shims/$arch/winegstreamer.dll" "$SRC/shims/winegstreamer-stub.c" -luuid
    done
    "$toolchain/i686-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -shared -static \
        -o "$ROOT/build/shims/i686/MacGamingSA.asi" "$SRC/shims/gtasa-mtld3d.c" -luser32 -luuid
    "$toolchain/i686-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -static \
        -o "$ROOT/build/shims/i686/gta-sa.exe" "$SRC/probes/gtasa-multiplyadd-probe.c" -ld3d9 -luser32
    # This synthetic offscreen test must render its first draw instead of skipping an async compile.
    printf 'shader.asyncCompile = false\n' > "$ROOT/build/shims/i686/mtld3d.conf"
    shasum -a 256 "$ROOT"/build/shims/*/winegstreamer.dll
    shasum -a 256 "$ROOT/build/shims/i686/MacGamingSA.asi"
}

guard_test() {
    mkdir -p "$ROOT/build/safety"
    swiftc -O -module-cache-path "$ROOT/cache/clang" "$SRC/tools/horizon-trial/MemoryGuard.swift" \
        -o "$ROOT/build/safety/game-memory-guard"
    "$ROOT/build/safety/game-memory-guard" --self-test
}

case "${1:-app}" in
    test) swiftpm test ;;
    build) swiftpm build ;;
    wrapper) wrapper ;;
    preload) preload ;;
    probe) probe ;;
    icon) icon ;;
    shims) shims ;;
    guard-test) guard_test ;;
    app)
        [ -f "$ROOT/manifests/storage.json" ] || { echo 'Register your external data folder first (see docs/DEVELOPMENT.md).' >&2; exit 1; }
        wrapper
        preload
        swiftpm build -c release
        bin="$(swiftpm build -c release --show-bin-path)"
        app="$ROOT/build/MacGaming.app"
        staging="$ROOT/build/MacGaming.app.new"
        rm -rf "$staging"
        # The data volume is case-insensitive: the CLI cannot sit next to MacOS/MacGaming.
        mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers" "$staging/Contents/Resources"
        [ -f "$SRC/icon/AppIcon.icns" ] || icon
        cp "$SRC/icon/AppIcon.icns" "$staging/Contents/Resources/AppIcon.icns"
        cp "$ROOT/manifests/storage.json" "$staging/Contents/Resources/storage.json"
        cp "$bin/MacGamingDesktop" "$staging/Contents/MacOS/MacGaming"
        cp "$bin/macgaming" "$staging/Contents/Helpers/macgaming"
        cat > "$staging/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.macgaming.app</string>
    <key>CFBundleName</key><string>MacGaming</string>
    <key>CFBundleDisplayName</key><string>MacGaming</string>
    <key>CFBundleExecutable</key><string>MacGaming</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
        codesign --force --sign - "$staging/Contents/Helpers/macgaming"
        codesign --force --sign - "$staging"
        # Replace the previous bundle only once the new one is complete.
        rm -rf "$app"
        mv "$staging" "$app"
        echo "$app"
        ;;
    *) echo "Usage: $0 [test|build|wrapper|preload|probe|icon|shims|guard-test|app]" >&2; exit 2 ;;
esac
