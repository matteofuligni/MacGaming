// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import Darwin

/// Windows folders Steam Cloud names by number in remotecache.vdf (Steamworks ERemoteStorageFileRoot).
enum SaveRoot: String, Codable, CaseIterable {
    case steamCloud, gameInstall, documents, appDataLocal, appDataRoaming, savedGames, programData, appDataLocalLow

    init?(steamRoot: String) {
        switch steamRoot {
        case "0": self = .steamCloud
        case "1": self = .gameInstall
        case "2": self = .documents
        case "3": self = .appDataLocal
        case "4": self = .appDataRoaming
        case "9": self = .savedGames
        case "10": self = .programData
        case "12": self = .appDataLocalLow
        default: return nil
        }
    }
}

public struct SaveFile: Codable, Equatable, Sendable {
    public var root: String
    public var path: String
    public var size: Int64
    public var sha256: String
}

public struct SaveBackup: Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case automatic = "automatic", manual = "manual", beforeLaunch = "before launch", beforeRestore = "before restore"

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Backups written before the English interface carry Italian reasons.
            let legacy = ["manuale": "manual", "prima dell'avvio": "before launch", "prima del ripristino": "before restore"]
            guard let reason = Reason(rawValue: legacy[raw] ?? raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown reason \(raw)"))
            }
            self = reason
        }
    }
    public var schemaVersion = 1
    public var id: String
    public var appID: String
    public var environment: String
    public var reason: Reason
    public var createdAt: Date
    public var files: [SaveFile]
    /// Sizes and modification dates of the saves when backed up, to notice the next change cheaply.
    public var signature: String?
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// The folders a game's saves live in, inside one prefix.
struct SaveLocations {
    var bases: [SaveRoot: URL]
    /// Files Steam Cloud tracks, by root, as paths relative to the root's folder.
    var tracked: [(root: SaveRoot, path: String)]
    /// Whole folders a game profile declares, for games Steam Cloud does not list.
    var folders: [(root: SaveRoot, path: String)] = []
    var warnings: [String]
}

enum SaveBackups {
    /// Backups made without asking that are kept, per kind; manual ones are never removed.
    static let kept: [SaveBackup.Reason: Int] = [.automatic: 20, .beforeLaunch: 10]

    /// Reads every account's remotecache.vdf for the AppID and maps its roots to the prefix's folders.
    static func locate(appID: String, prefix: URL, user: String, installDirectory: URL?,
                       declared: [GameProfile.SavePath] = []) throws -> SaveLocations {
        let fm = FileManager.default
        let userdata = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/userdata")
        let accounts = ((try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.allSatisfy(\.isNumber) && fm.fileExists(atPath: $0.appendingPathComponent("\(appID)/remotecache.vdf").path) }
        guard !accounts.isEmpty || !declared.isEmpty else {
            throw Failure("Steam Cloud has no save list for AppID \(appID) in this environment yet: launch the game once from Steam.")
        }
        let home = prefix.appendingPathComponent("drive_c/users/\(user)")
        var bases: [SaveRoot: URL] = [
            .documents: home.appendingPathComponent("Documents"),
            .appDataLocal: home.appendingPathComponent("AppData/Local"),
            .appDataRoaming: home.appendingPathComponent("AppData/Roaming"),
            .appDataLocalLow: home.appendingPathComponent("AppData/LocalLow"),
            .savedGames: home.appendingPathComponent("Saved Games"),
            .programData: prefix.appendingPathComponent("drive_c/ProgramData"),
        ]
        if let installDirectory { bases[.gameInstall] = installDirectory }
        // Files in Steam's own cloud folder belong to one account: only unambiguous with a single one.
        if accounts.count == 1 { bases[.steamCloud] = accounts[0].appendingPathComponent("\(appID)/remote") }

        var tracked: [(root: SaveRoot, path: String)] = []
        var warnings: [String] = []
        for account in accounts {
            let cache = try KeyValues.parse(String(contentsOf: account.appendingPathComponent("\(appID)/remotecache.vdf"), encoding: .utf8)).value
            for (path, entry) in cache.entries {
                guard let rootNumber = entry["root"]?.string else { continue } // ChangeNumber, OSType…
                guard let root = SaveRoot(steamRoot: rootNumber), bases[root] != nil else {
                    warnings.append("Unsupported Steam Cloud root \(rootNumber): \(path)"); continue
                }
                guard let relative = safeRelative(path) else { warnings.append("Invalid path ignored: \(path)"); continue }
                if !tracked.contains(where: { $0.root == root && $0.path == relative }) { tracked.append((root, relative)) }
            }
        }
        var folders: [(root: SaveRoot, path: String)] = []
        for folder in declared {
            guard let root = SaveRoot(rawValue: folder.root), bases[root] != nil, let relative = safeRelative(folder.path) else {
                warnings.append("Invalid save folder in the profile: \(folder.root)/\(folder.path)"); continue
            }
            folders.append((root, relative))
        }
        return SaveLocations(bases: bases, tracked: tracked, folders: folders, warnings: warnings)
    }

    /// The files to keep: those Steam Cloud tracks plus the other files next to them, which can be
    /// saves made since the last sync.
    static func files(in locations: SaveLocations) -> [(root: SaveRoot, path: String, url: URL)] {
        let fm = FileManager.default
        var result: [(root: SaveRoot, path: String, url: URL)] = []
        var seen = Set<String>()
        func add(_ root: SaveRoot, _ path: String) {
            guard let base = locations.bases[root], seen.insert("\(root.rawValue)/\(path)").inserted,
                  let url = contained(path, in: base) else { return }
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            result.append((root, path, url))
        }
        for (root, path) in locations.tracked { add(root, path) }
        for (root, folder) in locations.folders {
            guard let base = locations.bases[root], let directory = contained(folder, in: base),
                  let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.path.hasPrefix(directory.path + "/") {
                add(root, folder + "/" + String(url.path.dropFirst(directory.path.count + 1)))
            }
        }
        var folders = Set<String>()
        for (root, path) in locations.tracked {
            let parent = (path as NSString).deletingLastPathComponent
            // Next to a game's own files, or loose in Documents, neighbours are not saves.
            guard root != .gameInstall, !parent.isEmpty, folders.insert("\(root.rawValue)/\(parent)").inserted, let base = locations.bases[root],
                  let folder = contained(parent, in: base),
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                add(root, parent + "/" + name)
            }
        }
        return result
    }

    /// Sizes and modification dates of the files to keep: equal signatures mean nothing to back up.
    static func signature(of locations: SaveLocations) -> String {
        files(in: locations).map { file -> String in
            let values = try? file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(file.root.rawValue)/\(file.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted().joined(separator: "\n")
    }

    static func backup(appID: String, environment: String, reason: SaveBackup.Reason, locations: SaveLocations,
                       into appDirectory: URL, now: Date = Date()) throws -> SaveBackup {
        let fm = FileManager.default
        let signature = signature(of: locations)
        let sources = files(in: locations)
        guard !sources.isEmpty else { throw Failure("No save files found for AppID \(appID).") }
        try fm.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        var id = formatter.string(from: now), suffix = 2
        while fm.fileExists(atPath: appDirectory.appendingPathComponent(id).path) { id = formatter.string(from: now) + "-\(suffix)"; suffix += 1 }
        // Written aside and renamed at the end: a backup directory is always complete.
        let staging = appDirectory.appendingPathComponent(".\(id).partial")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        do {
            var saved: [SaveFile] = []
            for source in sources {
                let target = staging.appendingPathComponent("files/\(source.root.rawValue)/\(source.path)")
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try clone(source.url, to: target)
                let size = Int64(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                saved.append(SaveFile(root: source.root.rawValue, path: source.path, size: size, sha256: try Runner.sha256(target)))
            }
            let backup = SaveBackup(id: id, appID: appID, environment: environment, reason: reason, createdAt: now,
                                    files: saved, signature: signature)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try fm.moveItem(at: staging, to: appDirectory.appendingPathComponent(id))
            try prune(appDirectory, reason: reason)
            return backup
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// An empty current save set is safe to restore into; any failure protecting existing saves aborts.
    static func safetyBackup(appID: String, environment: String, locations: SaveLocations,
                             into directory: URL, restoring: SaveBackup? = nil) throws -> SaveBackup? {
        var locations = locations
        // Cloud's current list can omit a file an older backup will overwrite. Protect that file too.
        for file in restoring?.files ?? [] {
            guard let root = SaveRoot(rawValue: file.root), locations.bases[root] != nil,
                  let path = safeRelative(file.path) else { throw Failure("Invalid restore target: no saves were restored.") }
            if !locations.tracked.contains(where: { $0.root == root && $0.path == path }) { locations.tracked.append((root, path)) }
        }
        guard !files(in: locations).isEmpty else { return nil }
        do {
            return try backup(appID: appID, environment: environment, reason: .beforeRestore,
                              locations: locations, into: directory)
        } catch {
            throw Failure("Restore cancelled: the current saves could not be backed up. No saves were restored. " + error.localizedDescription)
        }
    }

    static func list(_ appDirectory: URL) -> [SaveBackup] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? decoder.decode(SaveBackup.self, from: Data(contentsOf: $0.appendingPathComponent("manifest.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Puts a backup's files back. Files saved since then that the backup does not contain stay.
    static func restore(_ backup: SaveBackup, from appDirectory: URL, locations: SaveLocations) throws -> Int {
        let fm = FileManager.default
        guard backup.schemaVersion == 1, let id = safeRelative(backup.id), !id.contains("/"), !backup.files.isEmpty else {
            throw Failure("Invalid save backup manifest: no file was touched.")
        }
        let folder = appDirectory.appendingPathComponent(id)
        var plan: [(source: URL, target: URL)] = []
        for file in backup.files {
            guard let root = SaveRoot(rawValue: file.root), let base = locations.bases[root],
                  let relative = safeRelative(file.path), let target = contained(relative, in: base),
                  let source = contained("files/\(file.root)/\(relative)", in: folder) else {
                throw Failure("Backup \(backup.id) contains a path that cannot be restored: \(file.path)")
            }
            guard fm.fileExists(atPath: source.path), try Runner.sha256(source) == file.sha256 else {
                throw Failure("Backup \(backup.id) is incomplete or modified (\(file.path)): no file was touched.")
            }
            plan.append((source, target))
        }
        for (source, target) in plan {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).macgaming-restore")
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try clone(source, to: staged)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        }
        return plan.count
    }

    private static func prune(_ appDirectory: URL, reason: SaveBackup.Reason) throws {
        guard let limit = kept[reason] else { return }
        for old in list(appDirectory).filter({ $0.reason == reason }).dropFirst(limit) {
            try FileManager.default.removeItem(at: appDirectory.appendingPathComponent(old.id))
        }
    }

    /// Normalises a path written by Steam or a game; nil if absolute or climbing out with "..".
    static func safeRelative(_ path: String) -> String? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              !(parts.first?.hasSuffix(":") ?? false) else { return nil }
        return parts.joined(separator: "/")
    }

    /// base/relative, refused when a link along the way leads outside base.
    static func contained(_ relative: String, in base: URL) -> URL? {
        let url = relative.isEmpty ? base : base.appendingPathComponent(relative)
        let root = base.resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        return resolved == root || resolved.hasPrefix(root + "/") ? url : nil
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        // COPYFILE_CLONE falls back to a regular copy where cloning is not possible.
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)) == 0 else {
            throw Failure("Copy failed (\(String(cString: strerror(errno)))): \(source.lastPathComponent)")
        }
    }
}

extension Engine {
    func saveLocations(appID: String) throws -> SaveLocations {
        let id = try Self.validated(appID: appID)
        let prefix = try prefix()
        let installDirectory = try? library().games.first { $0.appID == id }?.installDirectory
        let declared = (try? profile(appID: id))?.savePaths ?? []
        return try SaveBackups.locate(appID: id, prefix: prefix, user: prefixUser(prefix), installDirectory: installDirectory,
                                      declared: declared)
    }
    func prefixUser(_ prefix: URL) -> String {
        let users = prefix.appendingPathComponent("drive_c/users")
        let current = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        if FileManager.default.fileExists(atPath: users.appendingPathComponent(current).path) { return current }
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }
        return others.count == 1 ? others[0] : current
    }
    func saveBackupDirectory(appID: String) throws -> URL {
        try storage.path("backups/saves/\(translation.rawValue)/\(try Self.validated(appID: appID))")
    }

    /// Backs up a game's saves; with `onlyIfChanged`, returns nil when they match the latest backup.
    @discardableResult
    func makeSaveBackup(appID: String, reason: SaveBackup.Reason, onlyIfChanged: Bool = false) throws -> SaveBackup? {
        try storage.validate()
        let locations = try saveLocations(appID: appID)
        let directory = try saveBackupDirectory(appID: appID)
        if onlyIfChanged, let latest = SaveBackups.list(directory).first,
           latest.signature == SaveBackups.signature(of: locations) { return nil }
        return try SaveBackups.backup(appID: appID, environment: translation.rawValue, reason: reason,
                                      locations: locations, into: directory)
    }

    /// Copies a game's saves into backups/saves/<environment>/<appid>/<date>/. Steam may stay open.
    public func backupSaves(appID: String) throws -> String {
        guard let backup = try makeSaveBackup(appID: appID, reason: .manual) else { return "Nothing to back up." }
        let size = ByteCountFormatter.string(fromByteCount: backup.totalBytes, countStyle: .file)
        return "Backup \(backup.id): \(backup.files.count) save files (\(size)) for AppID \(appID), \(translation.name) environment."
    }

    public func saveBackups(appID: String) throws -> [SaveBackup] {
        try storage.validate()
        return SaveBackups.list(try saveBackupDirectory(appID: appID))
    }

    /// Puts back the newest backup, or the one named. Steam must be closed; the current saves are
    /// backed up first, so a restore can itself be undone.
    public func restoreSaves(appID: String, backupID: String? = nil) throws -> String {
        let id = try Self.validated(appID: appID)
        try storage.validate()
        let prefix = try prefix()
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard SessionProbe.wineserverPID(prefix: prefix) == nil else {
            throw Failure("Stop this environment before restoring saves.")
        }
        let directory = try saveBackupDirectory(appID: appID)
        let backups = SaveBackups.list(directory)
        let chosen: SaveBackup?
        if let backupID {
            chosen = backups.first { $0.id == backupID }
        } else {
            // A safety copy made by a previous restore is not what one means by "the last backup".
            chosen = backups.first { $0.reason != .beforeRestore } ?? backups.first
        }
        guard let chosen else {
            throw Failure(backupID.map { "Backup \($0) not found for AppID \(appID)." } ?? "No save backups for AppID \(appID).")
        }
        guard chosen.appID == id, chosen.environment == translation.rawValue else { throw Failure("This backup belongs to a different game or environment.") }
        let locations = try saveLocations(appID: appID)
        let safety = try SaveBackups.safetyBackup(appID: appID, environment: translation.rawValue,
                                                  locations: locations, into: directory, restoring: chosen)
        let restored = try SaveBackups.restore(chosen, from: directory, locations: locations)
        return "Restored \(restored) files from backup \(chosen.id)" + (safety.map { "; the previous state is in backup \($0.id)." } ?? ".")
            + " When Steam starts again, Steam Cloud may ask which version to keep."
    }
}

/// Backs up saves automatically while MacGaming runs: once a game's saves differ from their latest
/// backup and have stopped changing for `settle` seconds, the game has finished writing them.
public final class SaveWatcher: @unchecked Sendable {
    private var pending: [String: (signature: String, since: Date)] = [:]
    private let settle: TimeInterval
    private let lock = NSLock()

    public init(settle: TimeInterval = 15) { self.settle = settle }

    /// Checks every installed game of the environment; returns one line per backup made.
    public func poll(_ engine: Engine, now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let games = try? engine.library().games else { return [] }
        var made: [String] = []
        for game in games {
            let key = "\(engine.translation.rawValue)/\(game.appID)"
            guard let locations = try? engine.saveLocations(appID: game.appID),
                  let directory = try? engine.saveBackupDirectory(appID: game.appID) else { pending[key] = nil; continue }
            let current = SaveBackups.signature(of: locations)
            guard shouldBackUp(key: key, current: current, latest: SaveBackups.list(directory).first?.signature, now: now) else { continue }
            if let backup = try? SaveBackups.backup(appID: game.appID, environment: engine.translation.rawValue,
                                                    reason: .automatic, locations: locations, into: directory) {
                made.append("Saves of \(game.name) backed up automatically (\(backup.id), \(backup.files.count) files).")
            }
        }
        return made
    }

    /// True once `current` differs from the latest backup and has stayed the same for `settle` seconds.
    func shouldBackUp(key: String, current: String, latest: String?, now: Date) -> Bool {
        if current.isEmpty || current == latest { pending[key] = nil; return false }
        guard let seen = pending[key], seen.signature == current else { pending[key] = (current, now); return false }
        guard now.timeIntervalSince(seen.since) >= settle else { return false }
        pending[key] = nil
        return true
    }
}
