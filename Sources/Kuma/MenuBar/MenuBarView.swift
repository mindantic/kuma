import KumaCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: MenuBarIcon.image(attention: model.needsAttention, dimmed: model.settings.mode == .disabled))
            .onAppear(perform: registerOpeners)
    }

    private func registerOpeners() {
        model.windowOpener = { id in openWindow(id: id) }
        model.settingsOpener = { openSettings() }
        AppDelegate.shared?.labelDidAppear()
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Session.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let current = model.current {
                NowSpeaking(model: model, briefing: current)
            }
            Divider()
            sessionList
            Divider()
            footer
        }
        .frame(width: 400)
        .background(KumaTheme.surface)
        .tint(KumaTheme.purple)
        .animation(.easeOut(duration: 0.18), value: expanded)
        .animation(.easeOut(duration: 0.18), value: model.current?.id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            KumaLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kuma")
                    .font(.system(size: 14, weight: .semibold))
                statusLine
            }
            Spacer()
            ModeMenu(model: model)
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusLine: some View {
        let parts: [(Int, String, Color)] = [
            (model.needsYouCount, "need you", .orange),
            (model.workingCount, "working", .blue),
            (model.doneCount, "done", .green),
        ].filter { $0.0 > 0 }
        return HStack(spacing: 10) {
            if parts.isEmpty {
                Text("No active sessions").foregroundStyle(.secondary)
            }
            ForEach(parts, id: \.1) { count, label, color in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text("\(count) \(label)")
                        .foregroundStyle(label == "need you" ? Color.orange : Color.secondary)
                }
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            MenuSessionRow(model: model, session: session, expanded: expanded == session.id) {
                                expanded = expanded == session.id ? nil : session.id
                            }
                        }
                    } header: {
                        SectionHeader(title: group.title, count: group.sessions.count)
                    }
                }
                if model.visibleSessions.isEmpty {
                    VStack(spacing: 8) {
                        KumaLogo(size: 40).opacity(0.8)
                        Text("No sessions yet. Start Claude Code, OpenCode, Codex or Cursor and they show up here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Dashboard", symbol: "rectangle.grid.1x2") { model.openDashboard() }
            FooterButton(title: "Settings", symbol: "gearshape") { model.openSettings() }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { model.quit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var groups: [(title: String, sessions: [Session])] {
        let sorted = model.sortedSessions
        let buckets: [(String, (Session) -> Bool)] = [
            ("Needs you", { $0.status.needsYou }),
            ("Done", { $0.status == .done }),
            ("Working", { $0.status == .working }),
            ("Ended", { $0.status == .ended }),
        ]
        return buckets.compactMap { title, test in
            let items = sorted.filter(test)
            return items.isEmpty ? nil : (title, items)
        }
    }
}

private struct NowSpeaking: View {
    @ObservedObject var model: AppModel
    let briefing: Briefing

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(KumaTheme.purple)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(briefing.project).font(.system(size: 12, weight: .semibold))
                    if model.pendingCount > 0 {
                        Text("\(model.pendingCount) queued").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(briefing.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Skip") { model.skipCurrent() }
                .controlSize(.small)
                .help("Skip (\(model.skipShortcut.label))")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(KumaTheme.purple.opacity(0.1))
        .transition(.opacity)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(KumaTheme.surface)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private enum RowSpeak: Hashable {
    case everything, important, muted
}

struct MenuSessionRow: View {
    @ObservedObject var model: AppModel
    let session: Session
    let expanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let prefs = model.prefs(for: session)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                StatusDot(status: session.status)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.project)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let title = session.title, title != session.project {
                            Text(title)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        if prefs.muted || prefs.highOnly || hovering {
                            Button {
                                model.muteToggle(session)
                            } label: {
                                Image(systemName: prefs.muted ? "speaker.slash.fill" : (prefs.highOnly ? "speaker.badge.exclamationmark.fill" : "speaker.wave.2.fill"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(prefs.muted ? Color.secondary : KumaTheme.purple)
                                    .frame(width: 18, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(prefs.muted ? "Unmute this session" : "Mute this session")
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(Elapsed.short(since: session.statusSince, now: context.date))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(session.status.needsYou ? session.status.color : .secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: session.tool.symbol)
                        Text(metaLine).lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 4)
                    .opacity(hovering || expanded ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if expanded {
                details(prefs)
                    .padding(.leading, 17)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(expanded ? Color.primary.opacity(0.06) : (hovering ? Color.primary.opacity(0.04) : .clear))
        .opacity(session.status == .ended && !expanded ? 0.6 : 1)
        .onHover { hovering = $0 }
    }

    private func details(_ prefs: SessionPrefs) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let pending = session.pendingDetail {
                Text(pending)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(session.status.color.opacity(0.12)))
            }
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(session.lastSummary == nil && session.lastMessage == nil ? .secondary : .primary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Picker("Speak", selection: Binding(
                    get: { prefs.muted ? RowSpeak.muted : prefs.highOnly ? .important : .everything },
                    set: { model.setSpeakLevel(session, muted: $0 == .muted, highOnly: $0 == .important) }
                )) {
                    Text("Everything").tag(RowSpeak.everything)
                    Text("Important").tag(RowSpeak.important)
                    Text("Muted").tag(RowSpeak.muted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Button {
                    model.openDashboard(focus: session)
                } label: {
                    Label("Details", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)
            }
        }
    }

    private var summaryText: String {
        if let summary = session.lastSummary { return summary }
        if let message = session.lastMessage { return message }
        return "No summary yet."
    }

    private var metaLine: String {
        [session.tool.displayName, session.model, session.terminal].compactMap { $0 }.joined(separator: ", ")
    }
}
