import KumaCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case briefings = "Recent briefings"
    var id: String { rawValue }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsYou = "Needs you"
    case working = "Working"
    case done = "Done"
    case ended = "Ended"
    var id: String { rawValue }

    func matches(_ status: SessionStatus) -> Bool {
        switch self {
        case .all: return true
        case .needsYou: return status.needsYou
        case .working: return status == .working
        case .done: return status == .done
        case .ended: return status == .ended
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: DashboardSection = .sessions
    @State private var selection: Session.ID?
    @State private var search = ""
    @State private var filter: StatusFilter = .all

    var body: some View {
        Group {
            switch section {
            case .sessions: sessionsPane
            case .briefings: BriefingsPane(model: model)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .tint(KumaTheme.purple)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(DashboardSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: Binding(get: { model.settings.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Mode")
            }
        }
        .onAppear {
            if selection == nil { selection = filteredSessions.first?.id }
        }
    }

    private var filteredSessions: [Session] {
        model.sortedSessions.filter { session in
            guard filter.matches(session.status) else { return false }
            guard !search.isEmpty else { return true }
            let haystack = [session.project, session.title, session.model, session.terminal, session.tool.displayName, session.lastSummary].compactMap { $0 }.joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(search)
        }
    }

    private var sessionsPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search sessions", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                    Picker("Status", selection: $filter) {
                        ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                List(filteredSessions, selection: $selection) { session in
                    SidebarSessionRow(model: model, session: session)
                        .tag(session.id)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 300)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            Divider()
            Group {
                if let session = model.sessions.first(where: { $0.id == selection }) {
                    SessionDetailView(model: model, session: session)
                        .id(session.id)
                } else {
                    VStack(spacing: 8) {
                        KumaLogo(size: 56).opacity(0.85)
                        Text("Select a session").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SidebarSessionRow: View {
    @ObservedObject var model: AppModel
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: session.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if model.prefs(for: session).muted {
                        Image(systemName: "speaker.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Elapsed.short(since: session.statusSince)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(session.title ?? session.cwd).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: session.tool.symbol)
                    Text(session.tool.displayName)
                    Text(session.status.label).foregroundStyle(session.status.color)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct BriefingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.recentBriefings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Nothing spoken yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.recentBriefings) { briefing in
                    BriefingRow(model: model, briefing: briefing)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct BriefingRow: View {
    @ObservedObject var model: AppModel
    let briefing: Briefing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: briefing.priority == .high ? "exclamationmark.circle.fill" : "waveform.circle.fill")
                .font(.title3)
                .foregroundStyle(briefing.priority == .high ? Color.orange : KumaTheme.purple)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(briefing.project).font(.system(size: 13, weight: .semibold))
                    Text(briefing.tool.displayName).font(.caption).foregroundStyle(.secondary)
                    if model.current?.id == briefing.id {
                        Label("Speaking", systemImage: "waveform").font(.caption).foregroundStyle(KumaTheme.purple)
                    }
                }
                Text(briefing.text).font(.system(size: 13)).textSelection(.enabled)
                Text("\(briefing.createdAt.formatted(date: .omitted, time: .shortened)), \(model.voiceName(briefing.voice)), \(String(format: "%.2fx", briefing.speed))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.replay(briefing)
            } label: {
                Label("Replay", systemImage: "play.fill")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
