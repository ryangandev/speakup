import AVFoundation
import Foundation
import os

/// A voice as the choice sees it, so the choice is testable without installed voices.
struct VoiceInfo: Sendable, Equatable {
    enum Quality: Int, Sendable, Comparable {
        case standard, enhanced, premium
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    let identifier: String
    let language: String
    let quality: Quality
    /// A novelty or Personal Voice, never right for coaching feedback.
    let isSpecial: Bool
}

enum VoiceChoice {
    nonisolated static let language = "en-US"

    /// The best en-US voice that is better than the default: premium first, then enhanced,
    /// the identifier breaking ties so the choice is stable. Nil when only standard voices are
    /// installed, which means "use the system default for en-US".
    nonisolated static func best(among voices: [VoiceInfo]) -> VoiceInfo? {
        voices
            .filter { $0.language == language && !$0.isSpecial && $0.quality > .standard }
            .min { ($1.quality, $0.identifier) < ($0.quality, $1.identifier) }
    }

    /// The voice to render with: an installed enhanced or premium en-US voice, else the
    /// default en-US voice.
    nonisolated static func preferred() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let infos = installed.map(info)
        if let best = best(among: infos), let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return defaultVoice()
    }

    nonisolated static func defaultVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: language)
    }

    private nonisolated static func info(_ voice: AVSpeechSynthesisVoice) -> VoiceInfo {
        let quality: VoiceInfo.Quality =
            switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
        let traits = voice.voiceTraits
        return VoiceInfo(
            identifier: voice.identifier, language: voice.language, quality: quality,
            isSpecial: traits.contains(.isNoveltyVoice) || traits.contains(.isPersonalVoice))
    }
}

/// What `SpeechRenderer.render` produced. The buffers are only read after this is returned.
struct RenderedSpeech: @unchecked Sendable {
    var buffers: [AVAudioPCMBuffer]
}

/// Renders text to PCM with `AVSpeechSynthesizer.write`, which delivers mono 22.05 kHz Float32
/// buffers and ends with a zero-length one (the task 0 spike on the iOS 27 simulator).
///
/// An installed premium voice that renders nothing is replaced by the default voice for the
/// rest of the drive.
final class SpeechRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var voice: AVSpeechSynthesisVoice?
    private var chosen = false

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "SpeechRenderer")

    func render(_ text: String) async -> RenderedSpeech {
        let voice = currentVoice()
        let rendered = await Self.write(text, voice: voice)
        if rendered.buffers.isEmpty, voice?.quality != .default, let fallback = VoiceChoice.defaultVoice() {
            Self.log.error("Voice \(voice?.identifier ?? "nil", privacy: .public) rendered nothing; using the default")
            lock.withLock { self.voice = fallback }
            return await Self.write(text, voice: fallback)
        }
        return rendered
    }

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        lock.withLock {
            if !chosen {
                voice = VoiceChoice.preferred()
                chosen = true
            }
            return voice
        }
    }

    private static func write(_ text: String, voice: AVSpeechSynthesisVoice?) async -> RenderedSpeech {
        let collector = Collector()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = SpeechOutput.rate
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        return await withCheckedContinuation { continuation in
            collector.start(utterance, timeout: 20 + Double(text.count) * 0.1, continuation: continuation)
        }
    }

    /// Collects the callback's buffers; the synthesizer lives as long as the collection.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        private var continuation: CheckedContinuation<RenderedSpeech, Never>?
        private var done = false
        private let synthesizer = AVSpeechSynthesizer()

        func start(
            _ utterance: AVSpeechUtterance, timeout: TimeInterval,
            continuation: CheckedContinuation<RenderedSpeech, Never>
        ) {
            lock.withLock { self.continuation = continuation }
            synthesizer.write(utterance) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finish()
                } else {
                    lock.withLock { if !done { buffers.append(pcm) } }
                }
            }
            // A synthesizer that never ends its stream must not hang the drive.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish() }
        }

        private func finish() {
            let (continuation, result): (CheckedContinuation<RenderedSpeech, Never>?, RenderedSpeech) = lock.withLock {
                guard !done else { return (nil, RenderedSpeech(buffers: [])) }
                done = true
                let pending = self.continuation
                self.continuation = nil
                return (pending, RenderedSpeech(buffers: buffers))
            }
            continuation?.resume(returning: result)
        }
    }
}
