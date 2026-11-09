import AVFoundation
import Foundation
import os

/// How a spoken item or tone went.
struct SpeechPlayback: Sendable, Equatable {
    /// False when `cancel()` (or a stopped engine) cut it short.
    var finished: Bool
    /// The drive-clock time at which everything spoken so far ends (`SpeechOutputting.outputEnd`).
    var end: TimeInterval
    /// Seconds of audio this call scheduled.
    var duration: TimeInterval
}

/// What the drive loop needs from speech output, so its tests can use a fake.
@MainActor
protocol SpeechOutputting: AnyObject {
    /// The drive-clock time (`DriveAudio.now`) at which the speech and tones scheduled so far
    /// finish playing, with a margin for the output path. Pass it to the recognizer's
    /// `listen(from:)` so it ignores the app's own voice, and open a take after it.
    var outputEnd: TimeInterval { get }

    /// Speaks `text` and returns when it has finished playing, or was cancelled.
    @discardableResult func speak(_ text: String) async -> SpeechPlayback
    /// Speaks each segment in turn, with a short pause between them.
    /// `DriveScript.Feedback.segments` is the unit a later skip can move between.
    @discardableResult func speak(segments: [String]) async -> SpeechPlayback
    /// Plays a tone and returns when it has finished.
    @discardableResult func play(_ tone: DriveTone) async -> SpeechPlayback
    /// Stops what is playing now. Every `speak` and `play` waiting returns with
    /// `finished == false`. A later call plays normally.
    func cancel()
}

/// The drive's voice (plan section 2): text is rendered with `AVSpeechSynthesizer.write` and
/// played on `DriveAudio`'s player.
///
/// `AVSpeechSynthesizer.speak` would play through its own audio path and fight the drive's
/// session, so the synthesizer only renders PCM here, and the drive engine plays it, next to
/// the tones, on the one clock the recognizer uses.
///
/// The output end time is computed, not measured: each item starts at the later of "the
/// drive clock now, plus the lag" and "the end of the item before it", and ends its duration
/// later. The lag is how far real time can be ahead of the drive clock when an item is
/// queued: the length of the latest input buffer (the clock only moves when a whole buffer
/// arrives, and a 4096-frame buffer at 16 kHz is 256 ms) plus the session's input latency,
/// IO buffer duration and output latency. Items queued on the player play back to back, so
/// this follows playback. Playback completion (`.dataPlayedBack`) is what releases `speak`, so
/// a call returns when the sound is out.
///
/// When the audio core flushes the player (an interruption, a restart, the end of the drive)
/// every call waiting returns unfinished and `outputEnd` is reset, so nothing queued before
/// plays later, on top of what comes next.
@MainActor
final class SpeechOutput: SpeechOutputting {
    /// The format of everything played: speech buffers are converted to it if they differ,
    /// and tones are generated in it. 22.05 kHz mono is what the system voices deliver.
    nonisolated static let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    /// Slightly under the system default (0.5): clearer over road noise and a car speaker.
    nonisolated static let rate: Float = 0.48
    /// The pause between segments.
    nonisolated static let segmentGap: TimeInterval = 0.3
    /// How long past its expected end a call waits for the player before it gives up.
    nonisolated static let completionGrace: TimeInterval = 3

    struct Options {
        /// The session's part of the lag, in seconds: output latency (handing a buffer to the
        /// player to hearing it), input latency and IO buffer duration.
        var latency: @MainActor () -> TimeInterval = {
            let session = AVAudioSession.sharedInstance()
            return session.outputLatency + session.inputLatency + session.ioBufferDuration
        }
        /// The length of the latest input buffer; nil reads it from `DriveAudio`.
        var inputBuffer: (@MainActor () -> TimeInterval)?
        /// Renders text to audio; nil uses the system synthesizer. For tests.
        var render: (@Sendable (String) async -> RenderedSpeech)?
        #if DEBUG
        /// `-debug.instantSpeech`: nothing is rendered or played, and each item takes no time.
        var instant = false
        /// `-debug.speechLog`: every utterance and tone is appended here.
        var log: SpokenLog?
        #endif

        /// The options a launch selects: the defaults in a Release build.
        @MainActor static var launch: Options {
            var options = Options()
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            options.instant = arguments.contains("-debug.instantSpeech")
            if arguments.contains("-debug.speechLog") { options.log = SpokenLog() }
            #endif
            return options
        }
    }

    private let audio: DriveAudio
    private let options: Options
    private let renderer = SpeechRenderer()
    private(set) var outputEnd: TimeInterval = 0
    /// Bumped by `cancel()`; a call that started earlier stops when it sees a newer one.
    private var generation = 0
    private var waiters: [ObjectIdentifier: PlaybackWaiter] = [:]

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "SpeechOutput")

    #if DEBUG
    var spokenLog: SpokenLog? { options.log }
    #endif

    init(audio: DriveAudio, options: Options = .launch) {
        self.audio = audio
        self.options = options
        // Before the engine starts is the quietest moment to change the player's format.
        audio.connectPlayer(format: Self.format)
        audio.onPlayerFlush = { [weak self] in self?.playerFlushed() }
    }

    // MARK: Speaking

    func speak(_ text: String) async -> SpeechPlayback {
        await speak(segments: [text])
    }

    func speak(segments: [String]) async -> SpeechPlayback {
        let texts = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let token = generation
        var last: PlaybackWaiter?
        var scheduled: TimeInterval = 0
        var skipped = false
        for (index, text) in texts.enumerated() {
            guard token == generation else { return cut(scheduled) }
            #if DEBUG
            if options.instant {
                let start = reserve(0)
                options.log?.append(.speech, text, at: start)
                continue
            }
            #endif
            guard canPlay else {
                Self.log.error("Not spoken, the drive's audio is not playing")
                return SpeechPlayback(finished: false, end: outputEnd, duration: scheduled)
            }
            guard let rendered = await render(text, token: token), token == generation else { return cut(scheduled) }
            guard canPlay else {
                return SpeechPlayback(finished: false, end: outputEnd, duration: scheduled)
            }
            var buffers = Self.matching(rendered.buffers)
            guard !buffers.isEmpty else {
                // The listener never hears this one; the caller must not assume it was said.
                Self.log.error("Nothing was rendered for a segment")
                skipped = true
                continue
            }
            if index > 0, scheduled > 0 { buffers.insert(Self.silence(Self.segmentGap), at: 0) }
            let duration = Self.duration(of: buffers)
            let start = reserve(duration)
            #if DEBUG
            options.log?.append(.speech, text, at: start)
            #endif
            last = schedule(buffers, duration: duration)
            scheduled += duration
        }
        let finished = await last?.wait() ?? true
        return SpeechPlayback(
            finished: finished && !skipped && token == generation, end: outputEnd, duration: scheduled)
    }

    func play(_ tone: DriveTone) async -> SpeechPlayback {
        let token = generation
        #if DEBUG
        if options.instant {
            let start = reserve(0)
            options.log?.append(.tone, tone.logName, at: start)
            return SpeechPlayback(finished: true, end: outputEnd, duration: 0)
        }
        #endif
        guard canPlay else {
            return SpeechPlayback(finished: false, end: outputEnd, duration: 0)
        }
        let duration = tone.duration
        let start = reserve(duration)
        #if DEBUG
        options.log?.append(.tone, tone.logName, at: start)
        #endif
        let waiter = schedule([tone.buffer()], duration: duration)
        let finished = await waiter.wait()
        return SpeechPlayback(finished: finished && token == generation, end: outputEnd, duration: duration)
    }

    func cancel() {
        generation += 1
        finishWaiters()
        let stopsAt = readyTime()
        guard outputEnd > stopsAt else { return }
        #if DEBUG
        if !options.instant { options.log?.append(.cancelled, "", at: audio.now) }
        #endif
        outputEnd = stopsAt
        guard audio.isRunning, !audio.isInterrupted else { return }
        // Stopping drops what is queued, and the node must be playing again for the next item.
        audio.player.stop()
        audio.player.play()
    }

    /// The audio core is about to stop the player (an interruption, an engine restart, the end
    /// of the drive): what is queued will never play, and the stop would report it as played.
    private func playerFlushed() {
        generation += 1
        finishWaiters()
        outputEnd = min(outputEnd, readyTime())
    }

    private func finishWaiters() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.finish(false) }
    }

    /// Whether buffers handed to the player would be heard.
    private var canPlay: Bool { audio.isRunning && !audio.isInterrupted }

    // MARK: Rendering

    /// Renders `text`, or returns nil as soon as `cancel()` runs, without waiting for the
    /// synthesizer.
    private func render(_ text: String, token: Int) async -> RenderedSpeech? {
        let renderer = renderer
        let custom = options.render
        let job = Task { () -> RenderedSpeech in
            if let custom { return await custom(text) }
            return await renderer.render(text)
        }
        let gate = PlaybackWaiter()
        let key = ObjectIdentifier(gate)
        waiters[key] = gate
        Task {
            _ = await job.value
            gate.finish(true)
        }
        let done = await gate.wait()
        waiters[key] = nil
        guard done, token == generation else { return nil }
        return await job.value
    }

    // MARK: Scheduling

    /// How far real time can be ahead of the drive clock right now.
    func lag() -> TimeInterval {
        (options.inputBuffer?() ?? audio.inputBufferDuration) + options.latency()
    }

    /// The drive-clock time at which something queued now starts to be heard, if nothing is
    /// queued before it.
    private func readyTime() -> TimeInterval {
        audio.now + lag()
    }

    /// Where an item of `duration` starts on the drive clock; moves `outputEnd` to its end.
    func reserve(_ duration: TimeInterval) -> TimeInterval {
        #if DEBUG
        let instant = options.instant
        #else
        let instant = false
        #endif
        let ready = instant ? audio.now : readyTime()
        let start = max(ready, outputEnd)
        outputEnd = start + duration
        return start
    }

    /// Queues the buffers back to back. The returned waiter finishes when the last one has
    /// played, or when the player is flushed or `cancel()` runs, or a little after it should
    /// have played.
    private func schedule(_ buffers: [AVAudioPCMBuffer], duration: TimeInterval) -> PlaybackWaiter {
        let waiter = PlaybackWaiter()
        let key = ObjectIdentifier(waiter)
        waiters[key] = waiter
        for (index, buffer) in buffers.enumerated() {
            if index == buffers.count - 1 {
                audio.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    waiter.finish(true)
                }
            } else {
                audio.player.scheduleBuffer(buffer)
            }
        }
        // A stopped engine never plays what is queued; do not wait forever.
        let wait = max(0, outputEnd - audio.now) + Self.completionGrace
        waiter.setTimeout(wait)
        waiter.onFinish = { [weak self] in
            Task { @MainActor in self?.waiters[key] = nil }
        }
        return waiter
    }

    private func cut(_ scheduled: TimeInterval) -> SpeechPlayback {
        SpeechPlayback(finished: false, end: outputEnd, duration: scheduled)
    }

    // MARK: Buffers

    nonisolated static func duration(of buffers: [AVAudioPCMBuffer]) -> TimeInterval {
        buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    nonisolated static func silence(_ seconds: TimeInterval) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
        return buffer
    }

    /// The buffers in `format`: ones already in it pass through, others are converted.
    nonisolated static func matching(_ buffers: [AVAudioPCMBuffer]) -> [AVAudioPCMBuffer] {
        var converter: AVAudioConverter?
        var converted: [AVAudioPCMBuffer] = []
        for buffer in buffers where buffer.frameLength > 0 {
            if buffer.format == format {
                converted.append(buffer)
                continue
            }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { continue }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
            nonisolated(unsafe) var supplied = false
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status != .error, output.frameLength > 0 { converted.append(output) }
        }
        // Drain what the converter still holds, so the end of the speech is not cut off.
        if let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) {
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status != .error, output.frameLength > 0 { converted.append(output) }
        }
        return converted
    }
}

/// Released when the last buffer of an item has played, when it is cancelled, or when it is
/// overdue. The first outcome wins.
private final class PlaybackWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    var onFinish: (@Sendable () -> Void)? {
        get { lock.withLock { finishHandler } }
        set {
            let call = lock.withLock {
                finishHandler = newValue
                return result != nil
            }
            if call { newValue?() }
        }
    }
    private var finishHandler: (@Sendable () -> Void)?

    func setTimeout(_ seconds: TimeInterval) {
        guard lock.withLock({ result == nil }) else { return }
        let task = Task { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { finish(false) }
        }
        lock.withLock { timeout = task }
    }

    func finish(_ value: Bool) {
        let (continuation, handler, timeout) = lock.withLock {
            guard result == nil else { return (nil as CheckedContinuation<Bool, Never>?, nil as (@Sendable () -> Void)?, nil as Task<Void, Never>?) }
            result = value
            let pending = self.continuation
            self.continuation = nil
            return (pending, finishHandler, self.timeout)
        }
        timeout?.cancel()
        continuation?.resume(returning: value)
        handler?()
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
