// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class ConfigurationTransactionTests: XCTestCase {
    private func fixture() throws -> (URL, Engine, URL, Data) {
        let fm = FileManager.default
        let root = TestWorkspace.root.appendingPathComponent("tests/configuration-transaction-\(UUID().uuidString)")
        for path in ["manifests", "logs", "tmp", "runtime", "prefixes/steam-fex/dosdevices", "profiles"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: TestWorkspace.root.appendingPathComponent("manifests/storage.json"), to: root.appendingPathComponent("manifests/storage.json"))
        let engine = Engine(storage: Storage(root: root))
        let prefix = try engine.prefix()
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        let stub = root.appendingPathComponent("runtime/fake-wine")
        // This POSIX stub simulates registry responses; no Windows binary is run.
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$WINEPREFIX/fake-calls"
        if [ "$2" = "import" ]; then
          if [ -f "$WINEPREFIX/applied" ]; then /bin/rm "$WINEPREFIX/applied"; else : > "$WINEPREFIX/applied"; fi
          exit 0
        fi
        if [ "$2" = "query" ]; then
          if [ -f "$WINEPREFIX/fail-verification" ] && [ -f "$WINEPREFIX/applied" ]; then
            printf '    d3d12    REG_SZ    native,builtin\\n'
            exit 0
          fi
          exit 1
        fi
        exit 99
        """
        try Data(script.utf8).write(to: stub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let digest = try Runner.sha256(stub)
        let manifest: [String: Any] = ["schemaVersion": 1, "id": "fake", "version": "1", "translation": "fex", "hostArchitecture": "arm64",
            "sourceURL": "", "packageSHA256": "", "loader": "runtime/fake-wine", "server": "runtime/fake-wine",
            "loaderSHA256": digest, "serverSHA256": digest, "environment": [:], "steamArguments": [], "status": "test-only stub"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifests/runtime-fex.json"))
        let steamapps = try engine.steamExecutable().deletingLastPathComponent().appendingPathComponent("steamapps")
        try fm.createDirectory(at: steamapps.appendingPathComponent("common/Game"), withIntermediateDirectories: true)
        try Data("placeholder, never executed".utf8).write(to: steamapps.appendingPathComponent("common/Game/Game.exe"))
        try "\"AppState\" { \"appid\" \"1\" \"name\" \"Game\" \"installdir\" \"Game\" \"StateFlags\" \"4\" \"buildid\" \"100\" }".write(to: steamapps.appendingPathComponent("appmanifest_1.acf"), atomically: true, encoding: .utf8)
        _ = try engine.createConfiguration(appID: "1", renderer: .dxmt)
        let target = prefix.appendingPathComponent("drive_c/users/\(NSUserName())/AppData/Local/Game/Engine.ini")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("[SystemSettings]\nr.Cache=0\nr.Quality=5\n".utf8)
        try original.write(to: target)
        _ = try engine.editProfile(appID: "1") {
            $0.configFileEdits = [ConfigurationFileEdit(root: "appDataLocal", path: "Game/Engine.ini", section: "SystemSettings", values: ["r.Cache": "1"], removeKeys: [])]
        }
        return (root, engine, target, original)
    }
    func testExplicitApplicationStagesBackupsAndOnlyRunsRegistryCommands() throws {
        let (root, engine, target, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try engine.applySelectedConfiguration(appID: "1")
        let after = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(after.contains("r.Cache=1")); XCTAssertTrue(after.contains("r.Quality=5"))
        let directory = root.appendingPathComponent("backups/configurations/fex/1/current")
        let journal = try JSONDecoder().decode(ConfigurationJournal.self, from: Data(contentsOf: directory.appendingPathComponent("journal.json")))
        XCTAssertEqual(journal.phase, "applied")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("0.before")), original)
        let calls = try String(contentsOf: engine.prefix().appendingPathComponent("fake-calls"), encoding: .utf8)
        XCTAssertTrue(calls.split(separator: "\n").allSatisfy { $0.hasPrefix("reg ") })
        XCTAssertFalse(calls.contains("steam.exe")); XCTAssertFalse(calls.contains("-applaunch"))
    }
    func testFailedVerificationRestoresINIAndKeepsRecoveryEvidence() throws {
        let (root, engine, target, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: engine.prefix().appendingPathComponent("fail-verification"))
        XCTAssertThrowsError(try engine.applySelectedConfiguration(appID: "1"))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let url = root.appendingPathComponent("backups/configurations/fex/1/current/journal.json")
        var journal = try JSONDecoder().decode(ConfigurationJournal.self, from: Data(contentsOf: url))
        XCTAssertEqual(journal.phase, "rolledBack")
        journal.phase = "applying"; try JSONEncoder().encode(journal).write(to: url)
        let callsBefore = try Data(contentsOf: engine.prefix().appendingPathComponent("fake-calls"))
        XCTAssertThrowsError(try engine.applySelectedConfiguration(appID: "1"))
        XCTAssertEqual(try Data(contentsOf: engine.prefix().appendingPathComponent("fake-calls")), callsBefore)
    }
}
