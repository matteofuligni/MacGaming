// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import Darwin

public struct Failure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// FEX comes first: it is the default and the only environment that draws Direct3D 11 games today.
public enum CPUTranslation: String, Codable, CaseIterable {
    case fex, rosetta
    /// Short name, for sentences such as "nell'ambiente …".
    public var name: String { self == .fex ? "ARM64 + FEX" : "Intel + Rosetta" }
    /// Engine choice as shown in the app and in `doctor`, with what has been verified on it.
    public var label: String {
        self == .fex ? "ARM64 + FEX · Hadron · Direct3D 11 via DXMT" : "Intel + Rosetta · no Direct3D 11 games"
    }
}

public struct StorageIdentity: Codable {
    public var schemaVersion: Int
    public var volumeUUID: String
    public var mountPoint: String
    public var relativeRoot: String?
}

public struct Storage {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = (root ?? Self.discover()).standardizedFileURL
    }

    /// Discovery is read-only. An absent disk never causes an internal fallback to be created.
    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         executable: URL? = Bundle.main.executableURL,
                         volumes: [URL]? = nil, registration: StorageIdentity? = nil) -> URL {
        if let value = environment["MACGAMING_DATA_ROOT"], value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        let fm = FileManager.default
        var bundled = registration
        var ancestor = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let folder = ancestor, folder.path != "/" {
            if bundled == nil {
                bundled = readIdentity(folder.appendingPathComponent("Resources/storage.json"))
            }
            if let identity = readIdentity(folder.appendingPathComponent("manifests/storage.json")),
               bundled == nil || bundled?.volumeUUID.caseInsensitiveCompare(identity.volumeUUID) == .orderedSame {
                return folder
            }
            ancestor = folder.deletingLastPathComponent()
        }
        let mounts = volumes ?? fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        // A standalone app must carry a registration made by its own user. Do not search
        // for a developer's checkout layout or guess a data directory on other volumes.
        guard let bundled, let relative = bundled.relativeRoot, Self.safeRelativeRoot(relative) else {
            return URL(fileURLWithPath: "/Volumes/.macgaming-unavailable")
        }
        let candidates = mounts.compactMap { mount -> URL? in
            if (try? mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)?.uppercased() != bundled.volumeUUID.uppercased() { return nil }
            let candidate = mount.appendingPathComponent(relative)
            guard let identity = readIdentity(candidate.appendingPathComponent("manifests/storage.json")),
                  identity.volumeUUID.uppercased() == bundled.volumeUUID.uppercased(),
                  (try? mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)?.uppercased() == identity.volumeUUID.uppercased() else { return nil }
            return candidate
        }
        return candidates.count == 1 ? candidates[0] : URL(fileURLWithPath: "/Volumes/.macgaming-unavailable")
    }

    static func safeRelativeRoot(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.split(separator: "/").contains("..")
    }
    static func readIdentity(_ url: URL) -> StorageIdentity? {
        guard let bytes = try? Data(contentsOf: url), let identity = try? JSONDecoder().decode(StorageIdentity.self, from: bytes), identity.schemaVersion == 1 else { return nil }
        return identity
    }
    /// Registers an existing checkout on an external volume, without depending on diskutil.
    public static func register(root: URL) throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .volumeIsInternalKey])
        guard values.volumeIsInternal == false, let uuid = values.volumeUUIDString, let mount = values.volume,
              root.path.hasPrefix(mount.path + "/") else {
            throw Failure("Registration requires an existing folder on an external volume with a UUID.")
        }
        let marker = root.appendingPathComponent("manifests/storage.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let old = readIdentity(marker), old.volumeUUID.uppercased() == uuid.uppercased() else {
                throw Failure("A different or invalid volume registration already exists. Review storage.json first.")
            }
        }
        let relative = String(root.path.dropFirst(mount.path.count + 1))
        guard safeRelativeRoot(relative) else { throw Failure("Invalid volume-relative data path.") }
        let identity = StorageIdentity(schemaVersion: 1, volumeUUID: uuid, mountPoint: mount.path, relativeRoot: relative)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identity).write(to: marker, options: .atomic)
        return "Registered the existing external volume. No runtime, prefix or game was modified."
    }
    public func validate() throws {
        guard let identity = Self.readIdentity(root.appendingPathComponent("manifests/storage.json")) else {
            throw Failure("Connect the registered MacGaming drive. No data will be created on the internal drive.")
        }
        // The actual mount comes from the filesystem, never from a remembered volume name.
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        guard values.volumeUUIDString?.uppercased() == identity.volumeUUID.uppercased(), let mount = values.volume else {
            throw Failure("The mounted volume is not the registered MacGaming drive. Check the connection.")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().path
        let canonicalMount = mount.resolvingSymlinksInPath().path
        guard canonicalRoot.hasPrefix(canonicalMount == "/" ? "/" : canonicalMount + "/") else {
            throw Failure("The data folder must be on the registered volume.")
        }
    }
    public func path(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw Failure("Path outside the data folder: \(relative)")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().path
        var url = root
        // Resolve each existing ancestor too: Foundation does not always resolve a symlink
        // when the final descendant has not been created yet.
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
            guard url.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot + "/") else {
                throw Failure("Link points outside the data folder: \(relative)")
            }
        }
        return url.standardizedFileURL
    }
    public func freeBytes() throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    public func write<T: Encodable>(_ value: T, to relative: String) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: path(relative), options: .atomic)
    }
}

public final class PrefixLock {
    private let descriptor: Int32
    public init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure("Cannot open the prefix lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw Failure("Another operation is using this environment. Wait for it to finish.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
