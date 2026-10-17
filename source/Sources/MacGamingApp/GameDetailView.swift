// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
import SwiftUI
import AppKit
import MacGamingCore

struct GameDetailView: View {
    @ObservedObject var model: Model
    let game: InstalledGame
    @Environment(\.dismiss) private var dismiss
    @State private var argumentText = ""
    @State private var environmentText = ""
    @State private var diagnosticText = ""
    @State private var newCheck = ""
    @State private var dllName = ""
    private var profile: GameProfile? { model.profiles[game.appID] }
    private var entry: EngineProfile? { profile?.selectedEntry(for: model.translation) }
    private var choices: [ConfigurationChoice] { profile?.choices(for: model.translation) ?? [] }
    private var selectedID: String { profile?.selectedID(for: model.translation) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(game.name).font(.title2.bold())
                    Text("AppID \(game.appID) · build \(game.buildID) · \(model.translation.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let compatibility = model.compatibility[game.appID] { CompatibilityBadge(compatibility: compatibility) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configurationSection
                    if let entry {
                        if let limits = entry.limits, !limits.isEmpty {
                            GroupBox("Known limits") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in Text(limit).font(.callout) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        checksSection(entry)
                        advancedSection(entry)
                    }
                    diagnosticsSection
                }.padding(.trailing, 6)
            }
            Text(model.output).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            if model.busy { ProgressView().controlSize(.small) }
        }.padding(24).frame(width: 800, height: 720)
            .onAppear { loadArguments() }
            .onChange(of: selectedID) { _, _ in loadArguments(); diagnosticText = "" }
            .onChange(of: model.translation) { _, _ in dismiss() }
    }
    private var configurationSection: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                if !choices.isEmpty {
                    Picker("Use", selection: Binding(get: { selectedID }, set: { value in
                        model.perform { try $0.selectConfiguration(appID: game.appID, configurationID: value) }
                    })) {
                        ForEach(choices) { choice in
                            Text(choice.name + (choice.profile.recommended == true ? " · Recommended" : "") + " · " + choice.profile.status.rawValue.capitalized).tag(choice.id)
                        }
                    }.disabled(model.busy)
                    Text("The selected settings are applied when you press Play. Close any running game before changing configuration.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let entry {
                        Text(entry.renderer ?? "Default renderer").font(.callout)
                        Text("Test record: \(entry.runtimeID) \(entry.runtimeVersion) · game build \(entry.buildID) · \(entry.date)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No compatibility record yet. Create a candidate configuration and record your tests after playing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.translation == .fex {
                    Menu("Add Untested Configuration") {
                        ForEach(RendererKind.allCases, id: \.self) { renderer in
                            Button(renderer.label) { model.perform { try $0.createConfiguration(appID: game.appID, renderer: renderer) } }
                                .disabled(choices.contains { $0.id == renderer.rawValue })
                        }
                    }.disabled(model.busy)
                }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func checksSection(_ entry: EngineProfile) -> some View {
        GroupBox("Compatibility checks · selected configuration") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Record only tests you have performed. Reaching the menu does not complete a gameplay test.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entry.checks.enumerated()), id: \.offset) { _, check in
                    CheckEditor(check: check, busy: model.busy) { result, notes in
                        model.perform { try $0.recordCheck(appID: game.appID, name: check.name, result: result, notes: notes) }
                    }.id(selectedID + "/" + check.name)
                    Divider()
                }
                HStack {
                    TextField("New check name", text: $newCheck)
                    Button("Add Pending Check") {
                        let name = newCheck; newCheck = ""
                        model.perform { try $0.recordCheck(appID: game.appID, name: name, result: .pending, notes: nil) }
                    }.disabled(newCheck.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                HStack {
                    Button("Mark Verified") { model.perform { try $0.markProfile(appID: game.appID, status: .verified) } }
                        .disabled(model.busy || entry.checks.isEmpty || entry.checks.contains { $0.result != .passed })
                    Button("Mark Experimental") { model.perform { try $0.markProfile(appID: game.appID, status: .experimental) } }.disabled(model.busy)
                    Button("Mark Blocked") { model.perform { try $0.markProfile(appID: game.appID, status: .blocked) } }.disabled(model.busy)
                }
                Text("Verified requires all checks to pass on the current game build and runtime. Configuration results are independent.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private func advancedSection(_ entry: EngineProfile) -> some View {
        DisclosureGroup("Advanced settings") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Launch arguments · one argument per line").font(.caption)
                TextEditor(text: $argumentText).font(.system(.callout, design: .monospaced)).frame(height: 65).border(.quaternary)
                Button("Save Launch Arguments") {
                    let arguments = argumentText.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    model.perform { try $0.updateConfigurationArguments(appID: game.appID, arguments: arguments) }
                }.disabled(model.busy || entry.rendererKind == nil)
                Text("Environment · one KEY=VALUE per line (FEX_, DXMT_, MTLD3D_, VKD3D_, DXVK_, MESA_); Play restarts Steam with it")
                    .font(.caption)
                TextEditor(text: $environmentText).font(.system(.callout, design: .monospaced)).frame(height: 50).border(.quaternary)
                Button("Save Environment") {
                    var environment: [String: String] = [:]
                    for line in environmentText.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        environment[parts[0]] = parts.count == 2 ? parts[1] : ""
                    }
                    model.perform { try $0.updateConfigurationEnvironment(appID: game.appID, environment: environment) }
                }.disabled(model.busy || entry.rendererKind == nil)
                Toggle("Emulate display modes", isOn: Binding(get: { entry.emulateModeset ?? false }, set: { value in
                    model.perform { try $0.updateConfigurationModeset(appID: game.appID, enabled: value) }
                })).disabled(model.busy || entry.rendererKind == nil)
                Text("Changing settings resets this configuration's checks to pending. Existing game patches are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach((entry.dllOverrides ?? [:]).keys.sorted(), id: \.self) { dll in
                    HStack {
                        Text("\(dll) = \(entry.dllOverrides?[dll] ?? "default")").font(.caption.monospaced())
                        Spacer()
                        if !["d3d9", "d3d10", "d3d10core", "d3d11", "d3d12", "d3d12core", "dxgi"].contains(dll) {
                            Button("Remove Override") { model.perform { try $0.updateConfigurationDLL(appID: game.appID, dll: dll, enabled: false) } }.disabled(model.busy)
                        }
                    }
                }
                HStack {
                    TextField("Additional DLL name, e.g. dinput8", text: $dllName)
                    Button("Add Native DLL Override") {
                        let name = dllName; dllName = ""
                        model.perform { try $0.updateConfigurationDLL(appID: game.appID, dll: name, enabled: true) }
                    }.disabled(model.busy || dllName.isEmpty || entry.rendererKind == nil)
                }
                if let patches = entry.patches {
                    ForEach(Array(patches.enumerated()), id: \.offset) { _, patch in Text(patch).font(.caption).textSelection(.enabled) }
                }
                Button("Recover Interrupted Configuration Change") {
                    model.perform { try $0.recoverConfiguration(appID: game.appID) }
                }.disabled(model.busy)
            }.padding(.top, 8)
        }
    }
    private var diagnosticsSection: some View {
        DisclosureGroup("Diagnostic report") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview versions, configurations, checks and known limits. Account files, saves and raw logs are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Generate Preview") {
                    do { diagnosticText = try Engine(translation: model.translation).diagnosticsReport(appID: game.appID) }
                    catch { diagnosticText = "Error: " + error.localizedDescription }
                }.disabled(model.busy)
                if !diagnosticText.isEmpty {
                    Text(diagnosticText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.25))
                    Button("Export Report to External Drive") {
                        model.perform { engine in
                            let url = try engine.exportDiagnostics(appID: game.appID)
                            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            return "Diagnostic report exported to \(url.path)"
                        }
                    }.disabled(model.busy || diagnosticText.hasPrefix("Error:"))
                }
            }.padding(.top, 8)
        }
    }
    private func loadArguments() {
        argumentText = (entry?.launchArguments ?? []).joined(separator: "\n")
        environmentText = (entry?.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

private struct CheckEditor: View {
    let check: ProfileCheck
    let busy: Bool
    let save: (ProfileCheck.Result, String?) -> Void
    @State private var result: ProfileCheck.Result
    @State private var notes: String
    init(check: ProfileCheck, busy: Bool, save: @escaping (ProfileCheck.Result, String?) -> Void) {
        self.check = check; self.busy = busy; self.save = save
        _result = State(initialValue: check.result); _notes = State(initialValue: check.notes ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(check.name).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Picker("Result", selection: $result) {
                    Text("Pending").tag(ProfileCheck.Result.pending)
                    Text("Passed").tag(ProfileCheck.Result.passed)
                    Text("Failed").tag(ProfileCheck.Result.failed)
                }.labelsHidden().frame(width: 115)
                Button("Save") { save(result, notes.isEmpty ? nil : notes) }
                    .disabled(busy || (result == check.result && notes == (check.notes ?? "")))
            }
            TextField("Test notes", text: $notes, axis: .vertical).font(.caption).lineLimit(1...5)
        }.disabled(busy)
            .onChange(of: check) { _, updated in result = updated.result; notes = updated.notes ?? "" }
    }
}
