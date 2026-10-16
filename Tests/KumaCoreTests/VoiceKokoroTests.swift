import XCTest
@testable import KumaCore

enum VoiceTestEnv {
    static let jarvis = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/jarvis")
    static var python: URL { jarvis.appendingPathComponent(".venv/bin/python") }
    static var models: URL { jarvis.appendingPathComponent("models") }
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var helper: URL { repoRoot.appendingPathComponent("Resources/voice/kuma_voice.py") }
    static var setupScript: URL { repoRoot.appendingPathComponent("Resources/voice/setup.sh") }

    static var available: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: models.appendingPathComponent(VoiceSetup.modelFileName).path)
            && fm.fileExists(atPath: models.appendingPathComponent(VoiceSetup.voicesFileName).path)
    }

    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func linkedSetup() throws -> VoiceSetup {
        let root = try tempDir("voice")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent(".venv"), withDestinationURL: jarvis.appendingPathComponent(".venv"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: models)
        return VoiceSetup(root: root)
    }
}

final class VoiceSetupTests: XCTestCase {
    func testStatusReportsMissingPieces() throws {
        let root = try VoiceTestEnv.tempDir("status")
        let setup = VoiceSetup(root: root)
        XCTAssertEqual(setup.status, .missingPython)
        try FileManager.default.createDirectory(at: setup.pythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: setup.pythonURL, withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        XCTAssertEqual(setup.status, .missingModels)
        XCTAssertEqual(setup.modelsURL.lastPathComponent, "models")
    }

    func testLinkedSetupIsReady() throws {
        try XCTSkipUnless(VoiceTestEnv.available, "jarvis venv or models missing")
        XCTAssertEqual(try VoiceTestEnv.linkedSetup().status, .ready)
    }

    func testInstallStreamsProgressAndReportsFailure() async throws {
        let dir = try VoiceTestEnv.tempDir("install")
        let ok = dir.appendingPathComponent("ok.sh")
        try "echo one\necho two\necho \"dir=$KUMA_VOICE_DIR\"\n".write(to: ok, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.sh")
        try "echo trying\nexit 7\n".write(to: bad, atomically: true, encoding: .utf8)
        let setup = VoiceSetup(root: dir.appendingPathComponent("voice"))
        let lines = LockedLines()
        try await setup.install(scriptURL: ok) { lines.append($0) }
        XCTAssertEqual(lines.all, ["one", "two", "dir=\(setup.root.path)"])
        do {
            try await setup.install(scriptURL: bad) { _ in }
            XCTFail("expected failure")
        } catch let VoiceSetupError.failed(code, output) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(output.contains("trying"))
        }
    }

    func testSetupScriptIsValidBash() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", VoiceTestEnv.setupScript.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

final class VoiceHelperProtocolTests: XCTestCase {
    func testHelperProtocolAndLatency() throws {
        try XCTSkipUnless(VoiceTestEnv.available, "jarvis venv or models missing")
        let out = try VoiceTestEnv.tempDir("proto")
        let p = Process()
        p.executableURL = VoiceTestEnv.python
        p.arguments = [
            "-u", VoiceTestEnv.helper.path,
            VoiceTestEnv.models.appendingPathComponent(VoiceSetup.modelFileName).path,
            VoiceTestEnv.models.appendingPathComponent(VoiceSetup.voicesFileName).path,
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { p.terminate() }
        let reader = LineReader(handle: outPipe.fileHandleForReading)

        let loadStart = Date()
        let ready = try XCTUnwrap(reader.nextJSON())
        XCTAssertEqual(ready["ready"] as? Bool, true)
        let loadSeconds = Date().timeIntervalSince(loadStart)

        func send(_ obj: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        func sendRaw(_ s: String) throws {
            try inPipe.fileHandleForWriting.write(contentsOf: Data((s + "\n").utf8))
        }

        try sendRaw("not json")
        let bad = try XCTUnwrap(reader.nextJSON())
        XCTAssertEqual(bad["ok"] as? Bool, false)

        try send(["id": "v", "text": "hi", "voice": "zz_nope", "speed": 1, "out": out.appendingPathComponent("v.wav").path])
        let badVoice = try XCTUnwrap(reader.nextJSON())
        XCTAssertEqual(badVoice["id"] as? String, "v")
        XCTAssertEqual(badVoice["ok"] as? Bool, false)

        try send(["id": "warm", "text": "Warming up.", "voice": "am_onyx", "speed": 1, "out": out.appendingPathComponent("warm.wav").path])
        XCTAssertEqual(try XCTUnwrap(reader.nextJSON())["ok"] as? Bool, true)

        var timings: [Int] = []
        let sentences = [
            "The payments session finished and all tests pass.",
            "Kuma needs your approval to run a database migration.",
            "The docs build failed with a missing import.",
        ]
        for (i, s) in sentences.enumerated() {
            let path = out.appendingPathComponent("s\(i).wav").path
            let started = Date()
            try send(["id": "s\(i)", "text": s, "voice": i == 1 ? "bm_george" : "am_onyx", "speed": 1.0, "out": path])
            let reply = try XCTUnwrap(reader.nextJSON())
            let roundTrip = Int(Date().timeIntervalSince(started) * 1000)
            XCTAssertEqual(reply["id"] as? String, "s\(i)")
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            timings.append(roundTrip)
        }

        let long = String(repeating: "This is a longer briefing sentence for the split test. ", count: 4)
        try send(["id": "long", "text": long, "voice": "am_onyx", "speed": 1.2, "out": out.appendingPathComponent("long.wav").path])
        let longReply = try XCTUnwrap(reader.nextJSON())
        XCTAssertEqual(longReply["ok"] as? Bool, true)
        XCTAssertEqual(longReply["chunks"] as? Int, 4)

        let avg = timings.reduce(0, +) / timings.count
        print("KUMA_VOICE_LATENCY load=\(String(format: "%.2f", loadSeconds))s warm_sentence_ms=\(timings) avg=\(avg)ms")
        try? inPipe.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: out)
    }
}

final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    func nextJSON() throws -> [String: Any]? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                continue
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}

final class VoiceKokoroEngineTests: XCTestCase {
    func testNotInstalledThrows() async throws {
        let root = try VoiceTestEnv.tempDir("none")
        let voice = KokoroVoice(setup: VoiceSetup(root: root), scriptURL: VoiceTestEnv.helper)
        do {
            try await voice.warmUp()
            XCTFail("expected error")
        } catch let error as KokoroError {
            XCTAssertEqual(error, .notInstalled(.missingPython))
        }
    }

    func testSynthesizeRestartAndStop() async throws {
        try XCTSkipUnless(VoiceTestEnv.available, "jarvis venv or models missing")
        let voice = KokoroVoice(setup: try VoiceTestEnv.linkedSetup(), scriptURL: VoiceTestEnv.helper)
        defer { voice.shutdown() }
        try await voice.warmUp()
        XCTAssertTrue(voice.isWarm)

        let url = try await voice.synthesize("Quiet synthesis check.", voice: "am_onyx", speed: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)

        voice.engine?.restart()
        try await Task.sleep(for: .milliseconds(300))
        let again = try await voice.synthesize("Back again.", voice: "bm_lewis", speed: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path))
        XCTAssertEqual(voice.engine?.launches, 2)
        try? FileManager.default.removeItem(at: again)

        voice.volume = 0
        let started = Date()
        let task = Task {
            try await voice.speak("This sentence is long enough that it will still be playing when stop is called by the test.", voice: "am_onyx", speed: 1)
        }
        try await Task.sleep(for: .milliseconds(150))
        voice.stop()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testAudiblePlayback() async throws {
        try XCTSkipUnless(VoiceTestEnv.available, "jarvis venv or models missing")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KUMA_VOICE_PLAY"] == "1", "set KUMA_VOICE_PLAY=1 to hear audio")
        let voice = KokoroVoice(setup: try VoiceTestEnv.linkedSetup(), scriptURL: VoiceTestEnv.helper)
        defer { voice.shutdown() }
        try await voice.warmUp()
        voice.volume = 0.5
        let started = Date()
        try await voice.speak("Kuma voice check.", voice: "am_onyx", speed: 1)
        let total = Date().timeIntervalSince(started)
        print("KUMA_VOICE_PLAYBACK synth_ms=\(voice.lastSynthesisMilliseconds ?? -1) total=\(String(format: "%.2f", total))s")
        XCTAssertGreaterThan(total, 0.8)
    }

    func testSystemVoiceStopsInstantly() async throws {
        let voice = SystemVoice()
        voice.volume = 0
        try await voice.speak("   ", voice: "am_onyx", speed: 1)
        let task = Task {
            try await voice.speak("This is a long fallback sentence that should be cut off right away by the stop call.", voice: "am_onyx", speed: 1)
        }
        try await Task.sleep(for: .milliseconds(300))
        let stopAt = Date()
        voice.stop()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(stopAt), 0.5)
        XCTAssertNotNil(SystemVoice.defaultVoice())
    }
}
