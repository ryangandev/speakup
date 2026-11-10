import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

/// Hears voice commands on the phone with `SpeechAnalyzer` (plan section 3). Nothing leaves the
/// phone.
///
/// It feeds the drive's input to the engine, stamped on the drive clock, so every word time it
/// reports is a drive time that maps to a take frame. `CommandRecognitionCore` turns the
/// engine's results into spotter updates and decides when to finalize.
@MainActor
final class SpeechCommandRecognizer: CommandRecognizing {
    private let engine: any RecognitionEngine
    private var core: CommandRecognitionCore
    private var session: (any RecognitionSession)?
    private var continuation: AsyncStream<CommandRecognizerEvent>.Continuation?
    private var feeding: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    /// Counts starts, stops and failures, so a `start` that a `stop` overtook while it awaited
    /// the engine, or a late stop or failure from an old session, cannot act on the current one.
    private var generation = 0
    private let capture: RecognizerCapture?

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "SpeechCommandRecognizer")

    init(
        engine: any RecognitionEngine = SpeechAnalyzerEngine(), config: CommandRecognitionCore.Config = .init(),
        capture: RecognizerCapture? = nil
    ) {
        self.engine = engine
        core = CommandRecognitionCore(config: config)
        self.capture = capture
    }

    func prepare() async throws {
        try await engine.prepare()
    }

    /// A `stop()` while it waits for the engine wins: the stream it returns has already ended.
    func start(buffers: AsyncStream<DriveAudioBuffer>) async throws -> AsyncStream<CommandRecognizerEvent> {
        await stop()
        let started = generation
        let session = try await engine.startSession()
        guard generation == started else {
            await session.finish()
            return AsyncStream { $0.finish() }
        }
        self.session = session
        core = CommandRecognitionCore(config: core.config)
        let (stream, continuation) = AsyncStream.makeStream(of: CommandRecognizerEvent.self)
        self.continuation = continuation

        reading = Task { [weak self] in
            do {
                for try await result in session.results {
                    self?.received(result)
                }
                if !Task.isCancelled { self?.fail("The speech recognizer stopped.", generation: started) }
            } catch {
                if !Task.isCancelled { self?.fail(error.localizedDescription, generation: started) }
            }
        }
        let capture = self.capture
        feeding = Task.detached { [weak self] in
            for await buffer in buffers {
                capture?.write(buffer)
                do {
                    try session.append(buffer)
                } catch {
                    await self?.fail(error.localizedDescription, generation: started)
                    return
                }
                await self?.fed(through: buffer.endTime)
            }
            // The drive's audio stopped: so does recognition, with no failure.
            if !Task.isCancelled { await self?.stop(generation: started) }
        }
        return stream
    }

    func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        capture?.note(String(format: "listen %@ from %.2f", "\(mode)", time))
        core.listen(mode: mode, from: time)
    }

    func stopListening() {
        capture?.note("stop listening")
        core.stopListening()
    }

    func stop() async {
        generation += 1
        let session = self.session
        tearDown()
        await session?.finish()
    }

    // MARK: - Private

    private func stop(generation started: Int) async {
        guard generation == started else { return }
        await stop()
    }

    private func received(_ result: RecognizedResult) {
        capture?.note(result)
        perform(core.receive(result))
    }

    private func fed(through time: TimeInterval) {
        perform(core.fed(through: time))
    }

    private func perform(_ actions: [CommandRecognitionCore.Action]) {
        for action in actions {
            switch action {
            case .update(let update):
                continuation?.yield(.update(update))
            case .finalize(let time):
                guard let session else { continue }
                capture?.note(String(format: "finalize through %.2f", time))
                let started = generation
                Task { [weak self] in
                    do {
                        try await session.finalize(through: time)
                        self?.finalized(through: time, in: session)
                    } catch {
                        // Its time is never requested again, so a "done" waiting on it would never
                        // be confirmed.
                        self?.fail(
                            String(format: "Finalizing through %.2f s failed: %@", time, error.localizedDescription),
                            generation: started)
                    }
                }
            case .fail(let message):
                fail(message, generation: generation)
            }
        }
    }

    private func finalized(through time: TimeInterval, in finished: any RecognitionSession) {
        guard session === finished else { return }
        capture?.note(String(format: "finalized through %.2f", time))
        core.finalized(through: time)
    }

    private func fail(_ message: String, generation started: Int) {
        guard generation == started, let continuation else { return }
        generation += 1
        Self.log.error("Commands failed: \(message, privacy: .public)")
        continuation.yield(.failed(message))
        let session = self.session
        tearDown()
        Task { await session?.finish() }
    }

    private func tearDown() {
        feeding?.cancel()
        reading?.cancel()
        feeding = nil
        reading = nil
        session = nil
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - Engine seam

/// The speech engine behind `SpeechCommandRecognizer`: `SpeechAnalyzerEngine`, or a fake in tests.
protocol RecognitionEngine: Sendable {
    /// Checks availability and installs assets. Throws `CommandRecognizerError.unavailable`.
    func prepare() async throws
    /// Starts one analysis. Throws `CommandRecognizerError.unavailable`.
    func startSession() async throws -> any RecognitionSession
}

/// One running analysis.
protocol RecognitionSession: AnyObject, Sendable {
    /// Results in the order the engine reports them. It ends, or throws, when the engine stops.
    var results: AsyncThrowingStream<RecognizedResult, any Error> { get }
    /// Feeds one input buffer. Called from one task at a time, in drive-clock order.
    func append(_ buffer: DriveAudioBuffer) throws
    /// Asks the engine to make every result up to `time` final; returns once it has.
    func finalize(through time: TimeInterval) async throws
    func finish() async
}

extension DriveAudioBuffer {
    /// Where the buffer ends on the drive clock.
    var endTime: TimeInterval {
        let rate = buffer.format.sampleRate
        return rate > 0 ? startTime + Double(buffer.frameLength) / rate : startTime
    }
}

// MARK: - SpeechAnalyzer

/// `SpeechAnalyzer` with one transcriber, on device, in English.
///
/// Commands use `SpeechTranscriber` only. On a phone without it, `prepare()` throws
/// `CommandRecognizerError.unavailable` and the drive says commands are unavailable, rather than
/// falling back to `DictationTranscriber`, which fails the clips in `tools/drive-commands`. On
/// macOS 27, over those clips:
/// - `SpeechTranscriber` passes every clip: each "done" starts within 0.21 s of where it was
///   said, a "done" followed by more speech is left alone, and every between-take command is
///   heard. It stretches the last word before a pause
///   (`CommandRecognitionCore.trimmingStretchedEnd`), and drops words from a final when made to
///   finalize audio it has not reported yet (`CommandRecognitionCore`).
/// - `DictationTranscriber` misses a "done" after a thinking pause, starts another 0.36 s
///   late (so the take keeps part of it), and invents a word ("no") when silence is finalized.
///   It stays selectable (`Transcriber.dictation`) so the tool can measure it.
/// - In the iOS simulator neither works: `SpeechTranscriber` is unsupported and
///   `DictationTranscriber` has no model. Debug builds use `ScriptedRecognizer` there.
///
/// Neither needs speech-recognition authorization or a usage string. Never call the legacy
/// `SFSpeechRecognizer.requestAuthorization`: without a usage string it crashes.
struct SpeechAnalyzerEngine: RecognitionEngine {
    enum Transcriber: String, Sendable, CaseIterable {
        case speech
        case dictation
    }

    /// Words to bias the engine toward: the commands (`CommandSpotter.phrases` and "done").
    static let contextualStrings = ["done", "I'm done"] + CommandSpotter.phrases.keys.sorted()

    let transcriber: Transcriber
    let locale: Locale

    init(transcriber: Transcriber = .speech, locale: Locale = Locale(identifier: "en-US")) {
        self.transcriber = transcriber
        self.locale = locale
    }

    func prepare() async throws {
        let module = try await makeModule()
        if await AssetInventory.status(forModules: [module.module]) == .unsupported {
            throw CommandRecognizerError.unavailable("\(transcriber.rawValue) recognition is not supported here.")
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw CommandRecognizerError.unavailable("Speech assets could not be installed: \(error.localizedDescription)")
        }
        _ = try await audioFormat(for: module)
    }

    func startSession() async throws -> any RecognitionSession {
        let module = try await makeModule()
        let format = try await audioFormat(for: module)
        do {
            return try await SpeechAnalyzerSession(module: module, format: format, contextualStrings: Self.contextualStrings)
        } catch {
            throw CommandRecognizerError.unavailable("The speech analyzer did not start: \(error.localizedDescription)")
        }
    }

    private func makeModule() async throws -> Module {
        switch transcriber {
        case .speech:
            guard SpeechTranscriber.isAvailable,
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            else { throw CommandRecognizerError.unavailable("SpeechTranscriber does not support \(locale.identifier).") }
            return .speech(
                SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange]))
        case .dictation:
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw CommandRecognizerError.unavailable("DictationTranscriber does not support \(locale.identifier).")
            }
            return .dictation(
                DictationTranscriber(
                    locale: locale, contentHints: [], transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange]))
        }
    }

    private func audioFormat(for module: Module) async throws -> AVAudioFormat {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module]) else {
            throw CommandRecognizerError.unavailable("The \(transcriber.rawValue) model is not available.")
        }
        return format
    }

    enum Module: Sendable {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let transcriber): transcriber
            case .dictation(let transcriber): transcriber
            }
        }
    }
}

/// One `SpeechAnalyzer` run over the drive's input.
final class SpeechAnalyzerSession: RecognitionSession, @unchecked Sendable {
    let results: AsyncThrowingStream<RecognizedResult, any Error>
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let reader: Task<Void, Never>
    private let lock = NSLock()
    private var stamper: AnalyzerInputStamper

    init(module: SpeechAnalyzerEngine.Module, format: AVAudioFormat, contextualStrings: [String]) async throws {
        analyzer = SpeechAnalyzer(modules: [module.module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)
        let (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        stamper = AnalyzerInputStamper(outputFormat: format)
        let (results, continuation) = AsyncThrowingStream.makeStream(of: RecognizedResult.self)
        self.results = results
        reader = Task {
            do {
                switch module {
                case .speech(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(Self.result(result.text, result.range, result.isFinal, result.resultsFinalizationTime))
                    }
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        continuation.yield(Self.result(result.text, result.range, result.isFinal, result.resultsFinalizationTime))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            reader.cancel()
            input.finish()
            throw error
        }
    }

    func append(_ buffer: DriveAudioBuffer) throws {
        let converted = try lock.withLock { try stamper.convert(buffer) }
        if let converted { input.yield(converted) }
    }

    func finalize(through time: TimeInterval) async throws {
        try await analyzer.finalize(through: CMTime(seconds: time, preferredTimescale: 48_000))
    }

    func finish() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        reader.cancel()
    }

    /// One result in drive-clock seconds, with the words that carry their own times.
    static func result(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool, _ finalized: CMTime) -> RecognizedResult {
        var words: [CommandSpotter.TimedWord] = []
        for run in text.runs {
            guard let time = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            words.append(.init(piece, start: time.start.seconds, end: time.end.seconds))
        }
        let start = range.start.seconds
        let end = max(start, range.end.seconds)
        return RecognizedResult(
            text: String(text.characters), timedWords: words, range: start...end, isFinal: isFinal,
            finalizedThrough: finalized.isNumeric ? finalized.seconds : 0)
    }
}

/// Converts the drive's input to the analyzer's format and stamps each buffer with its start on
/// the drive clock.
///
/// Times are counted in output frames from an anchor, so they stay exact across buffers. A
/// new anchor is set when the input jumps (the drive clock moves on across an engine
/// restart) or changes format.
struct AnalyzerInputStamper {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var anchor: Int64 = 0
    private var produced: Int64 = 0
    private var expectedStart: TimeInterval?

    enum StamperError: LocalizedError {
        case unsupportedInput(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedInput(let format): return "The recognizer cannot convert input in \(format)."
            }
        }
    }

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    mutating func convert(_ input: DriveAudioBuffer) throws -> AnalyzerInput? {
        let buffer = input.buffer
        let format = buffer.format
        guard buffer.frameLength > 0, format.sampleRate > 0 else { return nil }
        let outRate = outputFormat.sampleRate
        let jumped = expectedStart.map { abs($0 - input.startTime) > 0.5 / format.sampleRate + 1e-6 } ?? true
        if converter == nil || inputFormat != format {
            guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                throw StamperError.unsupportedInput(format.description)
            }
            converter.downmix = format.channelCount > outputFormat.channelCount
            self.converter = converter
            inputFormat = format
            reanchor(at: input.startTime, rate: outRate)
        } else if jumped {
            converter?.reset()
            reanchor(at: input.startTime, rate: outRate)
        }
        expectedStart = input.startTime + Double(buffer.frameLength) / format.sampleRate

        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * outRate / format.sampleRate).rounded(.up)) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StamperError.unsupportedInput(format.description)
        }
        nonisolated(unsafe) var given = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? StamperError.unsupportedInput(format.description) }
        guard output.frameLength > 0 else { return nil }
        let start = CMTime(value: anchor + produced, timescale: CMTimeScale(outRate))
        produced += Int64(output.frameLength)
        return AnalyzerInput(buffer: output, bufferStartTime: start)
    }

    private mutating func reanchor(at time: TimeInterval, rate: Double) {
        anchor = Int64((time * rate).rounded())
        produced = 0
    }
}

// MARK: - Choosing a recognizer

enum CommandRecognizers {
    /// The recognizer for a drive: `SpeechCommandRecognizer`, or in Debug builds the
    /// `ScriptedRecognizer` that `-debug.recognizerScript <json>` selects.
    @MainActor
    static func makeDefault() -> any CommandRecognizing {
        #if DEBUG
        if let recognizer = ScriptedRecognizer.fromLaunchArguments() { return recognizer }
        if ProcessInfo.processInfo.arguments.contains("-debug.recognizerCapture") {
            return SpeechCommandRecognizer(capture: RecognizerCapture(directory: FileManager.default.temporaryDirectory))
        }
        #endif
        return SpeechCommandRecognizer()
    }
}

// MARK: - Capture

/// What the recognizer was fed and what it did, so a device run can be replayed on a Mac with
/// `tools/drive-commands`. Debug builds write it with `-debug.recognizerCapture`, to the app's
/// temporary directory:
///
/// - `recognizer-input.caf`: the input as fed, in its own format. It starts at drive time 0,
///   and a gap in the input (an engine restart) is filled with silence, so a time in the file
///   is a drive time.
/// - `recognizer-trace.txt`: one line per event, on the drive clock: listening windows,
///   finalization requests and completions, and every engine result with its range and words.
///
/// It holds Ryan's speech, so it stays on the phone unless copied off by hand.
final class RecognizerCapture: @unchecked Sendable {
    static let inputName = "recognizer-input.caf"
    static let traceName = "recognizer-trace.txt"

    private let directory: URL
    private let recordsInput: Bool
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var written: TimeInterval = 0
    private var trace: FileHandle?
    private let log = Logger(subsystem: "dev.ryangan.speakup", category: "RecognizerCapture")

    /// `recordsInput` false writes only the trace, under `traceName`.
    init(directory: URL, traceName: String = RecognizerCapture.traceName, recordsInput: Bool = true) {
        self.directory = directory
        self.recordsInput = recordsInput
        let traceURL = directory.appending(path: traceName)
        if recordsInput { try? FileManager.default.removeItem(at: directory.appending(path: Self.inputName)) }
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        trace = try? FileHandle(forWritingTo: traceURL)
    }

    deinit {
        try? trace?.close()
    }

    func write(_ input: DriveAudioBuffer) {
        lock.withLock {
            let buffer = input.buffer
            guard recordsInput else {
                written = max(written, input.startTime + Double(buffer.frameLength) / buffer.format.sampleRate)
                return
            }
            let format = buffer.format
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: directory.appending(path: Self.inputName), settings: format.settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                }
                guard let file, file.processingFormat == format else { return }
                let gap = input.startTime - written
                if gap > 1 / format.sampleRate, gap < 600,
                    let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap * format.sampleRate))
                {
                    silence.frameLength = silence.frameCapacity
                    for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                        if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
                    }
                    try file.write(from: silence)
                }
                try file.write(from: buffer)
                written = max(written, input.startTime) + Double(buffer.frameLength) / format.sampleRate
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                file = nil
            }
        }
    }

    func note(_ result: RecognizedResult) {
        let words = result.timedWords.map { String(format: "%@@%.2f-%.2f", $0.text, $0.start, $0.end) }
        note(
            String(
                format: "%@ %.2f-%.2f finalized %.2f: %@", result.isFinal ? "final" : "volatile",
                result.range.lowerBound, result.range.upperBound, result.finalizedThrough,
                words.joined(separator: " ")))
    }

    func note(_ line: String) {
        lock.withLock {
            let stamp = String(format: "%.2f ", written)
            _ = try? trace?.write(contentsOf: Data((stamp + line + "\n").utf8))
        }
    }
}
