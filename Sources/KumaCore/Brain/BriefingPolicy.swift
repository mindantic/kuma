import Foundation

public enum BriefingPolicy {
    public static func basePriority(for kind: EventKind) -> Priority? {
        switch kind {
        case .permission, .question, .error: return .high
        case .stop: return .normal
        case .subagentStop: return .fyi
        case .sessionStart, .prompt, .toolUse, .sessionEnd: return nil
        }
    }

    public static func decide(event: AgentEvent, session: Session, prefs: SessionPrefs, mode: Mode, watched: [Tool]) -> BriefingDecision {
        guard mode != .disabled, watched.contains(event.tool), !prefs.muted else { return .skip }
        guard let base = basePriority(for: event.kind) else { return .skip }
        let allowed: Bool
        switch event.kind {
        case .permission: allowed = prefs.speakApprovals
        case .question: allowed = prefs.speakQuestions
        case .error: allowed = prefs.speakErrors
        case .stop: allowed = prefs.speakFinished
        case .subagentStop: allowed = prefs.speakSubagents
        default: allowed = false
        }
        guard allowed else { return .skip }
        if (prefs.highOnly || mode == .dnd) && base != .high { return .skip }
        return BriefingDecision(shouldBrief: true, basePriority: base)
    }

    public static func finalPriority(base: Priority, summary: SummaryResult) -> Priority {
        if base == .high { return .high }
        if base == .normal && summary.priority == .high { return .high }
        return base
    }

    public static func shouldSpeak(final: Priority, prefs: SessionPrefs, mode: Mode) -> Bool {
        if mode == .disabled || prefs.muted { return false }
        if mode == .dnd || prefs.highOnly { return final == .high }
        return true
    }
}
