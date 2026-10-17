// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class CoreTests: XCTestCase {
    func testMissingExternalStorageDoesNotCreateFallback() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try Storage(root: root).validate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testFEXIsTheDefaultEnvironment() throws {
        XCTAssertEqual(Engine().translation, .fex)
        XCTAssertEqual(CPUTranslation.allCases, [.fex, .rosetta])
    }
    func testRejectsTraversalAndSymlinkEscape() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(root: root)
        XCTAssertThrowsError(try storage.path("../outside"))
        XCTAssertThrowsError(try storage.path("/etc/passwd"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try storage.path("escape/file"))
        XCTAssertEqual(try storage.path("prefixes/steam").path, root.path + "/prefixes/steam")
    }
    func testConcurrentPrefixOperationFailsAndReleasesLock() throws {
        let url = TestWorkspace.root.appendingPathComponent("tests/lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        var first: PrefixLock? = try PrefixLock(url: url)
        XCTAssertThrowsError(try PrefixLock(url: url))
        first = nil
        let second = try PrefixLock(url: url)
        withExtendedLifetime((first, second)) {}
    }
    func testProcessArgumentsStaySeparate() throws {
        let log = TestWorkspace.root.appendingPathComponent("tests/argv.log")
        let dangerous = "spaces ; $(touch /tmp/macgaming-test-must-not-exist)"
        let result = try Runner.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", dangerous], log: log)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.text, dangerous)
    }
    func testTimeoutStopsOnlyOwnedChild() throws {
        let log = TestWorkspace.root.appendingPathComponent("tests/timeout.log")
        XCTAssertThrowsError(try Runner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], log: log, timeout: 0.1))
    }
    func testKeyValuesParsesSteamFormat() throws {
        let text = """
        // comment
        "libraryfolders"
        {
        \t"0" { "path"\t\t"C:\\\\Program Files (x86)\\\\Steam" "label" "" }
        \t"1"
        \t{
        \t\tUnquoted value [$WIN32]
        \t\t"apps" { "489830" "0" }
        \t}
        }
        """
        let (key, root) = try KeyValues.parse(text)
        XCTAssertEqual(key, "libraryfolders")
        XCTAssertEqual(root["0"]?["PATH"]?.string, "C:\\Program Files (x86)\\Steam")
        XCTAssertEqual(root["1"]?["Unquoted"]?.string, "value")
        XCTAssertEqual(root["1"]?["apps"]?["489830"]?.string, "0")
        XCTAssertThrowsError(try KeyValues.parse("\"AppState\" { \"appid\" \"4"))
    }
    func testLibraryScanReadsManifestsAndSkipsBrokenOnes() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefixes/steam-test")
        let steamapps = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try """
        "libraryfolders" { "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" } "1" { "path" "Z:\\\\Users\\\\someone\\\\Games" } }
        """.write(to: steamapps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        func manifest(_ id: String, _ name: String, _ dir: String, _ flags: String) -> String {
            "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"\(flags)\"\n\t\"installdir\"\t\t\"\(dir)\"\n\t\"SizeOnDisk\"\t\t\"16092533099\"\n}\n"
        }
        try manifest("489830", "The Elder Scrolls V: Skyrim Special Edition", "Skyrim Special Edition", "4")
            .write(to: steamapps.appendingPathComponent("appmanifest_489830.acf"), atomically: true, encoding: .utf8)
        try manifest("570940", "DARK SOULS™: REMASTERED", "DARK SOULS REMASTERED", "1026")
            .write(to: steamapps.appendingPathComponent("appmanifest_570940.acf"), atomically: true, encoding: .utf8)
        try manifest("228980", "Steamworks Common Redistributables", "Steamworks Shared", "4")
            .write(to: steamapps.appendingPathComponent("appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try manifest("1", "Escape", "..", "4").write(to: steamapps.appendingPathComponent("appmanifest_1.acf"), atomically: true, encoding: .utf8)
        try "\"AppState\" { \"appid\" \"374".write(to: steamapps.appendingPathComponent("appmanifest_374320.acf"), atomically: true, encoding: .utf8)

        let scan = SteamLibraryScanner.scan(prefix: prefix, storageRoot: root)
        XCTAssertEqual(scan.games.map(\.appID), ["570940", "489830"])
        XCTAssertEqual(scan.games[1].installDirectory.path, steamapps.path + "/common/Skyrim Special Edition")
        XCTAssertTrue(scan.games[1].isReady)
        XCTAssertFalse(scan.games[0].isReady)
        XCTAssertEqual(scan.games[0].status, "Downloading")
        XCTAssertTrue(scan.warnings.contains { $0.contains("outside the external drive") })
        XCTAssertTrue(scan.warnings.contains { $0.contains("appmanifest_374320.acf") })
        XCTAssertTrue(scan.warnings.contains { $0.contains("appmanifest_1.acf") })
    }
    func testRegistryStateIsReadFromSteamSections() throws {
        let text = """
        [Software\\\\Valve\\\\Steam] 1792020361
        #time=1dd5c3360309728
        "RunningAppID"=dword:00077966
        "SteamPath"="c:/program files (x86)/steam"

        [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1792020359
        "ActiveUser"=dword:00000000
        "pid"=dword:000001f0
        """
        let steam = SessionProbe.registryValues(in: text, section: "Software\\\\Valve\\\\Steam")
        let active = SessionProbe.registryValues(in: text, section: "Software\\\\Valve\\\\Steam\\\\ActiveProcess")
        XCTAssertEqual(SessionProbe.dword(steam["RunningAppID"]), 489830)
        XCTAssertNil(steam["pid"])
        XCTAssertEqual(SessionProbe.dword(active["pid"]), 0x1f0)
        XCTAssertEqual(SessionProbe.dword(active["ActiveUser"]), 0)
    }
    func testWebHelperWrapperKeepsValveHelperAcrossUpdates() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/webhelper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: TestWorkspace.root.appendingPathComponent("manifests/storage.json").path,
                        toPath: root.appendingPathComponent("manifests/storage.json").path)
        let wrapper = root.appendingPathComponent("wrapper.exe")
        try Data("wrapper".utf8).write(to: wrapper)
        let manifest = "{\"schemaVersion\": 1, \"path\": \"wrapper.exe\", \"sha256\": \"\(try Runner.sha256(wrapper))\", \"flags\": \"--single-process\"}"
        try manifest.write(to: root.appendingPathComponent("manifests/steamwebhelper-wrapper.json"), atomically: true, encoding: .utf8)
        let steam = root.appendingPathComponent("Steam")
        let cef = steam.appendingPathComponent("bin/cef/cef.win64")
        try fm.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data("valve-1".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        let storage = Storage(root: root)

        XCTAssertEqual(try WebHelperWrapper.install(storage: storage, steamDirectory: steam), 1)
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper.exe")), Data("wrapper".utf8))
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper_real.exe")), Data("valve-1".utf8))
        XCTAssertEqual(try WebHelperWrapper.install(storage: storage, steamDirectory: steam), 0)

        // A Steam update puts a new helper back in place.
        try Data("valve-2".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertEqual(try WebHelperWrapper.install(storage: storage, steamDirectory: steam), 1)
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper_real.exe")), Data("valve-2".utf8))
        XCTAssertFalse(fm.fileExists(atPath: cef.appendingPathComponent("steamwebhelper.macgaming-new").path))

        // A newer wrapper build replaces an older one (recognised by its marker), Valve's helper stays.
        try Data("old build MACGAMING-STEAMWEBHELPER-WRAPPER".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertEqual(try WebHelperWrapper.install(storage: storage, steamDirectory: steam), 1)
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper.exe")), Data("wrapper".utf8))
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper_real.exe")), Data("valve-2".utf8))

        // An environment without the wrapper gets Valve's helper back.
        XCTAssertEqual(try WebHelperWrapper.remove(storage: storage, steamDirectory: steam), 1)
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper.exe")), Data("valve-2".utf8))
        XCTAssertFalse(fm.fileExists(atPath: cef.appendingPathComponent("steamwebhelper_real.exe").path))
        XCTAssertEqual(try WebHelperWrapper.remove(storage: storage, steamDirectory: steam), 0)
        XCTAssertEqual(try WebHelperWrapper.install(storage: storage, steamDirectory: steam), 1)

        try Data("tampered".utf8).write(to: wrapper)
        try Data("valve-3".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertThrowsError(try WebHelperWrapper.install(storage: storage, steamDirectory: steam))
        XCTAssertEqual(try Data(contentsOf: cef.appendingPathComponent("steamwebhelper.exe")), Data("valve-3".utf8))
    }
    func testImageReserveLibraryIsInsertedOnlyWhileVerified() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/image-reserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: TestWorkspace.root.appendingPathComponent("manifests/storage.json").path,
                        toPath: root.appendingPathComponent("manifests/storage.json").path)
        try """
        {"schemaVersion":1,"id":"test","version":"1","translation":"fex","hostArchitecture":"arm64",
         "sourceURL":"","packageSHA256":"","loader":"runtime/bin/wine","server":"runtime/bin/wineserver",
         "loaderSHA256":"","serverSHA256":"","environment":{"DYLD_INSERT_LIBRARIES":"/other.dylib"},
         "steamArguments":[],"imageReserve":true,"status":"test"}
        """.write(to: root.appendingPathComponent("manifests/runtime-fex.json"), atomically: true, encoding: .utf8)
        let storage = Storage(root: root)
        let runtime = try Runtime(translation: .fex, storage: storage)
        let prefix = root.appendingPathComponent("prefixes/steam-fex")
        // dyld would terminate every Wine process, so a missing build is an error, not a silent omission.
        XCTAssertThrowsError(try runtime.environment(prefix: prefix))

        let library = root.appendingPathComponent("build/preload/macgaming-image-reserve.dylib")
        try fm.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("library".utf8).write(to: library)
        let manifest = "{\"schemaVersion\": 1, \"path\": \"build/preload/macgaming-image-reserve.dylib\", \"sha256\": \"\(try Runner.sha256(library))\"}"
        try manifest.write(to: root.appendingPathComponent("manifests/image-reserve.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try runtime.environment(prefix: prefix)["DYLD_INSERT_LIBRARIES"], library.path + ":/other.dylib")

        try Data("tampered".utf8).write(to: library)
        XCTAssertThrowsError(try runtime.environment(prefix: prefix))
    }
    func testGameCopyIsCompleteBeforeSteamSeesIt() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let source = root.appendingPathComponent("a/steamapps"), destination = root.appendingPathComponent("b/steamapps")
        let game = source.appendingPathComponent("common/Skyrim Special Edition")
        try fm.createDirectory(at: game.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("esm".utf8).write(to: game.appendingPathComponent("Data/Skyrim.esm"))
        let manifest = source.appendingPathComponent("appmanifest_489830.acf")
        try Data("\"AppState\" { \"appid\" \"489830\" }".utf8).write(to: manifest)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let installed = InstalledGame(appID: "489830", name: "Skyrim", installDirectory: game, stateFlags: 4, sizeOnDisk: 3, buildID: "1")

        try GameTransfer.copy(installed, manifest: manifest, toSteamApps: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("common/Skyrim Special Edition/Data/Skyrim.esm")), Data("esm".utf8))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("appmanifest_489830.acf").path))
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("common/.Skyrim Special Edition.macgaming-copy").path))
        XCTAssertTrue(fm.fileExists(atPath: game.appendingPathComponent("Data/Skyrim.esm").path))
        XCTAssertThrowsError(try GameTransfer.copy(installed, manifest: manifest, toSteamApps: destination))
    }
    private func makeSavePrefix(_ root: URL) throws -> (prefix: URL, saves: URL, documents: URL) {
        let fm = FileManager.default
        let prefix = root.appendingPathComponent("prefixes/steam-test")
        let cache = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/userdata/12345/489830")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try """
        "489830"
        {
        	"ChangeNumber"		"3"
        	"My Games/Game/Saves/a.ess" { "root" "2" "size" "1" "sha" "x" }
        	"My Games\\\\Game\\\\Saves\\\\b.ess" { "root" "2" }
        	"..\\\\..\\\\escape.ess" { "root" "2" }
        	"weird.dat" { "root" "99" }
        	"loose.txt" { "root" "2" }
        }
        """.write(to: cache.appendingPathComponent("remotecache.vdf"), atomically: true, encoding: .utf8)
        let documents = prefix.appendingPathComponent("drive_c/users/tester/Documents")
        let saves = documents.appendingPathComponent("My Games/Game/Saves")
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        for (name, text) in [("a.ess", "a1"), ("b.ess", "b1"), ("new.ess", "n1")] { try Data(text.utf8).write(to: saves.appendingPathComponent(name)) }
        try Data("loose".utf8).write(to: documents.appendingPathComponent("loose.txt"))
        try Data("not a save".utf8).write(to: documents.appendingPathComponent("other.txt"))
        return (prefix, saves, documents)
    }
    func testSaveBackupRestoresWithoutDroppingNewerSaves() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (prefix, saves, documents) = try makeSavePrefix(root)
        let locations = try SaveBackups.locate(appID: "489830", prefix: prefix, user: "tester", installDirectory: nil)
        XCTAssertEqual(locations.tracked.map(\.path), ["My Games/Game/Saves/a.ess", "My Games/Game/Saves/b.ess", "loose.txt"])
        XCTAssertEqual(locations.warnings.count, 2)

        let backups = root.appendingPathComponent("backups/saves/test/489830")
        let backup = try SaveBackups.backup(appID: "489830", environment: "test", reason: .manual, locations: locations, into: backups)
        XCTAssertEqual(Set(backup.files.map(\.path)), ["My Games/Game/Saves/a.ess", "My Games/Game/Saves/b.ess", "My Games/Game/Saves/new.ess", "loose.txt"])
        XCTAssertEqual(SaveBackups.list(backups).map(\.id), [backup.id])

        try Data("a2".utf8).write(to: saves.appendingPathComponent("a.ess"))
        try FileManager.default.removeItem(at: saves.appendingPathComponent("b.ess"))
        try Data("c1".utf8).write(to: saves.appendingPathComponent("c.ess"))
        XCTAssertEqual(try SaveBackups.restore(backup, from: backups, locations: locations), 4)
        XCTAssertEqual(try String(contentsOf: saves.appendingPathComponent("a.ess"), encoding: .utf8), "a1")
        XCTAssertEqual(try String(contentsOf: saves.appendingPathComponent("b.ess"), encoding: .utf8), "b1")
        XCTAssertEqual(try String(contentsOf: saves.appendingPathComponent("c.ess"), encoding: .utf8), "c1")
        XCTAssertEqual(try String(contentsOf: documents.appendingPathComponent("loose.txt"), encoding: .utf8), "loose")

        // A tampered backup is refused before any file is touched.
        try Data("a2".utf8).write(to: saves.appendingPathComponent("a.ess"))
        try Data("evil".utf8).write(to: backups.appendingPathComponent("\(backup.id)/files/documents/My Games/Game/Saves/b.ess"))
        XCTAssertThrowsError(try SaveBackups.restore(backup, from: backups, locations: locations))
        XCTAssertEqual(try String(contentsOf: saves.appendingPathComponent("a.ess"), encoding: .utf8), "a2")
    }
    func testAutomaticSaveBackupsAreLimited() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (prefix, _, _) = try makeSavePrefix(root)
        let locations = try SaveBackups.locate(appID: "489830", prefix: prefix, user: "tester", installDirectory: nil)
        let backups = root.appendingPathComponent("backups/saves/test/489830")
        let manual = try SaveBackups.backup(appID: "489830", environment: "test", reason: .manual, locations: locations,
                                            into: backups, now: Date(timeIntervalSince1970: 1_000))
        for i in 0..<12 {
            _ = try SaveBackups.backup(appID: "489830", environment: "test", reason: .beforeLaunch, locations: locations,
                                   into: backups, now: Date(timeIntervalSince1970: 2_000 + Double(i) * 60))
        }
        let all = SaveBackups.list(backups)
        XCTAssertEqual(all.filter { $0.reason == .beforeLaunch }.count, SaveBackups.kept[.beforeLaunch])
        XCTAssertTrue(all.contains { $0.id == manual.id })
        XCTAssertEqual(SaveBackups.safeRelative("C:\\Users\\x"), nil)
        XCTAssertEqual(SaveBackups.safeRelative("a\\b.ess"), "a/b.ess")
    }
    func testSaveSignatureAndWatcherWaitForQuietSaves() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (prefix, saves, _) = try makeSavePrefix(root)
        let locations = try SaveBackups.locate(appID: "489830", prefix: prefix, user: "tester", installDirectory: nil)
        let backups = root.appendingPathComponent("backups/saves/test/489830")
        let first = try SaveBackups.backup(appID: "489830", environment: "test", reason: .automatic, locations: locations, into: backups)
        XCTAssertEqual(first.signature, SaveBackups.signature(of: locations))
        try Data("a-new-save".utf8).write(to: saves.appendingPathComponent("a.ess"))
        let changed = SaveBackups.signature(of: locations)
        XCTAssertNotEqual(changed, first.signature)

        let watcher = SaveWatcher(settle: 15)
        let start = Date()
        XCTAssertFalse(watcher.shouldBackUp(key: "k", current: changed, latest: first.signature, now: start))
        XCTAssertFalse(watcher.shouldBackUp(key: "k", current: changed, latest: first.signature, now: start.addingTimeInterval(5)))
        // The game writes again: the quiet period starts over.
        XCTAssertFalse(watcher.shouldBackUp(key: "k", current: changed + "x", latest: first.signature, now: start.addingTimeInterval(10)))
        XCTAssertFalse(watcher.shouldBackUp(key: "k", current: changed + "x", latest: first.signature, now: start.addingTimeInterval(20)))
        XCTAssertTrue(watcher.shouldBackUp(key: "k", current: changed + "x", latest: first.signature, now: start.addingTimeInterval(26)))
        XCTAssertFalse(watcher.shouldBackUp(key: "k", current: changed, latest: changed, now: start.addingTimeInterval(60)))

        // A backup written by the Italian version still reads.
        let legacy = try JSONDecoder().decode(SaveBackup.Reason.self, from: Data("\"manuale\"".utf8))
        XCTAssertEqual(legacy, .manual)
    }
    func testProcessArgumentsAreReadFromTheKernel() throws {
        let own = try XCTUnwrap(SessionProbe.processArguments(getpid()))
        XCTAssertFalse(own.arguments.isEmpty)
        XCTAssertTrue(own.environment.contains { $0.hasPrefix("PATH=") })
        let prefix = TestWorkspace.root.appendingPathComponent("tests/no-steam-\(UUID().uuidString)")
        XCTAssertFalse(SessionProbe.steamRunning(prefix: prefix))
    }
    func testStoppedPrefixHasNoWineserver() throws {
        let prefix = TestWorkspace.root.appendingPathComponent("tests/prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        XCTAssertNil(SessionProbe.wineserverPID(prefix: prefix))
        XCTAssertEqual(SessionProbe.status(prefix: prefix).phase, .stopped)
    }
}
