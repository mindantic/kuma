import XCTest
@testable import KumaCore

final class BrainPolicyTests: XCTestCase {
    let all: [Tool] = [.claude, .opencode, .codex, .cursor]
    let session = Session(id: "s1", tool: .claude, project: "bion", cwd: "/tmp/bion")

    func decide(_ kind: EventKind, prefs: SessionPrefs = .default, mode: Mode = .enabled, watched: [Tool]? = nil, tool: Tool = .claude) -> BriefingDecision {
        BriefingPolicy.decide(event: brainEvent(kind, tool: tool), session: session, prefs: prefs, mode: mode, watched: watched ?? all)
    }

    func testSpeakableKindsAndPriorities() {
        XCTAssertEqual(decide(.permission), BriefingDecision(shouldBrief: true, basePriority: .high))
        XCTAssertEqual(decide(.question), BriefingDecision(shouldBrief: true, basePriority: .high))
        XCTAssertEqual(decide(.error), BriefingDecision(shouldBrief: true, basePriority: .high))
        XCTAssertEqual(decide(.stop), BriefingDecision(shouldBrief: true, basePriority: .normal))
        for k in [EventKind.prompt, .toolUse, .sessionStart, .sessionEnd] {
            XCTAssertFalse(decide(k).shouldBrief, "\(k)")
        }
    }

    func testSubagentsOnlyWhenEnabled() {
        XCTAssertFalse(decide(.subagentStop).shouldBrief)
        XCTAssertEqual(decide(.subagentStop, prefs: SessionPrefs(speakSubagents: true)), BriefingDecision(shouldBrief: true, basePriority: .fyi))
        XCTAssertFalse(decide(.subagentStop, prefs: SessionPrefs(speakSubagents: true), mode: .dnd).shouldBrief)
    }

    func testDisabledUnwatchedMuted() {
        XCTAssertFalse(decide(.permission, mode: .disabled).shouldBrief)
        XCTAssertFalse(decide(.permission, watched: [.opencode]).shouldBrief)
        XCTAssertTrue(decide(.permission, watched: [.opencode], tool: .opencode).shouldBrief)
        XCTAssertFalse(decide(.permission, prefs: SessionPrefs(muted: true)).shouldBrief)
    }

    func testPerKindToggles() {
        XCTAssertFalse(decide(.permission, prefs: SessionPrefs(speakApprovals: false)).shouldBrief)
        XCTAssertFalse(decide(.question, prefs: SessionPrefs(speakQuestions: false)).shouldBrief)
        XCTAssertFalse(decide(.error, prefs: SessionPrefs(speakErrors: false)).shouldBrief)
        XCTAssertFalse(decide(.stop, prefs: SessionPrefs(speakFinished: false)).shouldBrief)
        XCTAssertTrue(decide(.stop, prefs: SessionPrefs(speakApprovals: false)).shouldBrief)
    }

    func testDndAndHighOnly() {
        XCTAssertFalse(decide(.stop, mode: .dnd).shouldBrief)
        XCTAssertTrue(decide(.permission, mode: .dnd).shouldBrief)
        XCTAssertTrue(decide(.error, mode: .dnd).shouldBrief)
        XCTAssertFalse(decide(.stop, prefs: SessionPrefs(highOnly: true)).shouldBrief)
        XCTAssertTrue(decide(.question, prefs: SessionPrefs(highOnly: true)).shouldBrief)
    }

    func testFinalPriorityAndShouldSpeak() {
        XCTAssertEqual(BriefingPolicy.finalPriority(base: .normal, summary: SummaryResult(say: "x", priority: .high)), .high)
        XCTAssertEqual(BriefingPolicy.finalPriority(base: .high, summary: SummaryResult(say: "x", priority: .fyi)), .high)
        XCTAssertEqual(BriefingPolicy.finalPriority(base: .normal, summary: SummaryResult(say: "x", priority: .fyi)), .normal)
        XCTAssertEqual(BriefingPolicy.finalPriority(base: .fyi, summary: SummaryResult(say: "x", priority: .high)), .fyi)

        XCTAssertTrue(BriefingPolicy.shouldSpeak(final: .normal, prefs: .default, mode: .enabled))
        XCTAssertFalse(BriefingPolicy.shouldSpeak(final: .normal, prefs: .default, mode: .dnd))
        XCTAssertTrue(BriefingPolicy.shouldSpeak(final: .high, prefs: .default, mode: .dnd))
        XCTAssertFalse(BriefingPolicy.shouldSpeak(final: .normal, prefs: SessionPrefs(highOnly: true), mode: .enabled))
        XCTAssertTrue(BriefingPolicy.shouldSpeak(final: .high, prefs: SessionPrefs(highOnly: true), mode: .enabled))
        XCTAssertFalse(BriefingPolicy.shouldSpeak(final: .high, prefs: .default, mode: .disabled))
        XCTAssertFalse(BriefingPolicy.shouldSpeak(final: .high, prefs: SessionPrefs(muted: true), mode: .enabled))
    }

    func testPersonaLibrary() {
        XCTAssertEqual(PersonaLibrary.persona(id: nil, custom: []).id, "kuma")
        XCTAssertEqual(PersonaLibrary.persona(id: "butler", custom: []).id, "jarvis")
        XCTAssertEqual(PersonaLibrary.persona(id: "luffy", custom: []).name, "Luffy")
        XCTAssertEqual(PersonaLibrary.builtIns.count, 11)
        let custom = Persona(id: "pirate", name: "Pirate", voice: "am_adam", speed: 1.1, tone: "Arr.")
        let clash = Persona(id: "kuma", name: "Fake", voice: "x", speed: 1, tone: "x")
        XCTAssertEqual(PersonaLibrary.all(custom: [custom, clash]).map(\.id), PersonaLibrary.builtIns.map(\.id) + ["pirate"])
        XCTAssertEqual(PersonaLibrary.persona(id: "pirate", custom: [custom]).voice, "am_adam")
        XCTAssertEqual(PersonaLibrary.persona(id: "missing", custom: []).id, "kuma")
    }
}
