// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import Darwin

enum GameTransfer {
    /// Copies an installed game's folder and appmanifest into another Steam's default library.
    /// Files are APFS clones when the volume allows it, so the copy takes no space until one side
    /// changes. The appmanifest goes last: Steam sees the game only once its files are complete.
    static func copy(_ game: InstalledGame, manifest: URL, toSteamApps steamapps: URL) throws {
        let fm = FileManager.default
        let installDir = game.installDirectory.lastPathComponent
        let common = steamapps.appendingPathComponent("common")
        let target = common.appendingPathComponent(installDir)
        let targetManifest = steamapps.appendingPathComponent(manifest.lastPathComponent)
        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: targetManifest.path) else {
            throw Failure("\(game.name) is already in the destination environment.")
        }
        guard fm.fileExists(atPath: game.installDirectory.path) else { throw Failure("Folder of \(game.name) not found.") }
        try fm.createDirectory(at: common, withIntermediateDirectories: true)
        let staging = common.appendingPathComponent(".\(installDir).macgaming-copy")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try clone(game.installDirectory, to: staging)
        do {
            try fm.moveItem(at: staging, to: target)
            try clone(manifest, to: targetManifest)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        // COPYFILE_CLONE falls back to a regular copy where cloning is not possible.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw Failure("Copy failed (\(String(cString: strerror(errno)))): \(source.lastPathComponent)")
        }
    }
}

extension Engine {
    /// Copies a fully installed game from the other environment into this one. This environment's
    /// Steam must be closed; it adopts the game at its next start.
    public func copyGame(appID: String) throws -> String {
        try storage.validate()
        guard let source = CPUTranslation.allCases.first(where: { $0 != translation }) else { throw Failure("No other environment.") }
        let sourceEngine = Engine(storage: storage, translation: source)
        guard let game = try sourceEngine.library().games.first(where: { $0.appID == appID }) else {
            throw Failure("AppID \(appID) is not installed in the \(source.name) environment.")
        }
        guard game.isReady else { throw Failure("\(game.name) is not ready in the \(source.name) environment: \(game.status).") }
        let prefix = try prefix()
        guard FileManager.default.fileExists(atPath: try steamExecutable().path) else { throw Failure("Install Steam in this environment before copying games into it.") }
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard SessionProbe.wineserverPID(prefix: prefix) == nil else { throw Failure("Stop this environment before copying a game into it.") }
        let sourceSteamApps = game.installDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = sourceSteamApps.appendingPathComponent("appmanifest_\(appID).acf")
        let steamapps = try steamExecutable().deletingLastPathComponent().appendingPathComponent("steamapps")
        try GameTransfer.copy(game, manifest: manifest, toSteamApps: steamapps)
        return "\(game.name) copied from the \(source.name) environment. Steam will pick it up at its next start."
    }
}
