// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import SwiftUI
import AppKit
import MacGamingCore

@main
struct MacGamingApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("MacGaming") {
            ContentView(model: model).environment(\.locale, Model.locale)
        }
        .defaultSize(width: 820, height: 760)
    }
}

/// A restore the user picked from a game's menu, waiting for confirmation.
struct PendingRestore: Identifiable {
    let game: InstalledGame
    let backup: SaveBackup
    var id: String { game.appID + "/" + backup.id }
}

@MainActor
final class Model: ObservableObject {
    /// The interface is English whatever the Mac's language.
    static let locale = Locale(identifier: "en_US")

    @Published var translation: CPUTranslation = .fex { didSet { games = []; warnings = []; status = nil; backups = [:]; compatibility = [:]; profiles = [:]; selectedGame = nil; refresh() } }
    @Published var output = "Connect the external drive and check the environment to get started."
    @Published var busy = false
    @Published var appID = ""
    @Published var games: [InstalledGame] = []
    @Published var warnings: [String] = []
    @Published var status: SessionStatus?
    @Published var backups: [String: [SaveBackup]] = [:]
    @Published var compatibility: [String: Compatibility] = [:]
    @Published var pendingRestore: PendingRestore?
    @Published var performanceOverlay = false
    @Published var profiles: [String: GameProfile] = [:]
    @Published var selectedGame: InstalledGame?
    private let watcher = SaveWatcher()

    func perform(_ action: @escaping (Engine) throws -> String) {
        guard !busy else { return }
        busy = true
        let engine = Engine(translation: translation)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                do { return try action(engine) } catch { return "Error: \(error.localizedDescription)" }
            }.value
            output = result; busy = false
            refresh()
        }
    }
    /// Reads the library, the session state and the save backups of the selected environment; never starts anything.
    func refresh() {
        let selected = translation
        let engine = Engine(translation: selected)
        Task {
            let (scan, status, backups, compatibility, overlay, profiles) = await Task.detached(priority: .utility) {
                () -> (LibraryScan, SessionStatus?, [String: [SaveBackup]], [String: Compatibility], Bool, [String: GameProfile]) in
                var scan: LibraryScan
                do { scan = try engine.library() }
                catch {
                    var failed = LibraryScan(); failed.warnings = [error.localizedDescription]
                    return (failed, nil, [:], [:], false, [:])
                }
                var backups: [String: [SaveBackup]] = [:]
                var compatibility: [String: Compatibility] = [:]
                var profiles: [String: GameProfile] = [:]
                for game in scan.games {
                    backups[game.appID] = try? engine.saveBackups(appID: game.appID)
                    compatibility[game.appID] = try? engine.compatibility(for: game)
                    do { profiles[game.appID] = try engine.profile(appID: game.appID) }
                    catch { scan.warnings.append("Profile for \(game.name): \(error.localizedDescription)") }
                }
                return (scan, try? engine.status(), backups, compatibility, (try? engine.performanceOverlayEnabled()) ?? false, profiles)
            }.value
            guard selected == translation else { return }
            games = scan.games; warnings = scan.warnings; self.status = status; self.backups = backups
            self.compatibility = compatibility
            performanceOverlay = overlay; self.profiles = profiles
        }
    }
    /// Backs up, in every environment, the saves games wrote since their last backup.
    func watchSaves() {
        let watcher = watcher
        Task {
            let made = await Task.detached(priority: .utility) { () -> [String] in
                CPUTranslation.allCases.flatMap { watcher.poll(Engine(translation: $0)) }
            }.value
            guard !made.isEmpty else { return }
            output = made.joined(separator: "\n")
            refresh()
        }
    }
    /// Closes Windows Steam if needed, then puts the chosen backup back.
    func restore(_ pending: PendingRestore) {
        let appID = pending.game.appID, backupID = pending.backup.id
        perform { engine in
            var lines: [String] = []
            if (try? engine.status())?.isRunning == true { lines.append(try engine.stop()) }
            lines.append(try engine.restoreSaves(appID: appID, backupID: backupID))
            return lines.joined(separator: "\n")
        }
    }
    static func describe(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 38)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacGaming").font(.largeTitle.bold())
                    Text("Windows Steam on your Mac · version 0.1").foregroundStyle(.secondary)
                }
                Spacer()
                Text("ALPHA").font(.caption.bold()).padding(8).background(.teal.opacity(0.12), in: Capsule())
            }
            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Data on the external drive").font(.headline)
                        Text("Runtimes, Steam, games, saves, caches and logs stay in your registered data folder.")
                            .foregroundStyle(.secondary)
                        Text("If the drive is not connected, nothing starts.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(7)
            }
            HStack {
                Picker("Engine", selection: $model.translation) {
                    ForEach(CPUTranslation.allCases, id: \.self) { Text($0.label).tag($0) }
                }.frame(maxWidth: 420).disabled(model.busy)
                StatusBadge(status: model.status)
                Spacer()
                Button("Check") { model.perform { try $0.doctor() } }
            }
            HStack {
                Button("1. Prepare Steam") { model.perform { try $0.installSteam() } }
                Button("2. Open Windows Steam") { model.perform { try $0.launchSteam() } }.buttonStyle(.borderedProminent).tint(.teal)
                Spacer()
                Button("Stop Environment") { model.perform { try $0.stop() } }
            }.disabled(model.busy)
            HStack(spacing: 12) {
                Toggle("FPS Overlay", isOn: Binding(get: { model.performanceOverlay }, set: { enabled in
                    model.perform { try $0.setPerformanceOverlay(enabled: enabled) }
                }))
                .toggleStyle(.switch).fixedSize().disabled(model.busy)
                Text("Shows FPS and frame times. Restart Windows Steam to apply.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            LibraryView(model: model)
            HStack {
                TextField("AppID of an installed game", text: $model.appID).frame(width: 230)
                Button("Launch Game") {
                    let id = model.appID
                    model.perform { try $0.launchSteam(appID: id) }
                }.disabled(model.appID.isEmpty || model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text("Working…").font(.caption) }
            }
            ScrollView {
                Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(minHeight: 70, maxHeight: 130)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Sign in with the official Steam client. Games are verified one at a time.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Data Folder") { NSWorkspace.shared.open(Storage().root) }
            }
        }.padding(28).frame(minWidth: 760, minHeight: 700)
            .onAppear { model.perform { try $0.doctor() } }
            .task {
                // Steam's registry state reaches disk with some delay: a slow poll is enough.
                while !Task.isCancelled {
                    model.refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    model.watchSaves()
                }
            }
            .sheet(item: $model.selectedGame) { game in
                GameDetailView(model: model, game: game)
            }
            .confirmationDialog(
                model.pendingRestore.map { "Restore saves of \($0.game.name)?" } ?? "",
                isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.pendingRestore = nil } }),
                titleVisibility: .visible, presenting: model.pendingRestore
            ) { pending in
                Button("Restore") { model.restore(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("""
                The saves from \(Model.describe(pending.backup.createdAt)) will be put back. Windows Steam is closed first, \
                and the current saves are backed up so this can be undone. When Steam starts again, Steam Cloud may ask \
                which version to keep.
                """)
            }
    }
}

struct StatusBadge: View {
    let status: SessionStatus?
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(status?.label ?? "Status unknown").font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
    private var color: Color {
        switch status?.phase {
        case .steamReady?: return .green
        case .playing?: return .teal
        case .loginRequired?, .environmentRunning?: return .orange
        case .stopped?, nil: return .gray
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: Model
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if model.games.isEmpty {
                    Text(emptyMessage).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.games) { game in
                                GameRow(game: game, backups: model.backups[game.appID] ?? [],
                                        compatibility: model.compatibility[game.appID], busy: model.busy) {
                                    model.perform { try $0.launchSteam(appID: game.appID) }
                                } restore: { backup in
                                    model.pendingRestore = PendingRestore(game: game, backup: backup)
                                } showDetails: {
                                    model.selectedGame = game
                                }
                                if game != model.games.last { Divider() }
                            }
                        }
                    }.frame(minHeight: 70, maxHeight: 220)
                }
                ForEach(model.warnings.prefix(2), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(7)
        } label: {
            HStack {
                Text("Installed Games").font(.headline)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh library and status")
            }
        }
    }
    private var emptyMessage: String {
        switch model.status?.phase {
        case .loginRequired?: return "Sign in to Windows Steam, then install a game from its library: it will show up here."
        case .steamReady?, .playing?: return "No games installed in this environment. Install one from Windows Steam's library: it will show up here."
        default: return "No games installed in this environment. Open Windows Steam, sign in and install a game from its library."
        }
    }
}

struct GameRow: View {
    let game: InstalledGame
    let backups: [SaveBackup]
    let compatibility: Compatibility?
    let busy: Bool
    let play: () -> Void
    let restore: (SaveBackup) -> Void
    let showDetails: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(game.name).font(.headline)
                    if let compatibility { CompatibilityBadge(compatibility: compatibility) }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Details", action: showDetails).disabled(busy)
            Menu("Restore Saves") {
                ForEach(backups.prefix(12), id: \.id) { backup in
                    Button("\(Model.describe(backup.createdAt)) · \(backup.reason.rawValue) · \(backup.files.count) files") {
                        restore(backup)
                    }
                }
            }
            .fixedSize()
            .disabled(backups.isEmpty || busy)
            .help(backups.isEmpty ? "No local save backups yet: they are made automatically when the game saves." : "Put back a local copy of the saves.")
            Button("Play", action: play).disabled(!game.isReady || busy)
        }.padding(.vertical, 8)
    }
    private var details: String {
        var parts = ["AppID \(game.appID)", game.status]
        if game.sizeOnDisk > 0 { parts.append(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)) }
        if let latest = backups.first {
            parts.append("last save backup \(latest.createdAt.formatted(.relative(presentation: .named).locale(Model.locale)))")
        }
        return parts.joined(separator: " · ")
    }
}

struct CompatibilityBadge: View {
    let compatibility: Compatibility
    var body: some View {
        Text(compatibility.label + (compatibility.pendingChecks.isEmpty ? "" : " · \(compatibility.pendingChecks.count) pending"))
            .font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .help(tooltip)
    }
    private var color: Color {
        switch compatibility.state {
        case .verified: return .green
        case .experimental: return .teal
        case .needsRecheck: return .orange
        case .blocked: return .red
        case .untested: return .gray
        }
    }
    private var tooltip: String {
        var lines: [String] = []
        if let reason = compatibility.reason { lines.append(reason) }
        if !compatibility.pendingChecks.isEmpty { lines.append("Pending: " + compatibility.pendingChecks.joined(separator: "; ")) }
        return lines.isEmpty ? compatibility.label : lines.joined(separator: "\n")
    }
}
