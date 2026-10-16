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
    public var summarizerRoutes: [String: String]
    public var commandPaths: [String: String]
    public var customSummarizers: [CustomSummarizer]

    public init(mode: Mode = .enabled, personaId: String = "kuma", voice: String = "am_onyx", speed: Double = 1.0, watchedTools: [Tool] = [.claude, .opencode, .codex, .cursor], summaryModels: [String: String] = ["claude": "haiku"], defaultPrefs: SessionPrefs = .default, projectPrefs: [String: SessionPrefs] = [:], sessionPrefs: [String: SessionPrefs] = [:], customPersonas: [Persona] = [], launchAtLogin: Bool = false, summarizerRoutes: [String: String] = [:], commandPaths: [String: String] = [:], customSummarizers: [CustomSummarizer] = []) {
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
        self.summarizerRoutes = summarizerRoutes
        self.commandPaths = commandPaths
        self.customSummarizers = customSummarizers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KumaSettings()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        personaId = try c.decodeIfPresent(String.self, forKey: .personaId) ?? d.personaId
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        watchedTools = try c.decodeIfPresent([Tool].self, forKey: .watchedTools) ?? d.watchedTools
        summaryModels = try c.decodeIfPresent([String: String].self, forKey: .summaryModels) ?? d.summaryModels
        defaultPrefs = try c.decodeIfPresent(SessionPrefs.self, forKey: .defaultPrefs) ?? d.defaultPrefs
        projectPrefs = try c.decodeIfPresent([String: SessionPrefs].self, forKey: .projectPrefs) ?? d.projectPrefs
        sessionPrefs = try c.decodeIfPresent([String: SessionPrefs].self, forKey: .sessionPrefs) ?? d.sessionPrefs
        customPersonas = try c.decodeIfPresent([Persona].self, forKey: .customPersonas) ?? d.customPersonas
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        summarizerRoutes = try c.decodeIfPresent([String: String].self, forKey: .summarizerRoutes) ?? d.summarizerRoutes
        commandPaths = try c.decodeIfPresent([String: String].self, forKey: .commandPaths) ?? d.commandPaths
        customSummarizers = try c.decodeIfPresent([CustomSummarizer].self, forKey: .customSummarizers) ?? d.customSummarizers
    }

    public func prefs(sessionId: String, project: String) -> SessionPrefs {
        sessionPrefs[sessionId] ?? projectPrefs[project] ?? defaultPrefs
    }
}

public struct CustomSummarizer: Codable, Equatable, Identifiable, Sendable {
    public static let promptToken = "{prompt}"
    public static let modelToken = "{model}"

    public var id: String
    public var name: String
    public var command: String
    public var arguments: String
    public var model: String

    public init(id: String = "custom-\(UUID().uuidString.prefix(8).lowercased())", name: String, command: String, arguments: String = "{prompt}", model: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.model = model
    }

    public func argumentList(prompt: String) -> [String] {
        var args: [String] = []
        var usedPrompt = false
        for token in Self.tokenize(arguments) {
            if token.contains(Self.modelToken), model.isEmpty { continue }
            if token.contains(Self.promptToken) { usedPrompt = true }
            args.append(token.replacingOccurrences(of: Self.modelToken, with: model).replacingOccurrences(of: Self.promptToken, with: prompt))
        }
        if !usedPrompt { args.append(prompt) }
        return args
    }

    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var inToken = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inToken = true
            } else if ch.isWhitespace {
                if inToken { tokens.append(current) }
                current = ""
                inToken = false
            } else {
                current.append(ch)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
