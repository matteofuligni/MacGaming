// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

struct WebHelperWrapperManifest: Codable {
    var schemaVersion: Int
    var path: String
    var sha256: String
    var flags: String
}

/// Steam's browser paints a black window on Wine for macOS unless it runs in a single process, and
/// Steam has no option for that any more. MacGaming puts its wrapper (source/wrapper) in place of
/// steamwebhelper.exe; the wrapper starts Valve's helper, kept as steamwebhelper_real.exe, with the flags.
enum WebHelperWrapper {
    static let realName = "steamwebhelper_real.exe"
    /// Steam's bootstrapper checks file sizes at every start and would put Valve's helper back
    /// before the browser starts. Steam updates still replace it; install() then adopts the new one.
    static let steamArguments = ["-noverifyfiles", "-norepairfiles"]
    /// Every wrapper build carries this marker; the first one, already installed, did not.
    static let marker = Data("MACGAMING-STEAMWEBHELPER-WRAPPER".utf8)
    static let unmarkedDigests: Set<String> = ["79200f5b011dfda0c4e5b626e9dea2bf3ea8e6860e7cf18eefccecde8fac73e2"]

    /// Any version of MacGaming's wrapper. Valve's helper is several megabytes and is never read whole.
    static func isWrapper(_ url: URL) throws -> Bool {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 2_000_000 else { return false }
        let data = try Data(contentsOf: url)
        return try data.range(of: marker) != nil || unmarkedDigests.contains(Runner.sha256(url))
    }

    /// Installs the verified wrapper in every bin/cef/cef.win* folder. Only while Steam is closed:
    /// the helper is in use otherwise. Returns how many folders changed.
    @discardableResult
    static func install(storage: Storage, steamDirectory: URL) throws -> Int {
        let manifestURL = try storage.path("manifests/steamwebhelper-wrapper.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Failure("The steamwebhelper wrapper is not built: run source/build.sh wrapper.")
        }
        let manifest = try JSONDecoder().decode(WebHelperWrapperManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.sha256.count == 64 else { throw Failure("Invalid steamwebhelper wrapper manifest.") }
        let wrapper = try storage.path(manifest.path)
        guard FileManager.default.fileExists(atPath: wrapper.path), try Runner.sha256(wrapper) == manifest.sha256 else {
            throw Failure("steamwebhelper wrapper missing or modified. Rebuild it with source/build.sh wrapper.")
        }
        let fm = FileManager.default
        let cef = steamDirectory.appendingPathComponent("bin/cef")
        guard let folders = try? fm.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil) else { return 0 }
        var changed = 0
        for folder in folders where folder.lastPathComponent.hasPrefix("cef.win") {
            let helper = folder.appendingPathComponent("steamwebhelper.exe")
            let real = folder.appendingPathComponent(realName)
            guard fm.fileExists(atPath: helper.path) else { continue }
            let current = try Runner.sha256(helper) == manifest.sha256
            let ours = try current || isWrapper(helper)
            if ours && !fm.fileExists(atPath: real.path) {
                throw Failure("\(realName) is missing in \(folder.lastPathComponent): have Steam verify its files.")
            }
            if current { continue }
            // Stage the copy first so that a failure never leaves the folder without a steamwebhelper.exe.
            let staged = folder.appendingPathComponent("steamwebhelper.macgaming-new")
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: wrapper, to: staged)
            if ours {
                // An older wrapper: replace it, Valve's helper stays where it is.
                try fm.removeItem(at: helper)
            } else {
                // Valve's helper, first install or brought by a Steam update: it becomes the real one.
                if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
                try fm.moveItem(at: helper, to: real)
            }
            try fm.moveItem(at: staged, to: helper)
            changed += 1
        }
        return changed
    }

    /// Puts Valve's helper back where the wrapper is installed. Only while Steam is closed.
    @discardableResult
    static func remove(storage: Storage, steamDirectory: URL) throws -> Int {
        let fm = FileManager.default
        let manifestURL = try storage.path("manifests/steamwebhelper-wrapper.json")
        let currentDigest = (try? JSONDecoder().decode(WebHelperWrapperManifest.self, from: Data(contentsOf: manifestURL)))?.sha256
        guard let folders = try? fm.contentsOfDirectory(at: steamDirectory.appendingPathComponent("bin/cef"), includingPropertiesForKeys: nil) else { return 0 }
        var changed = 0
        for folder in folders where folder.lastPathComponent.hasPrefix("cef.win") {
            let helper = folder.appendingPathComponent("steamwebhelper.exe")
            let real = folder.appendingPathComponent(realName)
            guard fm.fileExists(atPath: real.path) else { continue }
            if fm.fileExists(atPath: helper.path) {
                // A helper that is not the wrapper is Valve's, newer than the copy kept aside.
                guard try Runner.sha256(helper) == currentDigest || isWrapper(helper) else { try fm.removeItem(at: real); continue }
                try fm.removeItem(at: helper)
            }
            try fm.moveItem(at: real, to: helper)
            changed += 1
        }
        return changed
    }
}
