import Foundation

public final class KokoroVoice: VoiceEngine, @unchecked Sendable {
    public let setup: VoiceSetup
    public let scriptURL: URL?
    public let readyTimeout: TimeInterval
    public let requestTimeout: TimeInterval

    private let lock = NSLock()
    var engine: KokoroProcess?
    private var activeRequestId: String?
    private var lastMs: Int?
    private let generation = Generation()
    private let gate = SerialGate()
    private let player = WavPlayer()
    private let tempDir: URL

    public init(setup: VoiceSetup = VoiceSetup(), scriptURL: URL? = nil, readyTimeout: TimeInterval = 90, requestTimeout: TimeInterval = 60) {
        self.setup = setup
        self.scriptURL = scriptURL
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kuma-voice", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    deinit {
        engine?.shutdown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    public var lastSynthesisMilliseconds: Int? { lock.withLock { lastMs } }

    public var isWarm: Bool { lock.withLock { engine?.isReady ?? false } }

    public var volume: Float = 1.0 {
        didSet { player.setVolume(volume) }
    }

    public func warmUp() async throws {
        try await processHandle().ensureReady()
    }

    public func synthesize(_ text: String, voice: String, speed: Double) async throws -> URL {
        let token = generation.current
        return try await gate.run {
            try await synthesizeLocked(text, voice: voice, speed: speed, token: token)
        }
    }

    public func speak(_ text: String, voice: String, speed: Double) async throws {
        let token = generation.current
        try await gate.run {
            let url = try await synthesizeLocked(text, voice: voice, speed: speed, token: token)
            defer { try? FileManager.default.removeItem(at: url) }
            let gen = generation
            try await player.play(url) { gen.isCurrent(token) }
        }
    }

    public func stop() {
        generation.bump()
        let (proc, id) = lock.withLock { () -> (KokoroProcess?, String?) in
            let id = activeRequestId
            activeRequestId = nil
            return (engine, id)
        }
        if let proc, let id { proc.cancel(id: id) }
        player.stop()
    }

    public func shutdown() {
        stop()
        let proc = lock.withLock { () -> KokoroProcess? in
            let p = engine
            engine = nil
            return p
        }
        proc?.shutdown()
    }

    private func synthesizeLocked(_ text: String, voice: String, speed: Double, token: UInt64) async throws -> URL {
        guard generation.isCurrent(token) else { throw CancellationError() }
        try Task.checkCancellation()
        let proc = try processHandle()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let out = tempDir.appendingPathComponent("\(id).wav")
        lock.withLock { activeRequestId = id }
        let reply: KokoroReply
        do {
            reply = try await proc.synthesize(id: id, text: text, voice: voice, speed: speed, out: out)
        } catch {
            lock.withLock { if activeRequestId == id { activeRequestId = nil } }
            throw error
        }
        lock.withLock {
            if activeRequestId == id { activeRequestId = nil }
            lastMs = reply.milliseconds
        }
        guard generation.isCurrent(token) else {
            try? FileManager.default.removeItem(at: reply.path)
            throw CancellationError()
        }
        return reply.path
    }

    private func processHandle() throws -> KokoroProcess {
        if let existing = lock.withLock({ engine }) { return existing }
        let status = setup.status
        guard status == .ready else { throw KokoroError.notInstalled(status) }
        guard let script = scriptURL ?? setup.helperURL else { throw KokoroError.helperMissing }
        return lock.withLock {
            if let existing = engine { return existing }
            let created = KokoroProcess(
                pythonURL: setup.pythonURL,
                scriptURL: script,
                modelURL: setup.modelURL,
                voicesURL: setup.voicesURL,
                readyTimeout: readyTimeout,
                requestTimeout: requestTimeout
            )
            engine = created
            return created
        }
    }
}
