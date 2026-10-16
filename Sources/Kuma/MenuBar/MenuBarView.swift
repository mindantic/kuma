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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionList
            Divider()
            footer
        }
        .frame(width: 400)
        .tint(KumaTheme.purple)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(KumaTheme.purple)
                Text("Kuma")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: Binding(get: { model.settings.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help(model.settings.mode.label)
            }
            HStack(spacing: 14) {
                CountChip(count: model.needsYouCount, label: "need you", color: .orange)
                CountChip(count: model.workingCount, label: "working", color: .blue)
                CountChip(count: model.doneCount, label: "done", color: .green)
                Spacer()
                if model.current != nil {
                    Label("Speaking", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(KumaTheme.purple)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            MenuSessionRow(model: model, session: session)
                        }
                    } header: {
                        SectionHeader(title: group.title, count: group.sessions.count)
                    }
                }
                if model.sessions.isEmpty {
                    Text("No sessions yet. Start Claude Code, OpenCode, Codex or Cursor and they appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
            }
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Open Dashboard", symbol: "rectangle.grid.1x2") { model.openDashboard() }
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

private struct CountChip: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)").font(.callout.monospacedDigit().weight(.semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSessionRow: View {
    @ObservedObject var model: AppModel
    let session: Session
    @State private var hovering = false

    var body: some View {
        let prefs = model.prefs(for: session)
        HStack(alignment: .top, spacing: 9) {
            StatusDot(status: session.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(session.title ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Elapsed.short(since: session.statusSince, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(session.status.needsYou ? session.status.color : .secondary)
                    }
                }
                if let summary = session.lastSummary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 5) {
                    Image(systemName: session.tool.symbol)
                    Text(metaLine)
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            Button {
                model.muteToggle(session)
            } label: {
                Image(systemName: prefs.muted ? "speaker.slash.fill" : (prefs.highOnly ? "speaker.badge.exclamationmark" : "speaker.wave.2"))
                    .font(.system(size: 11))
                    .foregroundStyle(prefs.muted ? Color.secondary : KumaTheme.purple)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(prefs.muted ? "Unmute this session" : "Mute this session")
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .opacity(session.status == .ended ? 0.6 : 1)
        .onHover { hovering = $0 }
    }

    private var metaLine: String {
        [session.tool.displayName, session.model, session.terminal].compactMap { $0 }.joined(separator: ", ")
    }
}
