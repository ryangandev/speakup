import AVFoundation
import Foundation
import Observation

/// Plays take audio: a whole take, a quote's range, or from a word to the end.
///
/// Each play button passes a key; the button for the key that is playing shows Stop.
/// The app plays its own copy of a take when it has one and otherwise downloads it
/// (architecture.md#get-v1takestake_idaudio).
@MainActor
@Observable
final class AudioPlayer {
    private(set) var playingKey: String?
    private(set) var loadingKey: String?
    var errorMessage: String?

    /// Returns a local file for a take id.
    var resolveAudio: (String) async throws -> URL = { _ in throw APIError.notConfigured }

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    func isPlaying(_ key: String) -> Bool { playingKey == key }
    func isLoading(_ key: String) -> Bool { loadingKey == key }

    /// Plays or, when this key is already playing, stops.
    func toggle(key: String, takeID: String, from start: Double = 0, to end: Double? = nil) {
        if playingKey == key || loadingKey == key {
            stop()
            return
        }
        stop()
        loadingKey = key
        loadTask = Task {
            do {
                let url = try await resolveAudio(takeID)
                guard loadingKey == key else { return }
                try play(url: url, key: key, from: start, to: end)
            } catch {
                if loadingKey == key {
                    errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                }
            }
            if loadingKey == key { loadingKey = nil }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingKey = nil
        loadingKey = nil
    }

    private func play(url: URL, key: String, from start: Double, to end: Double?) throws {
        try AudioSessionConfig.activateForPlayback()
        let player = try AVAudioPlayer(contentsOf: url)
        let begin = max(0, min(start, player.duration))
        player.currentTime = begin
        player.prepareToPlay()
        player.play()
        self.player = player
        playingKey = key
        loadingKey = nil
        let stopAt = min(end ?? player.duration, player.duration)
        let length = max(0.1, stopAt - begin)
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled, let self, self.playingKey == key else { return }
            self.stop()
        }
    }
}
