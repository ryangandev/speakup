import AVFoundation
import Foundation
import Observation

/// What the drive loop needs from the audio core, so its tests can use a fake.
@MainActor
protocol DriveAudioControlling: AnyObject {
    /// The drive clock now: the end of the latest input buffer, in seconds since the drive started.
    var now: TimeInterval { get }
    /// How long the open take is, or nil when no take is open.
    var takeDuration: TimeInterval? { get }
    var onEvent: ((DriveAudio.Event) -> Void)? { get set }

    func start() async throws
    func stop() async -> DriveAudio.FinishedTake?
    func recognizerBuffers() -> AsyncStream<DriveAudioBuffer>
    func openTake(url: URL) throws
    func finishTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async throws -> DriveAudio.FinishedTake?
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
/// `player` is the seam for spoken prompts and tones: it is attached to the engine and
/// connected to the output, in `playerFormat` until `connectPlayer(format:)` changes it.
@MainActor
@Observable
final class DriveAudio: DriveAudioControlling {
    enum Event: Sendable, Equatable {
        /// The audio core ended the open take by itself and kept it up to that point:
        /// `.interrupted` for a call or Siri, `.routeChanged` when the microphone changed.
        case takeEnded(FinishedTake)
        /// A call or Siri took the audio. Input stops until the interruption ends.
        case interrupted
        /// The interruption ended. `resumed` is false when the system said not to resume or
        /// the engine could not restart; the drive then ends.
        case interruptionEnded(resumed: Bool)
        /// The engine stopped and could not restart. The drive ends.
        case failed(String)
    }

    /// A take as the store keeps it: the trimmed file and the hash of the trimmed file.
    struct FinishedTake: Sendable, Equatable {
        let recording: AudioRecorder.Recording
        let sha256: String
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

    private let engine = AVAudioEngine()
    private let input: Input
    private let tap = DriveTap()
    private var inputFormat: AVAudioFormat?
    private var inputPortID: String?
    private var micRoute = MicRoute.other
    private var micName = ""
    private var isInterrupted = false
    private var observers: [NSObjectProtocol] = []

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

    /// The format `player` plays; a scheduled buffer must be in it.
    private(set) var playerFormat = DriveAudio.playerFormat

    /// Connects `player` in the format of the buffers about to be scheduled, such as the
    /// 22.05 kHz mono buffers `AVSpeechSynthesizer.write` delivers, so they need no conversion.
    func connectPlayer(format: AVAudioFormat) {
        guard format != playerFormat else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
    }

    var takeDuration: TimeInterval? { tap.gate.duration }

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

    /// Stops the engine and deactivates the session. An open take is finished and returned,
    /// kept up to this point; the caller decides whether to keep it.
    func stop() async -> FinishedTake? {
        guard isRunning else { return nil }
        let take = try? await finishTake(cutAt: nil, reason: .finished)
        isRunning = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopEngine()
        tap.finishRecognizerStream()
        await AudioSessionConfig.deactivateAfterDriving()
        return take
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
            let route = AVAudioSession.sharedInstance().currentRoute.inputs.first
            micRoute = MicRoute(port: route?.portType)
            micName = route?.portName ?? "Microphone"
            inputPortID = route?.uid
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
    }

    private func stopEngine() {
        switch input {
        case .microphone: engine.inputNode.removeTap(onBus: 0)
        #if DEBUG
        case .scripted(let microphone): microphone.stop()
        #endif
        }
        player.stop()
        engine.stop()
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

    /// Opens the take gate: the take starts with the next input buffer, at that buffer's
    /// time on the drive clock.
    func openTake(url: URL) throws {
        guard isRunning, let inputFormat else { throw DriveAudioError.notRunning }
        guard !tap.gate.isActive else { throw DriveAudioError.takeAlreadyOpen }
        let sink = try RecordingSink(url: url, inputFormat: inputFormat)
        tap.gate.arm(sink, micRoute: micRoute, micName: micName)
        isTakeOpen = true
        #if DEBUG
        if case .scripted(let microphone) = input { microphone.playTakeClip() }
        #endif
    }

    /// Closes the take gate, trims the take, and hashes the trimmed file.
    ///
    /// `cutAt` is the start of "done" on the drive clock (`CommandSpotter.Event.done`); the
    /// take keeps everything before `cutAt - cutMargin`. Nil keeps the whole take (time
    /// limit, interruption, stop).
    func finishTake(cutAt: TimeInterval?, reason: AudioRecorder.StopReason) async throws -> FinishedTake? {
        guard let closed = tap.gate.close() else { return nil }
        isTakeOpen = false
        let cut = cutAt.map { $0 - Self.cutMargin }
        return try await Task.detached { try closed.finish(cutAt: cut, reason: reason) }.value
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

    private func interruptionBegan() {
        guard isRunning, !isInterrupted else { return }
        isInterrupted = true
        endTakeByItself(.interrupted)
        onEvent?(.interrupted)
    }

    private func interruptionEnded(shouldResume: Bool) {
        guard isRunning, isInterrupted else { return }
        isInterrupted = false
        guard shouldResume else {
            onEvent?(.interruptionEnded(resumed: false))
            return
        }
        Task {
            do {
                try await AudioSessionConfig.activateForDriving()
                try restartEngine()
                onEvent?(.interruptionEnded(resumed: true))
            } catch {
                onEvent?(.interruptionEnded(resumed: false))
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
        inputPortID = current?.uid
        micRoute = MicRoute(port: current?.portType)
        micName = current?.portName ?? "Microphone"
        endTakeByItself(.routeChanged)
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
    /// passed, so recognizer times stay monotonic. An open take continues when the input
    /// format is the same, and ends otherwise.
    private func restartEngine() throws {
        if case .microphone = input {
            engine.inputNode.removeTap(onBus: 0)
            // The take's file converts from the old format; end it before any buffer in the
            // new one reaches the gate.
            if let inputFormat, engine.inputNode.outputFormat(forBus: 0) != inputFormat {
                endTakeByItself(.routeChanged)
            }
        }
        try startEngine()
    }

    private func fail(_ message: String) {
        guard isRunning else { return }
        endTakeByItself(.interrupted)
        isRunning = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        stopEngine()
        tap.finishRecognizerStream()
        onEvent?(.failed(message))
        Task { await AudioSessionConfig.deactivateAfterDriving() }
    }

    /// Closes the gate at once, so no later input reaches the take, then finishes the take
    /// and reports it.
    private func endTakeByItself(_ reason: AudioRecorder.StopReason) {
        guard let closed = tap.gate.close() else { return }
        isTakeOpen = false
        Task {
            let finished = try? await Task.detached { try closed.finish(cutAt: nil, reason: reason) }.value
            if let finished { onEvent?(.takeEnded(finished)) }
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
    private var started = false
    private var continuation: AsyncStream<DriveAudioBuffer>.Continuation?

    var now: TimeInterval { lock.withLock { clock.now } }

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
/// `arm` opens it at the next buffer, so the take's first frame is that buffer's start on
/// the drive clock. The gate records where each run of contiguous input starts, as a
/// (drive time, take frame) pair, so a drive time maps to the right take frame even when a
/// restart left a gap.
final class TakeGate: @unchecked Sendable {
    /// Where a run of contiguous input starts: its drive time and its first take frame.
    struct Segment: Sendable, Equatable {
        var time: TimeInterval
        var frame: Int
    }

    /// A take whose gate has closed, ready to trim and hash.
    struct ClosedTake: @unchecked Sendable {
        let sink: RecordingSink
        let recordedAt: Date
        let micRoute: MicRoute
        let micName: String
        let segments: [Segment]

        /// Trims at drive time `cut` (keeps everything when nil), finishes the file and hashes it.
        func finish(cutAt cut: TimeInterval?, reason: AudioRecorder.StopReason) throws -> DriveAudio.FinishedTake {
            let keep = cut.map {
                TakeGate.frame(at: $0, segments: segments, outputRate: sink.outputRate, frames: sink.frames)
            }
            let frames = try sink.finish(keepingFrames: keep)
            let sha = try WAVWriter.sha256(of: sink.url)
            let recording = AudioRecorder.Recording(
                url: sink.url, recordedAt: recordedAt,
                duration: Double(frames) / Double(sink.outputRate), sampleRate: sink.outputRate,
                micRoute: micRoute, micName: micName, stopReason: reason)
            return DriveAudio.FinishedTake(recording: recording, sha256: sha)
        }
    }

    private enum State {
        case closed
        case armed(RecordingSink, MicRoute, String)
        case open(Open)
    }

    private struct Open {
        let sink: RecordingSink
        let recordedAt: Date
        let micRoute: MicRoute
        let micName: String
        var segments: [Segment]
        var expectedNext: TimeInterval
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

    func arm(_ sink: RecordingSink, micRoute: MicRoute, micName: String) {
        lock.withLock { state = .armed(sink, micRoute, micName) }
    }

    /// Called for every input buffer; writes it only while the take is open.
    func ingest(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        lock.withLock {
            let length = Double(buffer.frameLength) / buffer.format.sampleRate
            switch state {
            case .closed:
                return
            case .armed(let sink, let route, let name):
                state = .open(
                    Open(
                        sink: sink, recordedAt: Date(), micRoute: route, micName: name,
                        segments: [Segment(time: time, frame: 0)], expectedNext: time + length))
                sink.append(buffer)
            case .open(var open):
                // Half a frame of slack absorbs floating-point rounding of contiguous times.
                if abs(time - open.expectedNext) > 0.5 / buffer.format.sampleRate {
                    open.segments.append(Segment(time: time, frame: open.sink.frames))
                }
                open.expectedNext = time + length
                open.sink.append(buffer)
                state = .open(open)
            }
        }
    }

    /// Closes the gate. Returns the take, or nil when no input reached it (an armed gate
    /// that never opened deletes its empty file, which no take ever pointed at).
    func close() -> ClosedTake? {
        let previous = lock.withLock {
            let previous = state
            state = .closed
            return previous
        }
        switch previous {
        case .closed:
            return nil
        case .armed(let sink, _, _):
            _ = try? sink.finish()
            try? FileManager.default.removeItem(at: sink.url)
            return nil
        case .open(let open):
            return ClosedTake(
                sink: open.sink, recordedAt: open.recordedAt, micRoute: open.micRoute,
                micName: open.micName, segments: open.segments)
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
