// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import XCTest
@testable import MacGamingCore

final class PerformanceOverlayTests: XCTestCase {
    func testOverlayReachesNewProcessesAndKeepsOtherRuntimeSettings() throws {
        let root = TestWorkspace.root.appendingPathComponent("tests/hud-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: TestWorkspace.root.appendingPathComponent("manifests/storage.json").path,
                        toPath: root.appendingPathComponent("manifests/storage.json").path)
        let manifest = """
        {"schemaVersion":1,"id":"test","version":"1","translation":"fex","hostArchitecture":"arm64",
         "sourceURL":"","packageSHA256":"","loader":"runtime/bin/wine","server":"runtime/bin/wineserver",
         "loaderSHA256":"","serverSHA256":"","environment":{"VK_DRIVER_FILES":"${ROOT}/driver.json","FEX_DISKCACHE":"1"},
         "steamArguments":["-no-cef-sandbox"],"webHelperWrapper":false,"status":"test"}
        """
        try manifest.write(to: root.appendingPathComponent("manifests/runtime-fex.json"), atomically: true, encoding: .utf8)
        let rosetta = Data("other environment untouched".utf8)
        try rosetta.write(to: root.appendingPathComponent("manifests/runtime-rosetta.json"))
        let storage = Storage(root: root)
        let engine = Engine(storage: storage)
        XCTAssertFalse(try engine.performanceOverlayEnabled())
        _ = try engine.setPerformanceOverlay(enabled: true)
        XCTAssertTrue(try engine.performanceOverlayEnabled())
        var runtime = try Runtime(translation: .fex, storage: storage)
        let env = try runtime.environment(prefix: engine.prefix())
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["FEX_DISKCACHE"], "1")
        XCTAssertEqual(env["VK_DRIVER_FILES"], root.path + "/driver.json")
        XCTAssertEqual(runtime.manifest.steamArguments, ["-no-cef-sandbox"])
        XCTAssertEqual(runtime.manifest.webHelperWrapper, false)
        // Enabling the overlay does not also enable extra diagnostic work or modify another engine.
        XCTAssertNil(env["MTL_HUD_LOG_ENABLED"])
        XCTAssertNil(env["MTL_HUD_ENCODER_TIMING_ENABLED"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifests/runtime-rosetta.json")), rosetta)
        _ = try engine.setPerformanceOverlay(enabled: false)
        runtime = try Runtime(translation: .fex, storage: storage)
        XCTAssertFalse(try engine.performanceOverlayEnabled())
        XCTAssertEqual(try runtime.environment(prefix: engine.prefix())["MTL_HUD_ENABLED"], "0")
    }
}
