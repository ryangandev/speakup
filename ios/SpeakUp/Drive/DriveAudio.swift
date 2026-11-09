import AVFoundation
import Foundation
import Observation
import os

/// What the drive loop needs from the audio core, so its tests can use a fake.
@MainActor
protocol DriveAudioControlling: AnyObject {
    /// The drive clock now: the end of the latest input buffer, in seconds since the drive started.
    var now: TimeInterval { get }
    /// How long the open take is, or nil when no take is open.
    var takeDuration: TimeInterval? { get }
    var onEvent: ((DriveAudio.Event) -> Void)? { get set }

    func start() async throws
    func stop() async -> DriveAudio.TakeEnd?
    func recognizerBuffers() -> AsyncStream<DriveAudioBuffer>
    func openTake(url: URL, at start: TimeInterval?) throws
    func finishTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async -> DriveAudio.TakeEnd?
}

/// The audio core of a drive (plan section 4): one `AVAudioEngine` that runs from the start
/// of the drive to its stop.
///
/// Restarting capture while the phone is locked fails, so the engine never stops between
/// takes. Its input tap feeds two outputs, both stamped on one drive clock:
/// - the recognizer, as a stream of buffers with their start times (`recognizerBuffers()`);
/// - the take gate, which writes a WAV only while a take is open.
///
/// Because both outputs use the same clock, a time the recognizer reports (the start of
/// "done") maps to an exact frame of the take, and `finishTake(cutAt:)` trims the take there.
///
/// Every way a take ends gives exactly one `TakeEnd`: as the return value of `finishTake` or
/// `stop()` when the loop ends it, or inside exactly one event when the audio core ends it.
/// A take whose file the store never received is deleted here when it holds no audio
/// (`.empty`); that is the one exception to "only the prune deletes take audio".
///
/// `player` is the seam for spoken prompts and tones: it is attached to the engine, connected
/// to the output (in `playerFormat` until `connectPlayer(format:)` changes it), and playing
/// whenever the engine runs, so a scheduled buffer plays at once.
@MainActor
@Observable
final class DriveAudio: DriveAudioControlling {
    /// What the audio core does by itself. Events arrive in the order things happened; one
    /// that carries a take arrives once the take is finished and hashed.
    enum Event: Sendable, Equatable {
        /// The microphone changed during a take, which ends it, kept up to that point.
        /// A take that was opened but had no input yet is moved to the new microphone instead,
        /// with no event.
        case takeEnded(TakeEnd)
        /// A call or Siri took the audio. Input stops until the interruption ends. Carries the
        /// take that was open, if any.
        case interrupted(TakeEnd?)
        /// The interruption ended. `resumed` is false when the system said not to resume or
        /// the engine could not restart; the drive then ends.
        case interruptionEnded(resumed: Bool)
        /// The engine stopped and could not restart, and the audio core has stopped. Carries
        /// the take that was open, if any. The drive ends.
        case failed(String, TakeEnd?)
    }

    /// How a take ended.
    enum TakeEnd: Sendable, Equatable {
        /// Keep it: `PracticeStore.keepTake` with the recording and hash.
        case kept(FinishedTake)
        /// Nothing to keep: no input reached the take, or the cut was at or before its start.
        /// Its file is already deleted. The loop says it did not catch an answer.
        case empty(AudioRecorder.StopReason)
        /// Writing or hashing the file failed (a full disk, say). Nothing can be kept.
        case failed(AudioRecorder.StopReason, message: String)
    }

    /// A take as the store keeps it: the trimmed file and the hash of the trimmed file.
    struct FinishedTake: Sendable, Equatable {
        let recording: AudioRecorder.Recording
        let sha256: String
        /// Where input was missing (an engine restart). The audio on either side is spliced,
        /// not padded with silence: padding would invent a pause the speaker never made.
        let gaps: [Gap]
    }

    /// Missing input inside a take.
    struct Gap: Sendable, Equatable {
        /// Seconds into the take's file where the splice is.
        let at: TimeInterval
        /// Seconds of input that were lost there.
        let length: TimeInterval
    }

    enum DriveAudioError: LocalizedError {
        case takeAlreadyOpen
        case notRunning

        var errorDescription: String? {
            switch self {
            case .takeAlreadyOpen: return "A take is already recording."
            case .notRunning: return "The drive's audio is not running."
            }
        }
    }

    /// The take is cut this long before the start of "done", so no part of the command is kept.
    nonisolated static let cutMargin: TimeInterval = 0.1
    /// The format `player` is connected in at first.
    nonisolated static let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private(set) var isRunning = false
    private(set) var isTakeOpen = false
    var onEvent: ((Event) -> Void)?

    /// Speech and tones go through this node (task 4 schedules buffers on it).
    let player = AVAudioPlayerNode()
    /// The format `player` plays; a scheduled buffer must be in it.
    private(set) var playerFormat = DriveAudio.playerFormat
    /// Called just before the player is stopped by the audio core (an interruption, an engine
    /// restart or the end of the drive), which drops what was queued on it. Whoever queued
    /// speech finishes it as not played here: stopping fires the completion handlers as if
    /// the audio had played.
    var onPlayerFlush: (() -> Void)?

    private let engine = AVAudioEngine()
    private let input: Input
    private let tap = DriveTap()
    private var inputFormat: AVAudioFormat?
    private var inputPortID: String?
    private var micRoute = MicRoute.other
    private var micName = ""
    /// True from the start of a call or Siri interruption until it ends. Nothing plays then.
    private(set) var isInterrupted = false
    private var observers: [NSObjectProtocol] = []
    /// The latest queued event; each event waits for the one before it.
    private var pendingEvent: Task<Void, Never>?

    /// Where the input comes from.
    enum Input {
        case microphone
        #if DEBUG
        case scripted(ScriptedMicrophone)
        #endif
    }

    init(input: Input = DriveAudio.defaultInput()) {
        self.input = input
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playerFormat)
    }

    /// The microphone, or in Debug builds the scripted microphone that the
    /// `-debug.syntheticMicrophone` and `-debug.microphoneFile` launch arguments select.
    static func defaultInput() -> Input {
        #if DEBUG
        if AudioRecorder.usesSyntheticInput {
            return .scripted(ScriptedMicrophone(takeClip: AudioRecorder.syntheticInputFile))
        }
        #endif
        return .microphone
    }

    var now: TimeInterval { tap.now }

    /// How long the latest input buffer was, in seconds: how far behind real time `now` can
    /// be, since it only moves when a whole buffer arrives. 0 before any input.
    var inputBufferDuration: TimeInterval { tap.lastBufferDuration }

    var takeDuration: TimeInterval? { tap.gate.duration }

    /// Connects `player` in the format of the buffers about to be scheduled, such as the
    /// 22.05 kHz mono buffers `AVSpeechSynthesizer.write` delivers, so they need no conversion.
    func connectPlayer(format: AVAudioFormat) {
        guard format != playerFormat else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    // MARK: Start and stop

    /// Activates the driving audio session and starts the engine. Call it in the foreground.
    func start() async throws {
        guard !isRunning else { return }
        switch input {
        case .microphone:
            guard AVAudioApplication.shared.recordPermission == .granted else {
                throw AudioRecorder.RecorderError.permissionDenied
            }
            try await AudioSessionConfig.activateForDriving()
            do {
                try startEngine()
            } catch {
                await AudioSessionConfig.deactivateAfterDriving()
                throw error
            }
        #if DEBUG
        case .scripted(let microphone):
            try await AudioSessionConfig.activateForDriving()
            do {
                try startEngine()
            } catch {
                await AudioSessionConfig.deactivateAfterDriving()
                throw error
            }
            micRoute = .builtIn
            micName = microphone.name
            inputFormat = microphone.format
            tap.startSegment(rate: microphone.format.sampleRate)
            microphone.start(into: tap)
        #endif
        }
        isRunning = true
        observeSession()
    }

    /// Stops the engine and deactivates the session. Events already under way are delivered
    /// first. A take still open is finished, kept up to this point, and returned; the
    /// caller decides whether to keep it.
    func stop() async -> TakeEnd? {
        guard isRunning else {
            await pendingEvent?.value
            return nil
        }
        isRunning = false
        removeObservers()
        let finish = closeGate(reason: .finished)
        stopEngine()
        tap.finishRecognizerStream()
        await pendingEvent?.value
        let end = await finish?(nil)
        await AudioSessionConfig.deactivateAfterDriving()
        return end
    }

    private func startEngine() throws {
        if case .microphone = input {
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            // A simulator reports a 0 Hz input, and tapping it kills the process; check both
            // sides of the input node first.
            let hardware = node.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, hardware.sampleRate > 0 else {
                throw AudioRecorder.RecorderError.noInput
            }
            updateRoute()
            inputFormat = format
            tap.startSegment(rate: format.sampleRate)
            node.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(for: tap))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            if case .microphone = input { engine.inputNode.removeTap(onBus: 0) }
            throw error
        }
        // Stopping the engine stops its player nodes; speech scheduled later must play.
        if !player.isPlaying { player.play() }
    }

    private func stopEngine() {
        switch input {
        case .microphone: engine.inputNode.removeTap(onBus: 0)
        #if DEBUG
        case .scripted(let microphone): microphone.stop()
        #endif
        }
        flushPlayer()
        engine.stop()
    }

    /// Drops what is queued on the player; `onPlayerFlush` runs first so that waiters are
    /// told before the stop fires the completion handlers.
    private func flushPlayer() {
        onPlayerFlush?()
        player.stop()
    }

    private func updateRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first
        micRoute = MicRoute(port: route?.portType)
        micName = route?.portName ?? "Microphone"
        inputPortID = route?.uid
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    private nonisolated static func tapBlock(for tap: DriveTap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.ingest(buffer) }
    }

    // MARK: Recognizer

    /// Every input buffer from now on, stamped on the drive clock. One consumer at a time:
    /// a new call ends the previous stream.
    func recognizerBuffers() -> AsyncStream<DriveAudioBuffer> {
        tap.makeRecognizerStream()
    }

    // MARK: Takes

    /// Opens the take gate. The take starts exactly at drive time `start` (now when nil):
    /// input before it, such as the tail of the tone, is left out, even inside one buffer.
    func openTake(url: URL, at start: TimeInterval? = nil) throws {
        guard isRunning, !isInterrupted, let inputFormat else { throw DriveAudioError.notRunning }
        guard !tap.gate.isActive else { throw DriveAudioError.takeAlreadyOpen }
        let sink = try RecordingSink(url: url, inputFormat: inputFormat)
        tap.gate.arm(sink, at: start ?? tap.now, micRoute: micRoute, micName: micName)
        isTakeOpen = true
        #if DEBUG
        if case .scripted(let microphone) = input { microphone.playTakeClip() }
        #endif
    }

    /// Closes the take gate, trims the take, and hashes the trimmed file. Nil when no take
    /// was open.
    ///
    /// `cutAt` is the start of "done" on the drive clock (`CommandSpotter.Event.done`); the
    /// take keeps everything before `cutAt - cutMargin`. Nil keeps the whole take (time
    /// limit, stop). A cut at or before the take's start leaves nothing: `.empty`.
    func finishTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async -> TakeEnd? {
        guard let finish = closeGate(reason: reason) else { return nil }
        return await finish(cutAt.map { $0 - Self.cutMargin })
    }

    /// Closes the gate now, so no later input reaches the take, and returns how to finish
    /// what it held (nil when nothing was armed or open).
    private func closeGate(
        reason: AudioRecorder.StopReason
    ) -> (@Sendable (TimeInterval?) async -> TakeEnd)? {
        let closed = tap.gate.close()
        isTakeOpen = false
        switch closed {
        case .nothing:
            return nil
        case .empty:
            return { _ in .empty(reason) }
        case .take(let take):
            return { cut in await Task.detached { take.finish(cutAt: cut, reason: reason) }.value }
        }
    }

    /// Queues an event after the ones before it. `make` may finish a take first.
    private func emit(_ make: @escaping @MainActor @Sendable () async -> Event) {
        let previous = pendingEvent
        pendingEvent = Task { @MainActor in
            await previous?.value
            let event = await make()
            onEvent?(event)
        }
    }

    // MARK: Interruptions and route changes

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let type = typeRaw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                MainActor.assumeIsolated {
                    switch type {
                    case .began?: self?.interruptionBegan()
                    case .ended?: self?.interruptionEnded(shouldResume: shouldResume)
                    default: break
                    }
                }
            })
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            })
        observers.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.configurationChanged() }
            })
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fail("The audio system was reset.") }
            })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func interruptionBegan() {
        guard isRunning, !isInterrupted else { return }
        isInterrupted = true
        // Anything queued must not play when the interruption ends, on top of what comes next.
        flushPlayer()
        let finish = closeGate(reason: .interrupted)
        emit { .interrupted(await finish?(nil)) }
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isRunning, isInterrupted else { return }
        isInterrupted = false
        guard shouldResume else {
            emit { .interruptionEnded(resumed: false) }
            return
        }
        emit { [weak self] in
            guard let self else { return .interruptionEnded(resumed: false) }
            do {
                try await AudioSessionConfig.activateForDriving()
                // The drive may have stopped, or been interrupted again, meanwhile.
                guard self.isRunning, !self.isInterrupted else { return .interruptionEnded(resumed: false) }
                try self.restartEngine()
                return .interruptionEnded(resumed: true)
            } catch {
                return .interruptionEnded(resumed: false)
            }
        }
    }

    /// An output change (car audio connecting, AirPods) is ignored. A different microphone
    /// ends the open take, kept up to that point, because the rest would not match it.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard isRunning, case .microphone = input else { return }
        if reason == .newDeviceAvailable { AudioSessionConfig.preferBuiltInMicrophone() }
        let current = AVAudioSession.sharedInstance().currentRoute.inputs.first
        guard current?.uid != inputPortID else { return }
        updateRoute()
        inputChanged(to: inputFormat)
    }

    /// The engine stops itself when the hardware configuration changes; restart it at once
    /// so the drive keeps listening. Not while interrupted: the interruption's end restarts it.
    private func configurationChanged() {
        guard isRunning, !isInterrupted, !engine.isRunning else { return }
        do {
            try restartEngine()
        } catch {
            fail("The microphone stopped: \(error.localizedDescription)")
        }
    }

    /// Starts the engine again after it stopped. The drive clock moves on by the time that
    /// passed, so recognizer times stay monotonic. An open take goes on (spliced over the
    /// gap) when the microphone and its format are the same, and ends otherwise. This
    /// notification can come before the route change's, so the port is checked here too.
    private func restartEngine() throws {
        flushPlayer()
        if case .microphone = input {
            engine.inputNode.removeTap(onBus: 0)
            let format = engine.inputNode.outputFormat(forBus: 0)
            let port = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            if port != inputPortID || format != inputFormat {
                updateRoute()
                inputChanged(to: format)
            }
        }
        try startEngine()
    }

    /// The microphone or its format changed. An open take ends here, kept up to this point.
    /// A take with no input yet moves to the new microphone at the same start.
    private func inputChanged(to format: AVAudioFormat?) {
        guard tap.gate.isActive else { return }
        if let format, tap.gate.isArmedOnly {
            let route = micRoute
            let name = micName
            do {
                if try tap.gate.rearm(micRoute: route, micName: name, sink: { try RecordingSink(url: $0, inputFormat: format) }) {
                    return
                }
            } catch {
                isTakeOpen = false
                emit { .takeEnded(.failed(.routeChanged, message: "The take could not move to the new microphone: \(error.localizedDescription)")) }
                return
            }
        }
        let finish = closeGate(reason: .routeChanged)
        if let finish { emit { .takeEnded(await finish(nil)) } }
    }

    /// Stops everything after an unrecoverable error and reports it with any open take.
    private func fail(_ message: String) {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        let finish = closeGate(reason: .interrupted)
        stopEngine()
        tap.finishRecognizerStream()
        emit {
            let end = await finish?(nil)
            await AudioSessionConfig.deactivateAfterDriving()
            return .failed(message, end)
        }
    }
}

/// One input buffer and where it starts on the drive clock. The buffer is a copy the
/// receiver owns, so it can cross to the recognizer's task.
struct DriveAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Seconds since the drive started.
    let startTime: TimeInterval
}

/// The drive's one audio clock: seconds since the drive started, counted in input frames.
///
/// Within a segment, time is frames divided by the input rate, so it is exact to the frame.
/// A restart (after an interruption or a hardware change) starts a new segment where the
/// last one ended plus the time that passed, so times only go forward.
struct DriveClock: Sendable, Equatable {
    private(set) var segmentStart: TimeInterval = 0
    private(set) var rate: Double = 0
    private(set) var frames: Int64 = 0

    /// The end of the last stamped buffer.
    var now: TimeInterval { rate > 0 ? segmentStart + Double(frames) / rate : segmentStart }

    mutating func startSegment(rate: Double, after gap: TimeInterval) {
        segmentStart = now + max(0, gap)
        self.rate = rate
        frames = 0
    }

    /// The start time of a buffer of `count` frames, which the clock then moves past.
    mutating func stamp(frames count: Int) -> TimeInterval {
        let start = now
        frames += Int64(count)
        return start
    }
}

/// The input tap's state: the clock, the gate and the recognizer stream. The tap thread
/// (or the scripted microphone) and the main actor both touch it, so it is behind a lock.
final class DriveTap: @unchecked Sendable {
    let gate = TakeGate()
    private let lock = NSLock()
    private var clock = DriveClock()
    private var lastBuffer: Date?
    private var lastDuration: TimeInterval = 0
    private var started = false
    private var continuation: AsyncStream<DriveAudioBuffer>.Continuation?

    var now: TimeInterval { lock.withLock { clock.now } }

    /// The length of the latest buffer, in seconds.
    var lastBufferDuration: TimeInterval { lock.withLock { lastDuration } }

    /// Starts counting at `rate`. After the first segment, the gap since the last buffer
    /// is added so the clock follows real time across a restart.
    func startSegment(rate: Double) {
        lock.withLock {
            let gap = started ? lastBuffer.map { Date().timeIntervalSince($0) } ?? 0 : 0
            clock.startSegment(rate: rate, after: gap)
            started = true
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let (time, continuation) = lock.withLock {
            lastBuffer = Date()
            lastDuration = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
            return (clock.stamp(frames: Int(buffer.frameLength)), self.continuation)
        }
        gate.ingest(buffer, at: time)
        if let continuation, let copy = buffer.copy() as? AVAudioPCMBuffer {
            continuation.yield(DriveAudioBuffer(buffer: copy, startTime: time))
        }
    }

    func makeRecognizerStream() -> AsyncStream<DriveAudioBuffer> {
        // About 40 seconds of 4096-frame buffers at 48 kHz: a stalled recognizer loses the
        // oldest audio, never the newest.
        let (stream, continuation) = AsyncStream.makeStream(
            of: DriveAudioBuffer.self, bufferingPolicy: .bufferingNewest(500))
        let previous = lock.withLock {
            let previous = self.continuation
            self.continuation = continuation
            return previous
        }
        previous?.finish()
        return stream
    }

    func finishRecognizerStream() {
        let previous = lock.withLock {
            let previous = continuation
            continuation = nil
            return previous
        }
        previous?.finish()
    }
}

/// Writes input to a take only while the take is open.
///
/// `arm` sets the take's start on the drive clock; the take opens with the first input at or
/// after it, dropping the frames of that buffer that come before it. The gate records where
/// each run of contiguous input starts, as a (drive time, take frame) pair, so a drive time
/// maps to the right take frame even when a restart left a gap.
final class TakeGate: @unchecked Sendable {
    /// Where a run of contiguous input starts: its drive time and its first take frame.
    struct Segment: Sendable, Equatable {
        var time: TimeInterval
        var frame: Int
    }

    /// What `close()` found.
    enum Closed {
        case nothing
        /// Armed, but no input reached it; its file is deleted.
        case empty
        case take(ClosedTake)
    }

    /// A take whose gate has closed, ready to trim and hash.
    struct ClosedTake: @unchecked Sendable {
        let sink: RecordingSink
        let recordedAt: Date
        let micRoute: MicRoute
        let micName: String
        let segments: [Segment]

        private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "DriveAudio")

        /// Trims at drive time `cut` (keeps everything when nil), finishes the file and hashes
        /// it. A take left with no frames is deleted and reported as `.empty`.
        func finish(cutAt cut: TimeInterval?, reason: AudioRecorder.StopReason) -> DriveAudio.TakeEnd {
            let keep = cut.map {
                TakeGate.frame(at: $0, segments: segments, outputRate: sink.outputRate, frames: sink.frames)
            }
            let frames: Int
            do {
                frames = try sink.finish(keepingFrames: keep)
            } catch {
                return .failed(reason, message: "The take could not be written: \(error.localizedDescription)")
            }
            guard frames > 0 else {
                // The store never saw this file, and it holds no audio.
                try? FileManager.default.removeItem(at: sink.url)
                return .empty(reason)
            }
            let sha: String
            do {
                sha = try WAVWriter.sha256(of: sink.url)
            } catch {
                return .failed(reason, message: "The take could not be read back: \(error.localizedDescription)")
            }
            let gaps = TakeGate.gaps(in: segments, outputRate: sink.outputRate, frames: frames)
            for gap in gaps {
                Self.log.notice(
                    "Take \(sink.url.lastPathComponent, privacy: .public) has \(gap.length, privacy: .public) s of input missing at \(gap.at, privacy: .public) s")
            }
            let recording = AudioRecorder.Recording(
                url: sink.url, recordedAt: recordedAt,
                duration: Double(frames) / Double(sink.outputRate), sampleRate: sink.outputRate,
                micRoute: micRoute, micName: micName, stopReason: reason)
            return .kept(DriveAudio.FinishedTake(recording: recording, sha256: sha, gaps: gaps))
        }
    }

    private struct Armed {
        let sink: RecordingSink
        let start: TimeInterval
        let micRoute: MicRoute
        let micName: String
    }

    private struct Open {
        let sink: RecordingSink
        let recordedAt: Date
        let micRoute: MicRoute
        let micName: String
        var segments: [Segment]
        var expectedNext: TimeInterval
    }

    private enum State {
        case closed
        case armed(Armed)
        case open(Open)
    }

    private let lock = NSLock()
    private var state = State.closed

    /// Armed or open.
    var isActive: Bool {
        lock.withLock {
            if case .closed = state { return false }
            return true
        }
    }

    /// Armed, with no input in the take yet.
    var isArmedOnly: Bool {
        lock.withLock {
            if case .armed = state { return true }
            return false
        }
    }

    /// The open take's length so far; zero while armed, nil when closed.
    var duration: TimeInterval? {
        lock.withLock {
            switch state {
            case .closed: return nil
            case .armed: return 0
            case .open(let open): return Double(open.sink.frames) / Double(open.sink.outputRate)
            }
        }
    }

    /// Opens the take at drive time `start`.
    func arm(_ sink: RecordingSink, at start: TimeInterval, micRoute: MicRoute, micName: String) {
        lock.withLock { state = .armed(Armed(sink: sink, start: start, micRoute: micRoute, micName: micName)) }
    }

    /// Replaces an armed take's file with one from `sink` (same URL, new input format) and
    /// keeps its start. Returns false when the gate is not armed with no input yet.
    func rearm(micRoute: MicRoute, micName: String, sink makeSink: (URL) throws -> RecordingSink) throws -> Bool {
        try lock.withLock {
            guard case .armed(let armed) = state else { return false }
            _ = try? armed.sink.finish()
            try? FileManager.default.removeItem(at: armed.sink.url)
            do {
                let sink = try makeSink(armed.sink.url)
                state = .armed(Armed(sink: sink, start: armed.start, micRoute: micRoute, micName: micName))
                return true
            } catch {
                state = .closed
                throw error
            }
        }
    }

    /// Called for every input buffer; writes it only while the take is open.
    func ingest(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        lock.withLock {
            let rate = buffer.format.sampleRate
            let frames = Int(buffer.frameLength)
            let end = time + Double(frames) / rate
            switch state {
            case .closed:
                return
            case .armed(let armed):
                let skip = max(0, Int(((armed.start - time) * rate).rounded()))
                guard skip < frames, let used = skip == 0 ? buffer : buffer.dropFirst(skip) else { return }
                state = .open(
                    Open(
                        sink: armed.sink, recordedAt: Date(), micRoute: armed.micRoute, micName: armed.micName,
                        segments: [Segment(time: skip > 0 ? armed.start : time, frame: 0)], expectedNext: end))
                armed.sink.append(used)
            case .open(var open):
                // Half a frame of slack absorbs floating-point rounding of contiguous times.
                if abs(time - open.expectedNext) > 0.5 / rate {
                    open.segments.append(Segment(time: time, frame: open.sink.frames))
                }
                open.expectedNext = end
                open.sink.append(buffer)
                state = .open(open)
            }
        }
    }

    /// Closes the gate. An armed gate that never got input deletes its file, which no take
    /// ever pointed at.
    func close() -> Closed {
        let previous = lock.withLock {
            let previous = state
            state = .closed
            return previous
        }
        switch previous {
        case .closed:
            return .nothing
        case .armed(let armed):
            _ = try? armed.sink.finish()
            try? FileManager.default.removeItem(at: armed.sink.url)
            return .empty
        case .open(let open):
            return .take(
                ClosedTake(
                    sink: open.sink, recordedAt: open.recordedAt, micRoute: open.micRoute,
                    micName: open.micName, segments: open.segments))
        }
    }

    /// The number of take frames recorded before drive time `time`, clamped to the take.
    /// A time inside a gap maps to the end of the input before the gap.
    static func frame(at time: TimeInterval, segments: [Segment], outputRate: Int, frames: Int) -> Int {
        guard let index = segments.lastIndex(where: { $0.time <= time }) else { return 0 }
        let segment = segments[index]
        let limit = index + 1 < segments.count ? segments[index + 1].frame : frames
        let offset = Int(((time - segment.time) * Double(outputRate)).rounded())
        return min(max(segment.frame + offset, segment.frame), limit)
    }

    /// The gaps between segments that lie inside the first `frames` frames of the take.
    static func gaps(in segments: [Segment], outputRate: Int, frames: Int) -> [DriveAudio.Gap] {
        zip(segments, segments.dropFirst()).compactMap { previous, segment in
            guard segment.frame < frames else { return nil }
            let previousEnd = previous.time + Double(segment.frame - previous.frame) / Double(outputRate)
            return DriveAudio.Gap(
                at: Double(segment.frame) / Double(outputRate), length: max(0, segment.time - previousEnd))
        }
    }
}

extension AVAudioPCMBuffer {
    /// A copy without the first `count` frames, for float buffers (what the input tap and the
    /// scripted microphone deliver).
    func dropFirst(_ count: Int) -> AVAudioPCMBuffer? {
        let remaining = Int(frameLength) - count
        guard remaining > 0, let source = floatChannelData,
            let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)),
            let target = copy.floatChannelData
        else { return nil }
        copy.frameLength = AVAudioFrameCount(remaining)
        let stride = self.stride
        for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
            target[channel].update(from: source[channel] + count * stride, count: remaining * stride)
        }
        return copy
    }
}

// MARK: Audio session for driving

extension AudioSessionConfig {
    /// The session for a whole drive (plan section 4).
    ///
    /// - `.playAndRecord`, because the drive speaks and listens on one running engine.
    /// - `.measurement`, as in home mode, so takes hold the raw signal with no gain control.
    /// - `.allowBluetoothA2DP` sends speech to car audio and AirPods in full quality.
    ///   `.allowBluetoothHFP` is left out on purpose: with both, HFP wins and both the input
    ///   and the output become a narrowband call link, and the car's hands-free microphone
    ///   can erase the fillers and short pauses the app measures (architecture.md#iphone-app).
    /// - `.defaultToSpeaker` uses the loudspeaker, not the receiver, when nothing is connected.
    /// - The built-in microphone is preferred, so a wired CarPlay car's microphone is not used.
    ///
    /// With the `audio` background mode and the engine running, the app keeps running and
    /// listening while the phone is locked.
    static func activateForDriving() async throws {
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            preferBuiltInMicrophone()
        }.value
    }

    /// Prefers the iPhone's own microphone over any other input that appears.
    nonisolated static func preferBuiltInMicrophone() {
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(builtIn)
    }

    /// Ends the drive's session and lets the audio the drive interrupted (music, a podcast)
    /// resume. The input preference is cleared so home mode routes as before.
    static func deactivateAfterDriving() async {
        await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try? session.setPreferredInput(nil)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }.value
    }
}
