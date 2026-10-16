import AVFoundation
import Foundation

public final class SystemVoice: NSObject, VoiceEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let preferredVoiceNames = ["Evan", "Nathan", "Tom", "Alex", "Aaron", "Daniel", "Arthur", "Oliver", "Fred"]

    private let lock = NSLock()
    private let generation = Generation()
    private let gate = SerialGate()
    private var synthesizer: AVSpeechSynthesizer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var activeUtterance: AVSpeechUtterance?
    private let fixedVoiceIdentifier: String?
    private var volumeValue: Float = 1.0

    public var volume: Float {
        get { lock.withLock { volumeValue } }
        set { lock.withLock { volumeValue = newValue } }
    }

    public init(voiceIdentifier: String? = nil) {
        self.fixedVoiceIdentifier = voiceIdentifier
        super.init()
    }

    public static func defaultVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var score = 0
            if v.gender == .male { score += 100 }
            if v.language == "en-US" { score += 20 } else if v.language == "en-GB" { score += 15 }
            switch v.quality {
            case .premium: score += 40
            case .enhanced: score += 30
            default: break
            }
            if let idx = preferredVoiceNames.firstIndex(where: { v.name.hasPrefix($0) }) {
                score += 10 - idx
            }
            if v.voiceTraits.contains(.isNoveltyVoice) { score -= 500 }
            return score
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    public static func resolveVoice(_ requested: String?) -> AVSpeechSynthesisVoice? {
        if let requested, !requested.isEmpty, let v = AVSpeechSynthesisVoice(identifier: requested) {
            return v
        }
        return defaultVoice()
    }

    public func speak(_ text: String, voice: String, speed: Double) async throws {
        let token = generation.current
        try await gate.run {
            guard generation.isCurrent(token) else { throw CancellationError() }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let voiceId = fixedVoiceIdentifier ?? voice
            let rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(max(speed, 0.5), 2.0))
            let gen = generation
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async { [self] in
                    guard gen.isCurrent(token) else {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    let utterance = AVSpeechUtterance(string: trimmed)
                    utterance.voice = Self.resolveVoice(voiceId)
                    utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
                    utterance.volume = volume
                    let synth = lock.withLock { () -> AVSpeechSynthesizer in
                        if let s = synthesizer { return s }
                        let s = AVSpeechSynthesizer()
                        s.delegate = self
                        synthesizer = s
                        return s
                    }
                    lock.withLock {
                        continuation = cont
                        activeUtterance = utterance
                    }
                    synth.speak(utterance)
                }
            }
        }
    }

    public func stop() {
        generation.bump()
        let work = { [self] in
            let (synth, cont) = lock.withLock { () -> (AVSpeechSynthesizer?, CheckedContinuation<Void, Error>?) in
                let c = continuation
                continuation = nil
                activeUtterance = nil
                return (synthesizer, c)
            }
            synth?.stopSpeaking(at: .immediate)
            cont?.resume(throwing: CancellationError())
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(utterance, error: nil)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(utterance, error: CancellationError())
    }

    private func complete(_ utterance: AVSpeechUtterance, error: Error?) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard activeUtterance === utterance else { return nil }
            let c = continuation
            continuation = nil
            activeUtterance = nil
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }
}
