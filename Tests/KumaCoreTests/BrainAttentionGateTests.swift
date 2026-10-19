import XCTest
@testable import KumaCore

final class BrainAttentionGateTests: XCTestCase {
    private func ev(_ kind: EventKind, id: String = "s1", detail: String? = nil, reminder: Bool = false) -> AgentEvent {
        AgentEvent(sessionId: id, tool: .claude, kind: kind, cwd: "/tmp/bion", detail: detail, reminder: reminder)
    }

    func testClaudeQuestionHooksSpeakOnce() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.question, detail: "Which database?")))
        XCTAssertFalse(gate.admit(ev(.question, detail: "Which database?")))
        XCTAssertFalse(gate.admit(ev(.permission, detail: "Claude needs your permission to use AskUserQuestion", reminder: true)))
        XCTAssertTrue(gate.isWaiting(sessionId: "s1"))
    }

    func testApprovalAndReminderSpeakOnce() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.toolUse, detail: "Bash: npm test")))
        XCTAssertTrue(gate.admit(ev(.permission, detail: "Bash: npm test")))
        XCTAssertFalse(gate.admit(ev(.permission, detail: "Claude needs your permission to use Bash", reminder: true)))
    }

    func testDistinctApprovalWhileWaitingStillSpeaks() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.permission, detail: "Bash: npm test")))
        XCTAssertTrue(gate.admit(ev(.permission, detail: "Write: README.md")))
        XCTAssertFalse(gate.admit(ev(.permission, detail: "Write: README.md")))
    }

    func testReminderWithoutOpenRequestSpeaks() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.question, detail: "Pick a server", reminder: true)))
        XCTAssertFalse(gate.admit(ev(.question, detail: "Pick a server", reminder: true)))
    }

    func testActivityReopensGate() {
        for reset in [EventKind.prompt, .toolUse, .stop, .error, .sessionStart, .sessionEnd] {
            var gate = AttentionGate()
            XCTAssertTrue(gate.admit(ev(.question, detail: "Which database?")))
            XCTAssertTrue(gate.admit(ev(reset)))
            XCTAssertFalse(gate.isWaiting(sessionId: "s1"), "\(reset)")
            XCTAssertTrue(gate.admit(ev(.question, detail: "Which database?")), "\(reset)")
        }
    }

    func testSubagentStopKeepsGateClosed() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.permission, detail: "Bash: npm test")))
        XCTAssertTrue(gate.admit(ev(.subagentStop)))
        XCTAssertFalse(gate.admit(ev(.permission, detail: "Claude needs your permission to use Bash", reminder: true)))
    }

    func testSessionsAreIndependent() {
        var gate = AttentionGate()
        XCTAssertTrue(gate.admit(ev(.question, id: "a", detail: "Which database?")))
        XCTAssertTrue(gate.admit(ev(.question, id: "b", detail: "Which database?")))
        XCTAssertFalse(gate.admit(ev(.question, id: "a", detail: "Which database?")))
    }
}
