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

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "SpeechCommandRecognizer")

    init(engine: any RecognitionEngine = SpeechAnalyzerEngine(), config: CommandRecognitionCore.Config = .init()) {
        self.engine = engine
        core = CommandRecognitionCore(config: config)
    }

    func prepare() async throws {
        try await engine.prepare()
    }

    func start(buffers: AsyncStream<DriveAudioBuffer>) async throws -> AsyncStream<CommandRecognizerEvent> {
        await stop()
        let session = try await engine.startSession()
        self.session = session
        core = CommandRecognitionCore(config: core.config)
        let (stream, continuation) = AsyncStream.makeStream(of: CommandRecognizerEvent.self)
        self.continuation = continuation

        reading = Task { [weak self] in
            do {
                for try await result in session.results {
                    self?.received(result)
                }
                if !Task.isCancelled { self?.fail("The speech recognizer stopped.") }
            } catch {
                if !Task.isCancelled { self?.fail(error.localizedDescription) }
            }
        }
        feeding = Task.detached { [weak self] in
            for await buffer in buffers {
                do {
                    try session.append(buffer)
                } catch {
                    await self?.fail(error.localizedDescription)
                    return
                }
                await self?.fed(through: buffer.endTime)
            }
            // The drive's audio stopped: so does recognition, with no failure.
            if !Task.isCancelled { await self?.stop() }
        }
        return stream
    }

    func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        core.listen(mode: mode, from: time)
    }

    func stopListening() {
        core.stopListening()
    }

    func stop() async {
        let session = self.session
        tearDown()
        await session?.finish()
    }

    // MARK: - Private

    private func received(_ result: RecognizedResult) {
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
                Task { [weak self] in
                    do {
                        try await session.finalize(through: time)
                        self?.finalized(through: time, in: session)
                    } catch {
                        Self.log.error("Finalizing through \(time, privacy: .public) s failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private func finalized(through time: TimeInterval, in finished: any RecognitionSession) {
        guard session === finished else { return }
        core.finalized(through: time)
    }

    private func fail(_ message: String) {
        guard let continuation else { return }
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
/// `SpeechTranscriber` is preferred, and `DictationTranscriber` is the fallback where it is
/// unavailable, as Apple's documentation recommends. On macOS 27, over the clips in
/// `tools/drive-commands`:
/// - `SpeechTranscriber` passes every clip: each "done" starts within 0.21 s of where it was
///   said, mid-sentence "done"s are left alone, and every between-take command is heard. The
///   task 0 spike saw it write "done" as "Don." right after another word
///   (`CommandRecognitionCore.misheard`), and it stretches the last word before a pause
///   (`CommandRecognitionCore.trimmingStretchedEnd`).
/// - `DictationTranscriber` misses a "done" after a thinking pause, starts another 0.36 s
///   late (so the take keeps part of it), and invents a word ("no") when silence is finalized.
/// - In the iOS simulator neither works: `SpeechTranscriber` is unsupported and
///   `DictationTranscriber` has no model. Debug builds use `ScriptedRecognizer` there.
///
/// Neither needs speech-recognition authorization or a usage string. Never call the legacy
/// `SFSpeechRecognizer.requestAuthorization`: without a usage string it crashes.
struct SpeechAnalyzerEngine: RecognitionEngine {
    enum Transcriber: String, Sendable, CaseIterable {
        case speech
        case dictation

        /// `SpeechTranscriber` where the phone supports it, otherwise `DictationTranscriber`.
        static var preferred: Transcriber { SpeechTranscriber.isAvailable ? .speech : .dictation }
    }

    /// Words to bias the engine toward: the commands (`CommandSpotter.phrases` and "done").
    static let contextualStrings = ["done", "I'm done"] + CommandSpotter.phrases.keys.sorted()

    let transcriber: Transcriber
    let locale: Locale

    init(transcriber: Transcriber = .preferred, locale: Locale = Locale(identifier: "en-US")) {
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
        #endif
        return SpeechCommandRecognizer()
    }
}
