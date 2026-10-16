import KumaCore
import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                metadata
                if let pending = session.pendingDetail {
                    callout(title: "Waiting on", text: pending, color: session.status.color)
                }
                textBlock(title: "Last summary", text: session.lastSummary ?? "No summary yet.")
                lastMessage
                PrefsEditor(model: model, session: session)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(status: session.status, size: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.project).font(.title2.weight(.semibold))
                Text(session.project).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Label(session.status.label, systemImage: session.status.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(session.status.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(session.status.color.opacity(0.12)))
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            row("Tool", session.tool.displayName, symbol: session.tool.symbol)
            row("Model", session.model ?? "Unknown", symbol: "cpu")
            row("Terminal", session.terminal ?? "Unknown", symbol: "macwindow")
            row("In status", "\(Elapsed.short(since: session.statusSince)), since \(session.statusSince.formatted(date: .omitted, time: .shortened))", symbol: "clock")
            row("Folder", session.cwd, symbol: "folder")
            row("Session ID", session.id, symbol: "number")
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String, symbol: String) -> some View {
        GridRow {
            Label(label, systemImage: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func callout(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }

    private func textBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.body).textSelection(.enabled)
        }
    }

    private var lastMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last message").font(.headline)
            ScrollView {
                Text(session.lastMessage ?? "No message yet.")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 60, maxHeight: 160)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

private enum SpeakLevel: Hashable {
    case everything, important, muted
}

struct PrefsEditor: View {
    @ObservedObject var model: AppModel
    let session: Session
    @State private var draft = SessionPrefs()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Behavior").font(.headline)
                Text(sourceText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(source == .defaults ? Color.secondary : KumaTheme.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(source == .defaults ? Color.primary.opacity(0.06) : KumaTheme.purple.opacity(0.14)))
                Spacer()
                if source != .defaults {
                    Button("Reset to defaults") { reset() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            VStack(spacing: 0) {
                row("Speak", symbol: "speaker.wave.2") {
                    Picker("Speak", selection: level) {
                        Text("Everything").tag(SpeakLevel.everything)
                        Text("Important").tag(SpeakLevel.important)
                        Text("Muted").tag(SpeakLevel.muted)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                Group {
                    Divider().padding(.leading, 40)
                    row("Detail", symbol: "text.alignleft") {
                        Picker("Detail", selection: $draft.verbosity) {
                            Text("One line").tag(Verbosity.line)
                            Text("Short summary").tag(Verbosity.summary)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Divider().padding(.leading, 40)
                    row("Persona", symbol: "theatermasks") {
                        Picker("Persona", selection: $draft.personaId) {
                            Text("Default (\(model.activePersona?.name ?? "Kuma"))").tag(String?.none)
                            Divider()
                            ForEach(model.personas) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Divider().padding(.leading, 40)
                    row("Voice", symbol: "waveform") {
                        Picker("Voice", selection: $draft.voice) {
                            Text("Match persona").tag(String?.none)
                            Divider()
                            ForEach(model.voices) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Divider().padding(.leading, 40)
                    VStack(alignment: .leading, spacing: 8) {
                        label("Speak about", symbol: "bell")
                        HStack(spacing: 6) {
                            chip("Finished", isOn: $draft.speakFinished)
                            chip("Approvals", isOn: $draft.speakApprovals)
                            chip("Questions", isOn: $draft.speakQuestions)
                            chip("Errors", isOn: $draft.speakErrors)
                            chip("Subagents", isOn: $draft.speakSubagents)
                        }
                        .padding(.leading, 28)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(draft.muted)
                .opacity(draft.muted ? 0.45 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

            Toggle(isOn: projectWide) {
                Text("Use for every session in \(session.project)")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 2)
            .padding(.top, 2)
        }
        .onAppear { draft = model.prefs(for: session) }
        .onChange(of: model.prefs(for: session)) { _, newValue in
            if draft != newValue { draft = newValue }
        }
        .onChange(of: draft) { _, newValue in
            guard newValue != model.prefs(for: session) else { return }
            model.updatePrefs(session: session, prefs: newValue, scope: source == .project ? .project : .session)
        }
    }

    private func row<Control: View>(_ title: String, symbol: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            label(title, symbol: symbol)
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 8)
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(KumaTheme.purple)
                .frame(width: 18)
            Text(title)
        }
    }

    private func chip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isOn.wrappedValue ? KumaTheme.purple : Color.secondary)
            .background(Capsule().fill(isOn.wrappedValue ? KumaTheme.purple.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(isOn.wrappedValue ? KumaTheme.purple.opacity(0.4) : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var level: Binding<SpeakLevel> {
        Binding(
            get: { draft.muted ? .muted : draft.highOnly ? .important : .everything },
            set: { value in
                draft.muted = value == .muted
                draft.highOnly = value == .important
            }
        )
    }

    private var projectWide: Binding<Bool> {
        Binding(
            get: { source == .project },
            set: { on in
                if on {
                    model.updatePrefs(session: session, prefs: draft, scope: .project)
                } else {
                    let current = draft
                    model.resetPrefs(session: session, scope: .project)
                    if current != model.settings.defaultPrefs {
                        model.updatePrefs(session: session, prefs: current, scope: .session)
                    }
                }
            }
        )
    }

    private var source: PrefsSource { model.prefsSource(for: session) }

    private var sourceText: String {
        switch source {
        case .session: return "Custom for this session"
        case .project: return "Shared with \(session.project)"
        case .defaults: return "Defaults"
        }
    }

    private func reset() {
        model.resetPrefs(session: session, scope: source == .project ? .project : .session)
        draft = model.prefs(for: session)
    }
}
