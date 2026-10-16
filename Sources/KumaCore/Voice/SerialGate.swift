import Foundation

actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}

final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 { lock.withLock { value } }

    @discardableResult
    func bump() -> UInt64 { lock.withLock { value &+= 1; return value } }

    func isCurrent(_ token: UInt64) -> Bool { current == token }
}
