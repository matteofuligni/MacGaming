// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import CryptoKit

public struct RuntimeManifest: Codable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var translation: CPUTranslation
    public var hostArchitecture: String
    public var sourceURL: String
    public var packageSHA256: String
    public var loader: String
    public var server: String
    public var loaderSHA256: String
    public var serverSHA256: String
    public var environment: [String: String]
    public var steamArguments: [String]
    public var status: String
    /// Add-ons with their own manifest (manifests/component-<id>.json); absent in older manifests.
    public var components: [String]?
    /// Whether Steam's browser starts through MacGaming's wrapper (WebHelper.swift); absent means yes.
    /// The wrapper's flags come from MACGAMING_WEBHELPER_FLAGS in `environment` when set.
    public var webHelperWrapper: Bool?
    /// Whether the loader has no Wine preloader, so MacGaming's library (source/preload) keeps each new
    /// process's executable range free; absent means no.
    public var imageReserve: Bool?

    /// Wine's Unix libraries next to the loader: <wine>/bin/wine → <wine>/lib/wine/<arch>-unix.
    public var unixLibraryDirectory: String {
        let wine = loader.split(separator: "/").dropLast(2).joined(separator: "/")
        return wine + "/lib/wine/" + (hostArchitecture == "arm64" ? "aarch64-unix" : "x86_64-unix")
    }
}

struct ImageReserveManifest: Codable {
    var schemaVersion: Int
    var path: String
    var sha256: String
}

public struct ProcessResult {
    public let exitCode: Int32
    public let text: String
    public let pid: Int32
}

public enum Runner {
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           directory: URL? = nil, log: URL, timeout: TimeInterval = 60,
                           detached: Bool = false) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        if detached { return ProcessResult(exitCode: 0, text: "Avviato PID \(process.processIdentifier)", pid: process.processIdentifier) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure("Operation timed out. Log: \(log.path)")
        }
        process.waitUntilExit()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, text: String(text.suffix(12000)), pid: process.processIdentifier)
    }
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct Runtime {
    public let manifest: RuntimeManifest
    public let storage: Storage
    public init(translation: CPUTranslation, storage: Storage) throws {
        try storage.validate()
        let url = try storage.path("manifests/runtime-\(translation.rawValue).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("The \(translation.name) runtime is not available on the external drive yet.")
        }
        manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
        self.storage = storage
        guard manifest.schemaVersion == 1, manifest.translation == translation,
              manifest.hostArchitecture == (translation == .fex ? "arm64" : "x86_64") else {
            throw Failure("Runtime manifest or architecture does not match the selected translation.")
        }
    }
    public func verify() throws {
        try storage.validate()
        for (path, expected) in [(manifest.loader, manifest.loaderSHA256), (manifest.server, manifest.serverSHA256)] {
            guard expected.count == 64, try Runner.sha256(storage.path(path)) == expected else {
                throw Failure("Runtime integrity check failed: \(path). Restore the verified release.")
            }
        }
        if manifest.translation == .rosetta {
            let result = try Runner.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"],
                                        log: storage.path("logs/rosetta-probe.log"), timeout: 10)
            guard result.exitCode == 0 else { throw Failure("Rosetta is not available. Select a verified ARM64/FEX runtime.") }
        }
    }
    public func environment(prefix: URL) throws -> [String: String] {
        // Inherit user session and system HOME; redirect only project-controlled caches and temporary files.
        let allowed = Set(["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "SECURITYSESSIONID"])
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let tmp = try storage.path("tmp").path
        env["WINEPREFIX"] = prefix.path; env["WINEARCH"] = "win64"; env["WINEDEBUG"] = "-all"
        env["TMPDIR"] = tmp + "/"; env["TMP"] = tmp; env["TEMP"] = tmp
        env["XDG_CACHE_HOME"] = try storage.path("cache").path
        env["XDG_CONFIG_HOME"] = try storage.path("cache/config").path
        env["WINESERVER"] = try storage.path(manifest.server).path
        env["WINELOADER"] = try storage.path(manifest.loader).path
        for (key, value) in manifest.environment { env[key] = value.replacingOccurrences(of: "${ROOT}", with: storage.root.path) }
        // Unpacked components only add builtin DLLs Wine lacks (winemetal); Wine's own tree is searched first.
        let dllPaths = try (manifest.components ?? []).map { try Component(id: $0, runtime: manifest, storage: storage) }
            .filter(\.isUnpacked).map { try storage.path($0.manifest.dllPath).path }
        if !dllPaths.isEmpty { env["WINEDLLPATH"] = dllPaths.joined(separator: ":") }
        // Wine passes its Unix environment to every process it creates, games started by Steam included.
        if manifest.imageReserve == true {
            let library = try imageReserveLibrary().path
            env["DYLD_INSERT_LIBRARIES"] = env["DYLD_INSERT_LIBRARIES"].map { library + ":" + $0 } ?? library
        }
        return env
    }
    /// The built library from manifests/image-reserve.json. dyld terminates any process whose inserted
    /// library is missing, so an absent or modified build stops here instead of in every Wine process.
    func imageReserveLibrary() throws -> URL {
        let manifestURL = try storage.path("manifests/image-reserve.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Failure("The image range library is not built: run source/build.sh preload.")
        }
        let reserve = try JSONDecoder().decode(ImageReserveManifest.self, from: Data(contentsOf: manifestURL))
        guard reserve.schemaVersion == 1, reserve.sha256.count == 64 else { throw Failure("Invalid image range library manifest.") }
        let library = try storage.path(reserve.path)
        guard FileManager.default.fileExists(atPath: library.path), try Runner.sha256(library) == reserve.sha256 else {
            throw Failure("Image range library missing or modified. Rebuild it with source/build.sh preload.")
        }
        return library
    }
    public func run(_ args: [String], prefix: URL, logName: String, timeout: TimeInterval = 60,
                    detached: Bool = false, useServer: Bool = false, overrides: [String: String] = [:]) throws -> ProcessResult {
        try storage.validate()
        return try Runner.run(storage.path(useServer ? manifest.server : manifest.loader), args,
                              environment: environment(prefix: prefix).merging(overrides) { $1 }, directory: prefix,
                              log: storage.path("logs/\(logName).log"), timeout: timeout, detached: detached)
    }
}
