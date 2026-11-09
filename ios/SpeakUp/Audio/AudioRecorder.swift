import AVFoundation
import Foundation
import Observation

/// Records one take with `AVAudioEngine` to a mono 16-bit WAV on disk, with a live level.
///
/// There is no pause: a paused take would hide real pauses (product.md#recording).
/// A phone call, another app taking the microphone, or an input route change stops the
/// take and keeps it up to that point; so does the 15-minute technical limit.
@MainActor
@Observable
final class AudioRecorder {
    enum StopReason: Equatable, Sendable {
        case finished
        case interrupted
        case routeChanged
        case limit
    }

    struct Recording: Equatable, Sendable {
        let url: URL
        let recordedAt: Date
        let duration: Double
        let sampleRate: Int
        let micRoute: MicRoute
        let micName: String
        let stopReason: StopReason
    }

    enum RecorderError: LocalizedError {
        case noInput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .permissionDenied: return "SpeakUp does not have access to the microphone."
            }
        }
    }

    static let warningAfter: TimeInterval = 14 * 60
    static let limit: TimeInterval = 15 * 60

    private(set) var isRecording = false
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var micName = ""
    /// Set when the recorder stops by itself (interruption, route change, limit).
    var onAutoStop: ((Recording) -> Void)?

    private let engine = AVAudioEngine()
    private var sink: RecordingSink?
    private var recordedAt = Date()
    private var micRoute = MicRoute.other
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    var isPastWarning: Bool { elapsed >= Self.warningAfter }

    func start(to url: URL) throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw RecorderError.permissionDenied
        }
        try AudioSessionConfig.activateForRecording()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first
        micRoute = MicRoute(port: route?.portType)
        micName = route?.portName ?? "Microphone"

        let sink = try RecordingSink(url: url, inputFormat: format)
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(for: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = try? sink.finish()
            self.sink = nil
            throw error
        }

        recordedAt = Date()
        elapsed = 0
        level = 0
        isRecording = true
        observeInterruptions()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    /// Stops and keeps the take.
    @discardableResult
    func stop(reason: StopReason = .finished) -> Recording? {
        guard isRecording, let sink else { return nil }
        tearDown()
        let frames = (try? sink.finish()) ?? sink.frames
        self.sink = nil
        return Recording(
            url: sink.url, recordedAt: recordedAt,
            duration: Double(frames) / Double(sink.outputRate), sampleRate: sink.outputRate,
            micRoute: micRoute, micName: micName, stopReason: reason)
    }

    /// Stops and deletes the take.
    func cancel() {
        guard let recording = stop() else { return }
        try? FileManager.default.removeItem(at: recording.url)
    }

    private func tearDown() {
        isRecording = false
        ticker?.cancel()
        ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        level = 0
    }

    private func tick() {
        guard isRecording, let sink else { return }
        elapsed = Double(sink.frames) / Double(sink.outputRate)
        level = sink.level
        if elapsed >= Self.limit { autoStop(.limit) }
    }

    private func autoStop(_ reason: StopReason) {
        guard let recording = stop(reason: reason) else { return }
        onAutoStop?(recording)
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
                MainActor.assumeIsolated { self?.autoStop(.interrupted) }
            })
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
                MainActor.assumeIsolated { self?.autoStop(.routeChanged) }
            })
        observers.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A configuration change that stopped the engine ends the take; one that
                    // left it running needs nothing.
                    guard let self, !self.engine.isRunning else { return }
                    self.autoStop(.routeChanged)
                }
            })
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoStop(.interrupted) }
            })
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    private nonisolated static func tapBlock(for sink: RecordingSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }
}

extension MicRoute {
    init(port: AVAudioSession.Port?) {
        switch port {
        case .builtInMic?: self = .builtIn
        case .bluetoothHFP?: self = .bluetoothHFP
        case .carAudio?: self = .carAudio
        case .headsetMic?: self = .headset
        case .usbAudio?: self = .usb
        default: self = .other
        }
    }
}

/// Converts tapped buffers to mono 16-bit PCM and writes them, off the main actor.
/// All state is behind one lock because the tap thread and the main actor both touch it.
final class RecordingSink: @unchecked Sendable {
    let url: URL
    let outputRate: Int
    private let lock = NSLock()
    private var writer: WAVWriter?
    private let inputRate: Double
    private let converter: AVAudioConverter?
    private let monoInputFormat: AVAudioFormat
    private let monoOutputFormat: AVAudioFormat
    private var latestLevel: Double = 0
    private var writtenFrames = 0

    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.url = url
        inputRate = inputFormat.sampleRate
        outputRate = AudioConversion.outputSampleRate(forInput: inputFormat.sampleRate)
        guard
            let monoIn = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let monoOut = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate), channels: 1,
                interleaved: false)
        else { throw AudioRecorder.RecorderError.noInput }
        monoInputFormat = monoIn
        monoOutputFormat = monoOut
        converter = Int(inputRate.rounded()) == outputRate ? nil : AVAudioConverter(from: monoIn, to: monoOut)
        writer = try WAVWriter(url: url, sampleRate: outputRate)
    }

    var frames: Int { lock.withLock { writtenFrames } }
    var level: Double { lock.withLock { latestLevel } }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map {
            UnsafeBufferPointer(start: channelData[$0], count: frameCount)
        }
        var mono = AudioConversion.downmix(channels, frames: frameCount)
        let meter = AudioConversion.meterLevel(mono)
        if let converter { mono = resample(mono, with: converter) }
        let pcm = AudioConversion.int16(mono)
        lock.withLock {
            guard let writer else { return }
            do {
                try writer.append(pcm)
                writtenFrames = writer.frameCount
            } catch {
                // A full disk stops the take from growing; what was written is kept.
            }
            latestLevel = meter
        }
    }

    /// Finishes the file and returns the number of frames in it.
    func finish() throws -> Int {
        try lock.withLock {
            guard let writer else { return writtenFrames }
            self.writer = nil
            try writer.finish()
            return writer.frameCount
        }
    }

    private func resample(_ samples: [Float], with converter: AVAudioConverter) -> [Float] {
        guard
            let input = AVAudioPCMBuffer(
                pcmFormat: monoInputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let ratio = Double(outputRate) / inputRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: monoOutputFormat, frameCapacity: capacity) else {
            return []
        }
        nonisolated(unsafe) var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// The app's one audio session setup, shared by recording and playback.
enum AudioSessionConfig {
    static func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    static func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }
}

/// The microphone permission flow.
enum MicrophonePermission {
    enum State { case granted, denied, undetermined }

    static var state: State {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Asks when undetermined; returns whether recording is allowed.
    static func request() async -> Bool {
        switch state {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        }
    }
}
