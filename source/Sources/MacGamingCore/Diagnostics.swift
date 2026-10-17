// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

extension Engine {
    /// A bounded, explicit report. Account data, saves, environment secrets and raw Steam logs are excluded.
    public func diagnosticsReport(appID: String) throws -> String {
        let id = try Self.validated(appID: appID)
        let runtime = try Runtime(translation: translation, storage: storage).manifest
        let game = try library().games.first { $0.appID == id }
        let profileText = try profileReport(appID: id)
        let report = """
        MacGaming diagnostic report · schema 1
        Created: \(ISO8601DateFormatter().string(from: Date()))
        System: \(Profiles.hardwareDescription())
        Environment: \(translation.rawValue)
        Runtime: \(runtime.id) \(runtime.version)
        Game: \(game?.name ?? "Unknown") · AppID \(id) · build \(game?.buildID ?? "not installed")
        Installation: \(game?.status ?? "Not installed")
        FPS overlay: \(runtime.environment["MTL_HUD_ENABLED"] == "1" ? "on" : "off")

        \(profileText)

        Includes configuration settings, compatibility checks and known limits.
        No account files, save contents, raw logs or complete process environment are included.
        Gameplay observations are manual records, not an automatic compatibility certification.
        """
        return DiagnosticRedaction.redact(report, root: storage.root.path)
    }
    public func exportDiagnostics(appID: String) throws -> URL {
        let report = try diagnosticsReport(appID: appID)
        let relative = "exports/diagnostics-\(appID)-\(UUID().uuidString).txt"
        try FileManager.default.createDirectory(at: try storage.path("exports"), withIntermediateDirectories: true)
        try Data(report.utf8).write(to: storage.path(relative), options: .atomic)
        return try storage.path(relative)
    }
    public func updateConfigurationArguments(appID: String, arguments: [String]) throws -> String {
        guard arguments.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) && !$0.contains("\0") && !$0.lowercased().hasPrefix("steam://") }) else {
            throw Failure("Enter one valid game argument per line.")
        }
        try ensureNoGamePlaying()
        _ = try editProfile(appID: appID) { entry in
            if (entry.launchArguments ?? []) != arguments {
                entry.launchArguments = arguments
            }
        }
        return "Launch arguments saved. Re-check this configuration in game."
    }
    /// Variable prefixes a configuration may set: emulator and renderer tuning only, never the loader,
    /// Wine's own paths or anything dyld reads.
    static let gameEnvironmentPrefixes = ["FEX_", "DXMT_", "MTLD3D_", "VKD3D_", "DXVK_", "MESA_"]
    static func validatedGameEnvironment(_ environment: [String: String]) throws -> [String: String] {
        for (key, value) in environment {
            guard key.count <= 64, let first = key.first, first.isASCII, first.isUppercase,
                  key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }),
                  gameEnvironmentPrefixes.contains(where: { key.hasPrefix($0) }) else {
                throw Failure("\(key) is not allowed. Use emulator or renderer variables: \(gameEnvironmentPrefixes.joined(separator: ", ")).")
            }
            guard value.count <= 256, !value.contains(where: \.isNewline), !value.contains("\0") else {
                throw Failure("Invalid value for \(key).")
            }
        }
        return environment
    }
    /// Replaces the selected configuration's environment; an empty dictionary removes it.
    public func updateConfigurationEnvironment(appID: String, environment: [String: String]) throws -> String {
        let environment = try Self.validatedGameEnvironment(environment)
        try ensureNoGamePlaying()
        _ = try editProfile(appID: appID) { entry in
            if (entry.environment ?? [:]) != environment {
                entry.environment = environment.isEmpty ? nil : environment
            }
        }
        return "Environment saved; Play restarts Steam with it when needed. Re-check this configuration in game."
    }
    public func updateConfigurationModeset(appID: String, enabled: Bool) throws -> String {
        try ensureNoGamePlaying()
        _ = try editProfile(appID: appID) { entry in
            if (entry.emulateModeset ?? false) != enabled {
                entry.emulateModeset = enabled
            }
        }
        return "Display mode setting saved; applied on the next Play."
    }
    public func updateConfigurationDLL(appID: String, dll: String, enabled: Bool) throws -> String {
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        guard !name.isEmpty, name.count <= 64, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { throw Failure("Invalid DLL name.") }
        guard !["d3d9", "d3d10", "d3d10core", "d3d11", "d3d12", "d3d12core", "dxgi"].contains(name) else {
            throw Failure("Use a renderer configuration to change graphics DLLs.")
        }
        try ensureNoGamePlaying()
        _ = try editProfile(appID: appID) { entry in
            var overrides = entry.dllOverrides ?? [:]
            overrides[name] = enabled ? Self.dxmtLoadOrder : nil
            entry.dllOverrides = overrides.isEmpty ? nil : overrides
            var removed = Set(entry.removedDLLOverrides ?? [])
            if enabled { removed.remove(name) } else { removed.insert(name) }
            entry.removedDLLOverrides = removed.isEmpty ? nil : removed.sorted()
        }
        return "DLL setting saved; applied on the next Play."
    }

    static func invalidateEvidence(_ entry: inout EngineProfile) {
        entry.status = .experimental
        entry.checks = entry.checks.map {
            ProfileCheck(name: $0.name, result: .pending, notes: "Configuration changed; previous result: \($0.result.rawValue). " + ($0.notes ?? ""))
        }
    }
}

enum DiagnosticRedaction {
    static func redact(_ text: String, root: String) -> String {
        var output = text.replacingOccurrences(of: root, with: "$DATA")
            .replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
        let patterns = [
            (#"(?i)\b(access_token|refresh_token|authorization|password|passwd|cookie|steamid|accountid)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
            (#"\b7656119[0-9]{10}\b"#, "[Steam account redacted]")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: replacement)
            }
        }
        return output
    }
}
