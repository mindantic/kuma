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

struct PrefsEditor: View {
    @ObservedObject var model: AppModel
    let session: Session
    @State private var draft = SessionPrefs()
    @State private var scope: PrefsScope = .session
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Behavior").font(.headline)
                Spacer()
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Apply to", selection: $scope) {
                    Text("This session").tag(PrefsScope.session)
                    Text("All sessions in \(session.project)").tag(PrefsScope.project)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 20) {
                    Toggle("Mute", isOn: $draft.muted)
                    Toggle("High priority only", isOn: $draft.highOnly)
                        .disabled(draft.muted)
                }

                Picker("Verbosity", selection: $draft.verbosity) {
                    Text("One line").tag(Verbosity.line)
                    Text("Short summary").tag(Verbosity.summary)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                HStack(spacing: 16) {
                    Picker("Persona", selection: $draft.personaId) {
                        Text("Global default").tag(String?.none)
                        Divider()
                        ForEach(model.personas) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .frame(maxWidth: 240)
                    Picker("Voice", selection: $draft.voice) {
                        Text("Persona voice").tag(String?.none)
                        Divider()
                        ForEach(model.voices) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .frame(maxWidth: 260)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speak when").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Toggle("Finished", isOn: $draft.speakFinished)
                        Toggle("Approvals", isOn: $draft.speakApprovals)
                        Toggle("Questions", isOn: $draft.speakQuestions)
                        Toggle("Errors", isOn: $draft.speakErrors)
                        Toggle("Subagents", isOn: $draft.speakSubagents)
                    }
                    .toggleStyle(.checkbox)
                }
                .disabled(draft.muted)

                HStack {
                    Button("Reset to defaults") {
                        model.resetPrefs(session: session, scope: scope)
                        reload()
                    }
                    .disabled(!canReset)
                    Spacer()
                    Button("Revert") { reload() }
                        .disabled(draft == model.prefs(for: session))
                    Button("Apply") {
                        model.updatePrefs(session: session, prefs: draft, scope: scope)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == model.prefs(for: session) && scopeMatchesSource)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            reload()
        }
        .onChange(of: model.prefs(for: session)) { _, newValue in
            draft = newValue
        }
    }

    private var sourceText: String {
        switch model.prefsSource(for: session) {
        case .session: return "Using settings for this session"
        case .project: return "Using settings for \(session.project)"
        case .defaults: return "Using global defaults"
        }
    }

    private var scopeMatchesSource: Bool {
        switch (model.prefsSource(for: session), scope) {
        case (.session, .session), (.project, .project): return true
        default: return false
        }
    }

    private var canReset: Bool {
        switch scope {
        case .session: return model.settings.sessionPrefs[session.id] != nil
        case .project: return model.settings.projectPrefs[session.project] != nil
        }
    }

    private func reload() {
        draft = model.prefs(for: session)
        scope = model.prefsSource(for: session) == .project ? .project : .session
    }
}
