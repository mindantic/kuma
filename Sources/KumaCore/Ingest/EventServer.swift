import Darwin
import Foundation

public enum EventServerError: Error, Equatable {
    case pathTooLong
    case alreadyRunning
    case posix(String, Int32)
}

public final class EventServer: @unchecked Sendable {
    public let socketPath: String
    public let maxLineBytes: Int
    private let onEnvelope: @Sendable (HookEnvelope) -> Void
    private let queue = DispatchQueue(label: "com.kuma.eventserver")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private let decoder = JSONDecoder()

    private final class Connection {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    public init(socketPath: String = KumaPaths.socket.path, maxLineBytes: Int = 8 * 1024 * 1024, onEnvelope: @escaping @Sendable (HookEnvelope) -> Void) {
        self.socketPath = socketPath
        self.maxLineBytes = maxLineBytes
        self.onEnvelope = onEnvelope
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
    }

    public var isRunning: Bool { queue.sync { listenFD >= 0 } }

    public func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            var addr = sockaddr_un()
            guard UnixSocket.fill(&addr, path: socketPath) else { throw EventServerError.pathTooLong }
            try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: socketPath) {
                if HookClient(socketPath: socketPath, timeout: 0.1).probe() { throw EventServerError.alreadyRunning }
                unlink(socketPath)
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw EventServerError.posix("socket", errno) }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else {
                let e = errno
                close(fd)
                throw EventServerError.posix("bind", e)
            }
            chmod(socketPath, 0o600)
            guard listen(fd, 512) == 0 else {
                let e = errno
                close(fd)
                unlink(socketPath)
                throw EventServerError.posix("listen", e)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.setCancelHandler { close(fd) }
            acceptSource = source
            source.resume()
        }
    }

    public func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for conn in connections.values { conn.source?.cancel() }
            connections.removeAll()
            unlink(socketPath)
        }
    }

    private func acceptAll() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let conn = Connection(fd: client)
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.read(conn)
            }
            source.setCancelHandler { close(client) }
            conn.source = source
            connections[client] = conn
            source.resume()
        }
    }

    private func read(_ conn: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(conn.fd, &chunk, chunk.count)
            if n > 0 {
                conn.buffer.append(contentsOf: chunk[0..<n])
                drainLines(conn)
                if conn.buffer.count > maxLineBytes {
                    finish(conn, flush: false)
                    return
                }
                continue
            }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            finish(conn, flush: true)
            return
        }
    }

    private func drainLines(_ conn: Connection) {
        while let nl = conn.buffer.firstIndex(of: 0x0A) {
            let line = conn.buffer[conn.buffer.startIndex..<nl]
            deliver(Data(line))
            conn.buffer.removeSubrange(conn.buffer.startIndex...nl)
        }
    }

    private func finish(_ conn: Connection, flush: Bool) {
        if flush, !conn.buffer.isEmpty { deliver(conn.buffer) }
        conn.buffer.removeAll()
        conn.source?.cancel()
        conn.source = nil
        connections[conn.fd] = nil
    }

    private func deliver(_ line: Data) {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return }
        guard let envelope = try? decoder.decode(HookEnvelope.self, from: line) else { return }
        onEnvelope(envelope)
    }
}

extension HookClient {
    func probe() -> Bool {
        var addr = sockaddr_un()
        guard UnixSocket.fill(&addr, path: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }
}
