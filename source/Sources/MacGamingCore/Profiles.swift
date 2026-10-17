// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// A game's compatibility record (plan, section 11): what was tested, on which engine, runtime and
/// game build, with which result. One file per game, profiles/<appid>.json, one entry per engine.
public struct GameProfile: Codable, Sendable {
    public var schemaVersion = 1
    public var appID: String
    public var name: String
    /// Folders holding saves, for games Steam Cloud does not list (root as in SaveRoot, e.g. "documents").
    public var savePaths: [SavePath]?
    public var engines: [String: EngineProfile]
    /// Schema 2: independent evidence and settings per engine AND configuration.
    public var configurations: [String: [String: EngineProfile]]?
    public var selectedConfigurations: [String: String]?

    public func choices(for engine: CPUTranslation) -> [ConfigurationChoice] {
        let entries = configurations?[engine.rawValue] ?? engines[engine.rawValue].map { ["default": $0] } ?? [:]
        return entries.map { ConfigurationChoice(id: $0.key, profile: $0.value) }.sorted {
            if ($0.profile.recommended ?? false) != ($1.profile.recommended ?? false) { return $0.profile.recommended == true }
            return $0.name < $1.name
        }
    }
    public func selectedID(for engine: CPUTranslation) -> String? {
        let choices = choices(for: engine)
        if let selected = selectedConfigurations?[engine.rawValue], choices.contains(where: { $0.id == selected }) { return selected }
        return choices.first?.id
    }
    public func selectedEntry(for engine: CPUTranslation) -> EngineProfile? {
        choices(for: engine).first { $0.id == selectedID(for: engine) }?.profile
    }

    public struct SavePath: Codable, Sendable, Equatable {
        public var root: String
        public var path: String
    }
}

public struct EngineProfile: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case verified, experimental, blocked, untested }
    public var status: Status
    /// What the result holds for: a different runtime or game build needs a new check.
    public var runtimeID: String
    public var runtimeVersion: String
    public var buildID: String
    public var renderer: String?
    public var date: String
    public var hardware: String?
    /// Passed to the game after -applaunch APPID.
    public var launchArguments: [String]?
    /// Wine DLL overrides set on the game's executables (e.g. d3d9 → native,builtin for mtld3d).
    public var dllOverrides: [String: String]?
    /// Wine's EmulateModeset for the game's executables: mode changes stay virtual, the Mac's screen keeps its own.
    public var emulateModeset: Bool?
    /// Emulator and renderer variables for the Steam session that starts this game: Windows Steam passes
    /// its environment to every game it launches, so Play restarts Steam when they differ.
    public var environment: [String: String]? = nil
    /// Third-party fixes installed in the game folder, with source and record (backups/game-patches/...).
    public var patches: [String]?
    /// Game files renamed out of the way (relative to the install folder), e.g. intro movies.
    public var disabledFiles: [String]?
    public var checks: [ProfileCheck]
    public var limits: [String]?
    public var configurationName: String?
    public var recommended: Bool?
    /// nil preserves legacy behaviour; explicit kinds opt into managed configuration application.
    public var rendererKind: RendererKind?
    public var configFileEdits: [ConfigurationFileEdit]?
    public var removedDLLOverrides: [String]?
}

public struct ProfileCheck: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable { case passed, failed, pending }
    public var name: String
    public var result: Result
    public var notes: String?
}

/// What a game's profile means for the selected engine right now.
public struct Compatibility: Sendable, Equatable {
    public enum State: Sendable, Equatable { case verified, experimental, blocked, needsRecheck, untested }
    public var state: State
    public var reason: String?
    public var pendingChecks: [String]

    public var label: String {
        switch state {
        case .verified: return "Verified"
        case .experimental: return "Experimental"
        case .blocked: return "Blocked"
        case .needsRecheck: return "Needs re-check"
        case .untested: return "Not tested"
        }
    }
}

enum Profiles {
    static func compatibility(_ profile: GameProfile?, engine: CPUTranslation, runtime: RuntimeManifest,
                              installedBuild: String) -> Compatibility {
        guard let entry = profile?.selectedEntry(for: engine) else {
            return Compatibility(state: .untested, reason: "No test record on this engine.", pendingChecks: [])
        }
        if entry.status == .untested { return Compatibility(state: .untested, reason: entry.limits?.first, pendingChecks: entry.checks.filter { $0.result == .pending }.map(\.name)) }
        let pending = entry.checks.filter { $0.result == .pending }.map(\.name)
        if entry.runtimeID != runtime.id || entry.runtimeVersion != runtime.version {
            return Compatibility(state: .needsRecheck, reason: "Tested with \(entry.runtimeID) \(entry.runtimeVersion); the runtime is now \(runtime.version).", pendingChecks: pending)
        }
        if !installedBuild.isEmpty && entry.buildID != installedBuild {
            return Compatibility(state: .needsRecheck, reason: "Tested on game build \(entry.buildID); Steam installed build \(installedBuild).", pendingChecks: pending)
        }
        if entry.status == .verified && (entry.checks.isEmpty || entry.checks.contains { $0.result != .passed }) {
            return Compatibility(state: .needsRecheck, reason: "This configuration has incomplete compatibility checks.", pendingChecks: pending)
        }
        let state: Compatibility.State
        switch entry.status {
        case .verified: state = .verified
        case .experimental: state = .experimental
        case .blocked: state = .blocked
        case .untested: state = .untested
        }
        return Compatibility(state: state, reason: entry.limits?.first, pendingChecks: pending)
    }

    /// A verified game has every check passed: reaching the menu is not enough (plan, section 11).
    static func canMark(_ entry: EngineProfile, as status: EngineProfile.Status) throws {
        guard status == .verified else { return }
        let open = entry.checks.filter { $0.result != .passed }
        guard entry.checks.isEmpty == false, open.isEmpty else {
            throw Failure(open.isEmpty ? "Record at least one passed check before marking the game verified."
                                       : "Cannot mark verified: \(open.map { "\($0.name) (\($0.result.rawValue))" }.joined(separator: ", ")).")
        }
    }

    static func upsert(_ check: ProfileCheck, into entry: inout EngineProfile) {
        if let index = entry.checks.firstIndex(where: { $0.name.caseInsensitiveCompare(check.name) == .orderedSame }) {
            entry.checks[index] = check
        } else {
            entry.checks.append(check)
        }
    }

    static func hardwareDescription() -> String {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"), "macOS \(version)"].compactMap { $0 }.joined(separator: " · ")
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

extension Engine {
    func profileRelative(_ appID: String) throws -> String { "profiles/\(try Self.validated(appID: appID)).json" }

    public func profile(appID: String) throws -> GameProfile? {
        try storage.validate()
        let url = try storage.path(profileRelative(appID))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let profile = try JSONDecoder().decode(GameProfile.self, from: Data(contentsOf: url))
        guard [1, 2].contains(profile.schemaVersion) else { throw Failure("Unsupported game profile version.") }
        if profile.schemaVersion == 2 {
            for (engine, selected) in profile.selectedConfigurations ?? [:] {
                guard profile.configurations?[engine]?[selected] != nil else { throw Failure("The selected game configuration is missing. Restore or repair the profile before Play.") }
            }
        }
        return profile
    }

    public func compatibility(for game: InstalledGame) throws -> Compatibility {
        let runtime = try Runtime(translation: translation, storage: storage)
        return Profiles.compatibility(try profile(appID: game.appID), engine: translation, runtime: runtime.manifest,
                                      installedBuild: game.buildID)
    }

    /// This engine's entry, created as experimental for the current runtime and game build when missing.
    func editProfile(appID: String, _ change: (inout EngineProfile) throws -> Void) throws -> GameProfile {
        let id = try Self.validated(appID: appID)
        try storage.validate()
        let lock = try PrefixLock(url: try prefix().appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard let game = try library().games.first(where: { $0.appID == id }) else {
            throw Failure("AppID \(id) is not installed in the \(translation.name) environment.")
        }
        let runtime = try Runtime(translation: translation, storage: storage).manifest
        var profile = try self.profile(appID: id) ?? GameProfile(appID: id, name: game.name, savePaths: nil, engines: [:])
        var entry = profile.selectedEntry(for: translation) ?? EngineProfile(
            status: .experimental, runtimeID: runtime.id, runtimeVersion: runtime.version, buildID: game.buildID,
            renderer: nil, date: Profiles.today(), hardware: Profiles.hardwareDescription(), launchArguments: nil,
            dllOverrides: nil, emulateModeset: nil, patches: nil, disabledFiles: nil, checks: [], limits: nil)
        let previousSettings = try Self.configurationSignature(entry)
        try change(&entry)
        if try previousSettings != Self.configurationSignature(entry) { Self.invalidateEvidence(&entry) }
        if profile.configurations != nil {
            let selected = profile.selectedID(for: translation) ?? "default"
            profile.configurations?[translation.rawValue, default: [:]][selected] = entry
        }
        profile.engines[translation.rawValue] = entry
        try FileManager.default.createDirectory(at: try storage.path("profiles"), withIntermediateDirectories: true)
        try storage.write(profile, to: profileRelative(id))
        return profile
    }

    private static func configurationSignature(_ entry: EngineProfile) throws -> Data {
        guard var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] else { throw Failure("Invalid configuration data.") }
        for key in ["status", "runtimeID", "runtimeVersion", "buildID", "date", "hardware", "checks", "limits", "configurationName", "recommended"] { dictionary.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }

    /// Records one check of the test sheet for this engine.
    public func recordCheck(appID: String, name: String, result: ProfileCheck.Result, notes: String?) throws -> String {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure("The check needs a name.") }
        let runtime = try Runtime(translation: translation, storage: storage).manifest
        let build = try library().games.first { $0.appID == appID }?.buildID ?? ""
        _ = try editProfile(appID: appID) {
            if $0.runtimeID != runtime.id || $0.runtimeVersion != runtime.version || $0.buildID != build {
                Self.invalidateEvidence(&$0)
                $0.runtimeID = runtime.id; $0.runtimeVersion = runtime.version; $0.buildID = build
            }
            $0.date = Profiles.today(); $0.hardware = Profiles.hardwareDescription()
            Profiles.upsert(ProfileCheck(name: name, result: result, notes: notes), into: &$0)
            if result != .passed && $0.status == .verified { $0.status = .experimental }
        }
        return "Check \"\(name)\" recorded as \(result.rawValue) for AppID \(appID) on \(translation.name)."
    }

    /// Sets the result for this engine and stamps it with the current runtime, game build, date and Mac.
    public func markProfile(appID: String, status: EngineProfile.Status) throws -> String {
        let id = try Self.validated(appID: appID)
        let game = try library().games.first { $0.appID == id }
        let runtime = try Runtime(translation: translation, storage: storage).manifest
        _ = try editProfile(appID: id) { entry in
            let stale = entry.runtimeID != runtime.id || entry.runtimeVersion != runtime.version || entry.buildID != game?.buildID
            if status == .verified && stale {
                throw Failure("Record fresh checks for the current game build and runtime before marking verified.")
            }
            if stale { Self.invalidateEvidence(&entry) }
            try Profiles.canMark(entry, as: status)
            entry.status = status
            entry.runtimeID = runtime.id; entry.runtimeVersion = runtime.version
            entry.buildID = game?.buildID ?? entry.buildID
            entry.date = Profiles.today(); entry.hardware = Profiles.hardwareDescription()
        }
        return "AppID \(id) marked \(status.rawValue) on \(translation.name) (game build \(game?.buildID ?? "?"), \(runtime.id) \(runtime.version))."
    }

    /// The profile as text, for `macgaming profile APPID`.
    public func profileReport(appID: String) throws -> String {
        let id = try Self.validated(appID: appID)
        guard let profile = try profile(appID: id) else { return "No profile for AppID \(id) yet." }
        var lines = ["\(profile.name) (AppID \(id))"]
        if let game = try library().games.first(where: { $0.appID == id }) {
            let compatibility = try compatibility(for: game)
            lines.append("On \(translation.name): \(compatibility.label)" + (compatibility.reason.map { " — \($0)" } ?? ""))
        }
        for engine in CPUTranslation.allCases {
          for choice in profile.choices(for: engine) {
            let entry = choice.profile
            lines.append("")
            lines.append("Configuration: \(choice.name) [\(choice.id)]" + (profile.selectedID(for: engine) == choice.id ? " · selected" : ""))
            lines.append("[\(engine.rawValue)] \(entry.status.rawValue) · \(entry.runtimeID) \(entry.runtimeVersion) · game build \(entry.buildID) · \(entry.date)")
            if let renderer = entry.renderer { lines.append("  Renderer: \(renderer)") }
            if let hardware = entry.hardware { lines.append("  Mac: \(hardware)") }
            if let arguments = entry.launchArguments, !arguments.isEmpty { lines.append("  Launch arguments: \(arguments.joined(separator: " "))") }
            if entry.emulateModeset == true { lines.append("  Display modes: emulated (Wine EmulateModeset)") }
            if let environment = entry.environment, !environment.isEmpty {
                lines.append("  Environment: " + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
            for patch in entry.patches ?? [] { lines.append("  Patch: \(patch)") }
            for file in entry.disabledFiles ?? [] { lines.append("  Disabled game file: \(file)") }
            if let overrides = entry.dllOverrides, !overrides.isEmpty {
                lines.append("  DLL overrides: " + overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            }
            for edit in entry.configFileEdits ?? [] {
                lines.append("  INI: \(edit.root)/\(edit.path) [\(edit.section)]")
                for key in edit.values.keys.sorted() { lines.append("    \(key)=\(edit.values[key] ?? "")") }
                if !edit.removeKeys.isEmpty { lines.append("    Remove: " + edit.removeKeys.joined(separator: ", ")) }
            }
            for check in entry.checks {
                let mark = check.result == .passed ? "✓" : check.result == .failed ? "✗" : "…"
                lines.append("  \(mark) \(check.name)" + (check.notes.map { " — \($0)" } ?? ""))
            }
            for limit in entry.limits ?? [] { lines.append("  Limit: \(limit)") }
        }
        }
        return lines.joined(separator: "\n")
    }
}
