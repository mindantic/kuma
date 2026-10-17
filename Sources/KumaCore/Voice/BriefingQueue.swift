import Combine
import Foundation

public enum BriefingOutcome: Equatable, Sendable {
    case completed
    case skipped
    case cleared
    case paused
    case failed(String)
}

public struct BriefingFinished: Equatable, Sendable {
    public let briefing: Briefing
    public let outcome: BriefingOutcome

    public var wasSkipped: Bool { outcome != .completed }
}

@MainActor
public final class BriefingQueue: ObservableObject {
    @Published public private(set) var current: Briefing?
    @Published public private(set) var audible: Briefing?
    @Published public private(set) var pending: [Briefing] = []
    @Published public private(set) var isPaused = false

    public let started = PassthroughSubject<Briefing, Never>()
    public let finished = PassthroughSubject<BriefingFinished, Never>()
    public var onStarted: ((Briefing) -> Void)?
    public var onFinished: ((Briefing, Bool) -> Void)?

    public let maxPending: Int
    public let gap: Duration

    private let voice: VoiceEngine
    private var runner: Task<Void, Never>?
    private var interruption: BriefingOutcome?

    public init(voice: VoiceEngine, gap: Duration = .milliseconds(350), maxPending: Int = 30) {
        self.voice = voice
        self.gap = gap
        self.maxPending = max(1, maxPending)
    }

    public var isSpeaking: Bool { current != nil }
    public var isIdle: Bool { current == nil && pending.isEmpty }

    public func enqueue(_ briefing: Briefing) {
        if let index = pending.firstIndex(where: { $0.sessionId == briefing.sessionId }) {
            let old = pending[index]
            var merged = briefing
            merged.priority = max(old.priority, briefing.priority)
            if merged.priority == old.priority {
                pending[index] = merged
            } else {
                pending.remove(at: index)
                insert(merged)
            }
        } else {
            insert(briefing)
            trim()
        }
        pump()
    }

    public func skipCurrent() {
        guard current != nil else { return }
        interruption = .skipped
        voice.stop()
    }

    public func clearAll() {
        pending.removeAll()
        guard current != nil else { return }
        interruption = .cleared
        voice.stop()
    }

    public func removePending(sessionId: String) {
        pending.removeAll { $0.sessionId == sessionId }
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        guard let playing = current else { return }
        interruption = .paused
        if !pending.contains(where: { $0.sessionId == playing.sessionId }) {
            pending.insert(playing, at: 0)
            trim()
        }
        voice.stop()
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        pump()
    }

    private func insert(_ briefing: Briefing) {
        if briefing.priority == .high {
            let index = pending.firstIndex { $0.priority != .high } ?? pending.endIndex
            pending.insert(briefing, at: index)
        } else {
            pending.append(briefing)
        }
    }

    private func trim() {
        while pending.count > maxPending {
            if let i = pending.firstIndex(where: { $0.priority == .fyi }) {
                pending.remove(at: i)
            } else if let i = pending.firstIndex(where: { $0.priority == .normal }) {
                pending.remove(at: i)
            } else {
                pending.removeLast()
            }
        }
    }

    private func pump() {
        guard runner == nil, !isPaused, !pending.isEmpty else { return }
        runner = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        var first = true
        while !isPaused, !pending.isEmpty {
            if !first {
                try? await Task.sleep(for: gap)
                guard !isPaused, !pending.isEmpty else { break }
            }
            first = false
            let item = pending.removeFirst()
            interruption = nil
            current = item
            started.send(item)
            onStarted?(item)
            var outcome: BriefingOutcome
            do {
                try await voice.speak(item.text, voice: item.voice, speed: item.speed) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.current == item else { return }
                        self.audible = item
                    }
                }
                outcome = interruption ?? .completed
            } catch is CancellationError {
                outcome = interruption ?? .skipped
            } catch {
                outcome = interruption ?? .failed(String(describing: error))
            }
            interruption = nil
            current = nil
            audible = nil
            if outcome != .paused {
                let event = BriefingFinished(briefing: item, outcome: outcome)
                finished.send(event)
                onFinished?(item, event.wasSkipped)
            }
        }
        runner = nil
    }
}
