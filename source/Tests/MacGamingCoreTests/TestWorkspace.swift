// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
@testable import MacGamingCore

/// Private fixtures created for this test process. No installed runtime, Steam account,
/// local registration or live game profile is used by the unit tests.
enum TestWorkspace {
    static let root: URL = {
        do {
            let fm = FileManager.default
            let base = ProcessInfo.processInfo.environment["MACGAMING_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
                ?? fm.temporaryDirectory
            let root = base.appendingPathComponent("macgaming-tests-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            for name in ["manifests", "profiles"] {
                try fm.copyItem(at: repository.appendingPathComponent("examples/\(name)"),
                                to: root.appendingPathComponent(name))
            }
            try fm.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
            let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
            guard let uuid = values.volumeUUIDString, let volume = values.volume else {
                throw Failure("Test filesystem has no volume identity.")
            }
            let relative = String(root.path.dropFirst(volume.path == "/" ? 1 : volume.path.count + 1))
            let identity = StorageIdentity(schemaVersion: 1, volumeUUID: uuid, mountPoint: volume.path, relativeRoot: relative)
            try JSONEncoder().encode(identity).write(to: root.appendingPathComponent("manifests/storage.json"))
            return root
        } catch {
            fatalError("Cannot create isolated MacGaming test fixtures: \(error)")
        }
    }()
}
