import AVFoundation
import Foundation
import Testing
@testable import SpeakUp

/// The drive audio core: one clock for the recognizer and the take, a gate that writes only
/// while a take is open, the trim at the start of "done", and exactly one outcome per take.
struct DriveAudioTests {
    private static let rate = 16_000.0
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "drive-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func url(_ name: String = "take.wav") -> URL {
        directory.appending(path: name)
    }

    /// A 16 kHz mono buffer holding one value.
    private func buffer(_ value: Float, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let frames = AVAudioFrameCount((seconds * Self.rate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }

    private func sink(_ name: String = "take.wav") throws -> RecordingSink {
        try RecordingSink(
            url: url(name), inputFormat: AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!)
    }

    private func armedGate(at start: TimeInterval = 0) throws -> TakeGate {
        let gate = TakeGate()
        gate.arm(try sink(), at: start, micRoute: .builtIn, micName: "Mic")
        return gate
    }

    private func closedTake(_ gate: TakeGate) throws -> TakeGate.ClosedTake {
        guard case .take(let take) = gate.close() else { throw TestFailure("The gate held no take") }
        return take
    }

    private func kept(_ end: DriveAudio.TakeEnd?) throws -> DriveAudio.FinishedTake {
        guard case .kept(let take)? = end else { throw TestFailure("Expected a kept take, got \(String(describing: end))") }
        return take
    }

    /// The 16-bit samples of a WAV the app wrote.
    private func samples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return stride(from: WAVWriter.headerSize, to: data.count, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }

    private func level(_ value: Float) -> Int16 { Int16((value * Float(Int16.max)).rounded()) }

    // MARK: Clock

    @Test func clockStampsBuffersInFramesAndMovesOnAcrossARestart() {
        var clock = DriveClock()
        clock.startSegment(rate: 16_000, after: 0)
        #expect(clock.stamp(frames: 1_600) == 0)
        #expect(clock.stamp(frames: 1_600) == 0.1)
        #expect(clock.now == 0.2)
        // A restart at 48 kHz, half a second later.
        clock.startSegment(rate: 48_000, after: 0.5)
        #expect(abs(clock.stamp(frames: 4_800) - 0.7) < 1e-12)
        #expect(abs(clock.now - 0.8) < 1e-12)
    }

    // MARK: Gate

    @Test func theGateWritesFramesOnlyWhileOpen() throws {
        let gate = TakeGate()
        gate.ingest(buffer(0.5, seconds: 0.1), at: 0)
        #expect(gate.isActive == false)
        #expect(gate.duration == nil)

        gate.arm(try sink(), at: 0.1, micRoute: .builtIn, micName: "Mic")
        #expect(gate.duration == 0)
        gate.ingest(buffer(0.25, seconds: 0.1), at: 0.1)
        gate.ingest(buffer(0.25, seconds: 0.1), at: 0.2)
        #expect(gate.duration == 0.2)
        let closed = try closedTake(gate)
        gate.ingest(buffer(0.5, seconds: 0.1), at: 0.3)

        #expect(closed.segments == [TakeGate.Segment(time: 0.1, frame: 0)])
        let take = try kept(closed.finish(cutAt: nil, reason: .finished))
        let written = try samples(take.recording.url)
        #expect(written.count == 3_200)
        #expect(written.allSatisfy { $0 == level(0.25) })
        #expect(take.recording.duration == 0.2)
        #expect(take.recording.micRoute == .builtIn)
        #expect(take.gaps.isEmpty)
    }

    /// The tone's tail in the same buffer as the take's start is left out.
    @Test func theTakeStartsAtItsTimeInsideABuffer() throws {
        let gate = try armedGate(at: 0.15)
        gate.ingest(buffer(0.5, seconds: 0.1), at: 0)  // all before the start
        let tail = buffer(0.5, seconds: 0.1)
        tail.floatChannelData![0].advanced(by: 800).update(repeating: 0.25, count: 800)
        gate.ingest(tail, at: 0.1)  // half tone tail, half answer
        gate.ingest(buffer(0.25, seconds: 0.1), at: 0.2)
        let closed = try closedTake(gate)
        #expect(closed.segments == [TakeGate.Segment(time: 0.15, frame: 0)])
        let take = try kept(closed.finish(cutAt: nil, reason: .finished))
        let written = try samples(take.recording.url)
        #expect(written.count == 2_400)
        #expect(written.allSatisfy { $0 == level(0.25) })
    }

    @Test func aGateClosedBeforeAnyInputDeletesItsFile() throws {
        let gate = try armedGate(at: 5)
        gate.ingest(buffer(0.5, seconds: 0.1), at: 0)
        guard case .empty = gate.close() else {
            Issue.record("Expected an empty close")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url().path))
        #expect(gate.isActive == false)
    }

    @Test func anArmedTakeMovesToANewMicrophoneAtTheSameStart() throws {
        let gate = try armedGate(at: 0.5)
        let format48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        #expect(try gate.rearm(micRoute: .headset, micName: "Headset") {
            try RecordingSink(url: $0, inputFormat: format48)
        })
        #expect(gate.isArmedOnly)
        let take = try kept(try closedTakeAfterOneSecond(gate, format: format48).finish(cutAt: nil, reason: .finished))
        #expect(take.recording.sampleRate == 48_000)
        #expect(take.recording.micRoute == .headset)
        #expect(take.recording.duration == 0.5)
        // An open take is not moved.
        let open = try armedGate()
        open.ingest(buffer(0.25, seconds: 0.1), at: 0)
        #expect(try open.rearm(micRoute: .headset, micName: "Headset") { _ in throw TestFailure("not called") } == false)
        _ = open.close()
    }

    private func closedTakeAfterOneSecond(_ gate: TakeGate, format: AVAudioFormat) throws -> TakeGate.ClosedTake {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].update(repeating: 0.25, count: 48_000)
        gate.ingest(buffer, at: 0)
        return try closedTake(gate)
    }

    /// Input missing after a restart is spliced, not padded, and reported.
    @Test func aGapIsSplicedAndReported() throws {
        let gate = try armedGate(at: 10)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 10)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 10.5)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 12)
        let closed = try closedTake(gate)
        #expect(closed.segments == [
            TakeGate.Segment(time: 10, frame: 0), TakeGate.Segment(time: 12, frame: 16_000),
        ])
        let take = try kept(closed.finish(cutAt: nil, reason: .finished))
        #expect(take.recording.duration == 1.5)
        #expect(take.gaps == [DriveAudio.Gap(at: 1, length: 1)])
    }

    @Test func aGapAfterTheCutIsNotReported() throws {
        let gate = try armedGate(at: 10)
        gate.ingest(buffer(0.25, seconds: 1), at: 10)
        gate.ingest(buffer(0.75, seconds: 1), at: 12)
        let take = try kept(try closedTake(gate).finish(cutAt: 10.5, reason: .finished))
        #expect(take.gaps.isEmpty)
        #expect(take.recording.duration == 0.5)
    }

    @Test func driveTimesMapToTakeFrames() {
        let segments = [TakeGate.Segment(time: 10, frame: 0), TakeGate.Segment(time: 15, frame: 16_000)]
        func frame(_ time: TimeInterval) -> Int {
            TakeGate.frame(at: time, segments: segments, outputRate: 16_000, frames: 32_000)
        }
        #expect(frame(9) == 0)
        #expect(frame(10) == 0)
        #expect(frame(10.5) == 8_000)
        #expect(frame(10.99995) == 15_999)
        // Inside the gap: the end of the input before it.
        #expect(frame(13) == 16_000)
        #expect(frame(15.5) == 24_000)
        #expect(frame(20) == 32_000)
        // A 44.1 kHz take that started at 2.5 s on the clock.
        #expect(TakeGate.frame(
            at: 4, segments: [TakeGate.Segment(time: 2.5, frame: 0)], outputRate: 44_100, frames: 100_000)
            == 66_150)
    }

    // MARK: Trim

    /// The take opens at 2 s on the drive clock; "done" starts at 3 s. The kept take is the
    /// 0.9 s before the cut margin, a valid WAV whose duration and hash match the trimmed file.
    @Test func trimmingAtTheCutTimeKeepsTheAnswerOnly() throws {
        let gate = try armedGate(at: 2)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 2)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 2.5)
        gate.ingest(buffer(0.75, seconds: 0.5), at: 3)  // "done"
        gate.ingest(buffer(0, seconds: 1.5), at: 3.5)  // the recognizer's lag

        let take = try kept(try closedTake(gate).finish(cutAt: 3 - DriveAudio.cutMargin, reason: .finished))

        let file = try AVAudioFile(forReading: take.recording.url)
        #expect(file.length == 14_400)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(take.recording.duration == 0.9)
        #expect(take.recording.sampleRate == 16_000)
        #expect(take.sha256 == (try WAVWriter.sha256(of: take.recording.url)))
        #expect(try samples(take.recording.url).allSatisfy { $0 == level(0.25) })
    }

    /// "done" said right away leaves nothing to keep: no 0-second take reaches the store.
    @Test func aCutAtOrBeforeTheStartIsEmptyAndDeleted() throws {
        let gate = try armedGate(at: 2)
        gate.ingest(buffer(0.75, seconds: 1), at: 2)
        let end = try closedTake(gate).finish(cutAt: 1.95, reason: .finished)
        #expect(end == .empty(.finished))
        #expect(!FileManager.default.fileExists(atPath: url().path))
    }

    // MARK: Engine with the scripted microphone

    /// The whole path in the simulator: the scripted microphone plays a clip (one second of
    /// "answer", then half a second of "done") when the take opens. The clip's start, found on
    /// the recognizer stream, plus one second is where a recognizer would put "done"; the
    /// trimmed take holds exactly the answer before the margin.
    @MainActor
    @Test func theScriptedMicrophoneFeedsTheRecognizerAndTheTakeOnOneClock() async throws {
        let answer: Int16 = 8_000
        let done: Int16 = 24_000
        let clipURL = url("clip.wav")
        let writer = try WAVWriter(url: clipURL, sampleRate: 16_000)
        try writer.append([Int16](repeating: answer, count: 16_000))
        try writer.append([Int16](repeating: done, count: 8_000))
        try writer.finish()

        let microphone = ScriptedMicrophone(takeClip: clipURL, pace: .milliseconds(10))
        let audio = DriveAudio(input: .scripted(microphone))
        try await audio.start()
        #expect(audio.player.isPlaying)
        let stream = audio.recognizerBuffers()
        let heard = Task {
            var buffers: [DriveAudioBuffer] = []
            for await buffer in stream { buffers.append(buffer) }
            return buffers
        }

        // Let some silence pass first, as between takes.
        while audio.now < 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        try audio.openTake(url: url())
        #expect(throws: DriveAudio.DriveAudioError.self) { try audio.openTake(url: url("second.wav")) }
        while (audio.takeDuration ?? 0) < 2 { try await Task.sleep(for: .milliseconds(5)) }

        // A new stream ends the old one, so the collecting task returns what it heard.
        _ = audio.recognizerBuffers()
        let clipStart = try clipStartTime(in: await heard.value, threshold: 0.2)
        let take = try kept(await audio.finishTake(cutAt: clipStart + 1, reason: .finished))
        #expect(await audio.stop() == nil)

        let written = try samples(take.recording.url)
        #expect(written.filter { $0 == answer }.count == 14_400)
        #expect(!written.contains(done))
        #expect(written.last == answer)
        #expect(take.recording.duration == Double(written.count) / 16_000)
        #expect(take.recording.micName == "Simulated microphone: clip.wav")
        #expect(take.sha256 == (try WAVWriter.sha256(of: take.recording.url)))
        #expect(audio.isRunning == false)
    }

    private func clipStartTime(in buffers: [DriveAudioBuffer], threshold: Float) throws -> TimeInterval {
        for item in buffers {
            let data = item.buffer.floatChannelData![0]
            for index in 0..<Int(item.buffer.frameLength) where abs(data[index]) > threshold {
                return item.startTime + Double(index) / item.buffer.format.sampleRate
            }
        }
        throw TestFailure("The clip never played")
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if resume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    @MainActor
    private static func scriptedAudio() -> DriveAudio {
        DriveAudio(input: .scripted(ScriptedMicrophone(takeClip: nil, pace: .milliseconds(10))))
    }

    /// A call mid-take gives one event carrying the take, kept up to there; when the call
    /// ends, the engine and the player restart and the drive can go on.
    @MainActor
    @Test func anInterruptionCarriesTheTakeAndResumes() async throws {
        let audio = Self.scriptedAudio()
        var events: [DriveAudio.Event] = []
        audio.onEvent = { events.append($0) }
        try await audio.start()
        try audio.openTake(url: url())
        while (audio.takeDuration ?? 0) < 0.5 { try await Task.sleep(for: .milliseconds(5)) }

        postInterruption(.began)
        #expect(audio.isTakeOpen == false)
        #expect(audio.takeDuration == nil)
        while events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        guard case .interrupted(let end) = events[0] else {
            Issue.record("Expected the interruption, got \(events)")
            return
        }
        let take = try kept(end)
        #expect(take.recording.stopReason == .interrupted)
        #expect(take.recording.duration >= 0.5)
        #expect(FileManager.default.fileExists(atPath: take.recording.url.path))
        #expect(throws: DriveAudio.DriveAudioError.self) { try audio.openTake(url: url("during.wav")) }

        postInterruption(.ended, resume: true)
        while events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(events[1] == .interruptionEnded(resumed: true))
        #expect(audio.player.isPlaying)
        try audio.openTake(url: url("after.wav"))
        #expect(audio.isTakeOpen)
        _ = await audio.stop()
        #expect(events.count == 2)
    }

    /// A take opened but with no input yet is not lost silently: the interruption says so.
    @MainActor
    @Test func anInterruptionBeforeAnyInputReportsAnEmptyTake() async throws {
        let audio = Self.scriptedAudio()
        var events: [DriveAudio.Event] = []
        audio.onEvent = { events.append($0) }
        try await audio.start()
        try audio.openTake(url: url(), at: audio.now + 60)
        postInterruption(.began)
        _ = await audio.stop()
        #expect(events == [.interrupted(.empty(.interrupted))])
        #expect(!FileManager.default.fileExists(atPath: url().path))
    }

    /// Stopping right after an interruption delivers the interruption's take before `stop`
    /// returns, and `stop` has no second take to return.
    @MainActor
    @Test func stopWaitsForATakeAlreadyEnding() async throws {
        let audio = Self.scriptedAudio()
        var events: [DriveAudio.Event] = []
        audio.onEvent = { events.append($0) }
        try await audio.start()
        try audio.openTake(url: url())
        while (audio.takeDuration ?? 0) < 0.3 { try await Task.sleep(for: .milliseconds(5)) }
        postInterruption(.began)
        let fromStop = await audio.stop()
        #expect(fromStop == nil)
        #expect(events.count == 1)
        guard case .interrupted(let end)? = events.first else {
            Issue.record("Expected the interruption, got \(events)")
            return
        }
        _ = try kept(end)
    }

    /// A take open when the audio system fails comes with the failure.
    @MainActor
    @Test func aFailureCarriesTheOpenTake() async throws {
        let audio = Self.scriptedAudio()
        var events: [DriveAudio.Event] = []
        audio.onEvent = { events.append($0) }
        try await audio.start()
        try audio.openTake(url: url())
        while (audio.takeDuration ?? 0) < 0.3 { try await Task.sleep(for: .milliseconds(5)) }
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        #expect(audio.isRunning == false)
        #expect(await audio.stop() == nil)
        #expect(events.count == 1)
        guard case .failed(_, let end)? = events.first else {
            Issue.record("Expected the failure, got \(events)")
            return
        }
        #expect(try kept(end).recording.stopReason == .interrupted)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
