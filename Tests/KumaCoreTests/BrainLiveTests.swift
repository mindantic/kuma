import XCTest
@testable import KumaCore

final class BrainLiveTests: XCTestCase {
    func liveRequest(tool: Tool) -> SummaryRequest {
        let message = "I refactored the login flow to use the new session API. All 42 unit tests pass. The staging deploy is blocked because the DATABASE_URL secret is missing, so please add it in the deploy settings before I can continue."
        let s = Session(id: "live", tool: tool, project: "bion", cwd: "/tmp/bion", status: .done, lastMessage: message)
        let e = AgentEvent(sessionId: "live", tool: tool, kind: .stop, cwd: "/tmp/bion", message: message)
        return SummaryRequest(session: s, event: e, persona: PersonaLibrary.kuma, verbosity: .line, model: nil)
    }

    func testLiveSummaries() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KUMA_LIVE"] == "1", "set KUMA_LIVE=1 to run")
        let locator = ToolLocator()
        let summarizer = CLISummarizer(locator: locator)
        for tool in [Tool.claude, .opencode, .cursor, .codex] {
            guard locator.isInstalled(tool) else {
                print("KUMA_LIVE \(tool.rawValue): not installed")
                continue
            }
            let req = liveRequest(tool: tool)
            let raw = await summarizer.runRaw(tool: tool, prompt: SummaryPrompt.build(req))
            let parsed = raw.text.flatMap { SummaryParser.parse($0, base: .normal) }
            print("KUMA_LIVE \(tool.rawValue) path=\(locator.path(for: tool) ?? "-") latency=\(String(format: "%.1f", raw.duration))s raw=\(raw.text ?? "nil")")
            print("KUMA_LIVE \(tool.rawValue) parsed say=\(parsed?.say ?? "nil") needs=\(parsed?.needs ?? "nil") priority=\(parsed?.priority.label ?? "nil")")
        }
        let started = Date()
        let full = await summarizer.summarize(liveRequest(tool: .claude))
        print("KUMA_LIVE summarize(claude) by=\(full.summarizedBy?.rawValue ?? "template") latency=\(String(format: "%.1f", Date().timeIntervalSince(started)))s say=\(full.say)")
        XCTAssertFalse(full.say.isEmpty)
    }

    func testLiveDiscovery() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KUMA_LIVE"] == "1", "set KUMA_LIVE=1 to run")
        let d = Discovery()
        let claude = d.claudeSessions()
        let opencode = d.opencodeSessions()
        func tally(_ list: [Session]) -> String {
            Dictionary(grouping: list, by: \.status).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
        }
        print("KUMA_LIVE discovery claude=\(claude.count) [\(tally(claude))] opencode=\(opencode.count) [\(tally(opencode))] projects=\(Set((claude + opencode).map(\.project)).count)")
    }
}
