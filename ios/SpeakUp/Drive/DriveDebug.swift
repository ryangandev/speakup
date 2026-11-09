#if DEBUG
import AVFoundation
import Foundation
import os

/// Debug builds only: the drive's input in a simulator, which has no usable microphone
/// (its input node reports 0 Hz).
///
/// It feeds the same path as the real input tap (drive clock, recognizer stream, take gate):
/// silence, in real time, with audio clips played into it when asked. `-debug.microphoneFile
/// <path>` sets the clip played each time a take opens, so a WAV with an answer that ends in a
/// spoken "done" drives a whole take. `enqueue(_:)` is for the per-state clips of a drive script.
///
/// Every clip must have the sample rate of the first one (the take clip), which sets the
/// clock's rate; a clip at another rate is skipped. `say -o x.wav --data-format=LEI16@16000`
/// makes matching clips.
final class ScriptedMicrophone: @unchecked Sendable {
    let format: AVAudioFormat
    let name: String
    private let takeClip: URL?
    /// How long 100 ms of input takes to arrive. Real time by default; tests go faster.
    private let pace: Duration
    private let lock = NSLock()
    private var queue: [URL] = []
    private var task: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "ScriptedMicrophone")

    init(takeClip: URL?, pace: Duration = .milliseconds(100)) {
        self.takeClip = takeClip
        self.pace = pace
        let rate = takeClip.flatMap { try? AVAudioFile(forReading: $0).processingFormat.sampleRate } ?? 16_000
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        name = takeClip.map { "Simulated microphone: \($0.lastPathComponent)" } ?? "Simulated microphone"
    }

    /// Plays the clip after the clips already queued.
    func enqueue(_ url: URL) {
        lock.withLock { queue.append(url) }
    }

    /// Plays the take clip, if there is one.
    func playTakeClip() {
        if let takeClip { enqueue(takeClip) }
    }

    func start(into tap: DriveTap) {
        stop()
        let task = Task.detached { [self] in await run(into: tap) }
        lock.withLock { self.task = task }
    }

    func stop() {
        let task = lock.withLock {
            let task = self.task
            self.task = nil
            queue.removeAll()
            return task
        }
        task?.cancel()
    }

    private func run(into tap: DriveTap) async {
        let chunk = Int(format.sampleRate / 10)
        var clip: AVAudioFile?
        var deadline = ContinuousClock.now
        while !Task.isCancelled {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            buffer.frameLength = AVAudioFrameCount(chunk)
            let output = buffer.floatChannelData![0]
            output.update(repeating: 0, count: chunk)
            var filled = 0
            while filled < chunk {
                if clip == nil { clip = nextClip() }
                guard let file = clip else { break }
                let wanted = AVAudioFrameCount(chunk - filled)
                guard
                    let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted),
                    (try? file.read(into: read, frameCount: wanted)) != nil, read.frameLength > 0,
                    let source = read.floatChannelData
                else {
                    clip = nil
                    continue
                }
                (output + filled).update(from: source[0], count: Int(read.frameLength))
                filled += Int(read.frameLength)
            }
            tap.ingest(buffer)
            deadline += pace
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    private func nextClip() -> AVAudioFile? {
        while let url = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) {
            guard let file = try? AVAudioFile(forReading: url) else {
                Self.log.error("Could not open clip \(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard file.processingFormat.sampleRate == format.sampleRate else {
                Self.log.error("Skipped clip \(url.lastPathComponent, privacy: .public): its sample rate differs")
                continue
            }
            return file
        }
        return nil
    }
}
#endif
