import XCTest
@testable import KumaCore

final class IngestNormalizerTests: XCTestCase {
    private func envelope(_ tool: Tool, _ event: String, _ json: String, env: [String: String] = [:]) -> HookEnvelope {
        HookEnvelope(tool: tool, event: event, payload: JSONValue.parse(Data(json.utf8)) ?? .null, env: env, parentPID: 42)
    }

    private func one(_ events: [AgentEvent], file: StaticString = #filePath, line: UInt = #line) -> AgentEvent? {
        XCTAssertEqual(events.count, 1, file: file, line: line)
        return events.first
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func transcript() throws -> String {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"fix the build"},"sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-4-5","role":"assistant","content":[{"type":"text","text":"Looking"}]},"sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Fix flaky build","sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","role":"assistant","content":[{"type":"text","text":"Done"}]},"sessionId":"s1"}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[]},"sessionId":"s1"}"#,
        ]
        let url = tempDir.appendingPathComponent("s1.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testClaudeStopReadsModelAndTitleFromTranscript() throws {
        let path = try transcript()
        let json = """
        {"session_id":"s1","transcript_path":"\(path)","cwd":"/Users/me/Codes/bion","permission_mode":"default","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"All 42 tests pass. I updated the parser."}
        """
        let e = try XCTUnwrap(one(ClaudeNormalizer().normalize(envelope(.claude, "Stop", json, env: ["TERM_PROGRAM": "iTerm.app", "TMUX": "/tmp/tmux-501/default,1,0"]))))
        XCTAssertEqual(e.kind, .stop)
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.cwd, "/Users/me/Codes/bion")
        XCTAssertEqual(e.message, "All 42 tests pass. I updated the parser.")
        XCTAssertEqual(e.model, "claude-sonnet-4-5")
        XCTAssertEqual(e.title, "Fix flaky build")
        XCTAssertEqual(e.terminal, "iTerm2 (tmux)")
        XCTAssertFalse(e.isSubagent)
    }

    func testClaudeSessionStartPrefersPayloadFields() throws {
        let json = #"{"session_id":"s2","transcript_path":"/nope.jsonl","cwd":"/p","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-4-5","session_title":"Refactor auth"}"#
        let e = try XCTUnwrap(one(ClaudeNormalizer().normalize(envelope(.claude, "SessionStart", json, env: ["TERM_PROGRAM": "Orca", "__CFBundleIdentifier": "com.stablyai.orca"]))))
        XCTAssertEqual(e.kind, .sessionStart)
        XCTAssertEqual(e.model, "claude-opus-4-5")
        XCTAssertEqual(e.title, "Refactor auth")
        XCTAssertEqual(e.terminal, "Orca")
    }

    func testClaudePreToolUseVariants() throws {
        let ask = #"{"session_id":"s","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should I use?","header":"DB","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false}]}}"#
        let q = try XCTUnwrap(one(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "PreToolUse", ask))))
        XCTAssertEqual(q.kind, .question)
        XCTAssertEqual(q.detail, "Which database should I use?")

        let plan = #"{"session_id":"s","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"1. Add table\n2. Migrate"}}"#
        let p = try XCTUnwrap(one(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "PreToolUse", plan))))
        XCTAssertEqual(p.kind, .permission)
        XCTAssertEqual(p.detail, "Plan approval: 1. Add table\n2. Migrate")

        let bash = #"{"session_id":"s","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run the test suite"}}"#
        let b = try XCTUnwrap(one(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "PreToolUse", bash))))
        XCTAssertEqual(b.kind, .toolUse)
        XCTAssertEqual(b.detail, "Bash: Run the test suite (npm test)")
    }

    func testClaudePermissionAndNotifications() throws {
        let perm = #"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf dist","description":"Clean build output"},"permission_suggestions":[]}"#
        let e = try XCTUnwrap(one(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "PermissionRequest", perm))))
        XCTAssertEqual(e.kind, .permission)
        XCTAssertEqual(e.detail, "Bash: Clean build output (rm -rf dist)")

        let note = #"{"session_id":"s","cwd":"/p","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#
        let n = try XCTUnwrap(one(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "Notification", note))))
        XCTAssertEqual(n.kind, .permission)
        XCTAssertEqual(n.detail, "Claude needs your permission to use Bash")
        XCTAssertTrue(n.reminder)
        XCTAssertFalse(e.reminder)

        let idle = #"{"session_id":"s","cwd":"/p","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#
        XCTAssertTrue(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "Notification", idle)).isEmpty)
    }

    func testClaudePermissionRequestMatchesPreToolUseForQuestionsAndPlans() throws {
        let n = ClaudeNormalizer(readTranscript: false)
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            let input = tool == "AskUserQuestion" ? #"{"questions":[{"question":"Which database?"}]}"# : #"{"plan":"Add table"}"#
            let pre = #"{"session_id":"s","cwd":"/p","tool_name":"\#(tool)","tool_input":\#(input)}"#
            let a = try XCTUnwrap(one(n.normalize(envelope(.claude, "PreToolUse", pre))))
            let b = try XCTUnwrap(one(n.normalize(envelope(.claude, "PermissionRequest", pre))))
            XCTAssertEqual(a.kind, b.kind, tool)
            XCTAssertEqual(a.detail, b.detail, tool)
        }
    }

    func testClaudeOtherEvents() throws {
        let n = ClaudeNormalizer(readTranscript: false)
        let prompt = #"{"session_id":"s","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"add dark mode"}"#
        XCTAssertEqual(n.normalize(envelope(.claude, "UserPromptSubmit", prompt)).first?.kind, .prompt)

        let sub = #"{"session_id":"s","cwd":"/p","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"Explore","last_assistant_message":"Found 3 call sites"}"#
        let s = try XCTUnwrap(one(n.normalize(envelope(.claude, "SubagentStop", sub))))
        XCTAssertEqual(s.kind, .subagentStop)
        XCTAssertEqual(s.agentType, "Explore")
        XCTAssertEqual(s.message, "Found 3 call sites")
        XCTAssertTrue(s.isSubagent)

        let fail = #"{"session_id":"s","cwd":"/p","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}"#
        let f = try XCTUnwrap(one(n.normalize(envelope(.claude, "StopFailure", fail))))
        XCTAssertEqual(f.kind, .error)
        XCTAssertEqual(f.detail, "rate_limit: 429 Too Many Requests")

        let end = #"{"session_id":"s","cwd":"/p","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#
        XCTAssertEqual(n.normalize(envelope(.claude, "SessionEnd", end)).first?.kind, .sessionEnd)

        XCTAssertTrue(n.normalize(envelope(.claude, "PostToolUse", #"{"session_id":"s","cwd":"/p"}"#)).isEmpty)
        XCTAssertTrue(n.normalize(envelope(.claude, "Stop", "not json")).isEmpty)
    }

    func testClaudeUsesHookEventNameWhenEventArgMissing() {
        let json = #"{"session_id":"s","cwd":"/p","hook_event_name":"Stop","last_assistant_message":"ok"}"#
        XCTAssertEqual(ClaudeNormalizer(readTranscript: false).normalize(envelope(.claude, "", json)).first?.kind, .stop)
    }

    func testCodex() throws {
        let n = Normalizers.for(.codex)
        let stop = #"{"session_id":"019a-codex","transcript_path":"/Users/me/.codex/sessions/rollout.jsonl","cwd":"/Users/me/Codes/api","hook_event_name":"Stop","model":"gpt-5.5-codex","permission_mode":"default","turn_id":"t9","stop_hook_active":false,"last_assistant_message":"Migrated the endpoints."}"#
        let s = try XCTUnwrap(one(n.normalize(envelope(.codex, "Stop", stop, env: ["TERM_PROGRAM": "ghostty"]))))
        XCTAssertEqual(s.kind, .stop)
        XCTAssertEqual(s.tool, .codex)
        XCTAssertEqual(s.model, "gpt-5.5-codex")
        XCTAssertEqual(s.message, "Migrated the endpoints.")
        XCTAssertEqual(s.terminal, "Ghostty")

        let perm = #"{"session_id":"019a-codex","cwd":"/c","hook_event_name":"PermissionRequest","model":"gpt-5.5-codex","turn_id":"t9","tool_name":"Bash","tool_input":{"command":"git push","description":"Push the branch"}}"#
        let p = try XCTUnwrap(one(n.normalize(envelope(.codex, "PermissionRequest", perm))))
        XCTAssertEqual(p.kind, .permission)
        XCTAssertEqual(p.detail, "Bash: Push the branch (git push)")

        let start = #"{"session_id":"019a-codex","cwd":"/c","hook_event_name":"SessionStart","model":"gpt-5.5-codex","source":"startup"}"#
        XCTAssertEqual(n.normalize(envelope(.codex, "SessionStart", start)).first?.kind, .sessionStart)
        XCTAssertTrue(n.normalize(envelope(.codex, "PostToolUse", start)).isEmpty)
    }

    func testCursor() throws {
        let n = Normalizers.for(.cursor)
        let common = #""conversation_id":"conv-1","generation_id":"gen-7","model":"claude-4.5-sonnet","model_id":"claude-sonnet-4-5","cursor_version":"2.4.1","workspace_roots":["/Users/me/Codes/web"],"user_email":null,"transcript_path":null"#
        let answer = "{\(common),\"hook_event_name\":\"afterAgentResponse\",\"text\":\"Added the settings page.\"}"
        let env = ["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"]
        let a = try XCTUnwrap(one(n.normalize(envelope(.cursor, "afterAgentResponse", answer, env: env))))
        XCTAssertEqual(a.kind, .stop)
        XCTAssertEqual(a.sessionId, "conv-1")
        XCTAssertEqual(a.cwd, "/Users/me/Codes/web")
        XCTAssertEqual(a.model, "claude-sonnet-4-5")
        XCTAssertEqual(a.message, "Added the settings page.")
        XCTAssertEqual(a.terminal, "Cursor")

        let stop = "{\(common),\"hook_event_name\":\"stop\",\"status\":\"completed\",\"loop_count\":0}"
        XCTAssertTrue(n.normalize(envelope(.cursor, "stop", stop)).isEmpty)

        let failed = "{\(common),\"hook_event_name\":\"stop\",\"status\":\"error\",\"loop_count\":0}"
        XCTAssertEqual(n.normalize(envelope(.cursor, "stop", failed)).first?.kind, .error)

        let prompt = "{\(common),\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"make it blue\",\"attachments\":[]}"
        let p = try XCTUnwrap(one(n.normalize(envelope(.cursor, "beforeSubmitPrompt", prompt))))
        XCTAssertEqual(p.kind, .prompt)
        XCTAssertEqual(p.detail, "make it blue")
    }

    func testOpenCode() throws {
        let n = Normalizers.for(.opencode)
        let idle = #"{"session_id":"ses_abc","directory":"/Users/me/Codes/cli","title":"Fix login","model":"anthropic/claude-sonnet-4-5","message":"Login works now."}"#
        let e = try XCTUnwrap(one(n.normalize(envelope(.opencode, "session.idle", idle, env: ["TERM_PROGRAM": "WezTerm"]))))
        XCTAssertEqual(e.kind, .stop)
        XCTAssertEqual(e.cwd, "/Users/me/Codes/cli")
        XCTAssertEqual(e.title, "Fix login")
        XCTAssertEqual(e.model, "anthropic/claude-sonnet-4-5")
        XCTAssertEqual(e.message, "Login works now.")
        XCTAssertEqual(e.terminal, "WezTerm")

        let child = #"{"session_id":"ses_abc","directory":"/d","agent_type":"subagent","message":"done"}"#
        XCTAssertEqual(n.normalize(envelope(.opencode, "session.idle", child)).first?.kind, .subagentStop)

        let perm = #"{"session_id":"ses_abc","directory":"/d","title":"Fix login","detail":"bash: rm -rf node_modules"}"#
        XCTAssertEqual(n.normalize(envelope(.opencode, "permission.asked", perm)).first?.kind, .permission)
        XCTAssertEqual(n.normalize(envelope(.opencode, "permission.updated", perm)).first?.detail, "bash: rm -rf node_modules")
        XCTAssertEqual(n.normalize(envelope(.opencode, "question.asked", perm)).first?.kind, .question)
        XCTAssertEqual(n.normalize(envelope(.opencode, "session.error", perm)).first?.kind, .error)

        let busy = #"{"session_id":"ses_abc","directory":"/d","status":"busy"}"#
        XCTAssertEqual(n.normalize(envelope(.opencode, "session.status", busy)).first?.kind, .toolUse)
        let idleStatus = #"{"session_id":"ses_abc","directory":"/d","status":"idle"}"#
        XCTAssertTrue(n.normalize(envelope(.opencode, "session.status", idleStatus)).isEmpty)

        let summary = #"{"session_id":"ses_x","directory":"/d","title":"kuma-summary 123","message":"x"}"#
        XCTAssertTrue(n.normalize(envelope(.opencode, "session.idle", summary)).isEmpty)
    }

    func testTerminalNames() {
        XCTAssertEqual(TerminalDetector.name(env: ["TERM_PROGRAM": "Apple_Terminal"]), "Terminal")
        XCTAssertEqual(TerminalDetector.name(env: ["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.microsoft.VSCode"]), "VS Code")
        XCTAssertEqual(TerminalDetector.name(env: ["TERM_PROGRAM": "tmux", "TMUX": "x", "__CFBundleIdentifier": "com.mitchellh.ghostty"]), "Ghostty (tmux)")
        XCTAssertEqual(TerminalDetector.name(env: ["__CFBundleIdentifier": "com.stablyai.orca"]), "Orca")
        XCTAssertEqual(TerminalDetector.name(env: ["ITERM_SESSION_ID": "w0t0p0"]), "iTerm2")
        XCTAssertNil(TerminalDetector.name(env: [:]))
    }

    func testTranscriptTailSkipsPartialFirstLine() throws {
        let url = tempDir.appendingPathComponent("big.jsonl")
        var text = ""
        for i in 0..<2000 {
            text += #"{"type":"assistant","message":{"model":"m-\#(i)","content":[{"type":"text","text":"padding padding padding padding"}]}}"# + "\n"
        }
        text += #"{"type":"custom-title","customTitle":"Named session","sessionId":"x"}"# + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let info = TranscriptReader.tail(path: url.path, maxBytes: 4096)
        XCTAssertEqual(info.model, "m-1999")
        XCTAssertEqual(info.title, "Named session")
    }
}
