import Combine
import Foundation

@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []

    private let namer: ProjectNamer
    private var index: [String: Session] = [:]

    public init(namer: ProjectNamer = .shared) {
        self.namer = namer
    }

    public func session(id: String) -> Session? { index[id] }

    @discardableResult
    public func apply(_ event: AgentEvent) -> Session {
        var s = index[event.sessionId] ?? Session(
            id: event.sessionId,
            tool: event.tool,
            project: namer.name(forCwd: event.cwd),
            cwd: event.cwd,
            status: .working,
            statusSince: event.timestamp,
            updatedAt: event.timestamp
        )
        if !event.cwd.isEmpty, event.cwd != s.cwd {
            s.cwd = event.cwd
            s.project = namer.name(forCwd: event.cwd)
        }
        if let m = event.model, !m.isEmpty { s.model = m }
        if let t = event.title, !t.isEmpty { s.title = t }
        if let t = event.terminal, !t.isEmpty { s.terminal = t }

        var next: SessionStatus? = nil
        switch event.kind {
        case .sessionStart, .prompt, .toolUse:
            next = .working
            s.pendingDetail = nil
        case .permission:
            next = .needsApproval
            s.pendingDetail = event.detail ?? event.message
        case .question:
            next = .question
            s.pendingDetail = event.detail ?? event.message
        case .stop:
            next = .done
            s.pendingDetail = nil
            if let m = event.message, !m.isEmpty { s.lastMessage = m }
        case .error:
            next = .error
            s.pendingDetail = nil
            if let m = event.message ?? event.detail, !m.isEmpty { s.lastMessage = m }
        case .sessionEnd:
            next = .ended
            s.pendingDetail = nil
        case .subagentStop:
            next = nil
        }
        if let next, next != s.status {
            s.status = next
            s.statusSince = event.timestamp
        }
        s.updatedAt = max(s.updatedAt, event.timestamp)
        store(s)
        return s
    }

    public func setSummary(sessionId: String, text: String) {
        guard var s = index[sessionId] else { return }
        s.lastSummary = text
        store(s)
    }

    public func remove(sessionId: String) {
        index[sessionId] = nil
        resort()
    }

    public func pruneEnded(olderThan age: TimeInterval, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-age)
        index = index.filter { !($0.value.status == .ended && $0.value.updatedAt < cutoff) }
        resort()
    }

    public func seed(_ seeded: [Session]) {
        for var s in seeded {
            if let existing = index[s.id], existing.updatedAt >= s.updatedAt { continue }
            if s.project.isEmpty { s.project = namer.name(forCwd: s.cwd) }
            index[s.id] = s
        }
        resort()
    }

    public var counts: [SessionStatus: Int] {
        var c: [SessionStatus: Int] = [:]
        for s in index.values { c[s.status, default: 0] += 1 }
        return c
    }

    public func count(_ status: SessionStatus) -> Int { counts[status] ?? 0 }

    public var attentionCount: Int {
        index.values.filter { $0.status == .needsApproval || $0.status == .question || $0.status == .error }.count
    }

    public static func sorted(_ list: [Session]) -> [Session] {
        list.sorted { a, b in
            if a.status.urgency != b.status.urgency { return a.status.urgency > b.status.urgency }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
    }

    private func store(_ s: Session) {
        index[s.id] = s
        resort()
    }

    private func resort() {
        sessions = Self.sorted(Array(index.values))
    }
}
