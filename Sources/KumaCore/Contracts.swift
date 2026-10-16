import Foundation

public enum KumaPaths {
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["KUMA_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kuma", isDirectory: true)
    }

    public static var socket: URL { appSupport.appendingPathComponent("kuma.sock") }
    public static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    public static var personas: URL { appSupport.appendingPathComponent("personas", isDirectory: true) }
    public static var voice: URL { appSupport.appendingPathComponent("voice", isDirectory: true) }
    public static var history: URL { appSupport.appendingPathComponent("history.jsonl") }
    public static var log: URL { appSupport.appendingPathComponent("kuma.log") }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: personas, withIntermediateDirectories: true)
    }
}

public enum KumaEnv {
    public static let summaryGuard = "KUMA_SUMMARY"
}

public protocol EventNormalizing: Sendable {
    func normalize(_ envelope: HookEnvelope) -> [AgentEvent]
}

public protocol Summarizing: Sendable {
    func summarize(_ request: SummaryRequest) async -> SummaryResult
}

public protocol VoiceEngine: AnyObject {
    func speak(_ text: String, voice: String, speed: Double) async throws
    func stop()
}

public struct BriefingDecision: Equatable, Sendable {
    public var shouldBrief: Bool
    public var basePriority: Priority

    public init(shouldBrief: Bool, basePriority: Priority) {
        self.shouldBrief = shouldBrief
        self.basePriority = basePriority
    }

    public static let skip = BriefingDecision(shouldBrief: false, basePriority: .fyi)
}

public struct KumaSettings: Codable, Equatable, Sendable {
    public var mode: Mode
    public var personaId: String
    public var voice: String
    public var speed: Double
    public var watchedTools: [Tool]
    public var summaryModels: [String: String]
    public var defaultPrefs: SessionPrefs
    public var projectPrefs: [String: SessionPrefs]
    public var sessionPrefs: [String: SessionPrefs]
    public var customPersonas: [Persona]
    public var launchAtLogin: Bool

    public init(mode: Mode = .enabled, personaId: String = "kuma", voice: String = "am_onyx", speed: Double = 1.0, watchedTools: [Tool] = [.claude, .opencode, .codex, .cursor], summaryModels: [String: String] = ["claude": "haiku"], defaultPrefs: SessionPrefs = .default, projectPrefs: [String: SessionPrefs] = [:], sessionPrefs: [String: SessionPrefs] = [:], customPersonas: [Persona] = [], launchAtLogin: Bool = false) {
        self.mode = mode
        self.personaId = personaId
        self.voice = voice
        self.speed = speed
        self.watchedTools = watchedTools
        self.summaryModels = summaryModels
        self.defaultPrefs = defaultPrefs
        self.projectPrefs = projectPrefs
        self.sessionPrefs = sessionPrefs
        self.customPersonas = customPersonas
        self.launchAtLogin = launchAtLogin
    }

    public func prefs(sessionId: String, project: String) -> SessionPrefs {
        sessionPrefs[sessionId] ?? projectPrefs[project] ?? defaultPrefs
    }
}
