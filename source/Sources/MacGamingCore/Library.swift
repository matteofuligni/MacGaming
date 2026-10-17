// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// Valve KeyValues text format (libraryfolders.vdf, appmanifest_*.acf). Keys keep file order and are
/// matched case-insensitively, as Steam does.
public indirect enum KeyValues: Equatable {
    case value(String)
    case object([(key: String, value: KeyValues)])

    public static func == (lhs: KeyValues, rhs: KeyValues) -> Bool {
        switch (lhs, rhs) {
        case let (.value(a), .value(b)): return a == b
        case let (.object(a), .object(b)): return a.elementsEqual(b) { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }
    public subscript(key: String) -> KeyValues? {
        guard case let .object(entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    public var string: String? { if case let .value(text) = self { return text }; return nil }
    public var entries: [(key: String, value: KeyValues)] { if case let .object(items) = self { return items }; return [] }

    /// Parses a document and returns its single root pair, e.g. ("AppState", {...}).
    public static func parse(_ text: String) throws -> (key: String, value: KeyValues) {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        guard let key = try parser.token(), case let .text(name) = key else { throw Failure("Empty or invalid Steam file.") }
        let value = try parser.value()
        return (name, value)
    }

    private enum Token: Equatable { case text(String), open, close }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func value() throws -> KeyValues {
            switch try token() {
            case let .text(text)?: return .value(text)
            case .open?:
                var items: [(key: String, value: KeyValues)] = []
                while true {
                    switch try token() {
                    case .close?: return .object(items)
                    case let .text(key)?: items.append((key, try value()))
                    case .open?: throw Failure("Invalid Steam file: block without a key.")
                    case nil: throw Failure("Incomplete Steam file: unclosed block.")
                    }
                }
            case .close?: throw Failure("Invalid Steam file: unexpected closing brace.")
            case nil: throw Failure("File Steam incompleto: valore mancante.")
            }
        }

        mutating func token() throws -> Token? {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.isWhitespace { index += 1; continue }
                if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                // Platform conditionals such as [$WIN32] follow a value; they do not apply to these files.
                if scalar == "[" {
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1; continue
                }
                break
            }
            guard index < scalars.count else { return nil }
            let scalar = scalars[index]
            if scalar == "{" { index += 1; return .open }
            if scalar == "}" { index += 1; return .close }
            var text = String.UnicodeScalarView()
            if scalar == "\"" {
                index += 1
                while true {
                    guard index < scalars.count else { throw Failure("Incomplete Steam file: unterminated string.") }
                    let current = scalars[index]; index += 1
                    if current == "\"" { break }
                    if current == "\\", index < scalars.count {
                        let escaped = scalars[index]; index += 1
                        switch escaped {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default: text.append(escaped)
                        }
                    } else {
                        text.append(current)
                    }
                }
            } else {
                while index < scalars.count {
                    let current = scalars[index]
                    if current.properties.isWhitespace || current == "{" || current == "}" || current == "\"" { break }
                    text.append(current); index += 1
                }
            }
            return .text(String(text))
        }
    }
}

public struct InstalledGame: Identifiable, Equatable, Sendable {
    public var id: String { appID }
    public let appID: String
    public let name: String
    public let installDirectory: URL
    public let stateFlags: UInt64
    public let sizeOnDisk: Int64
    public let buildID: String

    /// Steam's EAppState bits, as written to appmanifest StateFlags.
    public var isReady: Bool { stateFlags & 4 != 0 && stateFlags & (2 | 256 | 512 | 1024 | 2048) == 0 }
    public var status: String {
        if stateFlags & 2048 != 0 { return "Uninstalling" }
        if stateFlags & (256 | 1024 | 1_048_576 | 2_097_152 | 4_194_304) != 0 { return "Downloading" }
        if stateFlags & 512 != 0 { return "Download paused" }
        if stateFlags & 2 != 0 { return "Update required" }
        if stateFlags & 4 != 0 { return "Installed" }
        return "Incomplete installation"
    }
}

public struct LibraryScan: Sendable {
    public var games: [InstalledGame] = []
    /// Problems that did not stop the scan: unreadable manifests, libraries outside the data folder.
    public var warnings: [String] = []
    public init() {}
}

enum SteamLibraryScanner {
    /// Steam tools that appear as appmanifests but are not games.
    static let hiddenAppIDs: Set<String> = ["228980"]

    static func scan(prefix: URL, storageRoot: URL) -> LibraryScan {
        var result = LibraryScan()
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        var libraries = [steam]
        for name in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            let file = steam.appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            do {
                let root = try KeyValues.parse(text).value
                for (_, folder) in root.entries {
                    guard let windowsPath = folder["path"]?.string else { continue }
                    guard let url = macURL(forWindowsPath: windowsPath, prefix: prefix) else {
                        result.warnings.append("Unrecognised Steam library: \(windowsPath)"); continue
                    }
                    let canonicalRoot = storageRoot.resolvingSymlinksInPath().path + "/"
                    guard url.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) else {
                        result.warnings.append("Steam library outside the external drive, ignored: \(windowsPath)"); continue
                    }
                    if !libraries.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) { libraries.append(url) }
                }
            } catch {
                result.warnings.append("\(name): \(error.localizedDescription)")
            }
            break
        }
        for library in libraries {
            let steamapps = library.appendingPathComponent("steamapps")
            guard let files = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                do {
                    let state = try KeyValues.parse(String(contentsOf: file, encoding: .utf8)).value
                    guard let appID = state["appid"]?.string, !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let installDir = state["installdir"]?.string, !installDir.isEmpty,
                          !installDir.contains("/"), !installDir.contains("\\"), installDir != ".." else {
                        result.warnings.append("\(file.lastPathComponent): missing or invalid fields."); continue
                    }
                    if hiddenAppIDs.contains(appID) { continue }
                    result.games.append(InstalledGame(
                        appID: appID, name: state["name"]?.string ?? "AppID \(appID)",
                        installDirectory: steamapps.appendingPathComponent("common").appendingPathComponent(installDir),
                        stateFlags: UInt64(state["StateFlags"]?.string ?? "") ?? 0,
                        sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? "") ?? 0,
                        buildID: state["buildid"]?.string ?? ""))
                } catch {
                    // Steam rewrites manifests while it downloads: a partial file is skipped, not fatal.
                    result.warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        var seen = Set<String>()
        result.games = result.games.filter { seen.insert($0.appID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// Maps "C:\\Program Files (x86)\\Steam" or "D:\\Games" through the prefix's dosdevices links.
    static func macURL(forWindowsPath path: String, prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":"), drive.first!.isLetter,
              !parts.dropFirst().contains("..") else { return nil }
        var url = prefix.appendingPathComponent("dosdevices").appendingPathComponent(drive.lowercased()).resolvingSymlinksInPath()
        for part in parts.dropFirst() { url.appendPathComponent(part) }
        return url.standardizedFileURL
    }
}
