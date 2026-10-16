import XCTest
@testable import KumaCore

final class IngestServerTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [HookEnvelope] = []
        func add(_ e: HookEnvelope) { lock.lock(); items.append(e); lock.unlock() }
        var all: [HookEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func socketPath() -> String {
        "/tmp/kuma-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testTwentyFiveConcurrentSendersRoundTrip() throws {
        let path = socketPath()
        let box = Box()
        let done = expectation(description: "all envelopes")
        done.expectedFulfillmentCount = 25
        let server = EventServer(socketPath: path) { env in
            box.add(env)
            done.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let client = HookClient(socketPath: path)
        let results = Box()
        DispatchQueue.concurrentPerform(iterations: 25) { i in
            let payload = Data(#"{"session_id":"s\#(i)","hook_event_name":"Stop","last_assistant_message":"\#(String(repeating: "x", count: 20_000))"}"#.utf8)
            let env = HookClient.makeEnvelope(tool: .claude, event: "Stop", stdin: payload, env: ["TERM_PROGRAM": "iTerm.app", "SECRET": "nope"], parentPID: Int32(1000 + i))
            if client.send(env) { results.add(env) }
        }
        XCTAssertEqual(results.all.count, 25)
        wait(for: [done], timeout: 5)

        let got = box.all
        XCTAssertEqual(Set(got.compactMap { $0.payload["session_id"]?.string }), Set((0..<25).map { "s\($0)" }))
        XCTAssertTrue(got.allSatisfy { $0.env["TERM_PROGRAM"] == "iTerm.app" && $0.env["SECRET"] == nil })
        XCTAssertEqual(Set(got.map(\.parentPID)), Set((0..<25).map { Int32(1000 + $0) }))
        XCTAssertEqual(Normalizers.normalize(got[0]).first?.kind, .stop)
    }

    func testMultipleLinesAndUnterminatedLineOnOneConnection() throws {
        let path = socketPath()
        let box = Box()
        let done = expectation(description: "three")
        done.expectedFulfillmentCount = 3
        let server = EventServer(socketPath: path) { box.add($0); done.fulfill() }
        try server.start()
        defer { server.stop() }

        var data = Data()
        for i in 0..<3 {
            let env = HookEnvelope(tool: .codex, event: "Stop", payload: .object(["session_id": .string("c\(i)")]), env: [:], parentPID: 1)
            data.append(try JSONEncoder().encode(env))
            if i < 2 { data.append(0x0A) }
        }
        data.append(contentsOf: Array("\n\ngarbage\n".utf8).dropLast())
        XCTAssertTrue(HookClient(socketPath: path).send(line: data))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(box.all.map(\.tool), [.codex, .codex, .codex])
    }

    func testClientFailsFastWhenServerIsMissing() {
        let start = Date()
        let env = HookClient.makeEnvelope(tool: .claude, event: "Stop", stdin: Data("not json".utf8), env: [:], parentPID: 1)
        XCTAssertEqual(env.payload, .null)
        XCTAssertFalse(HookClient(socketPath: socketPath()).send(env))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
    }

    func testStaleSocketFileIsReplacedAndLiveServerIsDetected() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = EventServer(socketPath: path) { _ in }
        try server.start()
        defer { server.stop() }
        let second = EventServer(socketPath: path) { _ in }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? EventServerError, .alreadyRunning) }
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testHookBinaryHonorsSummaryGuardAndCodexStopOutput() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("kuma-hook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("kuma-hook not built at \(binary.path)")
        }
        let home = URL(fileURLWithPath: "/tmp/kh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("kuma.sock").path
        let box = Box()
        let got = expectation(description: "one envelope")
        let server = EventServer(socketPath: path) { box.add($0); got.fulfill() }
        try server.start()
        defer { server.stop() }

        func run(_ args: [String], extraEnv: [String: String]) throws -> (out: Data, err: Data, status: Int32) {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: KumaEnv.summaryGuard)
            env["KUMA_HOME"] = home.path
            for (k, v) in extraEnv { env[k] = v }
            p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            try p.run()
            inPipe.fileHandleForWriting.write(Data(#"{"session_id":"x","hook_event_name":"Stop","model":"gpt-5"}"#.utf8))
            try inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return (outPipe.fileHandleForReading.readDataToEndOfFile(), errPipe.fileHandleForReading.readDataToEndOfFile(), p.terminationStatus)
        }

        let guarded = try run(["claude", "Stop"], extraEnv: [KumaEnv.summaryGuard: "1"])
        XCTAssertEqual(guarded.status, 0)
        XCTAssertTrue(guarded.out.isEmpty)

        let missing = try run(["claude", "Stop"], extraEnv: ["KUMA_HOME": "/tmp/kuma-nowhere-\(UUID().uuidString.prefix(6))"])
        XCTAssertEqual(missing.status, 0)
        XCTAssertTrue(missing.out.isEmpty)
        XCTAssertTrue(missing.err.isEmpty)

        let codex = try run(["codex", "Stop"], extraEnv: [:])
        XCTAssertEqual(codex.status, 0)
        XCTAssertEqual(String(decoding: codex.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertTrue(codex.err.isEmpty)
        wait(for: [got], timeout: 3)
        XCTAssertEqual(box.all.first?.tool, .codex)
        XCTAssertEqual(box.all.first?.payload["model"]?.string, "gpt-5")
    }
}
