// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
// Standalone trial guard: it NEVER launches a game and only signals its identified catalog target.
import Foundation
import Darwin
import Dispatch

struct GuardFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
let gib: UInt64 = 1_073_741_824

struct Usage {
    let footprint: UInt64
    let resident: UInt64
    let start: UInt64
    let cpuAbsoluteTicks: UInt64
    let readBytes: UInt64
    let writtenBytes: UInt64
}
struct Identity: Equatable {
    let pid: Int32
    let start: UInt64
}
struct Arguments {
    var argv: [String]
    var environment: [String: String]
}
enum ProcessReader {
    static func isZombie(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var count = MemoryLayout<kinfo_proc>.size
        let result = withUnsafeMutablePointer(to: &info) {
            sysctl(&mib, UInt32(mib.count), $0, &count, nil, 0)
        }
        // Darwin SZOMB: an exited process can still answer kill(pid, 0), but has no argv.
        // proc_pidinfo returns ESRCH for a zombie on this macOS; KERN_PROC_PID retains it.
        return result == 0 && count == MemoryLayout<kinfo_proc>.size && info.kp_proc.p_stat == 5
    }
    static func cpuTimebase() throws -> mach_timebase_info_data_t {
        var value = mach_timebase_info_data_t()
        guard mach_timebase_info(&value) == KERN_SUCCESS, value.numer > 0, value.denom > 0 else {
            throw GuardFailure("Cannot read the CPU timebase.")
        }
        return value
    }
    static func usage(_ pid: Int32) throws -> Usage {
        var value = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &value) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0, value.ri_proc_start_abstime > 0 else {
            throw GuardFailure("Cannot measure PID \(pid): \(String(cString: strerror(errno)))")
        }
        return Usage(footprint: value.ri_phys_footprint, resident: value.ri_resident_size,
                     start: value.ri_proc_start_abstime, cpuAbsoluteTicks: value.ri_user_time + value.ri_system_time,
                     readBytes: value.ri_diskio_bytesread, writtenBytes: value.ri_diskio_byteswritten)
    }
    static func pids() throws -> [Int32] {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { throw GuardFailure("Cannot enumerate processes; the guard is not armed.") }
        var values = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.size + 256)
        let count = values.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw GuardFailure("Cannot enumerate processes; the guard is not armed.") }
        return Array(values.prefix(Int(count) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }
    static func path(_ pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        return count > 0 ? String(cString: bytes) : nil
    }
    static func arguments(_ pid: Int32) throws -> Arguments {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &count, nil, 0) == 0, count > 4, count < 4 * 1024 * 1024 else {
            throw GuardFailure("Cannot inspect PID \(pid) arguments; run the guard from an ordinary local Terminal.")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &count, nil, 0) }
        guard result == 0 else { throw GuardFailure("Cannot inspect PID \(pid) arguments.") }
        return try parseArguments(Array(bytes.prefix(count)))
    }
    static func parseArguments(_ bytes: [UInt8]) throws -> Arguments {
        guard bytes.count >= 5 else { throw GuardFailure("Invalid process argument buffer.") }
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard argc > 0, argc < 8192 else { throw GuardFailure("Invalid process argument count.") }
        var index = 4
        func string() throws -> String {
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { throw GuardFailure("Truncated process argument buffer.") }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        _ = try string() // native executable path
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<argc { argv.append(try string()) }
        var environment: [String: String] = [:]
        while index < bytes.count {
            let entry = try string()
            if entry.isEmpty { continue }
            if let equals = entry.firstIndex(of: "=") {
                let name = String(entry[..<equals])
                // Do not retain unrelated environment variables or account secrets.
                if name == "WINEPREFIX" { environment[name] = String(entry[entry.index(after: equals)...]) }
            }
        }
        return Arguments(argv: argv, environment: environment)
    }
}

enum TrialGame: String {
    case horizon = "1151640", hogwarts = "990080"
    var name: String { self == .horizon ? "Horizon" : "Hogwarts Legacy" }
    var logName: String { self == .horizon ? "horizon" : "hogwarts" }
    func matchesExecutable(_ argument: String) -> Bool {
        let path = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
        if self == .horizon { return path.split(separator: "/").last == "horizonzerodawn.exe" }
        // The launcher has the same basename; bind only the actual game under Phoenix.
        return path.hasSuffix("/phoenix/binaries/win64/hogwartslegacy.exe")
    }
}

struct Target {
    let root: URL
    var game: TrialGame = .horizon
    var prefix: String { root.appendingPathComponent("prefixes/steam-fex").path }
    var runtimeRoot: String { root.appendingPathComponent("runtimes").path + "/" }
    func matches(nativePath: String, arguments: Arguments) -> Bool {
        guard nativePath.hasPrefix(runtimeRoot),
              let first = arguments.argv.first,
              game.matchesExecutable(first),
              let winePrefix = arguments.environment["WINEPREFIX"] else { return false }
        return URL(fileURLWithPath: winePrefix).standardizedFileURL.resolvingSymlinksInPath().path == prefix
    }
    func matches(_ identity: Identity) -> Bool {
        guard let usage = try? ProcessReader.usage(identity.pid), usage.start == identity.start,
              let path = ProcessReader.path(identity.pid), let args = try? ProcessReader.arguments(identity.pid) else { return false }
        return matches(nativePath: path, arguments: args)
    }
    func find() throws -> Identity? {
        var matches: [Identity] = []
        for pid in try ProcessReader.pids() {
            guard let path = ProcessReader.path(pid), path.hasPrefix(runtimeRoot) else { continue }
            let args: Arguments
            do { args = try ProcessReader.arguments(pid) }
            catch {
                if ProcessReader.isZombie(pid) { continue }
                if kill(pid, 0) == 0 { throw error }
                continue
            }
            if self.matches(nativePath: path, arguments: args), let usage = try? ProcessReader.usage(pid) {
                matches.append(Identity(pid: pid, start: usage.start))
            }
        }
        guard matches.count <= 1 else { throw GuardFailure("Multiple instances of the selected game found. Close them before arming the trial.") }
        return matches.first
    }
}

struct Policy {
    let footprintLimit: UInt64
    let durationLimit: Double
    func stopReason(footprint: UInt64, seconds: Double, criticalPressure: Bool) -> String? {
        if criticalPressure { return "critical_system_memory_pressure" }
        if footprint >= footprintLimit { return "footprint_limit" }
        if seconds >= durationLimit { return "trial_time_limit" }
        return nil
    }
}
final class Signals {
    private let lock = NSLock()
    private var critical = false
    private var cancelled = false
    private let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .global())
    private let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    private let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    init() {
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        memory.setEventHandler { [weak self] in
            guard let self else { return }; self.lock.lock(); self.critical = true; self.lock.unlock()
        }
        interrupt.setEventHandler { [weak self] in
            guard let self else { return }; self.lock.lock(); self.cancelled = true; self.lock.unlock()
        }
        terminate.setEventHandler { [weak self] in
            guard let self else { return }; self.lock.lock(); self.cancelled = true; self.lock.unlock()
        }
        memory.resume(); interrupt.resume(); terminate.resume()
    }
    var state: (critical: Bool, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }; return (critical, cancelled)
    }
}

struct StorageRegistration: Decodable { var schemaVersion: Int; var volumeUUID: String }
func validateRoot(_ root: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { throw GuardFailure("Connect the MacGaming external drive. Nothing was started.") }
    let marker = root.appendingPathComponent("manifests/storage.json")
    let registration = try JSONDecoder().decode(StorageRegistration.self, from: Data(contentsOf: marker))
    let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsInternalKey])
    guard registration.schemaVersion == 1, values.volumeIsInternal == false,
          values.volumeUUIDString?.uppercased() == registration.volumeUUID.uppercased() else {
        throw GuardFailure("The data folder is not on its registered external volume.")
    }
}

final class TrialLog {
    let directory: URL
    private let handle: FileHandle
    init(root: URL, policy: Policy, game: TrialGame) throws {
        directory = root.appendingPathComponent("logs/" + game.logName + "-trial-" + UUID().uuidString)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw GuardFailure("The log directory points outside the external data folder.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.ndjson")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw GuardFailure("Cannot create the external trial log.") }
        handle = try FileHandle(forWritingTo: file)
        let timebase = try ProcessReader.cpuTimebase()
        try event("armed", values: ["footprintLimitBytes": policy.footprintLimit, "durationLimitSeconds": policy.durationLimit,
                                     "cpuTimebaseNumerator": timebase.numer, "cpuTimebaseDenominator": timebase.denom,
                                     "sampleIntervalSeconds": 1, "gameAppID": game.rawValue, "guardPID": getpid()])
    }
    deinit { try? handle.close() }
    func event(_ name: String, values: [String: Any] = [:]) throws {
        var data = values
        data["event"] = name; data["timeUTC"] = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) + Data([10]))
    }
    func state(_ name: String, values: [String: Any] = [:]) throws {
        var data = values; data["state"] = name; data["updatedAtUTC"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}

/// Verifies identity before EVERY signal, including forced termination. Never signals a process group.
@discardableResult
func stopOnly(_ identity: Identity, verify: (Identity) -> Bool, grace: Double = 3) -> (signalled: Bool, forced: Bool) {
    guard verify(identity), kill(identity.pid, SIGTERM) == 0 else { return (false, false) }
    let deadline = ProcessInfo.processInfo.systemUptime + grace
    while ProcessInfo.processInfo.systemUptime < deadline {
        if !verify(identity) { return (true, false) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard verify(identity) else { return (true, false) }
    return (true, kill(identity.pid, SIGKILL) == 0)
}

func preflight() throws {
    _ = try ProcessReader.cpuTimebase()
    _ = try ProcessReader.usage(getpid())
    guard try ProcessReader.pids().contains(getpid()), !(try ProcessReader.arguments(getpid()).argv).isEmpty else {
        throw GuardFailure("Process inspection is unavailable. Do not start the trial with this guard.")
    }
}

func monitor(root: URL, game: TrialGame = .horizon) throws {
    try validateRoot(root); try preflight()
    let descriptor = open(root.appendingPathComponent("manifests/." + game.logName + "-memory-guard.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw GuardFailure("Cannot open the guard lock.") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw GuardFailure("Another guard for this game is already armed.") }
    let policy = Policy(footprintLimit: min(24 * gib, ProcessInfo.processInfo.physicalMemory / 2), durationLimit: 15 * 60)
    let target = Target(root: root, game: game)
    // Check access to existing Wine processes before claiming that the guard is armed.
    _ = try target.find()
    let signals = Signals()
    let log = try TrialLog(root: root, policy: policy, game: game)
    let waitingSince = ProcessInfo.processInfo.systemUptime
    var bound: Identity?
    var gameSince = waitingSince
    var peak: UInt64 = 0
    print("ARMED: \(game.name) only, \(Double(policy.footprintLimit) / Double(gib)) GiB maximum charged footprint, 15 minutes maximum monitored session.")
    print("Start \(game.name) within 30 minutes. Logs: \(log.directory.path)")
    fflush(stdout)
    try log.state("armed", values: ["guardPID": getpid(), "startWithinSeconds": 1800])
    do {
        while true {
            try validateRoot(root)
            let now = ProcessInfo.processInfo.systemUptime
            let flags = signals.state
            if bound == nil {
                if flags.cancelled || now - waitingSince >= 1800 {
                    try log.event("waiting_ended"); try log.state("not_started"); return
                }
                bound = try target.find()
                if let identity = bound {
                    gameSince = now
                    try log.event("game_detected", values: ["pid": identity.pid, "startToken": identity.start])
                    try log.state("monitoring", values: ["pid": identity.pid])
                    print("Monitoring \(game.name) PID \(identity.pid)."); fflush(stdout)
                }
            }
            if let identity = bound {
                let usage: Usage
                do { usage = try ProcessReader.usage(identity.pid) }
                catch {
                    if kill(identity.pid, 0) != 0 && errno == ESRCH {
                        try log.event("game_exited", values: ["peakFootprintBytes": peak]); try log.state("exited"); return
                    }
                    throw error
                }
                guard usage.start == identity.start, target.matches(identity) else {
                    throw GuardFailure("The monitored PID identity changed. No other process will be signalled.")
                }
                peak = max(peak, usage.footprint)
                let elapsed = now - gameSince
                try log.event("sample", values: ["pid": identity.pid, "elapsedSeconds": elapsed,
                    "footprintBytes": usage.footprint, "residentBytes": usage.resident, "peakFootprintBytes": peak,
                    "cpuAbsoluteTicks": usage.cpuAbsoluteTicks, "diskReadBytes": usage.readBytes, "diskWrittenBytes": usage.writtenBytes])
                let reason = flags.cancelled ? "guard_cancelled" : policy.stopReason(footprint: usage.footprint, seconds: elapsed, criticalPressure: flags.critical)
                if let reason {
                    // Logging failure must never prevent the safety action.
                    try? log.event("stopping", values: ["reason": reason, "footprintBytes": usage.footprint])
                    let result = stopOnly(identity, verify: target.matches)
                    try log.event("stop_requested", values: ["reason": reason, "termSent": result.signalled, "killSent": result.forced])
                    Thread.sleep(forTimeInterval: 0.3)
                    let stillRunning = (try? ProcessReader.usage(identity.pid).start) == identity.start
                    try log.state(stillRunning ? "stop_unconfirmed" : "stopped", values: ["reason": reason, "peakFootprintBytes": peak])
                    print(stillRunning ? "STOP NOT CONFIRMED: close \(game.name) manually." : "\(game.name) stopped: \(reason). Steam was not signalled.")
                    fflush(stdout)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    } catch {
        // A lost disk or unreadable metric must not leave a previously identified game unprotected.
        if let identity = bound {
            _ = stopOnly(identity, verify: target.matches)
        }
        try? log.event("guard_error", values: ["message": error.localizedDescription])
        try? log.state("error", values: ["message": error.localizedDescription])
        throw error
    }
}

func selfTest() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw GuardFailure("Self-test failed: " + message) }; checks += 1
    }
    let policy = Policy(footprintLimit: 24 * gib, durationLimit: 900)
    try check(policy.stopReason(footprint: 24 * gib - 1, seconds: 899, criticalPressure: false) == nil, "below thresholds")
    try check(policy.stopReason(footprint: 24 * gib, seconds: 0, criticalPressure: false) == "footprint_limit", "memory boundary")
    try check(policy.stopReason(footprint: 1, seconds: 900, criticalPressure: false) == "trial_time_limit", "time boundary")
    try check(policy.stopReason(footprint: 1, seconds: 0, criticalPressure: true) == "critical_system_memory_pressure", "system pressure")
    let target = Target(root: URL(fileURLWithPath: "/Volumes/Fixture/Project"))
    let wine = target.runtimeRoot + "hadron/dist/bin/wine"
    let matching = Arguments(argv: ["C:\\Games\\HorizonZeroDawn.exe"], environment: ["WINEPREFIX": target.prefix])
    try check(target.matches(nativePath: wine, arguments: matching), "exact game and prefix")
    try check(!target.matches(nativePath: wine, arguments: Arguments(argv: ["C:\\Steam\\steam.exe"], environment: matching.environment)), "Steam excluded")
    try check(!target.matches(nativePath: wine, arguments: Arguments(argv: ["C:\\Games\\HellbladeGame.exe"], environment: matching.environment)), "other game excluded")
    try check(!target.matches(nativePath: wine, arguments: Arguments(argv: matching.argv, environment: ["WINEPREFIX": target.prefix + "-other"])), "other prefix excluded")
    try check(!target.matches(nativePath: "/usr/bin/true", arguments: matching), "unrelated native process excluded")
    let hogwarts = Target(root: target.root, game: .hogwarts)
    let hogwartsPath = "C:/Steam/steamapps/common/Hogwarts Legacy/Phoenix/Binaries/Win64/HogwartsLegacy.exe"
    try check(hogwarts.matches(nativePath: wine, arguments: Arguments(argv: [hogwartsPath], environment: matching.environment)), "Hogwarts game included")
    try check(!hogwarts.matches(nativePath: wine, arguments: Arguments(argv: ["C:/Steam/steamapps/common/Hogwarts Legacy/HogwartsLegacy.exe"], environment: matching.environment)), "Hogwarts launcher excluded")
    try check(!hogwarts.matches(nativePath: wine, arguments: matching), "Horizon excluded from Hogwarts guard")
    try check(!target.matches(nativePath: wine, arguments: Arguments(argv: [hogwartsPath], environment: matching.environment)), "Hogwarts excluded from Horizon guard")
    try check(!hogwarts.matches(nativePath: wine, arguments: Arguments(argv: [hogwartsPath], environment: ["WINEPREFIX": target.prefix + "-other"])), "Hogwarts wrong prefix excluded")
    var bytes: [UInt8] = [2, 0, 0, 0]
    bytes += Array("/native/wine\0\0HorizonZeroDawn.exe\0argument\0WINEPREFIX=/prefix\0SECRET=not-retained\0\0".utf8)
    let parsed = try ProcessReader.parseArguments(bytes)
    try check(parsed.argv == ["HorizonZeroDawn.exe", "argument"], "kernel arguments parsed")
    try check(parsed.environment == ["WINEPREFIX": "/prefix"], "secrets not retained")
    var truncatedRejected = false
    do { _ = try ProcessReader.parseArguments([1, 0, 0, 0, 65]) }
    catch { truncatedRejected = true }
    try check(truncatedRejected, "truncated arguments rejected")
    try preflight(); checks += 1
    try check(!ProcessReader.isZombie(getpid()), "live process is not mistaken for an exited zombie")
    guard let fixturePath = Bundle.main.executableURL?.path else { throw GuardFailure("Cannot locate fixture binary.") }
    var exitedChild: pid_t = 0
    let spawned = fixturePath.withCString { path in
        "--fixture-exit".withCString { option in
            var argv = [UnsafeMutablePointer(mutating: path), UnsafeMutablePointer(mutating: option), nil]
            // The disposable child only exits. It needs no inherited user environment,
            // and an explicit empty vector avoids a toolchain-specific environ symbol.
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            return argv.withUnsafeMutableBufferPointer { arguments in
                environment.withUnsafeMutableBufferPointer {
                    posix_spawn(&exitedChild, path, nil, nil, arguments.baseAddress!, $0.baseAddress!)
                }
            }
        }
    }
    guard spawned == 0 else { throw GuardFailure("Cannot spawn disposable zombie fixture.") }
    var childStatus: Int32 = 0
    let zombieDeadline = ProcessInfo.processInfo.systemUptime + 2
    while !ProcessReader.isZombie(exitedChild) && ProcessInfo.processInfo.systemUptime < zombieDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    let zombieObserved = ProcessReader.isZombie(exitedChild)
    _ = waitpid(exitedChild, &childStatus, 0)
    try check(zombieObserved, "exited child with unavailable arguments identified as zombie")
    try check(!ProcessReader.isZombie(exitedChild), "reaped child is not a live target")
    let own = try ProcessReader.usage(getpid())
    try check(own.footprint > 0 && own.start > 0, "native footprint and identity available")
    let process = Process()
    guard let binary = Bundle.main.executableURL else { throw GuardFailure("Cannot locate self-test binary.") }
    process.executableURL = binary; process.arguments = ["--fixture"]
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let identity = Identity(pid: process.processIdentifier, start: try ProcessReader.usage(process.processIdentifier).start)
    let rejected = stopOnly(Identity(pid: identity.pid, start: identity.start &+ 1), verify: { $0 == identity }, grace: 0.1)
    try check(!rejected.signalled && process.isRunning, "reused or wrong PID identity never signalled")
    let stopped = stopOnly(identity, verify: { candidate in
        guard candidate == identity, process.isRunning, let current = try? ProcessReader.usage(candidate.pid) else { return false }
        return current.start == candidate.start
    }, grace: 1)
    process.waitUntilExit()
    try check(stopped.signalled && !process.isRunning, "only the disposable child is stopped")
    let stubborn = Process()
    stubborn.executableURL = binary; stubborn.arguments = ["--fixture-ignore-term"]
    let ready = Pipe(); stubborn.standardOutput = ready
    try stubborn.run()
    defer {
        if stubborn.isRunning { kill(stubborn.processIdentifier, SIGKILL); stubborn.waitUntilExit() }
    }
    guard let acknowledgement = try ready.fileHandleForReading.read(upToCount: 1), !acknowledgement.isEmpty else {
        throw GuardFailure("The disposable child did not acknowledge readiness.")
    }
    let stubbornIdentity = Identity(pid: stubborn.processIdentifier, start: try ProcessReader.usage(stubborn.processIdentifier).start)
    let forced = stopOnly(stubbornIdentity, verify: { candidate in
        guard candidate == stubbornIdentity, stubborn.isRunning, let current = try? ProcessReader.usage(candidate.pid) else { return false }
        return current.start == candidate.start
    }, grace: 0.2)
    stubborn.waitUntilExit()
    try check(forced.signalled && forced.forced && !stubborn.isRunning, "unresponsive disposable child terminated after identity recheck")
    print("PASS: \(checks) safety checks. Only disposable child processes were terminated. No game was launched.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--fixture-exit"] { exit(0) }
    if arguments == ["--fixture"] { Thread.sleep(forTimeInterval: 20); exit(0) }
    if arguments == ["--fixture-ignore-term"] {
        signal(SIGTERM, SIG_IGN)
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        Thread.sleep(forTimeInterval: 20); exit(0)
    }
    if arguments == ["--self-test"] { try selfTest(); exit(0) }
    guard [2, 4].contains(arguments.count), arguments[0] == "--root", arguments[1].hasPrefix("/") else {
        throw GuardFailure("Usage: game-memory-guard --root ABSOLUTE-EXTERNAL-DATA-FOLDER [--game 1151640|990080] | --self-test")
    }
    var game = TrialGame.horizon
    if arguments.count == 4 {
        guard arguments[2] == "--game", let selected = TrialGame(rawValue: arguments[3]) else {
            throw GuardFailure("Only catalog games 1151640 and 990080 are supported.")
        }
        game = selected
    }
    let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    try monitor(root: root, game: game)
} catch {
    FileHandle.standardError.write(Data(("Game guard: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
