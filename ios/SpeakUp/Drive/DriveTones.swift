import AVFoundation
import Foundation

/// The two tones of a drive, generated as PCM so there are no asset files.
///
/// Both are short, soft two-note bells in the format speech output plays
/// (`SpeechOutput.format`), so they go through the same player as speech with no
/// conversion. Their direction tells them apart without looking: "start recording" rises
/// (go ahead), "ended" falls (that's it). The peak stays at half scale, so they are never
/// louder than the speech around them and cannot clip.
enum DriveTone: CaseIterable, Sendable, Equatable {
    /// Played after "Answer after the tone."; the take opens just after it ends.
    case startRecording
    /// Played when a take ends, either at "done" or at the time limit.
    case ended

    /// The largest sample value any tone reaches.
    nonisolated static let peak: Float = 0.5

    struct Note: Sendable, Equatable {
        let frequency: Double
        let duration: TimeInterval
    }

    var notes: [Note] {
        switch self {
        case .startRecording: [Note(frequency: 659.26, duration: 0.10), Note(frequency: 987.77, duration: 0.16)]
        case .ended: [Note(frequency: 783.99, duration: 0.11), Note(frequency: 523.25, duration: 0.20)]
        }
    }

    /// Silence after the last note, so the output does not cut it off.
    nonisolated static let tail: TimeInterval = 0.04

    /// How long the tone plays, in seconds.
    var duration: TimeInterval { notes.reduce(Self.tail) { $0 + $1.duration } }

    /// What the debug spoken log calls it.
    var logName: String {
        switch self {
        case .startRecording: "start recording"
        case .ended: "ended"
        }
    }

    /// The tone as samples in `SpeechOutput.format`.
    func buffer() -> AVAudioPCMBuffer {
        let format = SpeechOutput.format
        let rate = format.sampleRate
        var samples: [Float] = []
        for note in notes {
            let count = Int((note.duration * rate).rounded())
            let attack = 0.008 * rate
            let release = 0.02 * rate
            for index in 0..<count {
                let time = Double(index) / rate
                let rise = min(1, Double(index) / attack)
                let fall = min(1, Double(count - 1 - index) / release)
                // A soft decay, like a struck bell, with a quiet second harmonic for warmth.
                let envelope = sin(rise * .pi / 2) * sin(fall * .pi / 2) * exp(-time / 0.12)
                let wave = sin(2 * .pi * note.frequency * time) + 0.25 * sin(4 * .pi * note.frequency * time)
                // The two partials peak at 1.25 together.
                samples.append(Float(envelope * wave / 1.25) * Self.peak)
            }
        }
        samples += [Float](repeating: 0, count: Int((Self.tail * rate).rounded()))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
