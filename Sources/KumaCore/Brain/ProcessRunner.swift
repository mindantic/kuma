import Foundation

public struct ProcessOutput: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var duration: TimeInterval

    public var succeeded: Bool { !timedOut && exitCode == 0 }
}

public enum ProcessRunner {
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var timedOut = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    public static func start(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval,
        completion: @escaping @Sendable (ProcessOutput) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Buffer()
        let err = Buffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
            } else {
                out.append(d)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
            } else {
                err.append(d)
            }
        }
        let started = Date()
        let once = Once()
        let finish: @Sendable (Int32) -> Void = { code in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                guard once.claim() else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                completion(ProcessOutput(stdout: out.string, stderr: err.string, exitCode: code, timedOut: once.timedOut, duration: Date().timeIntervalSince(started)))
            }
        }
        process.terminationHandler = { p in finish(p.terminationStatus) }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if once.claim() {
                completion(ProcessOutput(stdout: "", stderr: "\(error)", exitCode: -1, timedOut: false, duration: 0))
            }
            return
        }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            once.timedOut = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval
    ) async -> ProcessOutput {
        await withCheckedContinuation { cont in
            start(executable: executable, arguments: arguments, environment: environment, directory: directory, timeout: timeout) {
                cont.resume(returning: $0)
            }
        }
    }

    public static func runSync(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval
    ) -> ProcessOutput {
        final class Box: @unchecked Sendable { var value: ProcessOutput? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        start(executable: executable, arguments: arguments, environment: environment, directory: directory, timeout: timeout) {
            box.value = $0
            sem.signal()
        }
        sem.wait()
        return box.value ?? ProcessOutput(stdout: "", stderr: "", exitCode: -1, timedOut: true, duration: timeout)
    }
}
