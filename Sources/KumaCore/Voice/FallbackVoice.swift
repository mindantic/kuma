import Foundation

public final class FallbackVoice: VoiceEngine, @unchecked Sendable {
    public let primary: VoiceEngine
    public let fallback: VoiceEngine
    public var onFallback: ((Error) -> Void)?

    private let isPrimaryReady: () -> Bool
    private let generation = Generation()
    private let lock = NSLock()
    private var lastError: Error?

    public init(primary: VoiceEngine, fallback: VoiceEngine, isPrimaryReady: @escaping () -> Bool) {
        self.primary = primary
        self.fallback = fallback
        self.isPrimaryReady = isPrimaryReady
    }

    public convenience init(setup: VoiceSetup = VoiceSetup(), scriptURL: URL? = nil) {
        let kokoro = KokoroVoice(setup: setup, scriptURL: scriptURL)
        self.init(primary: kokoro, fallback: SystemVoice(), isPrimaryReady: { setup.isReady })
    }

    public var kokoro: KokoroVoice? { primary as? KokoroVoice }

    public var lastPrimaryError: Error? { lock.withLock { lastError } }

    public func warmUp() async {
        guard isPrimaryReady(), let kokoro else { return }
        do {
            try await kokoro.warmUp()
        } catch {
            lock.withLock { lastError = error }
        }
    }

    public func speak(_ text: String, voice: String, speed: Double) async throws {
        let token = generation.current
        if isPrimaryReady() {
            do {
                try await primary.speak(text, voice: voice, speed: speed)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lock.withLock { lastError = error }
                onFallback?(error)
            }
        }
        guard generation.isCurrent(token) else { throw CancellationError() }
        try await fallback.speak(text, voice: voice, speed: speed)
    }

    public func stop() {
        generation.bump()
        primary.stop()
        fallback.stop()
    }
}
