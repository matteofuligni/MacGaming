// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import Foundation
import MacGamingCore

let arguments = Array(CommandLine.arguments.dropFirst())
// ARM64/FEX is the default; --fex is still accepted and changes nothing.
let translation: CPUTranslation = arguments.contains("--rosetta") ? .rosetta : .fex
let filtered = arguments.filter { $0 != "--fex" && $0 != "--rosetta" && $0 != "--debug" }
let engine = Engine(translation: translation)
do {
    if arguments.contains("--fex") && arguments.contains("--rosetta") {
        throw Failure("Choose one environment: --rosetta, or no option for ARM64/FEX.")
    }
    switch filtered.first ?? "help" {
    case "register-storage":
        guard filtered.count == 2, filtered[1].hasPrefix("/") else { throw Failure("Usage: macgaming register-storage ABSOLUTE-DATA-FOLDER") }
        print(try Storage.register(root: URL(fileURLWithPath: filtered[1])))
    case "doctor": print(try engine.doctor())
    case "prepare": print(try engine.prepare())
    case "install-steam": print(try engine.installSteam())
    case "install-dxmt": print(try engine.installDXMT())
    case "dxmt-enable", "dxmt-disable":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming \(filtered[0]) APPID --rosetta") }
        print(try engine.setDXMT(appID: filtered[1], enabled: filtered[0] == "dxmt-enable"))
    case "steam":
        print(arguments.contains("--debug") ? try engine.restartSteamForDiagnostics() : try engine.launchSteam())
    case "hud":
        if filtered.count == 1 {
            print("FPS overlay: \(try engine.performanceOverlayEnabled() ? "on" : "off"). Restart Windows Steam after changing this setting.")
        } else {
            guard filtered.count == 2, ["on", "off"].contains(filtered[1]) else { throw Failure("Usage: macgaming hud [on|off] [--rosetta]") }
            print(try engine.setPerformanceOverlay(enabled: filtered[1] == "on"))
        }
    case "launch":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming launch APPID [--rosetta]") }
        print(try engine.launchSteam(appID: filtered[1]))
    case "install":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming install APPID [--rosetta]") }
        print(try engine.requestInstall(appID: filtered[1]))
    case "copy-game":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming copy-game APPID [--rosetta] (copies from the other environment)") }
        print(try engine.copyGame(appID: filtered[1]))
    case "backup":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming backup APPID [--rosetta]") }
        print(try engine.backupSaves(appID: filtered[1]))
    case "backups":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming backups APPID [--rosetta]") }
        let backups = try engine.saveBackups(appID: filtered[1])
        if backups.isEmpty { print("No save backups for AppID \(filtered[1]).") }
        for backup in backups {
            let size = ByteCountFormatter.string(fromByteCount: backup.totalBytes, countStyle: .file)
            print("\(backup.id)\t\(backup.reason.rawValue)\t\(backup.files.count) files\t\(size)")
        }
    case "restore":
        guard filtered.count == 2 || filtered.count == 3 else { throw Failure("Usage: macgaming restore APPID [BACKUP] [--rosetta]") }
        print(try engine.restoreSaves(appID: filtered[1], backupID: filtered.count == 3 ? filtered[2] : nil))
    case "games":
        let scan = try engine.library()
        if scan.games.isEmpty { print("No games installed in this environment.") }
        for game in scan.games {
            let size = game.sizeOnDisk > 0 ? ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file) : "—"
            let compatibility = (try? engine.compatibility(for: game))?.label ?? "Not tested"
            print("\(game.appID)\t\(game.name)\t\(game.status)\t\(size)\t\(compatibility)")
        }
        for warning in scan.warnings { FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8)) }
    case "mtld3d-enable", "mtld3d-disable", "vkd3d-enable", "vkd3d-disable":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming \(filtered[0]) APPID") }
        let renderer: HadronRenderer = filtered[0].hasPrefix("mtld3d") ? .mtld3d : .vkd3d
        print(try engine.setRenderer(renderer, appID: filtered[1], enabled: filtered[0].hasSuffix("-enable")))
    case "modeset":
        guard filtered.count == 3, ["on", "off"].contains(filtered[2]) else { throw Failure("Usage: macgaming modeset APPID on|off [--rosetta]") }
        print(try engine.setEmulatedModeset(appID: filtered[1], enabled: filtered[2] == "on"))
    case "override":
        guard filtered.count == 4, ["on", "off"].contains(filtered[3]) else { throw Failure("Usage: macgaming override APPID DLL on|off [--rosetta]") }
        print(try engine.setDLLOverride(appID: filtered[1], dll: filtered[2], enabled: filtered[3] == "on"))
    case "disable-file", "enable-file":
        guard filtered.count == 3 else { throw Failure("Usage: macgaming \(filtered[0]) APPID PATH-IN-GAME-FOLDER [--rosetta]") }
        print(try engine.setGameFileDisabled(appID: filtered[1], path: filtered[2], disabled: filtered[0] == "disable-file"))
    case "run":
        guard filtered.count >= 2 else { throw Failure("Usage: macgaming run PATH.exe [ARGS...] [--rosetta]") }
        print(try engine.runProgram(filtered[1], arguments: Array(filtered.dropFirst(2))))
    case "profile":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming profile APPID [--rosetta]") }
        print(try engine.profileReport(appID: filtered[1]))
    case "configurations":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming configurations APPID") }
        let selected = try engine.selectedConfigurationID(appID: filtered[1])
        for choice in try engine.configurationChoices(appID: filtered[1]) {
            print("\(choice.id)\t\(choice.name)\t\(choice.profile.status.rawValue)" + (selected == choice.id ? "\tselected" : ""))
        }
    case "configuration":
        guard filtered.count == 3 else { throw Failure("Usage: macgaming configuration APPID CONFIGURATION-ID") }
        print(try engine.selectConfiguration(appID: filtered[1], configurationID: filtered[2]))
    case "configuration-create":
        guard filtered.count == 3, let renderer = RendererKind(rawValue: filtered[2]) else { throw Failure("Usage: macgaming configuration-create APPID dxmt|mtld3d|vkd3d|wine") }
        print(try engine.createConfiguration(appID: filtered[1], renderer: renderer))
    case "configuration-arguments":
        guard filtered.count >= 2 else { throw Failure("Usage: macgaming configuration-arguments APPID [ARGUMENTS...]") }
        print(try engine.updateConfigurationArguments(appID: filtered[1], arguments: Array(filtered.dropFirst(2))))
    case "configuration-recover":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming configuration-recover APPID") }
        print(try engine.recoverConfiguration(appID: filtered[1]))
    case "diagnostics":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming diagnostics APPID") }
        print(try engine.diagnosticsReport(appID: filtered[1]))
    case "diagnostics-export":
        guard filtered.count == 2 else { throw Failure("Usage: macgaming diagnostics-export APPID") }
        print(try engine.exportDiagnostics(appID: filtered[1]).path)
    case "check":
        guard filtered.count >= 4, let result = ProfileCheck.Result(rawValue: filtered[2]) else {
            throw Failure("Usage: macgaming check APPID passed|failed|pending \"CHECK NAME\" [NOTES] [--rosetta]")
        }
        let notes = filtered.count > 4 ? filtered[4...].joined(separator: " ") : nil
        print(try engine.recordCheck(appID: filtered[1], name: filtered[3], result: result, notes: notes))
    case "mark":
        guard filtered.count == 3, let status = EngineProfile.Status(rawValue: filtered[2]) else {
            throw Failure("Usage: macgaming mark APPID verified|experimental|blocked [--rosetta]")
        }
        print(try engine.markProfile(appID: filtered[1], status: status))
    case "status":
        let status = try engine.status()
        print(status.label + (status.wineserverPID.map { " (wineserver PID \($0))" } ?? ""))
    case "stop": print(try engine.stop())
    case "help", "--help", "-h":
        print("MacGaming 0.1\nCommands: register-storage PATH, doctor, prepare, install-steam, steam [--debug], hud [on|off] (FPS overlay; restart Steam to apply), install APPID, copy-game APPID, games, launch APPID, backup APPID, backups APPID, restore APPID [BACKUP], profile APPID, configurations APPID, configuration APPID ID, configuration-create APPID RENDERER, configuration-arguments APPID [ARGS...], configuration-recover APPID, diagnostics APPID, diagnostics-export APPID, check APPID RESULT NAME [NOTES], mark APPID STATUS, modeset APPID on|off, override APPID DLL on|off, disable-file/enable-file APPID PATH, mtld3d-enable/-disable APPID (Direct3D 9), vkd3d-enable/-disable APPID (Direct3D 12), run PATH.exe, status, stop\nDefault environment: ARM64/FEX (Hadron), the only one that renders Direct3D 11 games today (Hadron's DXMT)\n--rosetta: Intel/Rosetta environment (Steam yes, Direct3D 11 games no) · --fex: accepted, already the default\nDXMT for Rosetta (loads but does not render yet), with --rosetta: install-dxmt, dxmt-enable APPID, dxmt-disable APPID\nAll project data lives on the external drive.")
    default: throw Failure("Unknown command. Use macgaming --help.")
    }
} catch {
    FileHandle.standardError.write(Data("MacGaming: \(error.localizedDescription)\n".utf8))
    exit(1)
}
