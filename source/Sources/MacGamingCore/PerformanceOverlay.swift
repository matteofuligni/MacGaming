// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

extension Engine {
    /// Steam starts the games, so the HUD setting must reach Steam before it is launched.
    /// Saving this never interrupts a running game; it applies when this environment restarts.
    public func performanceOverlayEnabled() throws -> Bool {
        try Runtime(translation: translation, storage: storage).manifest.environment["MTL_HUD_ENABLED"] == "1"
    }

    public func setPerformanceOverlay(enabled: Bool) throws -> String {
        try storage.validate()
        let lock = try PrefixLock(url: storage.path("manifests/.runtime-\(translation.rawValue).lock"))
        defer { withExtendedLifetime(lock) {} }
        var manifest = try Runtime(translation: translation, storage: storage).manifest
        manifest.environment["MTL_HUD_ENABLED"] = enabled ? "1" : "0"
        try storage.write(manifest, to: "manifests/runtime-\(translation.rawValue).json")
        return "FPS overlay \(enabled ? "enabled" : "disabled") for \(translation.name). Restart Windows Steam in this environment to apply."
    }
}
