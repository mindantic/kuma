import Foundation

public enum VoiceSetupStatus: String, Equatable, Sendable {
    case ready
    case missingPython
    case missingModels
}

public enum VoiceSetupError: Error, Equatable, LocalizedError {
    case scriptNotFound(String)
    case failed(code: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path): return "Voice setup script not found at \(path)"
        case .failed(let code, let output): return "Voice setup failed with exit code \(code): \(output)"
        }
    }
}

public struct VoiceSetup: Sendable {
    public static let modelFileName = "kokoro-v1.0.onnx"
    public static let voicesFileName = "voices-v1.0.bin"
    public static let helperFileName = "kuma_voice.py"
    public static let setupFileName = "setup.sh"
    static let minModelBytes: Int64 = 300_000_000
    static let minVoicesBytes: Int64 = 20_000_000

    public let root: URL

    public init(root: URL = KumaPaths.voice) {
        self.root = root
    }

    public var pythonURL: URL { root.appendingPathComponent(".venv/bin/python") }
    public var modelsURL: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var modelURL: URL { modelsURL.appendingPathComponent(Self.modelFileName) }
    public var voicesURL: URL { modelsURL.appendingPathComponent(Self.voicesFileName) }
    public var installedHelperURL: URL { root.appendingPathComponent(Self.helperFileName) }

    public var status: VoiceSetupStatus {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pythonURL.path) else { return .missingPython }
        guard Self.size(of: modelURL) >= Self.minModelBytes, Self.size(of: voicesURL) >= Self.minVoicesBytes else {
            return .missingModels
        }
        return .ready
    }

    public var isReady: Bool { status == .ready }

    public var helperURL: URL? {
        if FileManager.default.fileExists(atPath: installedHelperURL.path) { return installedHelperURL }
        return Self.bundledResource(named: Self.helperFileName)
    }

    public static func bundledResource(named name: String) -> URL? {
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["KUMA_VOICE_RESOURCES"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("voice").appendingPathComponent(name))
            candidates.append(res.appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func install(scriptURL: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw VoiceSetupError.scriptNotFound(scriptURL.path)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["KUMA_VOICE_DIR"] = root.path
        let extraPath = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extraPath + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = LineCollector(onLine: progress)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.feed(data)
            }
        }

        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.feed(rest) }
        collector.flush()
        if code != 0 {
            throw VoiceSetupError.failed(code: code, output: collector.tail)
        }
    }

    static func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var recent: [String] = []
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                out.append(String(decoding: lineData, as: UTF8.self))
            }
            remember(out)
            return out
        }
        lines.forEach(emit)
    }

    func flush() {
        let line: String? = lock.withLock {
            guard !buffer.isEmpty else { return nil }
            let s = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            remember([s])
            return s
        }
        if let line { emit(line) }
    }

    var tail: String { lock.withLock { recent.joined(separator: "\n") } }

    private func remember(_ lines: [String]) {
        recent.append(contentsOf: lines)
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }
    }

    private func emit(_ line: String) {
        let last = line.split(separator: "\r").last.map(String.init) ?? line
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onLine(trimmed)
    }
}
