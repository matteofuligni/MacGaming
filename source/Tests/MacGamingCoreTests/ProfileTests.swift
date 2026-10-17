// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class ProfileTests: XCTestCase {
    private func runtime(version: String = "0.3.0") throws -> RuntimeManifest {
        try JSONDecoder().decode(RuntimeManifest.self, from: Data("""
        {"schemaVersion": 1, "id": "hadron-wine-arm64", "version": "\(version)", "translation": "fex",
         "hostArchitecture": "arm64", "sourceURL": "", "packageSHA256": "", "loader": "", "server": "",
         "loaderSHA256": "", "serverSHA256": "", "environment": {}, "steamArguments": [], "status": ""}
        """.utf8))
    }
    private func entry(_ status: EngineProfile.Status = .experimental, checks: [ProfileCheck] = []) -> EngineProfile {
        EngineProfile(status: status, runtimeID: "hadron-wine-arm64", runtimeVersion: "0.3.0", buildID: "100",
                      renderer: "DXMT", date: "2026-10-14", hardware: nil, launchArguments: nil, dllOverrides: nil, emulateModeset: nil, patches: nil, disabledFiles: nil,
                      checks: checks, limits: ["A known limit"])
    }

    func testCompatibilityFollowsRuntimeAndGameBuild() throws {
        let pending = ProfileCheck(name: "Long session", result: .pending, notes: nil)
        let profile = GameProfile(appID: "1", name: "Game", savePaths: nil, engines: ["fex": entry(checks: [pending])])
        let current = try runtime()

        XCTAssertEqual(Profiles.compatibility(nil, engine: .fex, runtime: current, installedBuild: "100").state, .untested)
        XCTAssertEqual(Profiles.compatibility(profile, engine: .rosetta, runtime: current, installedBuild: "100").state, .untested)
        let same = Profiles.compatibility(profile, engine: .fex, runtime: current, installedBuild: "100")
        XCTAssertEqual(same.state, .experimental)
        XCTAssertEqual(same.pendingChecks, ["Long session"])
        XCTAssertEqual(Profiles.compatibility(profile, engine: .fex, runtime: current, installedBuild: "101").state, .needsRecheck)
        XCTAssertEqual(Profiles.compatibility(profile, engine: .fex, runtime: try runtime(version: "0.4.0"), installedBuild: "100").state, .needsRecheck)
    }

    func testVerifiedNeedsEveryCheckPassed() throws {
        XCTAssertThrowsError(try Profiles.canMark(entry(), as: .verified))
        var sheet = entry(checks: [ProfileCheck(name: "Launch", result: .passed, notes: nil),
                                   ProfileCheck(name: "Long session", result: .pending, notes: nil)])
        XCTAssertThrowsError(try Profiles.canMark(sheet, as: .verified))
        XCTAssertNoThrow(try Profiles.canMark(sheet, as: .experimental))
        Profiles.upsert(ProfileCheck(name: "long session", result: .passed, notes: "45 min"), into: &sheet)
        XCTAssertEqual(sheet.checks.count, 2)
        XCTAssertEqual(sheet.checks[1], ProfileCheck(name: "long session", result: .passed, notes: "45 min"))
        XCTAssertNoThrow(try Profiles.canMark(sheet, as: .verified))
    }

    func testDeclaredSaveFoldersWorkWithoutSteamCloud() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        let saves = prefix.appendingPathComponent("drive_c/users/tester/AppData/Roaming/Studio/Game/Profile1")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("slot".utf8).write(to: saves.appendingPathComponent("slot0.sav"))
        XCTAssertThrowsError(try SaveBackups.locate(appID: "2", prefix: prefix, user: "tester", installDirectory: nil))

        let declared = [GameProfile.SavePath(root: "appDataRoaming", path: "Studio/Game"),
                        GameProfile.SavePath(root: "documents", path: "../../escape")]
        let locations = try SaveBackups.locate(appID: "2", prefix: prefix, user: "tester", installDirectory: nil, declared: declared)
        XCTAssertEqual(locations.warnings.count, 1)
        XCTAssertEqual(SaveBackups.files(in: locations).map(\.path), ["Studio/Game/Profile1/slot0.sav"])
    }

    func testLaunchArgumentsComeFromTheEngineEntry() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: TestWorkspace.root.appendingPathComponent("manifests/storage.json").path,
                                         toPath: root.appendingPathComponent("manifests/storage.json").path)
        let engine = Engine(storage: Storage(root: root), translation: .fex)
        func write(_ arguments: [String]) throws {
            var fex = entry(); fex.launchArguments = arguments
            let profile = GameProfile(appID: "489830", name: "Game", savePaths: nil, engines: ["fex": fex])
            try JSONEncoder().encode(profile).write(to: root.appendingPathComponent("profiles/489830.json"))
        }
        XCTAssertEqual(try engine.launchArguments(appID: "1"), [])
        try write(["-skipintro", "-windowed"])
        XCTAssertEqual(try engine.launchArguments(appID: "489830"), ["-skipintro", "-windowed"])
        try write(["steam://uninstall/489830"])
        XCTAssertThrowsError(try engine.launchArguments(appID: "489830"))
    }

    func testGameFilesAreDisabledReversiblyInsideTheFolder() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/gamefiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("game/movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try Data("mpg".utf8).write(to: movies.appendingPathComponent("Logo.mpg"))
        let game = root.appendingPathComponent("game")
        XCTAssertEqual(try GameFiles.setDisabled("movies\\Logo.mpg", in: game, disabled: true), "movies/Logo.mpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movies.appendingPathComponent("Logo.mpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movies.appendingPathComponent("Logo.mpg.macgaming-disabled").path))
        XCTAssertThrowsError(try GameFiles.setDisabled("movies/Logo.mpg", in: game, disabled: true))
        XCTAssertEqual(try GameFiles.setDisabled("movies/Logo.mpg", in: game, disabled: false), "movies/Logo.mpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movies.appendingPathComponent("Logo.mpg").path))
        XCTAssertThrowsError(try GameFiles.setDisabled("../outside.txt", in: game, disabled: true))
    }
}
