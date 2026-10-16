import Foundation

public struct RunnerContext: Sendable {
    public var executable: String
    public var environment: [String: String]
    public var directory: URL
    public var deadline: Date

    public var remaining: TimeInterval { max(0.5, deadline.timeIntervalSinceNow) }
}

public protocol SummaryRunner: Sendable {
    var tool: Tool { get }
    func run(prompt: String, model: String?, context: RunnerContext) async -> String?
}

public struct ClaudeRunner: SummaryRunner {
    public let tool = Tool.claude
    public static let defaultModel = "haiku"

    public init() {}

    public static func arguments(prompt: String, model: String?, bare: Bool) -> [String] {
        var args = ["-p"]
        if bare { args.append("--bare") }
        args += ["--model", model ?? defaultModel, "--output-format", "json", "--tools", "", "--no-session-persistence"]
        if !bare { args += ["--setting-sources", "", "--strict-mcp-config"] }
        args += ["--", prompt]
        return args
    }

    public func run(prompt: String, model: String?, context: RunnerContext) async -> String? {
        let hasKey = !(context.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
        for bare in hasKey ? [true, false] : [false, true] {
            if context.deadline.timeIntervalSinceNow <= 0.5 { return nil }
            let out = await ProcessRunner.run(executable: context.executable, arguments: Self.arguments(prompt: prompt, model: model, bare: bare), environment: context.environment, directory: context.directory, timeout: context.remaining)
            if out.timedOut { return nil }
            if let text = Self.parseEnvelope(out.stdout) { return text }
        }
        return nil
    }

    public static func parseEnvelope(_ stdout: String) -> String? {
        guard let start = stdout.firstIndex(of: "{") else { return nil }
        guard let obj = JSONValue.parse(Data(stdout[start...].utf8)) else { return nil }
        if obj["is_error"]?.bool == true { return nil }
        guard let result = obj["result"]?.string, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }
}

public struct OpenCodeRunner: SummaryRunner {
    public let tool = Tool.opencode
    public static let title = "kuma-summary"

    public init() {}

    public static func arguments(prompt: String, model: String?) -> [String] {
        var args = ["run", "--standalone", "--format", "json", "--title", title]
        if let model, !model.isEmpty { args += ["-m", model] }
        args += ["--", prompt]
        return args
    }

    public func run(prompt: String, model: String?, context: RunnerContext) async -> String? {
        let out = await ProcessRunner.run(executable: context.executable, arguments: Self.arguments(prompt: prompt, model: model), environment: context.environment, directory: context.directory, timeout: context.remaining)
        if out.timedOut { return nil }
        return Self.parseEvents(out.stdout)
    }

    public static func parseEvents(_ stdout: String) -> String? {
        var texts: [String] = []
        for line in stdout.split(separator: "\n") {
            guard let obj = JSONValue.parse(Data(line.utf8)) else { continue }
            if obj["type"]?.string == "error" { return nil }
            guard obj["type"]?.string == "text", let t = obj["part"]?["text"]?.string else { continue }
            texts.append(t)
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

public struct CursorRunner: SummaryRunner {
    public let tool = Tool.cursor

    public init() {}

    public static func arguments(prompt: String, model: String?) -> [String] {
        var args = ["-p", "--output-format", "json", "--trust", "--mode", "ask"]
        if let model, !model.isEmpty { args += ["--model", model] }
        args += ["--", prompt]
        return args
    }

    public func run(prompt: String, model: String?, context: RunnerContext) async -> String? {
        let out = await ProcessRunner.run(executable: context.executable, arguments: Self.arguments(prompt: prompt, model: model), environment: context.environment, directory: context.directory, timeout: context.remaining)
        if out.timedOut { return nil }
        return ClaudeRunner.parseEnvelope(out.stdout)
    }
}

public struct CodexRunner: SummaryRunner {
    public let tool = Tool.codex

    public init() {}

    public static func arguments(prompt: String, model: String?) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check"]
        if let model, !model.isEmpty { args += ["-m", model] }
        args += ["--", prompt]
        return args
    }

    public func run(prompt: String, model: String?, context: RunnerContext) async -> String? {
        let out = await ProcessRunner.run(executable: context.executable, arguments: Self.arguments(prompt: prompt, model: model), environment: context.environment, directory: context.directory, timeout: context.remaining)
        if out.timedOut { return nil }
        return Self.parseEvents(out.stdout)
    }

    public static func parseEvents(_ stdout: String) -> String? {
        var last: String?
        for line in stdout.split(separator: "\n") {
            guard let obj = JSONValue.parse(Data(line.utf8)) else { continue }
            if let item = obj["item"], item["type"]?.string == "agent_message", let t = item["text"]?.string {
                last = t
            } else if let msg = obj["msg"], msg["type"]?.string == "agent_message", let t = msg["message"]?.string {
                last = t
            }
        }
        return last
    }
}

public final class CLISummarizer: Summarizing, @unchecked Sendable {
    public static let fallbackOrder: [Tool] = [.claude, .opencode, .cursor, .codex]

    private let locator: ToolLocator
    private let runners: [Tool: SummaryRunner]
    private let models: [Tool: String]
    private let timeout: TimeInterval
    private let template = TemplateSummarizer()
    private let workDir: URL
    private let commandPaths: [Tool: String]
    private let routes: [Tool: String]
    private let customs: [CustomSummarizer]

    public init(
        locator: ToolLocator = .shared,
        models: [Tool: String] = [.claude: ClaudeRunner.defaultModel],
        timeout: TimeInterval = 25,
        runners: [SummaryRunner] = [ClaudeRunner(), OpenCodeRunner(), CursorRunner(), CodexRunner()],
        commandPaths: [Tool: String] = [:],
        routes: [Tool: String] = [:],
        customs: [CustomSummarizer] = []
    ) {
        self.locator = locator
        self.models = models
        self.timeout = timeout
        self.commandPaths = commandPaths
        self.routes = routes
        self.customs = customs
        var map: [Tool: SummaryRunner] = [:]
        for r in runners { map[r.tool] = r }
        self.runners = map
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-summary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir
    }

    public convenience init(settings: KumaSettings, locator: ToolLocator = .shared) {
        var models: [Tool: String] = [.claude: ClaudeRunner.defaultModel]
        for (k, v) in settings.summaryModels {
            if let t = Tool(rawValue: k), !v.isEmpty { models[t] = v }
        }
        var paths: [Tool: String] = [:]
        for (k, v) in settings.commandPaths {
            if let t = Tool(rawValue: k), !v.isEmpty { paths[t] = v }
        }
        var routes: [Tool: String] = [:]
        for (k, v) in settings.summarizerRoutes {
            if let t = Tool(rawValue: k), !v.isEmpty { routes[t] = v }
        }
        self.init(locator: locator, models: models, commandPaths: paths, routes: routes, customs: settings.customSummarizers)
    }

    public func executable(for tool: Tool) -> String? {
        if let custom = commandPaths[tool], FileManager.default.isExecutableFile(atPath: custom) { return custom }
        return locator.path(for: tool)
    }

    public func resolve(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in locator.fullPATH.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(trimmed)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func runCustom(_ custom: CustomSummarizer, prompt: String) async -> String? {
        guard let exe = resolve(command: custom.command) else { return nil }
        let out = await ProcessRunner.run(executable: exe, arguments: custom.argumentList(prompt: prompt), environment: childEnvironment, directory: workDir, timeout: timeout)
        if out.timedOut { return nil }
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func order(for tool: Tool) -> [Tool] {
        var list = [tool]
        for t in fallbackOrder where t != tool { list.append(t) }
        return list.filter { $0 != .other }
    }

    public static func prefersTemplate(_ request: SummaryRequest) -> Bool {
        switch request.event.kind {
        case .permission, .question:
            let msg = request.event.message ?? ""
            return msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    public var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "OPENCODE", "OPENCODE_SESSION_ID", "CURSOR_AGENT"] {
            env[key] = nil
        }
        env[KumaEnv.summaryGuard] = "1"
        env["PATH"] = locator.fullPATH
        return env
    }

    public func summarize(_ request: SummaryRequest) async -> SummaryResult {
        if Self.prefersTemplate(request) { return template.result(for: request) }
        let prompt = SummaryPrompt.build(request)
        let base = BriefingPolicy.basePriority(for: request.event.kind) ?? .normal
        let env = childEnvironment
        let route = routes[request.session.tool]
        if let route, let custom = customs.first(where: { $0.id == route }),
           let raw = await runCustom(custom, prompt: prompt),
           var parsed = SummaryParser.parse(raw, base: base) {
            parsed.say = SummaryParser.firstSentences(parsed.say, 2)
            parsed.summarizedBy = .other
            return parsed
        }
        let primary = route.flatMap(Tool.init(rawValue:)) ?? request.session.tool
        for tool in Self.order(for: primary) {
            guard let runner = runners[tool], let exe = executable(for: tool) else { continue }
            let model = (tool == request.session.tool ? request.model : nil) ?? models[tool]
            let ctx = RunnerContext(executable: exe, environment: env, directory: workDir, deadline: Date().addingTimeInterval(timeout))
            guard let raw = await runner.run(prompt: prompt, model: model, context: ctx),
                  var parsed = SummaryParser.parse(raw, base: base) else { continue }
            parsed.say = SummaryParser.firstSentences(parsed.say, 2)
            parsed.summarizedBy = tool
            return parsed
        }
        return template.result(for: request)
    }

    public func runRaw(tool: Tool, prompt: String, model: String? = nil) async -> (text: String?, duration: TimeInterval) {
        let started = Date()
        guard let runner = runners[tool], let exe = executable(for: tool) else { return (nil, 0) }
        let ctx = RunnerContext(executable: exe, environment: childEnvironment, directory: workDir, deadline: Date().addingTimeInterval(timeout))
        let text = await runner.run(prompt: prompt, model: model ?? models[tool], context: ctx)
        return (text, Date().timeIntervalSince(started))
    }

    public func runRaw(custom: CustomSummarizer, prompt: String) async -> (text: String?, duration: TimeInterval) {
        let started = Date()
        let text = await runCustom(custom, prompt: prompt)
        return (text, Date().timeIntervalSince(started))
    }
}
