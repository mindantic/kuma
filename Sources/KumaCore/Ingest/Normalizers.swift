import Foundation

public enum Normalizers {
    public static func `for`(_ tool: Tool) -> EventNormalizing {
        switch tool {
        case .claude: return ClaudeNormalizer()
        case .codex: return CodexNormalizer()
        case .cursor: return CursorNormalizer()
        case .opencode: return OpenCodeNormalizer()
        case .other: return NullNormalizer()
        }
    }

    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        Normalizers.for(envelope.tool).normalize(envelope)
    }
}

public struct NullNormalizer: EventNormalizing {
    public init() {}
    public func normalize(_ envelope: HookEnvelope) -> [AgentEvent] { [] }
}

enum NormalizeKit {
    static func text(_ v: JSONValue?) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func clip(_ s: String?, _ limit: Int) -> String? {
        guard let s else { return nil }
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "..."
    }

    static func eventName(_ envelope: HookEnvelope) -> String {
        if !envelope.event.isEmpty { return envelope.event }
        return text(envelope.payload["hook_event_name"]) ?? ""
    }

    static func cwd(_ envelope: HookEnvelope, _ candidates: JSONValue?...) -> String {
        for c in candidates { if let s = text(c) { return s } }
        return envelope.env["PWD"] ?? ""
    }

    static func describeTool(name: String?, input: JSONValue?) -> String? {
        let name = name ?? ""
        let desc = text(input?["description"])
        let target = text(input?["command"]) ?? text(input?["file_path"]) ?? text(input?["path"]) ?? text(input?["url"]) ?? text(input?["pattern"]) ?? text(input?["query"])
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        switch (desc, target) {
        case (let d?, let t?): parts.append("\(d) (\(clip(t, 200)!))")
        case (let d?, nil): parts.append(d)
        case (nil, let t?): parts.append(clip(t, 200)!)
        default: break
        }
        guard !parts.isEmpty else { return nil }
        return clip(parts.joined(separator: ": "), 500)
    }

    static func questions(_ input: JSONValue?) -> String? {
        if let list = input?["questions"]?.array {
            let qs = list.compactMap { text($0["question"]) ?? text($0["header"]) ?? text($0) }
            if !qs.isEmpty { return clip(qs.joined(separator: "\n"), 1000) }
        }
        return text(input?["question"])
    }
}

public struct ClaudeNormalizer: EventNormalizing {
    public var readTranscript: Bool

    public init(readTranscript: Bool = true) {
        self.readTranscript = readTranscript
    }

    public func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let p = envelope.payload
        guard let sessionId = NormalizeKit.text(p["session_id"]) else { return [] }
        let name = NormalizeKit.eventName(envelope)
        var kind: EventKind
        var message: String?
        var detail: String?
        var agentType = NormalizeKit.text(p["agent_type"])
        var reminder = false
        switch name {
        case "SessionStart":
            kind = .sessionStart
        case "UserPromptSubmit":
            kind = .prompt
            detail = NormalizeKit.clip(NormalizeKit.text(p["prompt"]), 2000)
        case "PreToolUse":
            (kind, detail) = Self.toolEvent(p, fallback: .toolUse)
        case "PermissionRequest":
            (kind, detail) = Self.toolEvent(p, fallback: .permission)
        case "Notification":
            reminder = true
            switch NormalizeKit.text(p["notification_type"]) {
            case "permission_prompt":
                kind = .permission
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                kind = .question
            default:
                return []
            }
            detail = NormalizeKit.text(p["message"])
        case "Stop":
            kind = .stop
            message = NormalizeKit.text(p["last_assistant_message"])
        case "SubagentStop":
            kind = .subagentStop
            message = NormalizeKit.text(p["last_assistant_message"])
            agentType = agentType ?? "subagent"
            detail = agentType
        case "StopFailure":
            kind = .error
            message = NormalizeKit.text(p["last_assistant_message"])
            let parts = [NormalizeKit.text(p["error"]), NormalizeKit.text(p["error_details"])].compactMap { $0 }
            detail = parts.isEmpty ? message : parts.joined(separator: ": ")
        case "SessionEnd":
            kind = .sessionEnd
            detail = NormalizeKit.text(p["reason"])
        default:
            return []
        }

        var model = NormalizeKit.text(p["model"]) ?? NormalizeKit.text(p["model"]?["id"])
        var title = NormalizeKit.text(p["session_title"])
        let enrich: Set<EventKind> = [.sessionStart, .stop, .subagentStop, .permission, .question, .error]
        if readTranscript, enrich.contains(kind), model == nil || title == nil, let path = NormalizeKit.text(p["transcript_path"]) {
            let info = TranscriptReader.tail(path: path)
            model = model ?? info.model
            title = title ?? info.title
        }

        return [AgentEvent(
            sessionId: sessionId,
            tool: .claude,
            kind: kind,
            cwd: NormalizeKit.cwd(envelope, p["cwd"]),
            model: model,
            title: title,
            message: message,
            detail: detail,
            agentType: agentType,
            terminal: TerminalDetector.name(env: envelope.env),
            reminder: reminder,
            timestamp: envelope.receivedAt
        )]
    }

    private static func toolEvent(_ p: JSONValue, fallback: EventKind) -> (EventKind, String?) {
        let tool = NormalizeKit.text(p["tool_name"])
        switch tool {
        case "AskUserQuestion":
            return (.question, NormalizeKit.questions(p["tool_input"]))
        case "ExitPlanMode":
            let plan = NormalizeKit.clip(NormalizeKit.text(p["tool_input"]?["plan"]), 600)
            return (.permission, plan.map { "Plan approval: \($0)" } ?? "Plan approval")
        default:
            return (fallback, NormalizeKit.describeTool(name: tool, input: p["tool_input"]))
        }
    }
}

public struct CodexNormalizer: EventNormalizing {
    public init() {}

    public func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let p = envelope.payload
        guard let sessionId = NormalizeKit.text(p["session_id"]) else { return [] }
        var kind: EventKind
        var message: String?
        var detail: String?
        var agentType: String?
        switch NormalizeKit.eventName(envelope) {
        case "SessionStart":
            kind = .sessionStart
        case "UserPromptSubmit":
            kind = .prompt
            detail = NormalizeKit.clip(NormalizeKit.text(p["prompt"]), 2000)
        case "PreToolUse":
            kind = .toolUse
            detail = NormalizeKit.describeTool(name: NormalizeKit.text(p["tool_name"]), input: p["tool_input"])
        case "PermissionRequest":
            kind = .permission
            detail = NormalizeKit.describeTool(name: NormalizeKit.text(p["tool_name"]), input: p["tool_input"])
        case "Stop":
            kind = .stop
            message = NormalizeKit.text(p["last_assistant_message"])
        case "SubagentStop":
            kind = .subagentStop
            message = NormalizeKit.text(p["last_assistant_message"])
            agentType = NormalizeKit.text(p["agent_type"]) ?? "subagent"
            detail = agentType
        case "SessionEnd":
            kind = .sessionEnd
            detail = NormalizeKit.text(p["reason"])
        default:
            return []
        }
        return [AgentEvent(
            sessionId: sessionId,
            tool: .codex,
            kind: kind,
            cwd: NormalizeKit.cwd(envelope, p["cwd"]),
            model: NormalizeKit.text(p["model"]),
            title: NormalizeKit.text(p["session_title"]) ?? NormalizeKit.text(p["title"]),
            message: message,
            detail: detail,
            agentType: agentType,
            terminal: TerminalDetector.name(env: envelope.env),
            timestamp: envelope.receivedAt
        )]
    }
}

public struct CursorNormalizer: EventNormalizing {
    public init() {}

    public func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let p = envelope.payload
        guard let sessionId = NormalizeKit.text(p["conversation_id"]) ?? NormalizeKit.text(p["session_id"]) else { return [] }
        var kind: EventKind
        var message: String?
        var detail: String?
        var agentType: String?
        switch NormalizeKit.eventName(envelope) {
        case "sessionStart":
            kind = .sessionStart
        case "beforeSubmitPrompt":
            kind = .prompt
            detail = NormalizeKit.clip(NormalizeKit.text(p["prompt"]), 2000)
        case "afterAgentResponse":
            guard let text = NormalizeKit.text(p["text"]) else { return [] }
            kind = .stop
            message = text
        case "stop":
            switch NormalizeKit.text(p["status"]) {
            case "error":
                kind = .error
                detail = NormalizeKit.text(p["error_message"]) ?? "Cursor agent stopped with an error"
            default:
                guard let text = NormalizeKit.text(p["text"]) else { return [] }
                kind = .stop
                message = text
            }
        case "subagentStop":
            kind = .subagentStop
            message = NormalizeKit.text(p["summary"])
            agentType = NormalizeKit.text(p["subagent_type"]) ?? "subagent"
            detail = NormalizeKit.text(p["description"]) ?? agentType
        case "sessionEnd":
            if NormalizeKit.text(p["reason"]) == "error" {
                kind = .error
                detail = NormalizeKit.text(p["error_message"]) ?? "Cursor session ended with an error"
            } else {
                kind = .sessionEnd
                detail = NormalizeKit.text(p["reason"])
            }
        default:
            return []
        }
        return [AgentEvent(
            sessionId: sessionId,
            tool: .cursor,
            kind: kind,
            cwd: NormalizeKit.cwd(envelope, p["workspace_roots"]?[0], p["cwd"]),
            model: NormalizeKit.text(p["model_id"]) ?? NormalizeKit.text(p["model"]),
            title: nil,
            message: message,
            detail: detail,
            agentType: agentType,
            terminal: TerminalDetector.name(env: envelope.env),
            timestamp: envelope.receivedAt
        )]
    }
}

public struct OpenCodeNormalizer: EventNormalizing {
    public static let summaryTitlePrefix = "kuma-summary"

    public init() {}

    public func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let p = envelope.payload
        guard let sessionId = NormalizeKit.text(p["session_id"]) else { return [] }
        let title = NormalizeKit.text(p["title"])
        if let title, title.hasPrefix(OpenCodeNormalizer.summaryTitlePrefix) { return [] }
        var kind: EventKind
        switch NormalizeKit.eventName(envelope) {
        case "session.created":
            kind = .sessionStart
        case "session.prompt":
            kind = .prompt
        case "session.status":
            switch NormalizeKit.text(p["status"]) {
            case "busy", "retry": kind = .toolUse
            default: return []
            }
        case "session.idle":
            kind = NormalizeKit.text(p["agent_type"]) == nil ? .stop : .subagentStop
        case "session.error":
            kind = .error
        case "permission.asked", "permission.updated":
            kind = .permission
        case "question.asked":
            kind = .question
        case "session.deleted":
            kind = .sessionEnd
        default:
            return []
        }
        return [AgentEvent(
            sessionId: sessionId,
            tool: .opencode,
            kind: kind,
            cwd: NormalizeKit.cwd(envelope, p["directory"], p["cwd"]),
            model: NormalizeKit.text(p["model"]),
            title: title,
            message: NormalizeKit.text(p["message"]),
            detail: NormalizeKit.text(p["detail"]),
            agentType: NormalizeKit.text(p["agent_type"]),
            terminal: TerminalDetector.name(env: envelope.env),
            timestamp: envelope.receivedAt
        )]
    }
}
