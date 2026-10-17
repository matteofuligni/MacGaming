// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// Reversible changes to a game's own files, recorded in its profile.
enum GameFiles {
    static let disabledSuffix = ".macgaming-disabled"

    /// Renames installDirectory/relative to …macgaming-disabled (disabled) or back. Returns the path changed.
    static func setDisabled(_ relative: String, in installDirectory: URL, disabled: Bool) throws -> String {
        guard let clean = SaveBackups.safeRelative(relative),
              let file = SaveBackups.contained(clean, in: installDirectory) else {
            throw Failure("Path outside the game folder: \(relative)")
        }
        let parked = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + disabledSuffix)
        let fm = FileManager.default
        let (from, to) = disabled ? (file, parked) : (parked, file)
        guard fm.fileExists(atPath: from.path) else {
            throw Failure(disabled ? "\(clean) not found in the game folder." : "\(clean) is not disabled.")
        }
        guard !fm.fileExists(atPath: to.path) else { throw Failure("\(to.lastPathComponent) already exists: nothing changed.") }
        try fm.moveItem(at: from, to: to)
        return clean
    }
}

extension Engine {
    /// Disables (or restores) one file of an installed game, e.g. an intro movie the runtime cannot play.
    /// Steam's "verify integrity of game files" would download a disabled file again.
    public func setGameFileDisabled(appID: String, path: String, disabled: Bool) throws -> String {
        let id = try Self.validated(appID: appID)
        try storage.validate()
        guard let game = try library().games.first(where: { $0.appID == id }) else {
            throw Failure("AppID \(id) is not installed in the \(translation.name) environment.")
        }
        let changed = try GameFiles.setDisabled(path, in: game.installDirectory, disabled: disabled)
        _ = try editProfile(appID: id) { entry in
            var files = Set(entry.disabledFiles ?? [])
            if disabled { files.insert(changed) } else { files.remove(changed) }
            entry.disabledFiles = files.isEmpty ? nil : files.sorted()
        }
        return disabled ? "\(changed) disabled for \(game.name) (renamed with \(GameFiles.disabledSuffix))."
                        : "\(changed) restored for \(game.name)."
    }
}
