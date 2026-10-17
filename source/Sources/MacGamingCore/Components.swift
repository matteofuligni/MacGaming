// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation

/// A pinned add-on for a Wine runtime (DXMT), unpacked from a release archive whose digest is recorded here.
public struct ComponentManifest: Codable {
    public struct File: Codable, Equatable {
        public var path: String          // inside the archive and below installPath
        public var sha256: String
    }
    /// A DLL copied into system32/syswow64. "native": without Wine's builtin marker, so only programs with an
    /// override load it. "builtin": unchanged; Wine 11 loads a builtin only through a copy in the prefix, then
    /// takes the real DLL and its Unix side from WINEDLLPATH.
    public struct PrefixDLL: Codable, Equatable {
        public var source: String        // one of files
        public var destination: String   // relative to the prefix
        public var machine: String       // "x86_64" or "i386"
        public var kind: String          // "native" or "builtin"
        public var sha256: String        // digest of the copy written to the prefix
    }
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var license: String
    public var sourceURL: String
    public var archiveURL: String
    public var archive: String
    public var archiveSHA256: String
    public var installPath: String
    /// Directory added to WINEDLLPATH: Wine finds builtin DLLs missing from its own tree here (winemetal).
    public var dllPath: String
    /// Runtimes ("id version") the component was checked against.
    public var runtimes: [String]
    /// Links inside installPath to libraries of the runtime's Unix folder (path → file name): winemetal.so
    /// needs @rpath/winemac.so and @rpath/ntdll.so next to itself, as inside Wine's own tree.
    public var runtimeLibraries: [String: String]
    public var files: [File]
    public var prefixDLLs: [PrefixDLL]
    /// DLLs set to native,builtin for each game executable.
    public var gameOverrides: [String]
    /// Symbol that winemac.so must export for DXMT to attach a Metal layer to a window.
    public var metalBridgeExport: String
    public var status: String

    public static func load(_ id: String, storage: Storage) throws -> ComponentManifest {
        let url = try storage.path("manifests/component-\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("Component manifest \(id) missing.") }
        let manifest = try JSONDecoder().decode(ComponentManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        func relative(_ path: String) -> Bool {
            !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("-") && !path.contains(":") && !path.contains("\\")
                && !path.split(separator: "/").contains("..") && !path.split(separator: "/").contains(".")
        }
        func digest(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
        guard schemaVersion == 1 else { throw Failure("Unsupported version of manifest \(id).") }
        guard digest(archiveSHA256), [archive, installPath, dllPath].allSatisfy(relative),
              archive.hasPrefix("downloads/"), installPath.hasPrefix("runtimes/"), dllPath.hasPrefix(installPath + "/") || dllPath == installPath,
              !files.isEmpty, files.allSatisfy({ relative($0.path) && digest($0.sha256) }),
              Set(files.map(\.path)).count == files.count else {
            throw Failure("Invalid manifest \(id): paths or digests.")
        }
        let digests = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sha256) })
        for dll in prefixDLLs {
            let folder = dll.machine == "x86_64" ? "drive_c/windows/system32/" : "drive_c/windows/syswow64/"
            guard WinePE.Machine(rawValue: dll.machine) != nil, let original = digests[dll.source], digest(dll.sha256),
                  dll.kind == "native" ? dll.sha256 != original : dll.kind == "builtin" && dll.sha256 == original,
                  relative(dll.destination), dll.destination.hasPrefix(folder),
                  !dll.destination.dropFirst(folder.count).contains("/"), dll.destination.lowercased().hasSuffix(".dll") else {
                throw Failure("Invalid manifest \(id): DLL \(dll.destination).")
            }
        }
        let dllFolder = dllPath == installPath ? "" : String(dllPath.dropFirst(installPath.count + 1)) + "/"
        guard runtimeLibraries.allSatisfy({ relative($0.key) && $0.key.hasPrefix(dllFolder) && digests[$0.key] == nil
                                            && !$0.value.isEmpty && !$0.value.contains("/") && $0.value != ".." }) else {
            throw Failure("Invalid manifest \(id): runtime links.")
        }
        guard !gameOverrides.isEmpty, gameOverrides.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") } }),
              metalBridgeExport.hasPrefix("_") else {
            throw Failure("Invalid manifest \(id): override or symbol.")
        }
    }
}

/// An add-on unpacked under runtimes/ on the external disk.
public struct Component {
    public let manifest: ComponentManifest
    public let storage: Storage
    /// Link path → destination, relative so that it survives a different mount point.
    public let links: [String: String]

    public init(id: String, runtime: RuntimeManifest, storage: Storage) throws {
        manifest = try ComponentManifest.load(id, storage: storage)
        self.storage = storage
        guard manifest.runtimes.contains("\(runtime.id) \(runtime.version)") else {
            throw Failure("\(id) \(manifest.version) has not been verified with \(runtime.id) \(runtime.version).")
        }
        let installDepth = manifest.installPath.split(separator: "/").count
        links = manifest.runtimeLibraries.reduce(into: [:]) { result, link in
            let up = String(repeating: "../", count: installDepth + link.key.split(separator: "/").count - 1)
            result[link.key] = up + runtime.unixLibraryDirectory + "/" + link.value
        }
    }
    public func installRoot() throws -> URL { try storage.path(manifest.installPath) }
    public func file(_ relative: String) throws -> URL { try storage.path(manifest.installPath + "/" + relative) }
    public var isUnpacked: Bool { (try? storage.path(manifest.dllPath)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Checks every unpacked file against the manifest; extra files or links are refused too.
    public func verifyUnpacked() throws { try Component.verify(directory: installRoot(), files: manifest.files, links: links) }

    static func verify(directory: URL, files: [ComponentManifest.File], links: [String: String] = [:]) throws {
        let fm = FileManager.default
        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.sha256) })
        var seen = Set<String>()
        guard let walk = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure("Component folder unreadable: \(directory.path)")
        }
        let base = directory.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let relative = String((url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent).dropFirst(base.count))
            if values.isSymbolicLink == true {
                guard let destination = links[relative], (try? fm.destinationOfSymbolicLink(atPath: url.path)) == destination,
                      fm.fileExists(atPath: url.path) else { throw Failure("Unexpected or broken link in the component: \(relative)") }
                seen.insert(relative); continue
            }
            guard values.isRegularFile == true else { continue }
            guard let digest = expected[relative] else { throw Failure("Unexpected file in the component: \(relative)") }
            guard try Runner.sha256(url) == digest else { throw Failure("Component file modified: \(relative)") }
            seen.insert(relative)
        }
        if let missing = (Array(expected.keys) + Array(links.keys)).sorted().first(where: { !seen.contains($0) }) {
            throw Failure("Component file missing: \(missing)")
        }
    }

    /// Unpacks the verified archive into installPath, replacing a damaged copy. Nothing is downloaded here.
    public func unpack() throws {
        try storage.validate()
        let archive = try storage.path(manifest.archive)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw Failure("Archivio \(manifest.id) assente: scarica \(manifest.archiveURL) in \(manifest.archive).")
        }
        guard try Runner.sha256(archive) == manifest.archiveSHA256 else {
            throw Failure("Archive \(manifest.id) differs from the release pinned in the manifest. Download it again.")
        }
        let fm = FileManager.default
        let staging = try storage.path("tmp/\(manifest.id)-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // Only the listed members are extracted; tar refuses absolute and ".." member names.
        let result = try Runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path] + manifest.files.map(\.path),
                                    log: storage.path("logs/component-\(manifest.id)-unpack.log"), timeout: 120)
        guard result.exitCode == 0 else { throw Failure("Extraction of \(manifest.id) failed. \(result.text)") }
        try Component.verify(directory: staging, files: manifest.files)
        let destination = try installRoot()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            let old = try storage.path("tmp/\(manifest.id)-old-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: old)
            defer { try? fm.removeItem(at: old) }
            try fm.moveItem(at: staging, to: destination)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        for (path, target) in links { try fm.createSymbolicLink(atPath: destination.appendingPathComponent(path).path, withDestinationPath: target) }
        try verifyUnpacked()
    }
}

/// Reads the exported symbols of a Mach-O library without loading it (the runtime is x86_64, this process may not be).
public enum MachO {
    public static let x86_64: Int32 = 0x0100_0007
    public static let arm64: Int32 = 0x0100_000C

    /// Defined external symbols (what dlsym can find) of the slice for cpuType.
    public static func exportedSymbols(in data: Data, cpuType: Int32) throws -> Set<String> {
        let bytes = [UInt8](data)
        func be32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= bytes.count else { throw Failure("Libreria Mach-O troncata.") }
            return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func le32(_ at: Int) throws -> UInt32 { try be32(at).byteSwapped }
        func be64(_ at: Int) throws -> UInt64 { UInt64(try be32(at)) << 32 | UInt64(try be32(at + 4)) }

        var base = 0
        let magic = try be32(0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let wide = magic == 0xCAFE_BABF
            let count = Int(try be32(4))
            guard count <= 32 else { throw Failure("Invalid Mach-O library.") }
            var slice: Int?
            for index in 0..<count {
                let entry = 8 + index * (wide ? 32 : 20)
                if Int32(bitPattern: try be32(entry)) == cpuType {
                    slice = wide ? Int(clamping: try be64(entry + 8)) : Int(try be32(entry + 8))
                }
            }
            guard let slice else { throw Failure("The library does not contain the required architecture.") }
            base = slice
        }
        guard try le32(base) == 0xFEED_FACF else { throw Failure("Not a 64-bit Mach-O library.") }
        guard Int32(bitPattern: try le32(base + 4)) == cpuType else { throw Failure("The library is not for the required architecture.") }
        let commands = Int(try le32(base + 16))
        var cursor = base + 32
        for _ in 0..<commands {
            let command = try le32(cursor), size = Int(try le32(cursor + 4))
            guard size >= 8 else { throw Failure("Invalid Mach-O library.") }
            if command == 0x2 { // LC_SYMTAB
                let symbols = base + Int(try le32(cursor + 8)), count = Int(try le32(cursor + 12))
                let strings = base + Int(try le32(cursor + 16)), stringsSize = Int(try le32(cursor + 20))
                guard symbols + count * 16 <= bytes.count, strings + stringsSize <= bytes.count else { throw Failure("Libreria Mach-O troncata.") }
                var names = Set<String>()
                for index in 0..<count {
                    let entry = symbols + index * 16
                    let type = bytes[entry + 4]
                    // nlist_64: no debug entry (N_STAB), external (N_EXT), defined in a section (N_SECT).
                    guard type & 0xE0 == 0, type & 0x01 != 0, type & 0x0E == 0x0E else { continue }
                    var start = strings + Int(try le32(entry))
                    guard start < strings + stringsSize else { throw Failure("Invalid Mach-O library.") }
                    var name: [UInt8] = []
                    while start < strings + stringsSize, bytes[start] != 0 { name.append(bytes[start]); start += 1 }
                    names.insert(String(decoding: name, as: UTF8.self))
                }
                return names
            }
            cursor += size
        }
        throw Failure("The library has no symbol table.")
    }
}

/// Wine marks its own PE DLLs as builtin in the DOS stub; such a file in system32 is always replaced by the
/// copy in Wine's own tree. Clearing the marker turns the DXMT DLL into a native one that overrides can select.
public enum WinePE {
    public enum Machine: String { case x86_64, i386
        var code: UInt16 { self == .x86_64 ? 0x8664 : 0x014C }
    }
    static let builtinSignature = Array("Wine builtin DLL".utf8) + [0]
    static let markerOffset = 0x40   // right after IMAGE_DOS_HEADER, where wineserver looks

    static func header(_ bytes: [UInt8]) throws -> (peOffset: Int, machine: UInt16) {
        guard bytes.count >= 0x60, bytes[0] == 0x4D, bytes[1] == 0x5A else { throw Failure("Not a Windows DLL.") }
        let peOffset = Int(bytes[0x3C]) | Int(bytes[0x3D]) << 8 | Int(bytes[0x3E]) << 16 | Int(bytes[0x3F]) << 24
        guard peOffset >= markerOffset + builtinSignature.count, peOffset + 6 <= bytes.count,
              bytes[peOffset..<peOffset + 4].elementsEqual([0x50, 0x45, 0, 0]) else { throw Failure("Invalid PE header.") }
        return (peOffset, UInt16(bytes[peOffset + 4]) | UInt16(bytes[peOffset + 5]) << 8)
    }
    public static func isWineBuiltin(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard (try? header(bytes)) != nil else { return false }
        return bytes[markerOffset..<markerOffset + builtinSignature.count].elementsEqual(builtinSignature)
    }
    /// The same DLL without the builtin marker; refuses a DLL for another architecture.
    public static func nativeCopy(of data: Data, machine: Machine) throws -> Data {
        var bytes = [UInt8](data)
        guard try header(bytes).machine == machine.code else { throw Failure("The DLL is not for \(machine.rawValue).") }
        if bytes[markerOffset..<markerOffset + builtinSignature.count].elementsEqual(builtinSignature) {
            bytes.replaceSubrange(markerOffset..<markerOffset + builtinSignature.count, with: repeatElement(0, count: builtinSignature.count))
        }
        return Data(bytes)
    }
}

public enum DXMTSupport {
    /// What winemetal.so (DXMT 0.80, _CreateMetalViewFromHWND) falls back to without the macdrv_functions table.
    static let fallbackSymbols = ["_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view", "_macdrv_view_get_metal_layer"]

    public struct MetalBridge: Equatable {
        public let available: Bool
        public let detail: String
    }

    public static func metalBridge(exports: Set<String>, required: String) -> MetalBridge {
        let table = String(required.dropFirst())
        if exports.contains(required) {
            return MetalBridge(available: true, detail: "winemac.so exports \(table): DXMT can attach a Metal layer to windows.")
        }
        if fallbackSymbols.allSatisfy(exports.contains) {
            return MetalBridge(available: false, detail: "winemac.so exports the macdrv functions but not \(table): since Wine 10 the macdrv_win_data layout is no longer the one DXMT reads.")
        }
        return MetalBridge(available: false, detail: "winemac.so does not export \(table) or the macdrv Metal functions: DXMT cannot create its Metal view, so D3D11 games are not rendered. It needs a Wine with a modified winemac.drv.")
    }

    public static func macDriver(of runtime: Runtime) throws -> URL {
        try runtime.storage.path(runtime.manifest.unixLibraryDirectory + "/winemac.so")
    }

    public static func metalBridge(runtime: Runtime, component: ComponentManifest) throws -> MetalBridge {
        let cpu = runtime.manifest.hostArchitecture == "arm64" ? MachO.arm64 : MachO.x86_64
        let exports = try MachO.exportedSymbols(in: Data(contentsOf: macDriver(of: runtime), options: .mappedIfSafe), cpuType: cpu)
        return metalBridge(exports: exports, required: component.metalBridgeExport)
    }

    /// Wine's +loaddll trace: `Loaded L"C:\\windows\\system32\\d3d11.dll" at 00006FFFF0000000: native`.
    /// Returns the lowercased file name and how it was loaded; the last load of a name wins.
    public static func loadedModules(in log: String) -> [String: String] {
        var modules: [String: String] = [:]
        for line in log.split(separator: "\n") {
            guard let start = line.range(of: "Loaded L\""), let end = line[start.upperBound...].firstIndex(of: "\""),
                  let kind = line.split(separator: " ").last, kind == "native" || kind == "builtin" else { continue }
            let path = line[start.upperBound..<end]
            let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
            if !name.isEmpty { modules[name] = String(kind) }
        }
        return modules
    }

    /// Images reported by DYLD_PRINT_LIBRARIES: `dyld[pid]: <UUID> /path/lib.so`.
    public static func loadedImages(in log: String) -> [String] {
        log.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("dyld["), let slash = line.firstIndex(of: "/") else { return nil }
            return String(line[slash...])
        }
    }
}

/// Per-program DLL overrides (HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides), so Steam keeps Wine's own DLLs.
public enum WineRegistry {
    static let appDefaults = "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults"

    public static func isSafeExecutableName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".exe") && name.count > 4 && name.count <= 200
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control || "\\/[]\"".unicodeScalars.contains($0) }
    }

    /// A .reg document that sets (value != nil) or deletes the overrides for each executable.
    public static func overridesDocument(executables: [String], dlls: [String], value: String?) throws -> String {
        if let bad = executables.first(where: { !isSafeExecutableName($0) }) {
            throw Failure("Executable name not valid for the registry: \(bad)")
        }
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for exe in executables {
            lines.append("[\(appDefaults)\\\(exe)\\DllOverrides]")
            for dll in dlls { lines.append("\"\(dll)\"=" + (value.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? "-")) }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// A .reg document that sets (value != nil) or deletes per-executable Wine settings under
    /// AppDefaults\\<exe>\\<subkey>, e.g. "X11 Driver" → EmulateModeset (read by win32u for every driver).
    public static func appSettingsDocument(executables: [String], subkey: String, values: [String: String?]) throws -> String {
        if let bad = executables.first(where: { !isSafeExecutableName($0) }) {
            throw Failure("Executable name not valid for the registry: \(bad)")
        }
        let safe: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || " -_".contains($0)) } }
        guard safe(subkey), values.keys.allSatisfy(safe) else { throw Failure("Invalid registry key or value name.") }
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for exe in executables {
            lines.append("[\(appDefaults)\\\(exe)\\\(subkey)]")
            for (name, value) in values.sorted(by: { $0.key < $1.key }) {
                lines.append("\"\(name)\"=" + (value.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? "-"))
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// regedit/reg import read UTF-16 with a byte order mark, like the files Windows writes.
    public static func encoded(_ document: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in document.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return data
    }

    /// Values of `reg query KEY`: "    name    REG_SZ    data".
    public static func stringValues(inQueryOutput text: String) -> [String: String] {
        var values: [String: String] = [:]
        // isNewline: "\r\n", which reg.exe writes in Hadron's Wine, is a single Character in Swift.
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("    ") {
            guard let type = line.range(of: "    REG_SZ    ") ?? line.range(of: "    REG_SZ") else { continue }
            let name = line[..<type.lowerBound].trimmingCharacters(in: .whitespaces)
            values[name.lowercased()] = String(line[type.upperBound...])
        }
        return values
    }
}

/// Windows executables of an installed game; installers and redistributables are skipped.
public enum GameExecutables {
    static let skippedFolders = ["redist", "installer", "directx", "vcredist", "dotnet", "prereq", "easyanticheat", "battleye"]
    static let skippedNames = ["unins", "setup", "redist", "crashhandler", "crashreport"]

    // Unreal games commonly put the renderer in <Game>/Binaries/Win64/<Game>-Shipping.exe,
    // one level below the bootstrap launcher. Its own AppDefaults must get the DLL overrides too.
    public static func find(in directory: URL, maxDepth: Int = 4) -> [String] {
        let base = directory.resolvingSymlinksInPath().path + "/"
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var names = Set<String>()
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            let depth = url.resolvingSymlinksInPath().path.dropFirst(base.count).split(separator: "/").count
            let lower = url.lastPathComponent.lowercased()
            if values.isSymbolicLink == true { if values.isDirectory == true { walk.skipDescendants() }; continue }
            if values.isDirectory == true {
                if depth >= maxDepth || skippedFolders.contains(where: lower.contains) { walk.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, lower.hasSuffix(".exe"), !skippedNames.contains(where: lower.contains),
                  WineRegistry.isSafeExecutableName(url.lastPathComponent) else { continue }
            names.insert(url.lastPathComponent)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
