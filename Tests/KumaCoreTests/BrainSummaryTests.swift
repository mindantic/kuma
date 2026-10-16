import XCTest
@testable import KumaCore

struct FakeRunner: SummaryRunner {
    let tool: Tool
    let reply: String?
    let calls: CallLog

    func run(prompt: String, model: String?, context: RunnerContext) async -> String? {
        calls.add("\(tool.rawValue):\(model ?? "-")")
        XCTAssertEqual(context.environment[KumaEnv.summaryGuard], "1")
        return reply
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class BrainSummaryTests: XCTestCase {
    func request(_ kind: EventKind, tool: Tool = .claude, message: String? = nil, detail: String? = nil, model: String? = nil) -> SummaryRequest {
        let s = Session(id: "s1", tool: tool, project: "bion", cwd: "/tmp/bion", status: .done, pendingDetail: detail)
        return SummaryRequest(session: s, event: brainEvent(kind, tool: tool, message: message, detail: detail), persona: PersonaLibrary.kuma, verbosity: .line, model: model)
    }

    func fakeHome(with tools: [String]) throws -> URL {
        let home = brainTempDir()
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for t in tools {
            let p = bin.appendingPathComponent(t)
            try "#!/bin/sh\n".write(to: p, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        return home
    }

    func testParseStrictJSON() {
        let r = SummaryParser.parse(#"{"say":"bion is done. Tests pass.","needs":null,"priority":"normal"}"#, base: .normal)
        XCTAssertEqual(r, SummaryResult(say: "bion is done. Tests pass.", needs: nil, priority: .normal))
    }

    func testParseWrappedJSON() {
        let raw = "Sure! Here you go:\n```json\n{\"say\": \"Deploy is blocked {badly}.\", \"needs\": \"Fix the failing test\", \"priority\": \"HIGH\"}\n```\nThanks"
        let r = SummaryParser.parse(raw, base: .normal)
        XCTAssertEqual(r?.say, "Deploy is blocked {badly}.")
        XCTAssertEqual(r?.needs, "Fix the failing test")
        XCTAssertEqual(r?.priority, .high)
    }

    func testParseBadPriorityAndNullString() {
        let r = SummaryParser.parse(#"{"say":"ok","needs":"null","priority":"whatever"}"#, base: .fyi)
        XCTAssertEqual(r?.priority, .fyi)
        XCTAssertNil(r?.needs)
    }

    func testParsePlainTextFallback() {
        let r = SummaryParser.parse("**bion** finished the refactor. All tests pass. It also updated docs. More text.", base: .normal)
        XCTAssertEqual(r?.say, "bion finished the refactor. All tests pass.")
        XCTAssertEqual(r?.priority, .normal)
        XCTAssertNil(SummaryParser.parse("   ", base: .normal))
        XCTAssertNil(SummaryParser.parse("{broken json", base: .normal))
    }

    func testTemplateLines() {
        let t = TemplateSummarizer()
        XCTAssertEqual(t.result(for: request(.permission, detail: "Bash")).say, "bion needs approval to run Bash.")
        XCTAssertEqual(t.result(for: request(.permission, detail: "Bash: rm -rf build")).say, "bion needs approval to run Bash.")
        XCTAssertEqual(t.result(for: request(.permission)).say, "bion needs your approval.")
        XCTAssertEqual(t.result(for: request(.question)).say, "bion is asking you a question.")
        XCTAssertEqual(t.result(for: request(.stop)).say, "bion is done.")
        XCTAssertEqual(t.result(for: request(.error)).say, "bion hit an error.")
        XCTAssertEqual(t.result(for: request(.error)).priority, .high)
        XCTAssertEqual(t.result(for: request(.stop)).priority, .normal)
    }

    func testPromptContents() {
        let long = String(repeating: "a", count: 5000) + "TAIL"
        let p = SummaryPrompt.build(request(.stop, message: long, detail: nil))
        XCTAssertTrue(p.contains("Project: bion"))
        XCTAssertTrue(p.contains("Tool: Claude Code"))
        XCTAssertTrue(p.contains("TAIL"))
        XCTAssertFalse(p.contains(String(repeating: "a", count: 4001)))
        XCTAssertTrue(p.contains("at most one sentence"))
        XCTAssertTrue(p.contains("\"priority\""))
    }

    func testOrder() {
        XCTAssertEqual(CLISummarizer.order(for: .codex), [.codex, .claude, .opencode, .cursor])
        XCTAssertEqual(CLISummarizer.order(for: .claude), [.claude, .opencode, .cursor, .codex])
        XCTAssertEqual(CLISummarizer.order(for: .other), [.claude, .opencode, .cursor, .codex])
    }

    func testOwnToolFirstThenFallback() async throws {
        let home = try fakeHome(with: ["claude", "opencode"])
        let locator = ToolLocator(home: home, shell: nil)
        let log = CallLog()
        let s = CLISummarizer(locator: locator, models: [.claude: "haiku"], runners: [
            FakeRunner(tool: .claude, reply: #"{"say":"From claude.","needs":null,"priority":"normal"}"#, calls: log),
            FakeRunner(tool: .opencode, reply: nil, calls: log),
            FakeRunner(tool: .cursor, reply: "never", calls: log),
        ])
        let r = await s.summarize(request(.stop, tool: .opencode, message: "Finished.", model: "zai/glm"))
        XCTAssertEqual(r.say, "From claude.")
        XCTAssertEqual(r.summarizedBy, .claude)
        XCTAssertEqual(log.all, ["opencode:zai/glm", "claude:haiku"])
    }

    func testFallsBackToTemplate() async throws {
        let home = try fakeHome(with: ["claude"])
        let log = CallLog()
        let s = CLISummarizer(locator: ToolLocator(home: home, shell: nil), runners: [FakeRunner(tool: .claude, reply: nil, calls: log)])
        let r = await s.summarize(request(.stop, message: "Done."))
        XCTAssertEqual(r.say, "bion is done.")
        XCTAssertNil(r.summarizedBy)
        XCTAssertEqual(log.all.count, 1)
    }

    func testPermissionWithoutMessageUsesTemplate() async throws {
        let home = try fakeHome(with: ["claude"])
        let log = CallLog()
        let s = CLISummarizer(locator: ToolLocator(home: home, shell: nil), runners: [FakeRunner(tool: .claude, reply: "x", calls: log)])
        let r = await s.summarize(request(.permission, detail: "Bash"))
        XCTAssertEqual(r.say, "bion needs approval to run Bash.")
        XCTAssertTrue(log.all.isEmpty)
    }

    func testEnvelopeParsers() {
        XCTAssertEqual(ClaudeRunner.parseEnvelope(#"{"type":"result","is_error":false,"result":"hi"}"#), "hi")
        XCTAssertNil(ClaudeRunner.parseEnvelope(#"{"type":"result","is_error":true,"result":"Not logged in"}"#))
        let oc = """
        {"type":"step_start","part":{"type":"step-start"}}
        {"type":"text","part":{"type":"text","text":"{\\"say\\":\\"ok\\"}"}}
        """
        XCTAssertEqual(OpenCodeRunner.parseEvents(oc), #"{"say":"ok"}"#)
        let codex = #"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#
        XCTAssertEqual(CodexRunner.parseEvents(codex), "done")
        XCTAssertEqual(ClaudeRunner.arguments(prompt: "p", model: nil, bare: false), ["-p", "--model", "haiku", "--output-format", "json", "--tools", "", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--", "p"])
    }

    func testLocatorFindsCandidateDirAndBuildsPath() throws {
        let home = try fakeHome(with: ["cursor-agent"])
        let locator = ToolLocator(home: home, shell: nil)
        XCTAssertEqual(locator.path(for: .cursor), home.appendingPathComponent(".local/bin/cursor-agent").path)
        XCTAssertNil(locator.path(for: .codex))
        XCTAssertTrue(locator.fullPATH.contains(home.appendingPathComponent(".local/bin").path))
        XCTAssertTrue(locator.fullPATH.contains("/usr/bin"))
    }

    func testProcessRunnerTimeout() async {
        let out = await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.5)
        XCTAssertTrue(out.timedOut)
        XCTAssertLessThan(out.duration, 3)
        let echo = await ProcessRunner.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5)
        XCTAssertEqual(echo.stdout, "hello\n")
        XCTAssertTrue(echo.succeeded)
    }
}
