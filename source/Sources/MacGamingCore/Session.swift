// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import Darwin

public struct SessionStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case stopped
        case environmentRunning      // wineserver up, Steam not reported
        case loginRequired
        case steamReady
        case playing(appID: String)
    }
    public var phase: Phase
    public var wineserverPID: Int32?

    public var label: String {
        switch phase {
        case .stopped: return "Stopped"
        case .environmentRunning: return "Environment running"
        case .loginRequired: return "Steam open · sign-in required"
        case .steamReady: return "Steam signed in"
        case let .playing(appID): return "Playing · AppID \(appID)"
        }
    }
    public var isRunning: Bool { phase != .stopped }
}

enum SessionProbe {
    /// Wine keeps one wineserver per prefix, in /tmp/.wine-<uid>/server-<dev>-<inode>, and holds a write
    /// lock on its "lock" file while alive. F_GETLK only reads that lock: nothing is sent to the server.
    static func wineserverPID(prefix: URL) -> Int32? {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return nil }
        let lockPath = "/tmp/.wine-\(getuid())/server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))/lock"
        let descriptor = Darwin.open(lockPath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var query = flock()
        query.l_type = Int16(F_WRLCK); query.l_whence = Int16(SEEK_SET); query.l_start = 0; query.l_len = 0
        guard fcntl(descriptor, F_GETLK, &query) == 0, query.l_type != Int16(F_UNLCK), query.l_pid > 0 else { return nil }
        return query.l_pid
    }

    /// Reads Steam's own state from HKCU as wineserver last saved it (Wine flushes the registry
    /// periodically, so this can lag behind by some seconds). Only meaningful while wineserver runs.
    static func status(prefix: URL) -> SessionStatus {
        guard let pid = wineserverPID(prefix: prefix) else { return SessionStatus(phase: .stopped, wineserverPID: nil) }
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) else {
            return SessionStatus(phase: .environmentRunning, wineserverPID: pid)
        }
        // Steam's registry keys outlive a crash or a forced stop: trust them only while steam.exe runs.
        guard steamRunning(prefix: prefix) else { return SessionStatus(phase: .environmentRunning, wineserverPID: pid) }
        let steam = registryValues(in: text, section: "Software\\\\Valve\\\\Steam")
        let active = registryValues(in: text, section: "Software\\\\Valve\\\\Steam\\\\ActiveProcess")
        guard let steamPID = dword(active["pid"]), steamPID != 0 else { return SessionStatus(phase: .environmentRunning, wineserverPID: pid) }
        if let running = dword(steam["RunningAppID"]), running != 0 { return SessionStatus(phase: .playing(appID: String(running)), wineserverPID: pid) }
        let loggedIn = (dword(active["ActiveUser"]) ?? 0) != 0
        return SessionStatus(phase: loggedIn ? .steamReady : .loginRequired, wineserverPID: pid)
    }

    /// Whether a steam.exe of this prefix is alive. Wine rewrites a process's argv[0] to its Windows
    /// path; the prefix comes from the WINEPREFIX in its environment (both read with KERN_PROCARGS2).
    static func steamRunning(prefix: URL) -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return false }
        let wanted = "WINEPREFIX=" + prefix.path
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard let (arguments, environment) = processArguments(pid), let first = arguments.first,
                  first.lowercased().hasSuffix("\\steam.exe") || first.lowercased().hasSuffix("/steam.exe") else { continue }
            if environment.contains(wanted) { return true }
        }
        return false
    }

    static func processArguments(_ pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // executable path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        func next() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        // argv may hold empty strings: Wine rewrites it in place with its shorter Windows command line.
        var arguments: [String] = []
        while arguments.count < argc, let argument = next() { arguments.append(argument) }
        guard argc >= 0, arguments.count == argc else { return nil }
        while index < size && buffer[index] == 0 { index += 1 }
        var environment: [String] = []
        while let variable = next(), !variable.isEmpty { environment.append(variable) }
        return (arguments, environment)
    }

    static func registryValues(in text: String, section: String) -> [String: String] {
        var values: [String: String] = [:]
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                if inside { break }
                // Header form: [Software\\Valve\\Steam] 1792020361
                inside = line.hasPrefix("[\(section)]")
                continue
            }
            guard inside, line.hasPrefix("\""), let separator = line.range(of: "\"=") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            values[key] = String(line[separator.upperBound...])
        }
        return values
    }

    static func dword(_ raw: String?) -> UInt32? {
        guard let raw, raw.hasPrefix("dword:") else { return nil }
        return UInt32(raw.dropFirst(6), radix: 16)
    }
}
