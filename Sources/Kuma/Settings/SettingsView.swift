import KumaCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, voice, personality, tools, heard, shortcuts
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            VoiceSettings(model: model)
                .tabItem { Label("Voice", systemImage: "waveform") }
                .tag(SettingsTab.voice)
            PersonalitySettings(model: model)
                .tabItem { Label("Personality", systemImage: "theatermasks") }
                .tag(SettingsTab.personality)
            ToolsSettings(model: model)
                .tabItem { Label("Tools", systemImage: "hammer") }
                .tag(SettingsTab.tools)
            HeardSettings(model: model)
                .tabItem { Label("Heard", systemImage: "ear") }
                .tag(SettingsTab.heard)
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
        }
        .frame(width: 560)
        .tint(KumaTheme.purple)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(get: { model.settings.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(modeExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let error = model.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }

    private var modeExplanation: String {
        switch model.settings.mode {
        case .enabled: return "Kuma speaks every briefing your session settings allow."
        case .dnd: return "Only high priority briefings are spoken, such as approvals, questions and errors. Everything still shows in the dashboard."
        case .disabled: return "Kuma stays silent. Sessions are still tracked in the dashboard."
        }
    }
}

private struct VoiceSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: Binding(get: { model.settings.voice }, set: { model.setVoice($0) })) {
                    ForEach(model.voices) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(get: { model.settings.speed }, set: { model.setSpeed($0) }), in: 0.6...1.6)
                        Text(String(format: "%.2fx", model.settings.speed))
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        model.testVoice()
                    } label: {
                        Label("Test voice", systemImage: "play.fill")
                    }
                    .disabled(!model.voiceReady)
                }
            }
            Section("Kokoro voice engine") {
                HStack(spacing: 10) {
                    Image(systemName: model.voiceReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(model.voiceReady ? .green : .orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.voiceReady ? "Installed and ready" : "Not installed")
                        Text("Runs on your Mac, nothing is sent to the cloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.voiceInstalling {
                        ProgressView().controlSize(.small)
                    } else if !model.voiceReady {
                        Button("Install") { model.installVoice() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}

private struct PersonalitySettings: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var draft = Persona(id: "", name: "", voice: "am_onyx", speed: 1.0, tone: "")

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Presets") {
                        ForEach(model.personas.filter(\.isBuiltIn)) { personaRow($0) }
                    }
                    Section("Custom") {
                        ForEach(model.personas.filter { !$0.isBuiltIn }) { personaRow($0) }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 2) {
                    Button { newPersona() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    Button {
                        if let selection { model.deletePersona(selection) }
                        selection = model.settings.personaId
                    } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                    .disabled(selectedPersona?.isBuiltIn ?? true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 190)
            Divider()
            editor
        }
        .frame(height: 380)
        .onAppear {
            if selection == nil { selection = model.settings.personaId }
            loadDraft()
        }
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    private func personaRow(_ persona: Persona) -> some View {
        HStack {
            Text(persona.name)
            Spacer()
            if persona.id == model.settings.personaId {
                Image(systemName: "checkmark").foregroundStyle(KumaTheme.purple)
            }
        }
        .tag(persona.id)
    }

    private var selectedPersona: Persona? { model.personas.first { $0.id == selection } }

    private var editor: some View {
        Form {
            TextField("Name", text: $draft.name)
            Picker("Voice", selection: $draft.voice) {
                ForEach(model.voices) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Speed") {
                HStack {
                    Slider(value: $draft.speed, in: 0.6...1.6)
                    Text(String(format: "%.2fx", draft.speed)).font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Tone")
                TextEditor(text: $draft.tone)
                    .font(.callout)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                if draft.isBuiltIn {
                    Text("Presets are read only. Saving creates a copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use") { model.setPersona(draft.id) }
                    .disabled(draft.id == model.settings.personaId || selectedPersona == nil)
                Button(draft.isBuiltIn ? "Save as copy" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func loadDraft() {
        if let persona = selectedPersona { draft = persona }
    }

    private func newPersona() {
        let persona = Persona(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "New persona", voice: model.settings.voice, speed: 1.0, tone: "Describe how Kuma should talk.")
        model.saveCustomPersona(persona)
        selection = persona.id
        draft = persona
    }

    private func save() {
        var persona = draft
        if persona.isBuiltIn {
            persona.id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
            persona.name = "\(persona.name) copy"
        }
        model.saveCustomPersona(persona)
        selection = persona.id
    }
}

private struct ToolsSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            ForEach(Tool.watchable, id: \.self) { tool in
                ToolRow(model: model, tool: tool)
            }
            Section {
                Text("Summaries for each session are written by the same tool the session runs. Leave the model empty to use the tool default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 530)
    }
}

private struct ToolRow: View {
    @ObservedObject var model: AppModel
    let tool: Tool
    @State private var summaryModel = ""

    var body: some View {
        let status = model.toolStatus[tool] ?? ToolStatus(binaryFound: false, hookInstalled: false)
        Section {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .frame(width: 22)
                    .foregroundStyle(KumaTheme.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.displayName).font(.body.weight(.medium))
                    HStack(spacing: 10) {
                        badge(status.binaryFound ? "Binary found" : "Binary not found", ok: status.binaryFound)
                        badge(status.hookInstalled ? "Hooks installed" : "Hooks not installed", ok: status.hookInstalled)
                    }
                }
                Spacer()
                if model.toolBusy.contains(tool) {
                    ProgressView().controlSize(.small)
                } else if status.hookInstalled {
                    Button("Remove") { model.uninstallHooks(tool) }
                } else {
                    Button("Install") { model.installHooks(tool) }
                        .disabled(!status.binaryFound)
                }
            }
            TextField("Summary model", text: $summaryModel, prompt: Text("Tool default"))
                .onSubmit { model.setSummaryModel(tool, model: summaryModel) }
                .onChange(of: summaryModel) { _, value in model.setSummaryModel(tool, model: value) }
        }
        .onAppear { summaryModel = model.settings.summaryModels[tool.rawValue] ?? "" }
    }

    private func badge(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct HeardSettings: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.heardDetected ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(model.heardDetected ? .orange : .green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.heardDetected ? "Heard hooks detected" : "Heard is not installed")
                            .font(.body.weight(.medium))
                        Text(model.heardDetected
                            ? "Heard also speaks your Claude Code sessions, so you would hear every update twice. Kuma replaces it."
                            : "Nothing to clean up. Kuma is the only voice for your sessions.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.heardDetected {
                    HStack {
                        Spacer()
                        Button("Remove Heard", role: .destructive) { confirming = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
        .confirmationDialog("Remove Heard?", isPresented: $confirming) {
            Button("Remove Heard", role: .destructive) { model.removeHeard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Heard hooks from your Claude Code settings. A backup of the settings file is kept.")
        }
    }
}

private struct ShortcutsSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Skip the current briefing") {
                    KeyCaps(keys: ["⌥", "esc"])
                }
                LabeledContent("Clear all briefings") {
                    Text("Click the x on the paw bubble").foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Option and Escape only works while Kuma is speaking. Plain Escape is left alone so you can still interrupt Claude Code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 210)
    }
}

private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            }
        }
    }
}
