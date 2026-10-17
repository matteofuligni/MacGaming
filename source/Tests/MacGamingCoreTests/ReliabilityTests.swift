// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class ReliabilityTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = TestWorkspace.root.appendingPathComponent("tests/reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestWorkspace.root.appendingPathComponent("manifests/storage.json"),
                                        to: root.appendingPathComponent("manifests/storage.json"))
        return root
    }
    func testVolumeIdentitySurvivesAStaleMountNameAndRejectsAnotherUUID() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("manifests/storage.json")
        var identity = try JSONDecoder().decode(StorageIdentity.self, from: Data(contentsOf: marker))
        identity.mountPoint = "/Volumes/Old disk name that no longer exists"
        try JSONEncoder().encode(identity).write(to: marker)
        XCTAssertNoThrow(try Storage(root: root).validate())
        if try root.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal == false {
            XCTAssertNoThrow(try Storage.register(root: root))
        } else {
            XCTAssertThrowsError(try Storage.register(root: root))
        }
        XCTAssertThrowsError(try Storage.register(root: URL(fileURLWithPath: "/private/tmp")))
        identity.volumeUUID = UUID().uuidString
        try JSONEncoder().encode(identity).write(to: marker)
        XCTAssertThrowsError(try Storage(root: root).validate())
        XCTAssertThrowsError(try Storage.register(root: root))
    }
    func testDiscoveryUsesRegistrationAndRefusesAnAmbiguousOrAbsentDisk() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var identity = try JSONDecoder().decode(StorageIdentity.self, from: Data(contentsOf: root.appendingPathComponent("manifests/storage.json")))
        identity.relativeRoot = root.lastPathComponent
        let parent = root.deletingLastPathComponent()
        XCTAssertEqual(Storage.discover(environment: [:], executable: nil, volumes: [parent], registration: identity).path, root.path)
        XCTAssertEqual(Storage.discover(environment: [:], executable: nil, volumes: [], registration: identity).path, "/Volumes/.macgaming-unavailable")
        XCTAssertEqual(Storage.discover(environment: [:], executable: nil, volumes: [parent, parent], registration: identity).path, "/Volumes/.macgaming-unavailable")
        XCTAssertFalse(Storage.safeRelativeRoot("../../elsewhere"))
        XCTAssertFalse(Storage.safeRelativeRoot("/absolute"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/.macgaming-unavailable"))
    }
    func testDiscoveryDoesNotGuessADeveloperFolderWithoutRegistration() {
        XCTAssertEqual(Storage.discover(environment: [:], executable: nil,
                                       volumes: [TestWorkspace.root]).path, "/Volumes/.macgaming-unavailable")
        let explicit = TestWorkspace.root.appendingPathComponent("explicit-data")
        XCTAssertEqual(Storage.discover(environment: ["MACGAMING_DATA_ROOT": explicit.path],
                                       executable: nil, volumes: []).path, explicit.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: explicit.path))
    }
    func testRestoreSafetyBackupFailureLeavesCurrentSavesUntouched() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saves = root.appendingPathComponent("saves")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let current = saves.appendingPathComponent("slot.sav")
        try Data("current progress".utf8).write(to: current)
        let locations = SaveLocations(bases: [.documents: saves], tracked: [(.documents, "slot.sav")], warnings: [])
        let blocked = root.appendingPathComponent("backups")
        try Data("not a directory".utf8).write(to: blocked)
        XCTAssertThrowsError(try SaveBackups.safetyBackup(appID: "1", environment: "fex", locations: locations, into: blocked))
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "current progress")
        let backup = try XCTUnwrap(SaveBackups.safetyBackup(appID: "1", environment: "fex", locations: locations, into: root.appendingPathComponent("good-backups")))
        XCTAssertEqual(backup.reason, .beforeRestore)
        XCTAssertEqual(backup.files.first?.sha256, try Runner.sha256(current))
        var bad = backup; bad.id = "../outside"
        XCTAssertThrowsError(try SaveBackups.restore(bad, from: root.appendingPathComponent("good-backups"), locations: locations))
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "current progress")
        let empty = SaveLocations(bases: [.documents: saves], tracked: [], warnings: [])
        XCTAssertNil(try SaveBackups.safetyBackup(appID: "1", environment: "fex", locations: empty, into: blocked))
        // A current file absent from Cloud still needs protection if the chosen backup will overwrite it.
        XCTAssertThrowsError(try SaveBackups.safetyBackup(appID: "1", environment: "fex", locations: empty, into: blocked, restoring: backup))
        let protected = try XCTUnwrap(SaveBackups.safetyBackup(appID: "1", environment: "fex", locations: empty,
                                      into: root.appendingPathComponent("good-backups"), restoring: backup))
        XCTAssertEqual(protected.files.first?.sha256, try Runner.sha256(current))
    }
    func testINIChangesAreReversibleAndPreserveOtherSections() throws {
        let before = "; comments\r\n[SystemSettings]\r\nr.Quality=5\r\nr.Cache=0\r\nr.cache=2\r\n[Audio]\r\nr.Cache=9\r\n"
        let edit = ConfigurationFileEdit(root: "appDataLocal", path: "Game/Engine.ini", section: "SystemSettings", values: ["r.Cache": "1"], removeKeys: [])
        let after = try ConfigurationINI.applying(edit, to: before)
        XCTAssertTrue(after.contains("r.Quality=5\r\n"))
        XCTAssertTrue(after.contains("[Audio]\r\nr.Cache=9"))
        XCTAssertEqual(after.components(separatedBy: "r.Cache=1").count, 2)
        XCTAssertFalse(after.contains("r.cache=2"))
        XCTAssertEqual(try ConfigurationINI.applying(edit, to: after), after)
        let remove = ConfigurationFileEdit(root: "appDataLocal", path: "Game/Engine.ini", section: "SystemSettings", values: [:], removeKeys: ["r.Cache"])
        let restored = try ConfigurationINI.applying(remove, to: after)
        XCTAssertFalse(restored.contains("r.Cache=1"))
        XCTAssertTrue(restored.contains("[Audio]\r\nr.Cache=9"))
        var bad = edit; bad.values = ["bad\nkey": "1"]
        XCTAssertThrowsError(try ConfigurationINI.applying(bad, to: before))
    }
    func testConfigurationsKeepIndependentEvidenceAndLegacyProfilesStillDecode() throws {
        let root = TestWorkspace.root
        let original = try Data(contentsOf: root.appendingPathComponent("profiles/414340.json"))
        var profile = try JSONDecoder().decode(GameProfile.self, from: original)
        var dx11 = try XCTUnwrap(profile.selectedEntry(for: .fex))
        dx11.configurationName = "DX11"; dx11.launchArguments = ["-dx11"]
        dx11.checks = [ProfileCheck(name: "Frame pacing", result: .passed, notes: nil)]
        var dx12 = dx11; dx12.configurationName = "DX12"; dx12.launchArguments = ["-dx12"]
        dx12.checks[0].result = .failed
        profile.configurations = ["fex": ["dx11": dx11, "dx12": dx12]]
        profile.selectedConfigurations = ["fex": "dx11"]
        XCTAssertEqual(profile.selectedEntry(for: .fex)?.checks.first?.result, .passed)
        profile.selectedConfigurations?["fex"] = "dx12"
        XCTAssertEqual(profile.selectedEntry(for: .fex)?.checks.first?.result, .failed)
        XCTAssertEqual(profile.choices(for: .fex).first { $0.id == "dx11" }?.profile.checks.first?.result, .passed)
        let roundTrip = try JSONDecoder().decode(GameProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(roundTrip.selectedEntry(for: .fex)?.launchArguments, ["-dx12"])
        profile.configurations = nil; profile.selectedConfigurations = nil; profile.schemaVersion = 1
        let legacy = try JSONDecoder().decode(GameProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(legacy.choices(for: .fex).map(\.id), ["default"])
    }
    func testConfigurationSelectionAndChecksDoNotStartAnyRuntime() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(storage: Storage(root: root))
        let steamapps = try engine.steamExecutable().deletingLastPathComponent().appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps.appendingPathComponent("common/Game"), withIntermediateDirectories: true)
        try "\"AppState\" { \"appid\" \"1\" \"name\" \"Game\" \"installdir\" \"Game\" \"StateFlags\" \"4\" \"buildid\" \"100\" }".write(to: steamapps.appendingPathComponent("appmanifest_1.acf"), atomically: true, encoding: .utf8)
        let fake = """
        {"schemaVersion":1,"id":"fake","version":"1","translation":"fex","hostArchitecture":"arm64",
        "sourceURL":"","packageSHA256":"","loader":"does-not-exist","server":"does-not-exist",
        "loaderSHA256":"","serverSHA256":"","environment":{},"steamArguments":[],"status":""}
        """
        try Data(fake.utf8).write(to: root.appendingPathComponent("manifests/runtime-fex.json"))
        _ = try engine.createConfiguration(appID: "1", renderer: .dxmt)
        _ = try engine.createConfiguration(appID: "1", renderer: .vkd3d)
        _ = try engine.selectConfiguration(appID: "1", configurationID: "vkd3d")
        XCTAssertEqual(try engine.launchArguments(appID: "1"), ["-dx12"])
        _ = try engine.recordCheck(appID: "1", name: "Launch to menu", result: .passed, notes: "Manual observation")
        _ = try engine.selectConfiguration(appID: "1", configurationID: "dxmt")
        XCTAssertEqual(try engine.profile(appID: "1")?.selectedEntry(for: .fex)?.checks.first?.result, .pending)
        _ = try engine.updateConfigurationArguments(appID: "1", arguments: ["-dx11", "-windowed"])
        XCTAssertEqual(try engine.launchArguments(appID: "1"), ["-dx11", "-windowed"])
        XCTAssertThrowsError(try engine.markProfile(appID: "1", status: .verified))
        for check in try XCTUnwrap(engine.profile(appID: "1")?.selectedEntry(for: .fex)).checks {
            _ = try engine.recordCheck(appID: "1", name: check.name, result: .passed, notes: "Synthetic fixture evidence")
        }
        _ = try engine.markProfile(appID: "1", status: .verified)
        let acf = steamapps.appendingPathComponent("appmanifest_1.acf")
        let nextBuild = try String(contentsOf: acf, encoding: .utf8).replacingOccurrences(of: "100", with: "101")
        try nextBuild.write(to: acf, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try engine.markProfile(appID: "1", status: .verified))
        _ = try engine.recordCheck(appID: "1", name: "Launch to menu", result: .passed, notes: "Synthetic new-build fixture")
        let updated = try XCTUnwrap(engine.profile(appID: "1")?.selectedEntry(for: .fex))
        XCTAssertEqual(updated.buildID, "101")
        XCTAssertEqual(updated.checks.filter { $0.result == .passed }.count, 1)
        _ = try engine.updateConfigurationDLL(appID: "1", dll: "dinput8", enabled: true)
        _ = try engine.updateConfigurationDLL(appID: "1", dll: "dinput8", enabled: false)
        XCTAssertTrue(try engine.profile(appID: "1")?.selectedEntry(for: .fex)?.removedDLLOverrides?.contains("dinput8") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/configurations").path))
    }
    func testDiagnosticRedactionAndEvidenceInvalidation() throws {
        // Construct a synthetic identifier rather than embedding a real account in the fixture.
        let fakeSteamID = "7656119" + String(repeating: "0", count: 10)
        let report = "Path /private/data/prefix; access_token=secret password=hunter2 SteamID: \(fakeSteamID)"
        let redacted = DiagnosticRedaction.redact(report, root: "/private/data")
        XCTAssertTrue(redacted.contains("$DATA/prefix"))
        XCTAssertFalse(redacted.contains("secret")); XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains(fakeSteamID))
        let data = try Data(contentsOf: TestWorkspace.root.appendingPathComponent("profiles/489830.json"))
        var entry = try XCTUnwrap(JSONDecoder().decode(GameProfile.self, from: data).selectedEntry(for: .fex))
        entry.status = .verified
        Engine.invalidateEvidence(&entry)
        XCTAssertEqual(entry.status, .experimental)
        XCTAssertTrue(entry.checks.allSatisfy { $0.result == .pending })
    }
}
