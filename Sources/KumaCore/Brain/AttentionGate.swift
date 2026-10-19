import Foundation

public struct AttentionGate: Sendable {
    private var asked: [String: Set<String>] = [:]

    public init() {}

    public func isWaiting(sessionId: String) -> Bool { asked[sessionId] != nil }

    public mutating func admit(_ event: AgentEvent) -> Bool {
        switch event.kind {
        case .permission, .question:
            let key = "\(event.kind.rawValue):\(event.detail ?? event.message ?? "")"
            guard var open = asked[event.sessionId] else {
                asked[event.sessionId] = [key]
                return true
            }
            guard !event.reminder, !open.contains(key) else { return false }
            open.insert(key)
            asked[event.sessionId] = open
            return true
        case .subagentStop:
            return true
        case .sessionStart, .prompt, .toolUse, .stop, .error, .sessionEnd:
            asked[event.sessionId] = nil
            return true
        }
    }
}
