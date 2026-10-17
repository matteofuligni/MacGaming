#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
# Builds and arms the guard. It never launches Steam or Horizon.
set -eu
SOURCE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
TRIAL_ROOT="${1:-${MACGAMING_DATA_ROOT:-$(CDPATH= cd -- "$SOURCE_DIR/../../.." && pwd -P)}}"
case "$TRIAL_ROOT" in /*) ;; *) echo 'An absolute external data path is required.' >&2; exit 1 ;; esac
[ -f "$TRIAL_ROOT/manifests/storage.json" ] || { echo 'The registered external data folder is unavailable. Nothing was armed.' >&2; exit 1; }
TRIAL_ROOT="$(CDPATH= cd -- "$TRIAL_ROOT" && pwd -P)"
case "$TRIAL_ROOT" in /Volumes/*) ;; *) echo 'Use the existing external volume; internal fallback is not allowed.' >&2; exit 1 ;; esac
for directory in build build/safety cache cache/guard-clang tmp; do
    [ ! -L "$TRIAL_ROOT/$directory" ] || { echo 'Build/cache paths must stay on the registered disk.' >&2; exit 1; }
done
# All real trial output and compilation caches stay on the external disk.
mkdir -p "$TRIAL_ROOT/build/safety" "$TRIAL_ROOT/cache/guard-clang" "$TRIAL_ROOT/tmp"
export TMPDIR="$TRIAL_ROOT/tmp/"
TRIAL_SWIFTC="$(xcrun --find swiftc)"
TRIAL_SDK="$(xcrun --show-sdk-path)"
TRIAL_ARCH="$(uname -m)"
"$TRIAL_SWIFTC" -O -target "$TRIAL_ARCH-apple-macos14.0" -sdk "$TRIAL_SDK" \
    -module-cache-path "$TRIAL_ROOT/cache/guard-clang" "$SOURCE_DIR/MemoryGuard.swift" \
    -o "$TRIAL_ROOT/build/safety/horizon-memory-guard"
"$TRIAL_ROOT/build/safety/horizon-memory-guard" --self-test
exec "$TRIAL_ROOT/build/safety/horizon-memory-guard" --root "$TRIAL_ROOT"
