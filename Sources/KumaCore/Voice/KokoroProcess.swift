import Foundation

public enum KokoroError: Error, Equatable, LocalizedError {
    case notInstalled(VoiceSetupStatus)
    case helperMissing
    case launchFailed(String)
    case loadFailed(String)
    case synthesisFailed(String)
    case processExited(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let status): return "Kokoro voice is not installed (\(status.rawValue))"
        case .helperMissing: return "kuma_voice.py helper not found"
        case .launchFailed(let msg): return "Could not launch Kokoro helper: \(msg)"
        case .loadFailed(let msg): return "Kokoro failed to load: \(msg)"
        case .synthesisFailed(let msg): return "Kokoro synthesis failed: \(msg)"
        case .processExited(let msg): return "Kokoro helper exited: \(msg)"
        case .timedOut: return "Kokoro helper timed out"
        }
    }
}

public struct KokoroReply: Equatable, Sendable {
    public let id: String
    public let path: URL
    public let milliseconds: Int
}

final class KokoroProcess: @unchecked Sendable {
    let pythonURL: URL
    let scriptURL: URL
    let modelURL: URL
    let voicesURL: URL
    let readyTimeout: TimeInterval
    let requestTimeout: TimeInterval

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [String: CheckedContinuation<KokoroReply, Error>] = [:]
    private var launchCount = 0

    init(pythonURL: URL, scriptURL: URL, modelURL: URL, voicesURL: URL, readyTimeout: TimeInterval, requestTimeout: TimeInterval) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.modelURL = modelURL
        self.voicesURL = voicesURL
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
    }

    deinit {
        shutdown()
    }

    var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }
    var isReady: Bool { lock.withLock { ready } }
    var launches: Int { lock.withLock { launchCount } }

    func ensureReady() async throws {
        if lock.withLock({ ready && process != nil }) { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let failure: Error? = lock.withLock {
                if ready && process != nil { return nil }
                readyWaiters.append(cont)
                if process == nil {
                    do {
                        try launchLocked()
                    } catch {
                        readyWaiters.removeLast()
                        return error
                    }
                }
                return nil
            }
            if let failure {
                cont.resume(throwing: failure)
            } else if lock.withLock({ ready && process != nil }) {
                resolveReadyWaiters(with: nil)
            }
        }
    }

    func synthesize(id: String, text: String, voice: String, speed: Double, out: URL) async throws -> KokoroReply {
        try await ensureReady()
        let payload: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed, "out": out.path]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KokoroReply, Error>) in
            let failure: Error? = lock.withLock {
                guard let stdin, process != nil else { return KokoroError.processExited(stderrTail) }
                pending[id] = cont
                do {
                    try stdin.write(contentsOf: line)
                    return nil
                } catch {
                    pending[id] = nil
                    return KokoroError.processExited(error.localizedDescription)
                }
            }
            if let failure {
                cont.resume(throwing: failure)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                guard let self else { return }
                let timedOut = self.lock.withLock { self.pending.removeValue(forKey: id) }
                if let timedOut {
                    timedOut.resume(throwing: KokoroError.timedOut)
                    self.restart()
                }
            }
        }
    }

    func cancel(id: String) {
        let cont = lock.withLock { pending.removeValue(forKey: id) }
        cont?.resume(throwing: CancellationError())
    }

    func restart() {
        let p = lock.withLock { process }
        p?.terminate()
    }

    func shutdown() {
        let (p, handle) = lock.withLock { (process, stdin) }
        try? handle?.close()
        p?.terminate()
    }

    private func launchLocked() throws {
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = ["-u", scriptURL.path, modelURL.path, voicesURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self, let p else { return }
            self.consume(data, from: p)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock {
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            self?.handleExit(of: proc)
        }

        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw KokoroError.launchFailed(error.localizedDescription)
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        buffer.removeAll()
        stderrTail = ""
        ready = false
        launchCount += 1

        let timeout = readyTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak p] in
            guard let self, let p else { return }
            let stuck = self.lock.withLock { self.process === p && !self.ready }
            if stuck {
                self.resolveReadyWaiters(with: KokoroError.timedOut)
                p.terminate()
            }
        }
    }

    private func consume(_ data: Data, from p: Process) {
        let lines: [Data] = lock.withLock {
            guard process === p else { return [] }
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        for line in lines {
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let isReady = obj["ready"] as? Bool {
            if isReady {
                lock.withLock { ready = true }
                resolveReadyWaiters(with: nil)
            } else {
                let message = obj["error"] as? String ?? "unknown error"
                resolveReadyWaiters(with: KokoroError.loadFailed(message))
            }
            return
        }
        guard let id = obj["id"] as? String else { return }
        let ok = obj["ok"] as? Bool ?? false
        let path = obj["path"] as? String
        let cont = lock.withLock { pending.removeValue(forKey: id) }
        guard let cont else {
            if let path { try? FileManager.default.removeItem(atPath: path) }
            return
        }
        if ok, let path {
            let ms = (obj["ms"] as? NSNumber)?.intValue ?? 0
            cont.resume(returning: KokoroReply(id: id, path: URL(fileURLWithPath: path), milliseconds: ms))
        } else {
            cont.resume(throwing: KokoroError.synthesisFailed(obj["error"] as? String ?? "unknown error"))
        }
    }

    private func handleExit(of p: Process) {
        let (waiters, conts, tail): ([CheckedContinuation<Void, Error>], [CheckedContinuation<KokoroReply, Error>], String) = lock.withLock {
            guard process === p else { return ([], [], "") }
            process = nil
            try? stdin?.close()
            stdin = nil
            ready = false
            let w = readyWaiters
            readyWaiters.removeAll()
            let c = Array(pending.values)
            pending.removeAll()
            return (w, c, stderrTail)
        }
        let message = "status \(p.terminationStatus) \(tail.split(separator: "\n").suffix(3).joined(separator: " | "))"
        waiters.forEach { $0.resume(throwing: KokoroError.processExited(message)) }
        conts.forEach { $0.resume(throwing: KokoroError.processExited(message)) }
    }

    private func resolveReadyWaiters(with error: Error?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let w = readyWaiters
            readyWaiters.removeAll()
            return w
        }
        for w in waiters {
            if let error { w.resume(throwing: error) } else { w.resume() }
        }
    }
}
