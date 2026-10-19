import Foundation

public enum Tool: String, Codable, CaseIterable, Sendable {
    case claude
    case opencode
    case codex
    case cursor
    case other

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .other: return "Other"
        }
    }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case needsApproval
    case question
    case error
    case done
    case working
    case ended

    public var urgency: Int {
        switch self {
        case .needsApproval: return 5
        case .question: return 4
        case .error: return 3
        case .done: return 2
        case .working: return 1
        case .ended: return 0
        }
    }

    public var label: String {
        switch self {
        case .needsApproval: return "Needs approval"
        case .question: return "Asking you"
        case .error: return "Error"
        case .done: return "Done"
        case .working: return "Working"
        case .ended: return "Ended"
        }
    }
}

public enum Priority: Int, Codable, Comparable, CaseIterable, Sendable {
    case fyi = 0
    case normal = 1
    case high = 2

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

public enum EventKind: String, Codable, Sendable {
    case sessionStart
    case prompt
    case toolUse
    case permission
    case question
    case stop
    case subagentStop
    case error
    case sessionEnd
}

public struct HookEnvelope: Codable, Sendable {
    public var tool: Tool
    public var event: String
    public var payload: JSONValue
    public var env: [String: String]
    public var parentPID: Int32
    public var receivedAt: Date

    public init(tool: Tool, event: String, payload: JSONValue, env: [String: String], parentPID: Int32, receivedAt: Date = Date()) {
        self.tool = tool
        self.event = event
        self.payload = payload
        self.env = env
        self.parentPID = parentPID
        self.receivedAt = receivedAt
    }

    public static let capturedEnvKeys = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "TERM_SESSION_ID",
        "TMUX", "TMUX_PANE", "GHOSTTY_RESOURCES_DIR", "__CFBundleIdentifier", "PWD",
        "ORCA_TERMINAL_ID", "ORCA_WORKTREE_PATH",
    ]
}

public struct AgentEvent: Codable, Sendable {
    public var sessionId: String
    public var tool: Tool
    public var kind: EventKind
    public var cwd: String
    public var model: String?
    public var title: String?
    public var message: String?
    public var detail: String?
    public var agentType: String?
    public var terminal: String?
    public var reminder: Bool
    public var timestamp: Date

    public init(sessionId: String, tool: Tool, kind: EventKind, cwd: String, model: String? = nil, title: String? = nil, message: String? = nil, detail: String? = nil, agentType: String? = nil, terminal: String? = nil, reminder: Bool = false, timestamp: Date = Date()) {
        self.sessionId = sessionId
        self.tool = tool
        self.kind = kind
        self.cwd = cwd
        self.model = model
        self.title = title
        self.message = message
        self.detail = detail
        self.agentType = agentType
        self.terminal = terminal
        self.reminder = reminder
        self.timestamp = timestamp
    }

    public var isSubagent: Bool { kind == .subagentStop || agentType != nil }
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var tool: Tool
    public var project: String
    public var cwd: String
    public var title: String?
    public var model: String?
    public var terminal: String?
    public var status: SessionStatus
    public var statusSince: Date
    public var lastSummary: String?
    public var lastMessage: String?
    public var pendingDetail: String?
    public var updatedAt: Date

    public init(id: String, tool: Tool, project: String, cwd: String, title: String? = nil, model: String? = nil, terminal: String? = nil, status: SessionStatus = .working, statusSince: Date = Date(), lastSummary: String? = nil, lastMessage: String? = nil, pendingDetail: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.project = project
        self.cwd = cwd
        self.title = title
        self.model = model
        self.terminal = terminal
        self.status = status
        self.statusSince = statusSince
        self.lastSummary = lastSummary
        self.lastMessage = lastMessage
        self.pendingDetail = pendingDetail
        self.updatedAt = updatedAt
    }
}

public struct Briefing: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sessionId: String
    public var project: String
    public var tool: Tool
    public var text: String
    public var priority: Priority
    public var voice: String
    public var speed: Double
    public var createdAt: Date

    public init(id: UUID = UUID(), sessionId: String, project: String, tool: Tool, text: String, priority: Priority, voice: String, speed: Double, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.tool = tool
        self.text = text
        self.priority = priority
        self.voice = voice
        self.speed = speed
        self.createdAt = createdAt
    }
}

public enum Mode: String, Codable, CaseIterable, Sendable {
    case enabled
    case dnd
    case disabled

    public var label: String {
        switch self {
        case .enabled: return "Enabled"
        case .dnd: return "Do Not Disturb"
        case .disabled: return "Disabled"
        }
    }
}

public enum Verbosity: String, Codable, CaseIterable, Sendable {
    case line
    case summary
}

public struct SessionPrefs: Codable, Equatable, Sendable {
    public var muted: Bool
    public var highOnly: Bool
    public var verbosity: Verbosity
    public var personaId: String?
    public var voice: String?
    public var speakFinished: Bool
    public var speakApprovals: Bool
    public var speakQuestions: Bool
    public var speakErrors: Bool
    public var speakSubagents: Bool

    public init(muted: Bool = false, highOnly: Bool = false, verbosity: Verbosity = .line, personaId: String? = nil, voice: String? = nil, speakFinished: Bool = true, speakApprovals: Bool = true, speakQuestions: Bool = true, speakErrors: Bool = true, speakSubagents: Bool = false) {
        self.muted = muted
        self.highOnly = highOnly
        self.verbosity = verbosity
        self.personaId = personaId
        self.voice = voice
        self.speakFinished = speakFinished
        self.speakApprovals = speakApprovals
        self.speakQuestions = speakQuestions
        self.speakErrors = speakErrors
        self.speakSubagents = speakSubagents
    }

    public static let `default` = SessionPrefs()
}

public struct Persona: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var voice: String
    public var speed: Double
    public var tone: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, voice: String, speed: Double, tone: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.voice = voice
        self.speed = speed
        self.tone = tone
        self.isBuiltIn = isBuiltIn
    }
}

public struct SummaryRequest: Sendable {
    public var session: Session
    public var event: AgentEvent
    public var persona: Persona
    public var verbosity: Verbosity
    public var model: String?

    public init(session: Session, event: AgentEvent, persona: Persona, verbosity: Verbosity, model: String?) {
        self.session = session
        self.event = event
        self.persona = persona
        self.verbosity = verbosity
        self.model = model
    }
}

public struct SummaryResult: Codable, Equatable, Sendable {
    public var say: String
    public var needs: String?
    public var priority: Priority
    public var summarizedBy: Tool?

    public init(say: String, needs: String? = nil, priority: Priority, summarizedBy: Tool? = nil) {
        self.say = say
        self.needs = needs
        self.priority = priority
        self.summarizedBy = summarizedBy
    }
}
