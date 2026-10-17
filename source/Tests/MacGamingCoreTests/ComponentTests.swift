// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class ComponentTests: XCTestCase {
    let root = TestWorkspace.root

    /// A minimal 64-bit Mach-O with one LC_SYMTAB: (name, n_type) pairs.
    func machO(cpu: Int32, symbols: [(String, UInt8)]) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        var strings: [UInt8] = [0]
        var table: [UInt8] = []
        for (name, type) in symbols {
            table += le32(UInt32(strings.count)) + [type, 1] + [0, 0] + [UInt8](repeating: 0, count: 8)
            strings += Array(name.utf8) + [0]
        }
        let symoff = 32 + 24, stroff = symoff + table.count
        let header = le32(0xFEED_FACF) + le32(UInt32(bitPattern: cpu)) + le32(3) + le32(6) + le32(1) + le32(24) + le32(0) + le32(0)
        let symtab = le32(2) + le32(24) + le32(UInt32(symoff)) + le32(UInt32(symbols.count)) + le32(UInt32(stroff)) + le32(UInt32(strings.count))
        return header + symtab + table + strings
    }

    func testMachOExportsOnlyDefinedExternalSymbols() throws {
        let image = machO(cpu: MachO.x86_64, symbols: [("_macdrv_functions", 0x0F), ("_hidden", 0x0E), ("_imported", 0x01), ("_stab", 0x24)])
        XCTAssertEqual(try MachO.exportedSymbols(in: Data(image), cpuType: MachO.x86_64), ["_macdrv_functions"])
        XCTAssertThrowsError(try MachO.exportedSymbols(in: Data(image), cpuType: MachO.arm64))
        XCTAssertThrowsError(try MachO.exportedSymbols(in: Data(image.prefix(70)), cpuType: MachO.x86_64))

        // Universal file: the x86_64 slice is found by cpu type.
        func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        let arm = machO(cpu: MachO.arm64, symbols: [("_arm_only", 0x0F)])
        let armOffset = 64, x86Offset = armOffset + arm.count
        var fat = be32(0xCAFE_BABE) + be32(2)
            + be32(UInt32(bitPattern: MachO.arm64)) + be32(0) + be32(UInt32(armOffset)) + be32(UInt32(arm.count)) + be32(0)
            + be32(UInt32(bitPattern: MachO.x86_64)) + be32(3) + be32(UInt32(x86Offset)) + be32(UInt32(image.count)) + be32(0)
        fat += [UInt8](repeating: 0, count: armOffset - fat.count) + arm + image
        XCTAssertEqual(try MachO.exportedSymbols(in: Data(fat), cpuType: MachO.x86_64), ["_macdrv_functions"])
        XCTAssertEqual(try MachO.exportedSymbols(in: Data(fat), cpuType: MachO.arm64), ["_arm_only"])
    }

    func testMetalBridgeNeedsFunctionTable() {
        let required = "_macdrv_functions"
        XCTAssertTrue(DXMTSupport.metalBridge(exports: ["_macdrv_functions"], required: required).available)
        XCTAssertFalse(DXMTSupport.metalBridge(exports: Set(DXMTSupport.fallbackSymbols), required: required).available)
        let none = DXMTSupport.metalBridge(exports: ["___wine_unix_call_funcs"], required: required)
        XCTAssertFalse(none.available)
        XCTAssertTrue(none.detail.contains("does not export"))
    }

    /// The real runtimes on the external disk: Gcenx wine-stable 11.0_1 lacks the table, Hadron's Wine has it.
    func testInstalledRuntimesMetalBridge() throws {
        let gcenx = root.appendingPathComponent("runtimes/wine-stable-11.0_1/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so")
        let hadron = root.appendingPathComponent("runtimes/hadron-0.3.0/Hadron.app/Contents/SharedSupport/runtime/dist/lib/wine/aarch64-unix/winemac.so")
        guard FileManager.default.fileExists(atPath: gcenx.path), FileManager.default.fileExists(atPath: hadron.path) else {
            throw XCTSkip("Runtimes not present on the external drive.")
        }
        let stable = try MachO.exportedSymbols(in: Data(contentsOf: gcenx), cpuType: MachO.x86_64)
        XCTAssertTrue(stable.contains("___wine_unix_call_funcs"))
        XCTAssertFalse(stable.contains("_macdrv_functions"))
        XCTAssertTrue(try MachO.exportedSymbols(in: Data(contentsOf: hadron), cpuType: MachO.arm64).contains("_macdrv_functions"))
    }

    func pe(machine: UInt16, builtin: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0] = 0x4D; bytes[1] = 0x5A; bytes[0x3C] = 0x80
        if builtin { bytes.replaceSubrange(0x40..<0x51, with: Array("Wine builtin DLL".utf8) + [0]) }
        bytes.replaceSubrange(0x80..<0x86, with: [0x50, 0x45, 0, 0, UInt8(machine & 0xFF), UInt8(machine >> 8)])
        bytes[0xF0] = 0xAB
        return Data(bytes)
    }

    func testNativeCopyClearsOnlyTheBuiltinMarker() throws {
        let builtin = pe(machine: 0x8664, builtin: true)
        XCTAssertTrue(WinePE.isWineBuiltin(builtin))
        let native = try WinePE.nativeCopy(of: builtin, machine: .x86_64)
        XCTAssertFalse(WinePE.isWineBuiltin(native))
        XCTAssertEqual(native.count, builtin.count)
        XCTAssertEqual(native, pe(machine: 0x8664, builtin: false))
        XCTAssertEqual(try WinePE.nativeCopy(of: native, machine: .x86_64), native)
        XCTAssertThrowsError(try WinePE.nativeCopy(of: builtin, machine: .i386))
        XCTAssertThrowsError(try WinePE.nativeCopy(of: Data("not a dll".utf8), machine: .x86_64))
    }

    func testOverridesDocumentSetsAndDeletesValues() throws {
        let set = try WineRegistry.overridesDocument(executables: ["SkyrimSE.exe"], dlls: ["d3d11", "dxgi"], value: "native,builtin")
        XCTAssertEqual(set, """
        Windows Registry Editor Version 5.00\r
        \r
        [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\SkyrimSE.exe\\DllOverrides]\r
        "d3d11"="native,builtin"\r
        "dxgi"="native,builtin"\r

        """)
        let remove = try WineRegistry.overridesDocument(executables: ["DarkSoulsRemastered.exe"], dlls: ["d3d11"], value: nil)
        XCTAssertTrue(remove.contains("\"d3d11\"=-"))
        XCTAssertThrowsError(try WineRegistry.overridesDocument(executables: ["evil]\r\n[HKEY_LOCAL_MACHINE.exe"], dlls: ["d3d11"], value: nil))
        XCTAssertThrowsError(try WineRegistry.overridesDocument(executables: ["..\\steam.exe"], dlls: ["d3d11"], value: nil))
        XCTAssertThrowsError(try WineRegistry.overridesDocument(executables: ["steamwebhelper.dll"], dlls: ["d3d11"], value: nil))
        XCTAssertEqual([UInt8](WineRegistry.encoded("Wi")), [0xFF, 0xFE, 0x57, 0, 0x69, 0])
    }

    func testRegQueryOutputParsing() {
        let output = """

        HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\SkyrimSE.exe\\DllOverrides
            d3d11    REG_SZ    native,builtin
            DXGI    REG_SZ    native,builtin
            empty    REG_SZ
            count    REG_DWORD    0x1

        """
        let values = WineRegistry.stringValues(inQueryOutput: output)
        XCTAssertEqual(values["d3d11"], "native,builtin")
        XCTAssertEqual(values["dxgi"], "native,builtin")
        XCTAssertEqual(values["empty"], "")
        XCTAssertNil(values["count"])
        // Hadron's reg.exe ends lines with CRLF.
        let crlf = WineRegistry.stringValues(inQueryOutput: "\r\nHKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\gta-sa.exe\\DllOverrides\r\n    d3d9    REG_SZ    native,builtin\r\n\r\n")
        XCTAssertEqual(crlf["d3d9"], "native,builtin")
    }

    func testAppSettingsDocument() throws {
        let on = try WineRegistry.appSettingsDocument(executables: ["gta-sa.exe"], subkey: "X11 Driver", values: ["EmulateModeset": "y"])
        XCTAssertTrue(on.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\gta-sa.exe\\X11 Driver]\r\n\"EmulateModeset\"=\"y\""))
        let off = try WineRegistry.appSettingsDocument(executables: ["gta-sa.exe"], subkey: "X11 Driver", values: ["EmulateModeset": nil])
        XCTAssertTrue(off.contains("\"EmulateModeset\"=-"))
        XCTAssertThrowsError(try WineRegistry.appSettingsDocument(executables: ["bad]name.exe"], subkey: "X11 Driver", values: [:]))
        XCTAssertThrowsError(try WineRegistry.appSettingsDocument(executables: ["a.exe"], subkey: "X11\\Driver", values: [:]))
        XCTAssertThrowsError(try WineRegistry.appSettingsDocument(executables: ["a.exe"], subkey: "X11 Driver", values: ["a]b": "y"]))
    }

    func testLoaddllTraceParsing() {
        let log = """
        0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\regsvr32.exe" at 0000000140000000: builtin
        0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\winemetal.dll" at 00006FFFF0000000: builtin
        0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\D3D11.dll" at 00006FFFE0000000: native
        0024:err:module:import_dll Library foo.dll (which is needed by L"bar.dll") not found
        """
        let loaded = DXMTSupport.loadedModules(in: log)
        XCTAssertEqual(loaded["d3d11.dll"], "native")
        XCTAssertEqual(loaded["winemetal.dll"], "builtin")
        XCTAssertNil(loaded["foo.dll"])
        XCTAssertEqual(loaded.count, 3)
    }

    func testGameExecutablesSkipInstallersAndDeepFolders() throws {
        let game = root.appendingPathComponent("tests/game-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: game) }
        let fm = FileManager.default
        for folder in ["", "_CommonRedist/DirectX", "Binaries/Win64", "HellbladeGame/Binaries/Win64", "a/b/c/d"] {
            try fm.createDirectory(at: game.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["SkyrimSE.exe", "SkyrimSELauncher.exe", "unins000.exe", "readme.txt", "_CommonRedist/DirectX/DXSETUP.exe",
                     "_CommonRedist/vcredist.exe", "Binaries/Win64/Game-Win64-Shipping.exe",
                     "HellbladeGame/Binaries/Win64/HellbladeGame-Win64-Shipping.exe", "a/b/c/d/deep.exe"] {
            fm.createFile(atPath: game.appendingPathComponent(file).path, contents: Data())
        }
        XCTAssertEqual(GameExecutables.find(in: game), ["Game-Win64-Shipping.exe", "HellbladeGame-Win64-Shipping.exe", "SkyrimSE.exe", "SkyrimSELauncher.exe"])
        XCTAssertEqual(GameExecutables.find(in: game, maxDepth: 3), ["Game-Win64-Shipping.exe", "SkyrimSE.exe", "SkyrimSELauncher.exe"])
    }

    func testComponentManifestValidation() throws {
        func manifest() -> ComponentManifest {
            ComponentManifest(schemaVersion: 1, id: "dxmt", version: "0.80", license: "MIT", sourceURL: "https://example.invalid",
                              archiveURL: "https://example.invalid/a.tar.gz", archive: "downloads/a.tar.gz", archiveSHA256: String(repeating: "a", count: 64),
                              installPath: "runtimes/dxmt-v0.80", dllPath: "runtimes/dxmt-v0.80/v0.80", runtimes: ["wine-stable 11.0_1"],
                              runtimeLibraries: ["v0.80/x86_64-unix/winemac.so": "winemac.so"],
                              files: [.init(path: "v0.80/x86_64-windows/d3d11.dll", sha256: String(repeating: "b", count: 64)),
                                      .init(path: "v0.80/x86_64-windows/winemetal.dll", sha256: String(repeating: "d", count: 64))],
                              prefixDLLs: [.init(source: "v0.80/x86_64-windows/d3d11.dll", destination: "drive_c/windows/system32/d3d11.dll",
                                                 machine: "x86_64", kind: "native", sha256: String(repeating: "c", count: 64)),
                                           .init(source: "v0.80/x86_64-windows/winemetal.dll", destination: "drive_c/windows/system32/winemetal.dll",
                                                 machine: "x86_64", kind: "builtin", sha256: String(repeating: "d", count: 64))],
                              gameOverrides: ["d3d11", "dxgi", "d3d10core"], metalBridgeExport: "_macdrv_functions", status: "")
        }
        XCTAssertNoThrow(try manifest().validate())
        var bad = manifest(); bad.files[0].path = "../escape.dll"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.archive = "/tmp/a.tar.gz"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.archiveSHA256 = "ABC"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.prefixDLLs[0].destination = "drive_c/windows/syswow64/d3d11.dll"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.prefixDLLs[0].destination = "drive_c/users/steamuser/d3d11.dll"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.prefixDLLs[0].source = "v0.80/x86_64-windows/dxgi.dll"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.dllPath = "runtimes/other"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.gameOverrides = ["d3d11=b"]; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.schemaVersion = 2; XCTAssertThrowsError(try bad.validate())
        // A builtin copy must be the archive file itself, a native copy must differ from it.
        bad = manifest(); bad.prefixDLLs[1].sha256 = String(repeating: "e", count: 64); XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.prefixDLLs[0].sha256 = String(repeating: "b", count: 64); XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.prefixDLLs[0].kind = "patched"; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.runtimeLibraries = ["v0.80/x86_64-unix/winemac.so": "../../etc/passwd"]; XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.runtimeLibraries = ["other/winemac.so": "winemac.so"]; XCTAssertThrowsError(try bad.validate())
    }

    /// The pinned manifest shipped on the external disk must stay valid and match the Rosetta runtime.
    func testShippedDXMTManifest() throws {
        let storage = Storage(root: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifests/component-dxmt.json").path) else {
            throw XCTSkip("DXMT manifest not present.")
        }
        let manifest = try ComponentManifest.load("dxmt", storage: storage)
        XCTAssertEqual(manifest.archiveURL, "https://github.com/3Shain/dxmt/releases/download/v\(manifest.version)/dxmt-v\(manifest.version)-builtin.tar.gz")
        XCTAssertEqual(Set(manifest.prefixDLLs.map(\.machine)), ["x86_64", "i386"])
        XCTAssertEqual(manifest.prefixDLLs.filter { $0.kind == "builtin" }.map(\.destination),
                       ["drive_c/windows/system32/winemetal.dll", "drive_c/windows/syswow64/winemetal.dll"])
        XCTAssertFalse(manifest.files.contains { $0.path.contains("nvapi") || $0.path.contains("nvngx") })
        let runtime = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifests/runtime-rosetta.json")))
        XCTAssertEqual(runtime.components, ["dxmt"])
        let component = try Component(id: "dxmt", runtime: runtime, storage: storage)
        XCTAssertEqual(component.links["v0.80/x86_64-unix/winemac.so"],
                       "../../../../runtimes/wine-stable-11.0_1/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so")
    }

    /// The prefix copies made by WinePE match the digests recorded in the manifest (computed separately).
    func testPrefixCopiesOfUnpackedReleaseMatchManifest() throws {
        let storage = Storage(root: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("runtimes/dxmt-v0.80").path) else {
            throw XCTSkip("DXMT not extracted yet.")
        }
        let manifest = try ComponentManifest.load("dxmt", storage: storage)
        for dll in manifest.prefixDLLs {
            let original = try Data(contentsOf: root.appendingPathComponent(manifest.installPath + "/" + dll.source))
            XCTAssertTrue(WinePE.isWineBuiltin(original), dll.source)
            let copy = dll.kind == "native" ? try WinePE.nativeCopy(of: original, machine: WinePE.Machine(rawValue: dll.machine)!) : original
            XCTAssertEqual(Runner.sha256(copy), dll.sha256, dll.destination)
        }
    }

    func testRuntimeManifestWithoutComponentsStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"id":"x","version":"1","translation":"rosetta","hostArchitecture":"x86_64","sourceURL":"",
         "packageSHA256":"","loader":"a","server":"b","loaderSHA256":"","serverSHA256":"","environment":{},"steamArguments":[],"status":""}
        """
        XCTAssertNil(try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8)).components)
    }

    func testDyldImageListParsing() {
        let log = """
        dyld[51466]: <11111111-1111-1111-1111-111111111111> /Volumes/Fixture/x/lib/wine/x86_64-unix/ntdll.so
        0024:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\d3d11.dll" at 00006FFFE0000000: native
        dyld[51466]: <22222222-2222-2222-2222-222222222222> /Volumes/Fixture/x/runtimes/dxmt-v0.80/v0.80/x86_64-unix/winemetal.so
        """
        XCTAssertEqual(DXMTSupport.loadedImages(in: log), ["/Volumes/Fixture/x/lib/wine/x86_64-unix/ntdll.so",
                                                           "/Volumes/Fixture/x/runtimes/dxmt-v0.80/v0.80/x86_64-unix/winemetal.so"])
    }

    func testComponentLinksMustPointWhereExpected() throws {
        let folder = root.appendingPathComponent("tests/links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("so".utf8).write(to: folder.appendingPathComponent("target.so"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("lib/winemac.so").path, withDestinationPath: "../target.so")
        XCTAssertNoThrow(try Component.verify(directory: folder, files: [.init(path: "target.so", sha256: Runner.sha256(Data("so".utf8)))],
                                              links: ["lib/winemac.so": "../target.so"]))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: [.init(path: "target.so", sha256: Runner.sha256(Data("so".utf8)))],
                                                  links: ["lib/winemac.so": "/etc/target.so"]))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: [.init(path: "target.so", sha256: Runner.sha256(Data("so".utf8)))]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("target.so"))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: [], links: ["lib/winemac.so": "../target.so"]))
    }

    func testComponentVerificationRejectsExtraOrChangedFiles() throws {
        let folder = root.appendingPathComponent("tests/component-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("x86_64-unix"), withIntermediateDirectories: true)
        let content = Data("winemetal".utf8)
        try content.write(to: folder.appendingPathComponent("x86_64-unix/winemetal.so"))
        let files = [ComponentManifest.File(path: "x86_64-unix/winemetal.so", sha256: Runner.sha256(content))]
        XCTAssertNoThrow(try Component.verify(directory: folder, files: files))
        try Data().write(to: folder.appendingPathComponent("nvapi64.dll"))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: files))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("nvapi64.dll"))
        try Data("changed".utf8).write(to: folder.appendingPathComponent("x86_64-unix/winemetal.so"))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: files))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("x86_64-unix/winemetal.so"))
        XCTAssertThrowsError(try Component.verify(directory: folder, files: files))
    }
}
