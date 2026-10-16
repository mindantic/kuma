import XCTest
@testable import KumaCore

final class BrainSummarizerConfigTests: XCTestCase {
    func testOldSettingsFileStillDecodes() throws {
        let json = #"{"mode":"dnd","personaId":"butler","voice":"bm_george","speed":1.1,"watchedTools":["claude"],"summaryModels":{"claude":"sonnet"},"defaultPrefs":{"muted":false,"highOnly":false,"verbosity":"line","speakFinished":true,"speakApprovals":true,"speakQuestions":true,"speakErrors":true,"speakSubagents":false},"projectPrefs":{},"sessionPrefs":{},"customPersonas":[],"launchAtLogin":true}"#
        let settings = try JSONDecoder().decode(KumaSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.mode, .dnd)
        XCTAssertEqual(settings.summaryModels["claude"], "sonnet")
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.customSummarizers.isEmpty)
        XCTAssertTrue(settings.summarizerRoutes.isEmpty)
        let round = try JSONDecoder().decode(KumaSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
    }

    func testArgumentTemplate() {
        var custom = CustomSummarizer(name: "x", command: "llm", arguments: "-p {prompt} --model {model} --label 'two words'", model: "fast")
        XCTAssertEqual(custom.argumentList(prompt: "hi there"), ["-p", "hi there", "--model", "fast", "--label", "two words"])
        custom.model = ""
        XCTAssertEqual(custom.argumentList(prompt: "hi"), ["-p", "hi", "--model", "--label", "two words"])
        custom.arguments = "--quiet"
        XCTAssertEqual(custom.argumentList(prompt: "hi"), ["--quiet", "hi"])
    }

    func testRouteToCustomCommand() async throws {
        let custom = CustomSummarizer(name: "Echo", command: "/bin/sh", arguments: "-c 'echo Custom said hello.' {prompt}")
        let log = CallLog()
        let s = CLISummarizer(locator: ToolLocator(home: brainTempDir(), shell: nil), runners: [FakeRunner(tool: .claude, reply: "never", calls: log)], routes: [.claude: custom.id], customs: [custom])
        let session = Session(id: "s1", tool: .claude, project: "bion", cwd: "/tmp/bion", status: .done)
        let request = SummaryRequest(session: session, event: brainEvent(.stop, tool: .claude, message: "Done.", detail: nil), persona: PersonaLibrary.kuma, verbosity: .line, model: nil)
        let r = await s.summarize(request)
        XCTAssertEqual(r.say, "Custom said hello.")
        XCTAssertEqual(r.summarizedBy, .other)
        XCTAssertTrue(log.all.isEmpty)
    }

    func testEditedPresetReplacesBuiltIn() {
        var edited = PersonaLibrary.kuma
        edited.voice = "af_heart"
        edited.isBuiltIn = false
        let all = PersonaLibrary.all(custom: [edited])
        XCTAssertEqual(all.count, PersonaLibrary.builtIns.count)
        XCTAssertEqual(all.first { $0.id == "kuma" }?.voice, "af_heart")
        XCTAssertEqual(all.first { $0.id == "kuma" }?.isBuiltIn, true)
    }
}
