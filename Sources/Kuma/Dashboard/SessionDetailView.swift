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
                if let summary = session.lastSummary {
                    textBlock(title: "Last summary", text: summary)
                }
                if session.lastMessage != nil {
                    lastMessage
                }
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
            if let model = session.model { row("Model", model, symbol: "cpu") }
            if let terminal = session.terminal { row("Terminal", terminal, symbol: "macwindow") }
            row("In status", "\(Elapsed.short(since: session.statusSince)), since \(session.statusSince.formatted(date: .omitted, time: .shortened))", symbol: "clock")
            row("Folder", session.displayFolder, symbol: "folder")
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
                } else {
                    Button("Edit defaults") { model.openSettings(tab: SettingsTab.defaults.rawValue) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            BehaviorPanel(model: model, draft: $draft, inheritLabel: "Default (\(model.activePersona?.name ?? "Kuma"))")

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
