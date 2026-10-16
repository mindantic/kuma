import AVFoundation
import Foundation

public enum AudioPlaybackError: Error, Equatable {
    case couldNotStart
    case decodeFailed(String)
}

final class WavPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var volume: Float

    init(volume: Float = 1.0) {
        self.volume = volume
    }

    func setVolume(_ value: Float) {
        lock.withLock { volume = value }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.player?.volume = value }
        }
    }

    func play(_ url: URL, shouldStart: @escaping @Sendable () -> Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [self] in
                guard shouldStart() else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                let previous = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    let prev = continuation
                    continuation = cont
                    player?.stop()
                    player = nil
                    return prev
                }
                previous?.resume(throwing: CancellationError())
                do {
                    let p = try AVAudioPlayer(contentsOf: url)
                    p.delegate = self
                    p.volume = lock.withLock { volume }
                    p.prepareToPlay()
                    lock.withLock { player = p }
                    if !p.play() {
                        finish(p, with: AudioPlaybackError.couldNotStart)
                    }
                } catch {
                    finish(nil, with: AudioPlaybackError.decodeFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        let work = { [self] in
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                player?.stop()
                player = nil
                let c = continuation
                continuation = nil
                return c
            }
            cont?.resume(throwing: CancellationError())
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        finish(p, with: flag ? nil : AudioPlaybackError.decodeFailed("playback ended early"))
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        finish(p, with: AudioPlaybackError.decodeFailed(error?.localizedDescription ?? "decode error"))
    }

    private func finish(_ p: AVAudioPlayer?, with error: Error?) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if let p, player !== p { return nil }
            player = nil
            let c = continuation
            continuation = nil
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }
}
