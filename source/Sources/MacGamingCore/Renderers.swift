// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// Hadron's per-game renderers in the ARM64/FEX environment, set up the way Hadron's scripts do it
/// (scripts/mtld3d-prefix, scripts/play): their DLLs go into the prefix, verified, and a game uses
/// them only through DLL overrides on its own executables. Steam and other programs keep Wine's DLLs.
/// Direct3D 10/11 needs nothing: in Hadron's Wine the system d3d11/dxgi already are DXMT.
public enum HadronRenderer: String, CaseIterable, Sendable {
    /// Direct3D 9 on Metal.
    case mtld3d
    /// Direct3D 12 on Vulkan (KosmicKrisp, Mesa's Vulkan on Metal); DXMT's dxgi hands its swapchains
    /// to DXVK's DXGI, which it loads as dxgi_dxvk.dll.
    case vkd3d

    var overriddenDLLs: [String] { self == .mtld3d ? ["d3d9"] : ["d3d12", "d3d12core"] }
    var description: String {
        self == .mtld3d ? "mtld3d (Hadron) · Direct3D 9 on Metal" : "vkd3d-proton on KosmicKrisp (Hadron) · Direct3D 12 via Vulkan"
    }
    /// (source under the runtime's dist folder, destination in the prefix)
    func files(dist: String) -> [(source: String, destination: String)] {
        switch self {
        case .mtld3d:
            let base = dist + "/lib/hadron/d3d9"
            return [(base + "/i386/d3d9.dll", "drive_c/windows/syswow64/d3d9.dll"),
                    (base + "/aarch64/d3d9.dll", "drive_c/windows/system32/d3d9.dll"),
                    // mtld3d.dll is a builtin with its own name: Wine loads it only with a marker in the prefix.
                    (base + "/markers/syswow64/mtld3d.dll", "drive_c/windows/syswow64/mtld3d.dll"),
                    (base + "/markers/system32/mtld3d.dll", "drive_c/windows/system32/mtld3d.dll")]
        case .vkd3d:
            return [(dist + "/vkd3d-proton/x64/d3d12.dll", "drive_c/windows/system32/d3d12.dll"),
                    (dist + "/vkd3d-proton/x64/d3d12core.dll", "drive_c/windows/system32/d3d12core.dll"),
                    (dist + "/dxvk/x64/dxgi.dll", "drive_c/windows/system32/dxgi_dxvk.dll")]
        }
    }
}

extension Engine {
    /// Lets one game's executables change display mode without touching the Mac's screen: Wine's
    /// EmulateModeset (win32u) offers the classic modes (800x600, 1024x768, …) and keeps the real one.
    /// Old games that look for a mode the Mac does not list need it (GTA San Andreas:
    /// "Cannot find 800x600x32 video mode"). Read per process, so it works for games Steam starts.
    public func setEmulatedModeset(appID: String, enabled: Bool) throws -> String {
        let id = try Self.validated(appID: appID)
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage)
        guard let game = try library().games.first(where: { $0.appID == id }) else {
            throw Failure("AppID \(id) is not installed in the \(translation.name) environment.")
        }
        let executables = GameExecutables.find(in: game.installDirectory)
        guard !executables.isEmpty else { throw Failure("No executables found in \(game.installDirectory.path).") }
        let prefix = try prefix()
        do {
            let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
            let document = try WineRegistry.appSettingsDocument(executables: executables, subkey: "X11 Driver",
                                                                values: ["EmulateModeset": enabled ? "y" : nil])
            try importRegistry(document, runtime: runtime, prefix: prefix, logName: "modeset-\(translation.rawValue)")
            for exe in executables {
                let result = try runtime.run(["reg", "query", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\X11 Driver"], prefix: prefix,
                                             logName: "modeset-check-\(translation.rawValue)", timeout: 60)
                guard (WineRegistry.stringValues(inQueryOutput: result.text)["emulatemodeset"] == "y") == enabled else {
                    throw Failure("EmulateModeset for \(exe) not verified in the registry. Log: \(try storage.path("logs/modeset-check-\(translation.rawValue).log").path)")
                }
            }
        }
        _ = try editProfile(appID: id) { $0.emulateModeset = enabled ? true : nil }
        return enabled ? "\(game.name) gets emulated display modes (\(executables.joined(separator: ", "))): the Mac's resolution stays as it is."
                       : "\(game.name) sees the Mac's own display modes again."
    }

    /// Sets (or removes) one native,builtin DLL override on a game's executables, e.g. dinput8 for an ASI
    /// loader shipped in the game folder, and notes it in the game's profile.
    public func setDLLOverride(appID: String, dll: String, enabled: Bool) throws -> String {
        let id = try Self.validated(appID: appID)
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw Failure("Invalid DLL name: \(dll)")
        }
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage)
        guard let game = try library().games.first(where: { $0.appID == id }) else {
            throw Failure("AppID \(id) is not installed in the \(translation.name) environment.")
        }
        let executables = GameExecutables.find(in: game.installDirectory)
        guard !executables.isEmpty else { throw Failure("No executables found in \(game.installDirectory.path).") }
        let prefix = try prefix()
        do {
            let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
            try applyOverrides(executables, dlls: [name], enabled: enabled, runtime: runtime, prefix: prefix)
        }
        _ = try editProfile(appID: id) { entry in
            var overrides = entry.dllOverrides ?? [:]
            overrides[name] = enabled ? Engine.dxmtLoadOrder : nil
            entry.dllOverrides = overrides.isEmpty ? nil : overrides
        }
        return "\(name)=\(enabled ? Engine.dxmtLoadOrder : "default") for \(game.name) (\(executables.joined(separator: ", ")))."
    }

    /// Copies a renderer's files into the prefix where missing or different; returns how many changed.
    func install(_ renderer: HadronRenderer, runtime: Runtime) throws -> Int {
        let fm = FileManager.default
        // dist/bin/wine → dist
        let dist = runtime.manifest.loader.split(separator: "/").dropLast(2).joined(separator: "/")
        var changed = 0
        for file in renderer.files(dist: dist) {
            let source = try storage.path(file.source)
            guard fm.fileExists(atPath: source.path) else { throw Failure("This runtime has no \(renderer.rawValue): \(file.source) is missing.") }
            let destination = try storage.path(prefixRelative + "/" + file.destination)
            let digest = try Runner.sha256(source)
            if fm.fileExists(atPath: destination.path), try Runner.sha256(destination) == digest { continue }
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).macgaming-new")
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: source, to: staged)
            guard try Runner.sha256(staged) == digest else { throw Failure("Copy of \(file.source) could not be verified.") }
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
            else { try fm.moveItem(at: staged, to: destination) }
            changed += 1
        }
        if renderer == .vkd3d {
            // VKD3D_SHADER_CACHE_PATH in the FEX manifest points here, so pipelines stay out of the game's folder.
            try fm.createDirectory(at: try storage.path(prefixRelative + "/shadercache"), withIntermediateDirectories: true)
        }
        return changed
    }

    /// Turns a Hadron renderer on or off for one game's executables, and notes it in the game's profile.
    public func setRenderer(_ renderer: HadronRenderer, appID: String, enabled: Bool) throws -> String {
        let id = try Self.validated(appID: appID)
        guard translation == .fex else { throw Failure("\(renderer.rawValue) is part of Hadron: use it in the ARM64/FEX environment.") }
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        guard let game = try library().games.first(where: { $0.appID == id }) else {
            throw Failure("AppID \(id) is not installed in the \(translation.name) environment.")
        }
        let executables = GameExecutables.find(in: game.installDirectory)
        guard !executables.isEmpty else { throw Failure("No executables found in \(game.installDirectory.path).") }
        let prefix = try prefix()
        var installed = 0
        do {
            let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
            if enabled { installed = try install(renderer, runtime: runtime) }
            try applyOverrides(executables, dlls: renderer.overriddenDLLs, enabled: enabled, runtime: runtime, prefix: prefix)
        }
        _ = try editProfile(appID: id) { entry in
            var overrides = entry.dllOverrides ?? [:]
            for dll in renderer.overriddenDLLs { overrides[dll] = enabled ? Engine.dxmtLoadOrder : nil }
            entry.dllOverrides = overrides.isEmpty ? nil : overrides
            if enabled { entry.renderer = renderer.description }
            else if entry.renderer == renderer.description { entry.renderer = nil }
        }
        let dlls = renderer.overriddenDLLs.joined(separator: ",")
        return enabled
            ? "\(renderer.rawValue) enabled for \(game.name): \(dlls)=native,builtin on \(executables.joined(separator: ", "))"
                + (installed > 0 ? " (\(installed) files installed in the prefix)." : ".")
            : "\(renderer.rawValue) disabled for \(game.name): it goes back to Wine's \(dlls)."
    }
}
