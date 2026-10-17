// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

public struct PrefixState: Codable {
    public var schemaVersion = 1
    public var runtimeID: String
    public var runtimeVersion: String
    public var phase: String
    public var updatedAt: Date
}

/// How MacGaming last started Steam in a prefix. Windows Steam passes its environment to every game.
struct SteamSession: Codable, Equatable {
    var schemaVersion = 1
    var gameEnvironment: [String: String]
    var diagnostic: Bool
}

enum SteamSessionAction: Equatable { case start, reuse, restart }

public struct Engine {
    public let storage: Storage
    public let translation: CPUTranslation
    public init(storage: Storage = Storage(), translation: CPUTranslation = .fex) {
        self.storage = storage; self.translation = translation
    }
    public var prefixRelative: String { "prefixes/steam-\(translation.rawValue)" }
    public func prefix() throws -> URL { try storage.path(prefixRelative) }
    public func steamExecutable() throws -> URL {
        try storage.path(prefixRelative + "/drive_c/Program Files (x86)/Steam/steam.exe")
    }
    public func doctor() throws -> String {
        try storage.validate()
        let bytes = try storage.freeBytes()
        let runtime = try Runtime(translation: translation, storage: storage)
        try runtime.verify()
        let report = """
        MacGaming 0.1 · \(ProcessInfo.processInfo.operatingSystemVersionString)
        Data: \(storage.root.path)
        Registered volume: available · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free
        Runtime: \(runtime.manifest.id) \(runtime.manifest.version)
        Translation: \(translation.label)
        Loader/wineserver: SHA-256 verified
        Windows Steam: \(FileManager.default.fileExists(atPath: try steamExecutable().path) ? "installed" : "not installed")
        Compatibility: \(runtime.manifest.status)
        """
        return try dxmtSummary().map { report + "\n" + $0 } ?? report
    }
    public func state() throws -> PrefixState? {
        let url = try storage.path(prefixRelative + "/macgaming-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PrefixState.self, from: Data(contentsOf: url))
    }
    private func saveState(_ phase: String, runtime: Runtime) throws {
        try storage.write(PrefixState(runtimeID: runtime.manifest.id, runtimeVersion: runtime.manifest.version,
                                      phase: phase, updatedAt: Date()), to: prefixRelative + "/macgaming-state.json")
    }
    func checked(_ result: ProcessResult, operation: String) throws -> String {
        guard result.exitCode == 0 else { throw Failure("\(operation) failed (\(result.exitCode)). \(result.text)") }
        return result.text
    }
    public func prepare() throws -> String {
        try storage.validate()
        guard try storage.freeBytes() > 2_000_000_000 else { throw Failure("At least 2 GB must be free on the external drive to prepare Steam.") }
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let prefix = try prefix()
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        if let old = try state() {
            guard old.runtimeID == runtime.manifest.id && old.runtimeVersion == runtime.manifest.version else {
                throw Failure("This environment belongs to another runtime version. Use a new environment.")
            }
            if old.phase == "ready" || old.phase == "steam-installed" { return "Environment already ready on the external drive." }
        }
        try saveState("preparing", runtime: runtime)
        do {
            _ = try checked(runtime.run(["wineboot", "-u"], prefix: prefix, logName: "prepare-\(translation.rawValue)", timeout: 180), operation: "Preparation")
            _ = try checked(runtime.run(["-w"], prefix: prefix, logName: "prepare-wait-\(translation.rawValue)", timeout: 120, useServer: true), operation: "Waiting for Wine")
            try containUserFolders(prefix: prefix)
            _ = try checked(runtime.run(["cmd", "/c", "echo MACGAMING_WINDOWS_OK"], prefix: prefix,
                                         logName: "windows-probe-\(translation.rawValue)"), operation: "Windows test")
            try saveState("ready", runtime: runtime)
            return "Environment ready. The Windows test program ran."
        } catch {
            _ = try? runtime.run(["-k"], prefix: prefix, logName: "prepare-cleanup-\(translation.rawValue)", useServer: true)
            try? saveState("interrupted", runtime: runtime)
            throw error
        }
    }
    // Wine links Documents/Desktop to the real Mac home by default. Keep managed Steam data on the SSD.
    private func containUserFolders(prefix: URL) throws {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users")
        guard let enumeration = fm.enumerator(at: users, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in enumeration {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumeration.skipDescendants()
                if !url.resolvingSymlinksInPath().path.hasPrefix(prefix.path + "/") {
                    try fm.removeItem(at: url)
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                }
            }
        }
    }
    public func installSteam() throws -> String {
        _ = try prepare()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let prefix = try prefix()
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: try steamExecutable().path) { return "Steam is already installed. You can open it." }
        let installer = try storage.path("downloads/SteamSetup.exe")
        let downloadManifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: storage.path("manifests/steam-installer.json")))
        guard try Runner.sha256(installer) == downloadManifest["sha256"] else { throw Failure("Steam installer missing or modified. Download and verify the official installer.") }
        try saveState("installing-steam", runtime: runtime)
        do {
            _ = try checked(runtime.run([installer.path, "/S"], prefix: prefix,
                                         logName: "steam-install-\(translation.rawValue)", timeout: 180), operation: "Steam installation")
            guard FileManager.default.fileExists(atPath: try steamExecutable().path) else { throw Failure("The installer did not create steam.exe. Check the log.") }
            try containUserFolders(prefix: prefix)
            try saveState("steam-installed", runtime: runtime)
            return "Windows Steam installed on the external drive. Its first start downloads the official updates."
        } catch { try? saveState("interrupted", runtime: runtime); throw error }
    }
    public func launchSteam(appID: String? = nil) throws -> String {
        let id = try appID.map { try Self.validated(appID: $0) }
        var note = ""
        let session = steamSession()
        // Without a game, a running Steam keeps its session; a new one starts with no game variables.
        var gameEnvironment: [String: String] = [:]
        var diagnostic = false
        if let id {
            gameEnvironment = try Self.validatedGameEnvironment(
                (try profile(appID: id))?.selectedEntry(for: translation)?.environment ?? [:])
            let phase = try status().phase
            let steamRunning = phase != .stopped && phase != .environmentRunning
            if Self.steamSessionAction(steamRunning: steamRunning, current: session?.gameEnvironment, wanted: gameEnvironment) == .restart {
                if case .playing = phase { throw Failure("Close the running game first: Steam must restart to apply this game's environment.") }
                _ = try stop()
                diagnostic = session?.diagnostic ?? false
                note += " Steam restarted for this game's environment."
            }
            try applySelectedConfiguration(appID: id)
        }
        // A copy of the saves before each game launch, unless the game is already running.
        if let id, (try? status().phase) != .playing(appID: id) {
            do { note += try makeSaveBackup(appID: id, reason: .beforeLaunch, onlyIfChanged: true).map { " Saves backed up before launch (\($0.id))." } ?? "" }
            catch { note += " Automatic save backup skipped: \(error.localizedDescription)" }
        }
        let pid = try startSteam(id.map { ["-applaunch", $0] + (try launchArguments(appID: $0)) } ?? [],
                                 diagnostic: diagnostic, gameEnvironment: gameEnvironment).pid
        return "Launch request sent to Windows Steam (PID \(pid)). Sign-in and Steam Guard happen in its window." + note
    }
    /// A running Steam is reused only when it was started with the environment this game needs.
    static func steamSessionAction(steamRunning: Bool, current: [String: String]?, wanted: [String: String]) -> SteamSessionAction {
        guard steamRunning else { return .start }
        return (current ?? [:]) == wanted ? .reuse : .restart
    }
    var steamSessionRelative: String { prefixRelative + "/macgaming-steam-session.json" }
    func steamSession() -> SteamSession? {
        guard let url = try? storage.path(steamSessionRelative), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SteamSession.self, from: data)
    }
    /// Opens Steam's own install dialog for an AppID: library and confirmation stay in Steam's window.
    public func requestInstall(appID: String) throws -> String {
        // Same form as Steam's steam:// handler in the prefix: steam.exe -- "steam://..."
        let pid = try startSteam(["--", "steam://install/\(try Self.validated(appID: appID))"]).pid
        return "Request sent to Windows Steam (PID \(pid)): confirm the installation in its window. The game will appear among the installed ones."
    }
    /// The game's own arguments from its profile for this engine, which Steam passes on after -applaunch.
    func launchArguments(appID: String) throws -> [String] {
        let arguments = (try profile(appID: appID))?.selectedEntry(for: translation)?.launchArguments ?? []
        guard arguments.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) && !$0.contains("\0") && !$0.lowercased().hasPrefix("steam://") }) else {
            throw Failure("Invalid launch arguments in the profile of AppID \(appID).")
        }
        return arguments
    }
    static func validated(appID id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(id) != nil else { throw Failure("Invalid Steam AppID.") }
        return id
    }
    /// Starts steam.exe in this prefix, or hands the arguments to the Steam already running there.
    /// Runs a Windows program from the data folder in this environment's prefix and returns its output.
    /// For probes and checks; games run through Steam.
    public func runProgram(_ path: String, arguments: [String] = [], timeout: TimeInterval = 120) throws -> String {
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "exe", FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("Not a Windows program: \(path)")
        }
        guard url.resolvingSymlinksInPath().path.hasPrefix(storage.root.resolvingSymlinksInPath().path + "/") else {
            throw Failure("Only programs inside the MacGaming data folder can be run.")
        }
        let name = url.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let result = try runtime.run([url.path] + arguments, prefix: try prefix(), logName: "run-\(translation.rawValue)-\(name)",
                                     timeout: timeout)
        return "Exit code \(result.exitCode)\n" + result.text
    }

    /// Logging for a diagnostic session: Wine errors, exceptions and DLL loads, DXMT and mtld3d.
    static let diagnosticEnvironment = ["WINEDEBUG": "err+all,warn+seh,+loaddll", "DXMT_LOG_LEVEL": "info", "RUST_LOG": "mtld3d=info"]

    /// Restarts this environment's Steam with diagnostic logging; games launched from it log there too.
    public func restartSteamForDiagnostics() throws -> String {
        var lines: [String] = []
        if SessionProbe.wineserverPID(prefix: try prefix()) != nil { lines.append(try stop()) }
        let (pid, log) = try startSteam([], diagnostic: true)
        lines.append("Windows Steam started with diagnostic logging (PID \(pid)). Steam and the games it launches log to \(log.path)")
        lines.append("Back to normal: macgaming stop, then macgaming steam.")
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private func startSteam(_ extra: [String], diagnostic: Bool = false,
                            gameEnvironment: [String: String] = [:]) throws -> (pid: Int32, log: URL) {
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let prefix = try prefix()
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard let current = try state(), current.phase == "steam-installed",
              current.runtimeID == runtime.manifest.id, current.runtimeVersion == runtime.manifest.version,
              FileManager.default.fileExists(atPath: try steamExecutable().path) else {
            throw Failure("Prepare and install Steam first.")
        }
        let useWrapper = runtime.manifest.webHelperWrapper ?? true
        if SessionProbe.wineserverPID(prefix: prefix) == nil {
            let steamDirectory = try steamExecutable().deletingLastPathComponent()
            if useWrapper { try WebHelperWrapper.install(storage: storage, steamDirectory: steamDirectory) }
            else { try WebHelperWrapper.remove(storage: storage, steamDirectory: steamDirectory) }
        }
        let arguments = [try steamExecutable().path] + runtime.manifest.steamArguments
            + (useWrapper ? WebHelperWrapper.steamArguments : []) + extra
        // Only a new steam.exe takes this environment; a running one just receives the arguments.
        let phase = SessionProbe.status(prefix: prefix).phase
        let startsSteam = phase == .stopped || phase == .environmentRunning
        let environment = (diagnostic ? Self.diagnosticEnvironment : [:]).merging(gameEnvironment) { $1 }
        let logName = "steam-\(translation.rawValue)-\(diagnostic ? "debug-" : "")\(UUID().uuidString)"
        let pid = try runtime.run(arguments, prefix: prefix, logName: logName, detached: true, overrides: environment).pid
        if startsSteam {
            try storage.write(SteamSession(gameEnvironment: gameEnvironment, diagnostic: diagnostic), to: steamSessionRelative)
        }
        return (pid, try storage.path("logs/\(logName).log"))
    }
    public func stop() throws -> String {
        try storage.validate()
        let runtime = try Runtime(translation: translation, storage: storage); try runtime.verify()
        let prefix = try prefix()
        guard FileManager.default.fileExists(atPath: prefix.path) else { return "Environment not created yet." }
        let lock = try PrefixLock(url: prefix.appendingPathComponent(".macgaming.lock")); defer { withExtendedLifetime(lock) {} }
        guard SessionProbe.wineserverPID(prefix: prefix) != nil else { return "The environment is already stopped." }
        // Let Steam close itself first, so it saves login and settings; force only what is left of this prefix.
        if FileManager.default.fileExists(atPath: try steamExecutable().path) {
            _ = try? runtime.run([try steamExecutable().path, "-shutdown"], prefix: prefix,
                                 logName: "stop-steam-\(translation.rawValue)", timeout: 30)
            let deadline = Date().addingTimeInterval(25)
            while SessionProbe.wineserverPID(prefix: prefix) != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            if SessionProbe.wineserverPID(prefix: prefix) == nil { return "Windows Steam closed and environment stopped." }
        }
        _ = try checked(runtime.run(["-k"], prefix: prefix, logName: "stop-\(translation.rawValue)", useServer: true), operation: "Stop")
        _ = try checked(runtime.run(["-w"], prefix: prefix, logName: "stop-wait-\(translation.rawValue)", useServer: true), operation: "Waiting for stop")
        return "Windows Steam environment stopped. Remaining processes were force-closed."
    }
    /// Installed games of this environment's Steam libraries on the external disk.
    public func library() throws -> LibraryScan {
        try storage.validate()
        let prefix = try prefix()
        guard FileManager.default.fileExists(atPath: prefix.path) else { return LibraryScan() }
        return SteamLibraryScanner.scan(prefix: prefix, storageRoot: storage.root)
    }
    public func status() throws -> SessionStatus {
        try storage.validate()
        return SessionProbe.status(prefix: try prefix())
    }
}
