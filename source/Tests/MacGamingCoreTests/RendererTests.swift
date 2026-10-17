// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class RendererTests: XCTestCase {
    func testRendererFilesAreInstalledVerifiedAndIdempotent() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/renderer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: TestWorkspace.root.appendingPathComponent("manifests/storage.json").path,
                        toPath: root.appendingPathComponent("manifests/storage.json").path)
        try """
        {"schemaVersion": 1, "id": "test", "version": "1", "translation": "fex", "hostArchitecture": "arm64",
         "sourceURL": "", "packageSHA256": "", "loader": "runtimes/test/dist/bin/wine", "server": "runtimes/test/dist/bin/wineserver",
         "loaderSHA256": "", "serverSHA256": "", "environment": {}, "steamArguments": [], "status": ""}
        """.write(to: root.appendingPathComponent("manifests/runtime-fex.json"), atomically: true, encoding: .utf8)
        let dist = root.appendingPathComponent("runtimes/test/dist")
        for (path, text) in [("vkd3d-proton/x64/d3d12.dll", "d3d12"), ("vkd3d-proton/x64/d3d12core.dll", "core"), ("dxvk/x64/dxgi.dll", "dxvk")] {
            try fm.createDirectory(at: dist.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dist.appendingPathComponent(path))
        }
        let system32 = root.appendingPathComponent("prefixes/steam-fex/drive_c/windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        let storage = Storage(root: root)
        let engine = Engine(storage: storage, translation: .fex)
        let runtime = try Runtime(translation: .fex, storage: storage)

        XCTAssertEqual(try engine.install(.vkd3d, runtime: runtime), 3)
        XCTAssertEqual(try String(contentsOf: system32.appendingPathComponent("dxgi_dxvk.dll"), encoding: .utf8), "dxvk")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("prefixes/steam-fex/shadercache").path))
        XCTAssertEqual(try engine.install(.vkd3d, runtime: runtime), 0)
        try Data("changed".utf8).write(to: system32.appendingPathComponent("d3d12.dll"))
        XCTAssertEqual(try engine.install(.vkd3d, runtime: runtime), 1)
        XCTAssertEqual(try String(contentsOf: system32.appendingPathComponent("d3d12.dll"), encoding: .utf8), "d3d12")
        // mtld3d's files are not in this fake runtime: nothing is copied and the error says why.
        XCTAssertThrowsError(try engine.install(.mtld3d, runtime: runtime))
        XCTAssertEqual(HadronRenderer.vkd3d.overriddenDLLs, ["d3d12", "d3d12core"])
    }
}
