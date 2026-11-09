import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import SpeakUp

/// `SpeechCommandRecognizer` over a fake engine: what reaches the loop, what is asked of the
/// engine, and failures.
@MainActor
struct SpeechCommandRecognizerTests {
    typealias Word = CommandSpotter.TimedWord

    final class FakeSession: RecognitionSession, @unchecked Sendable {
        let results: AsyncThrowingStream<RecognizedResult, any Error>
        let output: AsyncThrowingStream<RecognizedResult, any Error>.Continuation
        private let lock = NSLock()
        private var _appended: [TimeInterval] = []
        private var _finalized: [TimeInterval] = []
        private var _finished = false

        init() {
            (results, output) = AsyncThrowingStream.makeStream(of: RecognizedResult.self)
        }

        var appended: [TimeInterval] { lock.withLock { _appended } }
        var finalized: [TimeInterval] { lock.withLock { _finalized } }
        var finished: Bool { lock.withLock { _finished } }

        func append(_ buffer: DriveAudioBuffer) throws {
            lock.withLock { _appended.append(buffer.startTime) }
        }

        func finalize(through time: TimeInterval) async throws {
            lock.withLock { _finalized.append(time) }
        }

        func finish() async {
            lock.withLock { _finished = true }
            output.finish()
        }
    }

    struct FakeEngine: RecognitionEngine {
        var session = FakeSession()
        var prepareError: CommandRecognizerError?
        var startError: CommandRecognizerError?

        func prepare() async throws {
            if let prepareError { throw prepareError }
        }

        func startSession() async throws -> any RecognitionSession {
            if let startError { throw startError }
            return session
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The model crashed." }
    }

    /// 0.1 s of silence starting at `start` on the drive clock.
    private func buffer(at start: TimeInterval) -> DriveAudioBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        return DriveAudioBuffer(buffer: buffer, startTime: start)
    }

    /// Feeds 0.1 s buffers from `from` up to `to`, each after the one before is handled.
    private func feed(
        _ input: AsyncStream<DriveAudioBuffer>.Continuation, _ session: FakeSession, from: Double, to: Double
    ) async throws {
        var time = from
        while time < to - 1e-9 {
            input.yield(buffer(at: time))
            let count = session.appended.count + 1
            try await until { session.appended.count >= count }
            // The recognizer handles the buffer on the main actor after appending it.
            await Task.yield()
            time += 0.1
        }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure("Timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func prepareReportsThatCommandsAreUnavailable() async {
        let recognizer = SpeechCommandRecognizer(engine: FakeEngine(prepareError: .unavailable("no model")))
        await #expect(throws: CommandRecognizerError.unavailable("no model")) { try await recognizer.prepare() }
    }

    @Test func startReportsThatCommandsAreUnavailable() async {
        let recognizer = SpeechCommandRecognizer(engine: FakeEngine(startError: .unavailable("no format")))
        let (buffers, _) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        await #expect(throws: CommandRecognizerError.unavailable("no format")) {
            _ = try await recognizer.start(buffers: buffers)
        }
    }

    /// The whole path: a volatile "done" is finalized, the timed final comes back, silence is
    /// confirmed by a further finalization, and the spotter ends the take at the start of "done".
    @Test func aDoneAfterAPauseEndsTheTakeAtItsStart() async throws {
        let engine = FakeEngine()
        let session = engine.session
        let recognizer = SpeechCommandRecognizer(engine: engine)
        let (buffers, input) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        let collected = Task {
            var spotter = CommandSpotter()
            spotter.listen(mode: .recording, from: 10)
            for await event in events {
                guard case .update(let update) = event else { return [CommandSpotter.Event]() }
                let found = spotter.receive(update)
                if !found.isEmpty { return found }
            }
            return []
        }
        recognizer.listen(mode: .recording, from: 10)

        try await feed(input, session, from: 9, to: 10.5)
        #expect(session.finalized == [10])

        session.output.yield(
            .init(
                text: "my answer.", timedWords: [Word("my", start: 10.5, end: 10.7), Word("answer.", start: 10.7, end: 11.2)],
                range: 10...11.3, isFinal: true, finalizedThrough: 11.3))
        session.output.yield(.init(text: " Done", timedWords: [], range: 11.3...13, isFinal: false, finalizedThrough: 11.3))
        try await feed(input, session, from: 10.5, to: 13.1)
        #expect(session.finalized == [10, 13])

        session.output.yield(
            .init(
                text: " Done.", timedWords: [Word("Done.", start: 12.2, end: 12.6)], range: 12.2...13, isFinal: true,
                finalizedThrough: 13))
        // 12.6 + 1.2 + 0.1 = 13.9, then 0.3 s to settle.
        try await feed(input, session, from: 13.1, to: 14.4)
        #expect(session.finalized.count == 3)
        #expect(abs(session.finalized[2] - 13.9) < 1e-9)
        try await feed(input, session, from: 14.4, to: 14.5)
        #expect(await collected.value == [.done(cutAt: 12.2)])
        await recognizer.stop()
        #expect(session.finished)
    }

    @Test func anEngineErrorIsReportedOnceAndEndsTheStream() async throws {
        let engine = FakeEngine()
        let recognizer = SpeechCommandRecognizer(engine: engine)
        let (buffers, _) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        engine.session.output.finish(throwing: Failure())
        var received: [CommandRecognizerEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.failed("The model crashed.")])
        try await until { engine.session.finished }
    }

    @Test func anEngineThatStopsByItselfIsAFailure() async throws {
        let engine = FakeEngine()
        let recognizer = SpeechCommandRecognizer(engine: engine)
        let (buffers, _) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        engine.session.output.finish()
        var received: [CommandRecognizerEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.failed("The speech recognizer stopped.")])
    }

    @Test func theEndOfTheDrivesAudioStopsRecognitionWithoutAFailure() async throws {
        let engine = FakeEngine()
        let recognizer = SpeechCommandRecognizer(engine: engine)
        let (buffers, input) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        input.yield(buffer(at: 0))
        input.finish()
        var received: [CommandRecognizerEvent] = []
        for await event in events { received.append(event) }
        #expect(received.isEmpty)
        #expect(engine.session.finished)
        #expect(engine.session.appended == [0])
    }

    @Test func stopEndsTheStream() async throws {
        let engine = FakeEngine()
        let recognizer = SpeechCommandRecognizer(engine: engine)
        let (buffers, _) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        await recognizer.stop()
        var received: [CommandRecognizerEvent] = []
        for await event in events { received.append(event) }
        #expect(received.isEmpty)
        #expect(engine.session.finished)
    }

    // MARK: Converting results and input

    @Test func speechResultsKeepTheirWordTimesOnTheDriveClock() {
        var text = AttributedString("Don.")
        text.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 12.2, preferredTimescale: 1000), end: CMTime(seconds: 12.6, preferredTimescale: 1000))
        let result = SpeechAnalyzerSession.result(
            text, CMTimeRange(start: CMTime(seconds: 12, preferredTimescale: 1000), end: CMTime(seconds: 13, preferredTimescale: 1000)),
            true, CMTime(seconds: 13, preferredTimescale: 1000))
        #expect(
            result
                == RecognizedResult(
                    text: "Don.", timedWords: [Word("Don.", start: 12.2, end: 12.6)], range: 12...13, isFinal: true,
                    finalizedThrough: 13))
    }

    /// The tap's 48 kHz input becomes the analyzer's 16 kHz, stamped on the drive clock, and a
    /// jump in the clock (an engine restart) starts a new anchor.
    @Test func inputIsStampedOnTheDriveClockAcrossAJump() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        var stamper = AnalyzerInputStamper(outputFormat: output)
        func stamp(_ start: TimeInterval) throws -> TimeInterval? {
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            return try stamper.convert(DriveAudioBuffer(buffer: buffer, startTime: start))?.bufferStartTime?.seconds
        }
        let first = try #require(try stamp(5))
        #expect(abs(first - 5) < 1e-6)
        var previous = first
        for index in 1..<5 {
            let next = try #require(try stamp(5 + Double(index) * 0.1))
            // Contiguous: each starts where the converted audio before it ended.
            #expect(next > previous && next - previous < 0.11)
            previous = next
        }
        let afterJump = try #require(try stamp(9))
        #expect(abs(afterJump - 9) < 1e-6)
    }
}
