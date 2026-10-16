import AppKit
import Carbon.HIToolbox
import KumaCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, defaults, personality, tools, shortcuts
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            DefaultsSettings(model: model)
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.defaults)
            PersonalitySettings(model: model)
                .tabItem { Label("Personality", systemImage: "person.crop.circle") }
                .tag(SettingsTab.personality)
            ToolsSettings(model: model)
                .tabItem { Label("Tools", systemImage: "hammer") }
                .tag(SettingsTab.tools)
            ShortcutsSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
        }
        .frame(width: 620)
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
            Section("Toast") {
                Toggle("Show a toast while Kuma speaks", isOn: Binding(get: { model.toastEnabled }, set: { model.setToastEnabled($0) }))
                LabeledContent("Style") {
                    HStack(spacing: 10) {
                        Picker("Style", selection: Binding(get: { model.toastStyle }, set: { model.setToastStyle($0) })) {
                            ForEach(ToastStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            model.testVoice()
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                        }
                    }
                }
                .disabled(!model.toastEnabled)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let error = model.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
    }

    private var modeExplanation: String {
        switch model.settings.mode {
        case .enabled: return "Kuma speaks every briefing your session settings allow."
        case .dnd: return "Only high priority briefings are spoken, such as approvals, questions and errors. Everything still shows in the dashboard."
        case .disabled: return "Kuma stays silent. Sessions are still tracked in the dashboard."
        }
    }
}

private struct DefaultsSettings: View {
    @ObservedObject var model: AppModel
    @State private var draft = SessionPrefs()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session defaults").font(.headline)
                    Text("Every session uses these until you change it in the dashboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore defaults") { draft = .default }
                    .disabled(draft == .default)
            }
            BehaviorPanel(model: model, draft: $draft, inheritLabel: "Active personality (\(model.activePersona?.name ?? "Kuma"))")
            if customCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(customCount == 1 ? "1 session or project has its own settings and keeps them." : "\(customCount) sessions or projects have their own settings and keep them.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(height: 350, alignment: .top)
        .onAppear { draft = model.settings.defaultPrefs }
        .onChange(of: draft) { _, value in model.setDefaultPrefs(value) }
    }

    private var customCount: Int {
        model.settings.sessionPrefs.count + model.settings.projectPrefs.count
    }
}

private struct ShortcutsSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(hotKey: Binding(get: { model.skipShortcut }, set: { model.setSkipShortcut($0) }))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Skip the current briefing")
                        Text("Works from any app while Kuma is speaking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                LabeledContent {
                    Text("Click the x on the toast")
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clear all briefings")
                        Text("Stops speaking and empties the queue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Label {
                    Text("Click the shortcut, then press a new one. It needs Command, Option or Control, so plain Esc stays free for Claude Code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }
}

private struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Group {
                    if recording {
                        Text(rejected ? "Add a modifier" : "Type a shortcut")
                            .font(.callout)
                            .foregroundStyle(rejected ? Color.orange : KumaTheme.purple)
                    } else {
                        KeyCaps(keys: hotKey.symbols)
                    }
                }
                .frame(minWidth: 130, minHeight: 30)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(recording ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? KumaTheme.purple : Color.primary.opacity(0.12), lineWidth: recording ? 1.5 : 1))
            .help(recording ? "Press the new shortcut, Esc cancels" : "Click to record a new shortcut")
            Button {
                stop()
                hotKey = .default
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to \(HotKey.default.label)")
            .opacity(hotKey == .default ? 0 : 1)
            .disabled(hotKey == .default)
        }
        .onDisappear { stop() }
    }

    private func start() {
        rejected = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
                stop()
                return nil
            }
            if let key = HotKey.from(event) {
                hotKey = key
                stop()
            } else {
                rejected = true
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        rejected = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
