// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

public enum RendererKind: String, Codable, CaseIterable, Sendable {
    case dxmt, mtld3d, vkd3d, wine
    public var label: String {
        switch self {
        case .dxmt: return "Direct3D 10/11 · DXMT"
        case .mtld3d: return "Direct3D 9 · mtld3d"
        case .vkd3d: return "Direct3D 12 · vkd3d-proton"
        case .wine: return "Wine default"
        }
    }
}

public struct ConfigurationFileEdit: Codable, Sendable {
    public var root: String
    public var path: String
    public var section: String
    public var values: [String: String]
    public var removeKeys: [String]
}

public struct ConfigurationChoice: Identifiable, Sendable {
    public var id: String
    public var profile: EngineProfile
    public var name: String { profile.configurationName ?? profile.renderer ?? id }
}

/// Small INI edits preserve unrelated options and remove duplicate occurrences of managed keys.
enum ConfigurationINI {
    static func applying(_ edit: ConfigurationFileEdit, to text: String) throws -> String {
        let clean: (String) -> Bool = { !$0.isEmpty && !$0.contains(where: \.isNewline) && !$0.contains("\0") }
        guard clean(edit.section), !edit.section.contains("["), !edit.section.contains("]"),
              (Array(edit.values.keys) + edit.removeKeys).allSatisfy({ clean($0) && !$0.contains("=") }),
              edit.values.values.allSatisfy(clean) else { throw Failure("Invalid INI configuration.") }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let managed = Set((Array(edit.values.keys) + edit.removeKeys).map { $0.lowercased() })
        var output: [String] = [], inSection = false, found = false, inserted = false
        func appendValues() {
            guard !inserted else { return }
            output += edit.values.keys.sorted().map { "\($0)=\(edit.values[$0]!)" }
            inserted = true
        }
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
                if inSection { appendValues() }
                inSection = stripped.dropFirst().dropLast().caseInsensitiveCompare(edit.section) == .orderedSame
                found = found || inSection
            }
            if inSection, !stripped.hasPrefix(";"), !stripped.hasPrefix("#"),
               let equal = stripped.firstIndex(of: "="), managed.contains(stripped[..<equal].trimmingCharacters(in: .whitespaces).lowercased()) { continue }
            output.append(line)
        }
        if inSection { appendValues() }
        if !found && !edit.values.isEmpty { output += ["[\(edit.section)]"]; appendValues() }
        return output.joined(separator: newline)
    }
}

struct ConfigurationJournal: Codable {
    struct File: Codable { var relativePath: String; var backupName: String; var existed: Bool; var sha256: String }
    var configurationID: String
    var phase: String
    var registryBefore: String
    var files: [File]
    var managedDLLs: [String]?
}

extension Engine {
    public func configurationChoices(appID: String) throws -> [ConfigurationChoice] {
        try profile(appID: appID)?.choices(for: translation) ?? []
    }
    public func selectedConfigurationID(appID: String) throws -> String? {
        try profile(appID: appID)?.selectedID(for: translation)
    }
    func ensureNoGamePlaying() throws {
        if case .playing = try status().phase { throw Failure("Close the running game before changing its configuration.") }
    }
    private func writeProfile(_ profile: GameProfile) throws {
        try FileManager.default.createDirectory(at: try storage.path("profiles"), withIntermediateDirectories: true)
        try storage.write(profile, to: profileRelative(profile.appID))
    }
    /// Saves the user's choice only. It never starts Wine, Steam or a game.
    public func selectConfiguration(appID: String, configurationID: String) throws -> String {
        try storage.validate(); try ensureNoGamePlaying()
        let lock = try PrefixLock(url: try prefix().appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard var profile = try profile(appID: appID),
              let choice = profile.choices(for: translation).first(where: { $0.id == configurationID }) else {
            throw Failure("Configuration not found for this game and environment.")
        }
        if profile.configurations == nil { profile.configurations = [translation.rawValue: Dictionary(uniqueKeysWithValues: profile.choices(for: translation).map { ($0.id, $0.profile) })] }
        profile.schemaVersion = 2
        profile.selectedConfigurations = (profile.selectedConfigurations ?? [:]).merging([translation.rawValue: configurationID]) { $1 }
        profile.engines[translation.rawValue] = choice.profile
        try writeProfile(profile)
        return "\(choice.name) selected for \(profile.name). Settings will be applied next time you press Play."
    }

    /// Explicit candidate creation for every installed game; no successful test is invented.
    public func createConfiguration(appID: String, renderer: RendererKind) throws -> String {
        let id = try Self.validated(appID: appID)
        try storage.validate(); try ensureNoGamePlaying()
        guard translation == .fex else { throw Failure("Create renderer configurations in the ARM64/FEX environment.") }
        guard let game = try library().games.first(where: { $0.appID == id }) else { throw Failure("Install the game first.") }
        let lock = try PrefixLock(url: try prefix().appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        let runtime = try Runtime(translation: translation, storage: storage).manifest
        var profile = try self.profile(appID: id) ?? GameProfile(appID: id, name: game.name, savePaths: nil, engines: [:])
        var choices = Dictionary(uniqueKeysWithValues: profile.choices(for: translation).map { ($0.id, $0.profile) })
        guard choices[renderer.rawValue] == nil else { throw Failure("This renderer already has a configuration.") }
        let entry = EngineProfile(status: .untested, runtimeID: runtime.id, runtimeVersion: runtime.version,
                                  buildID: game.buildID, renderer: renderer.label, date: Profiles.today(), hardware: nil,
                                  launchArguments: renderer == .vkd3d ? ["-dx12"] : (renderer == .dxmt ? ["-dx11"] : []),
                                  dllOverrides: nil, emulateModeset: nil, patches: nil, disabledFiles: nil,
                                  checks: Self.standardChecks, limits: ["Candidate only. Not tested in game. Launch arguments may need title-specific changes."],
                                  configurationName: renderer.label, recommended: false, rendererKind: renderer, configFileEdits: nil)
        var candidate = entry
        if let current = profile.selectedEntry(for: translation) {
            candidate.dllOverrides = current.dllOverrides?.filter { !["d3d9", "d3d10", "d3d10core", "d3d11", "dxgi", "d3d12", "d3d12core"].contains($0.key) }
            candidate.patches = current.patches; candidate.disabledFiles = current.disabledFiles
            candidate.emulateModeset = current.emulateModeset
        }
        choices[renderer.rawValue] = candidate
        profile.configurations = (profile.configurations ?? [:]).merging([translation.rawValue: choices]) { $1 }
        profile.schemaVersion = 2
        if profile.selectedID(for: translation) == nil || profile.engines[translation.rawValue] == nil {
            profile.selectedConfigurations = (profile.selectedConfigurations ?? [:]).merging([translation.rawValue: renderer.rawValue]) { $1 }
            profile.engines[translation.rawValue] = candidate
        }
        try writeProfile(profile)
        return "Untested \(renderer.label) configuration created for \(game.name)."
    }
    static var standardChecks: [ProfileCheck] {
        ["Launch to menu", "Rendering in gameplay", "Long session (30-60 min) with save, quit and reload", "Audio and controller"].map {
            ProfileCheck(name: $0, result: .pending, notes: nil)
        }
    }

    /// Configuration changes are scoped to executable names, with before-images for recovery.
    /// Called only by an explicit Play request. A failure prevents the game launch.
    func applySelectedConfiguration(appID: String) throws {
        guard let profile = try profile(appID: appID), let entry = profile.selectedEntry(for: translation),
              let renderer = entry.rendererKind, let configID = profile.selectedID(for: translation) else { return }
        if try status().phase == .playing(appID: appID) { return }
        try ensureNoGamePlaying()
        guard translation == .fex else { throw Failure("Managed renderer configurations require ARM64/FEX.") }
        guard let game = try library().games.first(where: { $0.appID == appID && $0.isReady }) else { throw Failure("The game installation is not ready.") }
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let prefix = try prefix()
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        let journalRelative = "backups/configurations/\(translation.rawValue)/\(appID)/current"
        let journalURL = try storage.path(journalRelative + "/journal.json")
        var previousJournal: ConfigurationJournal?
        if FileManager.default.fileExists(atPath: journalURL.path) {
            previousJournal = try JSONDecoder().decode(ConfigurationJournal.self, from: Data(contentsOf: journalURL))
        }
        if let old = previousJournal, ["applying", "rollbackFailed"].contains(old.phase) {
            throw Failure("An interrupted configuration change needs recovery. Use Recover Configuration before Play.")
        }
        let executables = GameExecutables.find(in: game.installDirectory)
        guard !executables.isEmpty else { throw Failure("No game executables found.") }
        var overrides = entry.dllOverrides ?? [:]
        if renderer == .mtld3d { overrides["d3d9"] = Self.dxmtLoadOrder }
        if renderer == .vkd3d { overrides["d3d12"] = Self.dxmtLoadOrder; overrides["d3d12core"] = Self.dxmtLoadOrder }
        guard overrides.values.allSatisfy({ ["native,builtin", "builtin,native", "native", "builtin", ""].contains($0) }) else {
            throw Failure("Invalid DLL load order in the selected configuration.")
        }
        let dlls = Set(["d3d9", "d3d12", "d3d12core"] + (previousJournal?.managedDLLs ?? []) + profile.choices(for: translation).flatMap {
            Array(($0.profile.dllOverrides ?? [:]).keys) + ($0.profile.removedDLLOverrides ?? [])
        })
        var before = "Windows Registry Editor Version 5.00\n", after = before
        for exe in executables {
            for (subkey, values) in [("DllOverrides", Dictionary(uniqueKeysWithValues: dlls.map { ($0, overrides[$0]) })),
                                     ("X11 Driver", ["EmulateModeset": entry.emulateModeset == true ? "y" : nil])] {
                let query = try runtime.run(["reg", "query", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\\(subkey)"], prefix: prefix,
                                            logName: "configuration-query-\(translation.rawValue)")
                guard [0, 1].contains(query.exitCode) else { throw Failure("Could not read the existing game registry settings.") }
                let old = WineRegistry.stringValues(inQueryOutput: query.text)
                before += try WineRegistry.appSettingsDocument(executables: [exe], subkey: subkey,
                            values: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, old[$0.lowercased()]) })).replacingOccurrences(of: "Windows Registry Editor Version 5.00", with: "")
                after += try WineRegistry.appSettingsDocument(executables: [exe], subkey: subkey, values: values).replacingOccurrences(of: "Windows Registry Editor Version 5.00", with: "")
            }
        }
        let fm = FileManager.default
        // Keep previous transactions; the current recovery slot is never deleted without archiving it.
        let directory = try storage.path(journalRelative)
        if fm.fileExists(atPath: directory.path) {
            try fm.moveItem(at: directory, to: directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var journal = ConfigurationJournal(configurationID: configID, phase: "prepared", registryBefore: before, files: [], managedDLLs: dlls.sorted())
        var writes: [(URL, Data)] = []
        for (index, edit) in (entry.configFileEdits ?? []).enumerated() {
            let target = try configurationFile(edit)
            let exists = fm.fileExists(atPath: target.path)
            let data = exists ? try Data(contentsOf: target) : Data()
            guard let text = String(data: data, encoding: .utf8) else { throw Failure("Configuration file is not UTF-8: \(edit.path)") }
            let updated = Data(try ConfigurationINI.applying(edit, to: text).utf8)
            try data.write(to: directory.appendingPathComponent("\(index).before"), options: .atomic)
            journal.files.append(.init(relativePath: String(target.path.dropFirst(storage.root.path.count + 1)),
                                       backupName: "\(index).before", existed: exists, sha256: Runner.sha256(data)))
            writes.append((target, updated))
        }
        journal.phase = "applying"; try storage.write(journal, to: journalRelative + "/journal.json")
        do {
            if renderer == .mtld3d { _ = try install(.mtld3d, runtime: runtime) }
            if renderer == .vkd3d { _ = try install(.vkd3d, runtime: runtime) }
            try importRegistry(after, runtime: runtime, prefix: prefix, logName: "configuration-apply-\(translation.rawValue)")
            for (target, data) in writes {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            // Read back the overrides: an import exit code alone is not proof of application.
            for exe in executables {
                let query = try runtime.run(["reg", "query", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides"], prefix: prefix,
                                            logName: "configuration-verify-\(translation.rawValue)")
                let actual = WineRegistry.stringValues(inQueryOutput: query.text)
                guard dlls.allSatisfy({ actual[$0.lowercased()] == overrides[$0] }) else { throw Failure("The selected configuration's DLL overrides could not be verified.") }
            }
            for exe in executables {
                let query = try runtime.run(["reg", "query", "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\X11 Driver"], prefix: prefix,
                                            logName: "configuration-modeset-verify-\(translation.rawValue)")
                let actual = WineRegistry.stringValues(inQueryOutput: query.text)["emulatemodeset"]
                guard actual == (entry.emulateModeset == true ? "y" : nil) else { throw Failure("Display mode configuration could not be verified.") }
            }
            journal.phase = "applied"; try storage.write(journal, to: journalRelative + "/journal.json")
        } catch {
            let original = error
            do { try restoreConfigurationJournal(journal, relative: journalRelative, runtime: runtime) }
            catch {
                journal.phase = "rollbackFailed"; try? storage.write(journal, to: journalRelative + "/journal.json")
                throw Failure("Configuration failed and recovery is incomplete. Use Recover Configuration. " + original.localizedDescription + " Recovery: " + error.localizedDescription)
            }
            throw Failure("Configuration was not applied; previous settings restored. " + original.localizedDescription)
        }
    }

    private func configurationFile(_ edit: ConfigurationFileEdit) throws -> URL {
        let prefix = try prefix()
        let home = "drive_c/users/\(prefixUser(prefix))"
        let roots = ["appDataLocal": home + "/AppData/Local", "appDataRoaming": home + "/AppData/Roaming", "documents": home + "/Documents"]
        guard let base = roots[edit.root], let path = SaveBackups.safeRelative(edit.path) else { throw Failure("Invalid configuration file location.") }
        return try storage.path(prefixRelative + "/" + base + "/" + path)
    }
    private func restoreConfigurationJournal(_ original: ConfigurationJournal, relative: String, runtime: Runtime) throws {
        // Verify every before-image before changing any setting.
        let files = try original.files.map { item -> (ConfigurationJournal.File, URL, Data) in
            guard let name = SaveBackups.safeRelative(item.backupName) else { throw Failure("Invalid configuration backup.") }
            let target = try storage.path(item.relativePath)
            guard target.path.hasPrefix(try prefix().path + "/drive_c/users/") else { throw Failure("Configuration recovery points outside user settings.") }
            let data = try Data(contentsOf: storage.path(relative + "/" + name))
            guard Runner.sha256(data) == item.sha256 else { throw Failure("Configuration backup integrity check failed.") }
            return (item, target, data)
        }
        try importRegistry(original.registryBefore, runtime: runtime, prefix: prefix(), logName: "configuration-recover-\(translation.rawValue)")
        for (item, target, data) in files {
            if item.existed { try data.write(to: target, options: .atomic) }
            else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        var journal = original; journal.phase = "rolledBack"
        try storage.write(journal, to: relative + "/journal.json")
    }
    public func recoverConfiguration(appID: String) throws -> String {
        let id = try Self.validated(appID: appID)
        try storage.validate(); try ensureNoGamePlaying()
        let lock = try PrefixLock(url: try prefix().appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        let relative = "backups/configurations/\(translation.rawValue)/\(id)/current"
        let data = try Data(contentsOf: storage.path(relative + "/journal.json"))
        let journal = try JSONDecoder().decode(ConfigurationJournal.self, from: data)
        guard ["applying", "rollbackFailed"].contains(journal.phase) else { return "No interrupted configuration change to recover." }
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        try restoreConfigurationJournal(journal, relative: relative, runtime: runtime)
        return "Previous game settings recovered. You can select a configuration and press Play."
    }
}
