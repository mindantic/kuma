import Darwin
import Foundation

public struct HookClient: Sendable {
    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = KumaPaths.socket.path, timeout: TimeInterval = 0.3) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public static func captureEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out: [String: String] = [:]
        for key in HookEnvelope.capturedEnvKeys {
            if let v = env[key], !v.isEmpty { out[key] = v }
        }
        return out
    }

    public static func makeEnvelope(tool: Tool, event: String, stdin: Data, env: [String: String] = ProcessInfo.processInfo.environment, parentPID: Int32 = getppid()) -> HookEnvelope {
        let payload = JSONValue.parse(stdin) ?? .null
        return HookEnvelope(tool: tool, event: event, payload: payload, env: captureEnv(env), parentPID: parentPID)
    }

    public static func encodeLine(_ envelope: HookEnvelope) -> Data? {
        guard var data = try? JSONEncoder().encode(envelope) else { return nil }
        data.append(0x0A)
        return data
    }

    @discardableResult
    public func send(_ envelope: HookEnvelope) -> Bool {
        guard let line = HookClient.encodeLine(envelope) else { return false }
        return send(line: line)
    }

    @discardableResult
    public func send(line: Data) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        guard let fd = connect(deadline: deadline) else { return false }
        defer { close(fd) }
        return write(fd: fd, data: line, deadline: deadline)
    }

    private func connect(deadline: Date) -> Int32? {
        var addr = sockaddr_un()
        guard UnixSocket.fill(&addr, path: socketPath) else { return nil }
        while Date() < deadline {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { return fd }
            let err = errno
            if err == EINPROGRESS || err == EINTR {
                if poll(fd: fd, events: Int16(POLLOUT), deadline: deadline) {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    if soErr == 0 { return fd }
                }
                close(fd)
                return nil
            }
            close(fd)
            guard err == EAGAIN || err == ECONNREFUSED else { return nil }
            guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
            usleep(5_000)
        }
        return nil
    }

    private func write(fd: Int32, data: Data, deadline: Date) -> Bool {
        var offset = 0
        let total = data.count
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < total {
                let n = Darwin.write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0, errno == EAGAIN || errno == EINTR {
                    if !poll(fd: fd, events: Int16(POLLOUT), deadline: deadline) { return false }
                    continue
                }
                return false
            }
            return true
        }
    }

    private func poll(fd: Int32, events: Int16, deadline: Date) -> Bool {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard remaining > 0 else { return false }
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let rc = Darwin.poll(&pfd, 1, remaining)
        return rc > 0 && (pfd.revents & events) != 0
    }
}

enum UnixSocket {
    static func fill(_ addr: inout sockaddr_un, path: String) -> Bool {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return true
    }
}
