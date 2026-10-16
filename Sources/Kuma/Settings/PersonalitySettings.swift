import KumaCore
import SwiftUI

struct PersonalitySettings: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var draft = Persona(id: "", name: "", voice: "am_onyx", speed: 1.0, tone: "")

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            if selectedPersona != nil {
                editor
            } else {
                Text("Select a personality")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 460)
        .onAppear {
            if selection == nil { selection = model.settings.personaId }
            loadDraft()
        }
        .onChange(of: selection) { _, _ in loadDraft() }
        .onChange(of: draft) { _, value in
            guard let current = selectedPersona, value.id == current.id, value != current,
                  !value.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            model.saveCustomPersona(value)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Presets") {
                    ForEach(model.personas.filter(\.isBuiltIn)) { row($0) }
                }
                let custom = model.personas.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("Custom") {
                        ForEach(custom) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button { newPersona() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                    .help("New personality")
                Button {
                    if let selection { model.deletePersona(selection) }
                    selection = model.settings.personaId
                } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                    .disabled(selectedPersona?.isBuiltIn ?? true)
                    .help("Delete this personality")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            engineStatus
                .padding(10)
        }
    }

    private func row(_ persona: Persona) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(persona.name)
                Text(model.isEditedPreset(persona.id) ? "\(model.voiceName(persona.voice)), edited" : model.voiceName(persona.voice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if persona.id == model.settings.personaId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(KumaTheme.purple)
                    .help("In use")
            }
        }
        .padding(.vertical, 2)
        .tag(persona.id)
    }

    private var engineStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: model.voiceReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(model.voiceReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Voice engine").font(.caption.weight(.semibold))
                Text(model.voiceReady ? "Installed, runs on this Mac" : "Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.voiceInstalling {
                ProgressView().controlSize(.small)
            } else if !model.voiceReady {
                Button("Install") { model.installVoice() }
                    .controlSize(.small)
            }
        }
    }

    private var isActive: Bool { draft.id == model.settings.personaId }

    private var editor: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                LabeledContent("Status") {
                    if isActive {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(KumaTheme.purple)
                    } else {
                        Button("Use this personality") { model.setPersona(draft.id) }
                    }
                }
            }
            Section("Voice") {
                Picker("Voice", selection: $draft.voice) {
                    ForEach(model.voices) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(get: { draft.speed }, set: { draft.speed = ($0 * 20).rounded() / 20 }), in: 0.6...1.6)
                        Text(String(format: "%.2fx", draft.speed))
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    if !model.voiceReady {
                        Text("Install the voice engine to hear it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.testVoice(draft)
                    } label: {
                        Label("Test voice", systemImage: "play.fill")
                    }
                    .disabled(!model.voiceReady)
                }
            }
            Section("Tone") {
                TextEditor(text: $draft.tone)
                    .font(.callout)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
            }
            if model.isEditedPreset(draft.id) {
                Section {
                    HStack {
                        Text("You changed this preset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore preset") {
                            model.restorePreset(draft.id)
                            loadDraft()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedPersona: Persona? { model.personas.first { $0.id == selection } }

    private func loadDraft() {
        if let persona = selectedPersona { draft = persona }
    }

    private func newPersona() {
        let persona = Persona(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "New personality", voice: model.settings.voice, speed: 1.0, tone: "Describe how Kuma should talk.")
        model.saveCustomPersona(persona)
        selection = persona.id
        draft = persona
    }
}
