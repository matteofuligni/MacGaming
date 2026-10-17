// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// DXMT in a prefix: the installed version and the games whose executables load it.
public struct DXMTState: Codable {
    public var schemaVersion = 1
    public var version: String
    public var games: [String: [String]]     // AppID → executables with overrides
    public var updatedAt: Date
}

extension Engine {
    var dxmtStateRelative: String { prefixRelative + "/macgaming-dxmt.json" }
    static let dxmtLoadOrder = "native,builtin"

    public func dxmtState() throws -> DXMTState? {
        let url = try storage.path(dxmtStateRelative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DXMTState.self, from: Data(contentsOf: url))
    }

    private func dxmtComponent(_ runtime: Runtime) throws -> Component {
        guard translation == .rosetta else { throw Failure("DXMT installs only in the Intel/Rosetta environment (--rosetta): Hadron (FEX) already includes its own.") }
        guard runtime.manifest.components?.contains("dxmt") == true else {
            throw Failure("Runtime \(runtime.manifest.id) \(runtime.manifest.version) does not provide for DXMT.")
        }
        return try Component(id: "dxmt", runtime: runtime.manifest, storage: storage)
    }

    /// Unpacks the pinned DXMT release, puts its DLLs into the prefix as native DLLs and checks with Wine's
    /// loader that a program with the game overrides really gets them. Steam keeps Wine's own DLLs.
    public func installDXMT() throws -> String {
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let component = try dxmtComponent(runtime)
        let prefix = try prefix()
        guard let current = try state(), ["ready", "steam-installed"].contains(current.phase),
              current.runtimeID == runtime.manifest.id, current.runtimeVersion == runtime.manifest.version else {
            throw Failure("Prepare the environment before installing DXMT.")
        }
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        if !component.isUnpacked || (try? component.verifyUnpacked()) == nil { try component.unpack() }
        for dll in component.manifest.prefixDLLs { try installPrefixDLL(dll, component: component) }
        let probe = try probeDXMTLoading(runtime: runtime, component: component, prefix: prefix)
        let bridge = try DXMTSupport.metalBridge(runtime: runtime, component: component.manifest)
        var state = try dxmtState() ?? DXMTState(version: component.manifest.version, games: [:], updatedAt: Date())
        state.version = component.manifest.version; state.updatedAt = Date()
        try storage.write(state, to: dxmtStateRelative)
        var lines = ["DXMT \(component.manifest.version) installed in the \(translation.name) environment: files verified with SHA-256.",
                     "Loading verified with the Wine loader: \(probe).",
                     "Metal bridge: \(bridge.detail)",
                     "Overrides apply to games only (macgaming dxmt-enable APPID --rosetta): Steam keeps using Wine's DLLs."]
        switch SessionProbe.status(prefix: prefix).phase {
        case .stopped, .environmentRunning: break
        default: lines.append("Steam is open: close it (macgaming stop --rosetta) and reopen it so games get WINEDLLPATH.")
        }
        return lines.joined(separator: "\n")
    }

    /// One DXMT DLL in system32/syswow64 (see ComponentManifest.PrefixDLL); Wine's copy is saved once in backups/.
    private func installPrefixDLL(_ dll: ComponentManifest.PrefixDLL, component: Component) throws {
        let fm = FileManager.default
        let destination = try storage.path(prefixRelative + "/" + dll.destination)
        if fm.fileExists(atPath: destination.path), try Runner.sha256(destination) == dll.sha256 { return }
        guard let machine = WinePE.Machine(rawValue: dll.machine) else { throw Failure("Architettura sconosciuta: \(dll.machine)") }
        let original = try Data(contentsOf: component.file(dll.source))
        let copy = dll.kind == "native" ? try WinePE.nativeCopy(of: original, machine: machine) : original
        guard Runner.sha256(copy) == dll.sha256 else { throw Failure("Copy of \(dll.source) differs from the manifest.") }
        let backup = try storage.path("backups/dxmt/\(prefix().lastPathComponent)/\(dll.destination)")
        if fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: backup.path) {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: destination, to: backup)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copy.write(to: destination, options: .atomic)
        guard try Runner.sha256(destination) == dll.sha256 else { throw Failure("Write of \(dll.destination) could not be verified.") }
    }

    /// regsvr32 loads d3d11.dll (it has no DllRegisterServer: only the loading matters) with the game overrides
    /// set for that process alone. Wine's +loaddll trace tells which copy of each DLL was used, dyld's list that
    /// winemetal.so came from the component and found Wine's own ntdll.so/winemac.so instead of loading copies.
    private func probeDXMTLoading(runtime: Runtime, component: Component, prefix: URL) throws -> String {
        let base = runtime.manifest.environment["WINEDLLOVERRIDES"].map { $0 + ";" } ?? ""
        let overrides = component.manifest.gameOverrides.joined(separator: ",") + "=n,b"
        let machines = Set(component.manifest.prefixDLLs.map(\.machine))
        var checked: [String] = []
        for (machine, folder, label) in [("x86_64", "system32", "64 bit"), ("i386", "syswow64", "32 bit")] where machines.contains(machine) {
            let logName = "dxmt-probe-\(translation.rawValue)-\(machine)"
            _ = try runtime.run(["C:\\windows\\\(folder)\\regsvr32.exe", "/s", "d3d11.dll"], prefix: prefix, logName: logName, timeout: 120,
                                overrides: ["WINEDLLOVERRIDES": base + overrides, "WINEDEBUG": "fixme-all,+loaddll", "DYLD_PRINT_LIBRARIES": "1"])
            let log = try storage.path("logs/\(logName).log")
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let loaded = DXMTSupport.loadedModules(in: text)
            guard loaded["d3d11.dll"] == "native", loaded["winemetal.dll"] == "builtin" else {
                throw Failure("DXMT \(label) not loaded as expected (d3d11: \(loaded["d3d11.dll"] ?? "missing"), winemetal: \(loaded["winemetal.dll"] ?? "missing")). Log: \(log.path)")
            }
            if let wrong = component.manifest.gameOverrides.first(where: { loaded[$0 + ".dll"].map { $0 != "native" } ?? false }) {
                throw Failure("\(wrong).dll \(label) loaded from Wine instead of DXMT. Log: \(log.path)")
            }
            let unixSide = try storage.path(component.manifest.dllPath).path + "/x86_64-unix/winemetal.so"
            let componentRoot = try component.installRoot().path + "/"
            let fromComponent = Set(DXMTSupport.loadedImages(in: text).filter { $0.hasPrefix(componentRoot) })
            guard fromComponent == [unixSide] else {
                throw Failure("DXMT Unix side \(label) not loaded as expected (\(fromComponent.sorted().joined(separator: ", "))). Log: \(log.path)")
            }
            checked.append(label)
        }
        // Without the overrides (Steam and every other program) Wine's own d3d11 must still win.
        let logName = "dxmt-probe-\(translation.rawValue)-default"
        _ = try runtime.run(["C:\\windows\\system32\\regsvr32.exe", "/s", "d3d11.dll"], prefix: prefix, logName: logName, timeout: 120,
                            overrides: ["WINEDEBUG": "fixme-all,+loaddll"])
        let log = try storage.path("logs/\(logName).log")
        let loaded = DXMTSupport.loadedModules(in: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        guard loaded["d3d11.dll"] == "builtin", loaded["winemetal.dll"] == nil else {
            throw Failure("Without overrides d3d11.dll is not Wine's: Steam would load DXMT. Log: \(log.path)")
        }
        return "DXMT's native d3d11 and builtin winemetal (\(checked.joined(separator: " and "))) with the overrides; Wine's d3d11 without"
    }

    /// Sets (or removes) the DXMT overrides for the executables of an installed game.
    public func setDXMT(appID: String, enabled: Bool) throws -> String {
        guard !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(appID) != nil else { throw Failure("Invalid Steam AppID.") }
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let component = try dxmtComponent(runtime)
        let prefix = try prefix()
        guard var state = try dxmtState() else { throw Failure("Install DXMT first with macgaming install-dxmt --rosetta.") }
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        let previous = state.games[appID] ?? []
        var executables: [String] = []
        if enabled {
            let bridge = try DXMTSupport.metalBridge(runtime: runtime, component: component.manifest)
            guard bridge.available else { throw Failure("\(bridge.detail)\nOverride not applied: the game stays on Wine's Direct3D DLLs.") }
            guard let game = try library().games.first(where: { $0.appID == appID }) else {
                throw Failure("AppID \(appID) is not installed in this environment.")
            }
            executables = GameExecutables.find(in: game.installDirectory)
            guard !executables.isEmpty else { throw Failure("No executables found in \(game.installDirectory.path).") }
            try applyOverrides(executables, dlls: component.manifest.gameOverrides, enabled: true, runtime: runtime, prefix: prefix)
        } else if previous.isEmpty {
            return "DXMT was not enabled for AppID \(appID)."
        }
        // Executables the game no longer has (or all of them, when disabling) lose their overrides.
        try applyOverrides(previous.filter { !executables.contains($0) }, dlls: component.manifest.gameOverrides,
                           enabled: false, runtime: runtime, prefix: prefix)
        state.games[appID] = enabled ? executables : nil
        state.updatedAt = Date()
        try storage.write(state, to: dxmtStateRelative)
        return enabled ? "DXMT enabled for AppID \(appID): \(executables.joined(separator: ", "))."
                       : "DXMT disabled for AppID \(appID): the game goes back to Wine's Direct3D DLLs."
    }

    /// Imports a .reg document into the prefix's registry with Wine's reg.exe.
    func importRegistry(_ document: String, runtime: Runtime, prefix: URL, logName: String) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path)) == "/" else {
            throw Failure("The prefix's Z: drive does not point to the Mac's root: cannot import registry settings.")
        }
        let file = try storage.path("tmp/registry-\(UUID().uuidString).reg")
        try WineRegistry.encoded(document).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try checked(runtime.run(["reg", "import", "Z:" + file.path.replacingOccurrences(of: "/", with: "\\")], prefix: prefix,
                                    logName: logName, timeout: 120), operation: "Writing registry settings")
    }
    func applyOverrides(_ executables: [String], dlls: [String], enabled: Bool, runtime: Runtime, prefix: URL) throws {
        guard !executables.isEmpty else { return }
        let document = try WineRegistry.overridesDocument(executables: executables, dlls: dlls, value: enabled ? Engine.dxmtLoadOrder : nil)
        try importRegistry(document, runtime: runtime, prefix: prefix, logName: "dxmt-overrides-\(translation.rawValue)")
        for exe in executables {
            let result = try runtime.run(["reg", "query", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides"], prefix: prefix,
                                         logName: "dxmt-overrides-check-\(translation.rawValue)", timeout: 60)
            let values = WineRegistry.stringValues(inQueryOutput: result.text)
            if let dll = dlls.first(where: { (values[$0] == Engine.dxmtLoadOrder) != enabled }) {
                throw Failure("Override \(dll) for \(exe) not verified in the registry. Log: \(try storage.path("logs/dxmt-overrides-check-\(translation.rawValue).log").path)")
            }
        }
    }

    /// For doctor: release files, prefix DLLs, games and whether this Wine lets DXMT draw.
    public func dxmtSummary() throws -> String? {
        guard translation == .rosetta else { return nil }
        let runtime = try Runtime(translation: translation, storage: storage)
        guard runtime.manifest.components?.contains("dxmt") == true else { return nil }
        let component = try Component(id: "dxmt", runtime: runtime.manifest, storage: storage)
        let bridge = try DXMTSupport.metalBridge(runtime: runtime, component: component.manifest)
        var parts: [String] = []
        if !component.isUnpacked { parts.append("release not extracted") }
        else { do { try component.verifyUnpacked(); parts.append("files verified") } catch { parts.append(error.localizedDescription) } }
        if let state = try dxmtState() {
            let changed = try component.manifest.prefixDLLs.filter {
                let url = try storage.path(prefixRelative + "/" + $0.destination)
                return try !FileManager.default.fileExists(atPath: url.path) || Runner.sha256(url) != $0.sha256
            }
            parts.append(changed.isEmpty ? "prefix DLLs verified" : "\(changed.count) prefix DLLs modified (run install-dxmt again)")
            parts.append(state.games.isEmpty ? "no games enabled" : "games: " + state.games.keys.sorted().joined(separator: ", "))
        } else {
            parts.append("not installed in the prefix")
        }
        return "DXMT \(component.manifest.version): " + parts.joined(separator: " · ")
            + "\nMetal bridge for DXMT: \(bridge.available ? "available" : "missing") — \(bridge.detail)"
    }
}
