import AVFoundation
import Foundation
import Testing
@testable import SpeakUp

/// The drive audio core: one clock for the recognizer and the take, a gate that writes only
/// while a take is open, and the trim at the start of "done".
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

        gate.arm(try sink(), micRoute: .builtIn, micName: "Mic")
        #expect(gate.duration == 0)
        gate.ingest(buffer(0.25, seconds: 0.1), at: 0.1)
        gate.ingest(buffer(0.25, seconds: 0.1), at: 0.2)
        #expect(gate.duration == 0.2)
        let closed = try #require(gate.close())
        gate.ingest(buffer(0.5, seconds: 0.1), at: 0.3)

        #expect(closed.segments == [TakeGate.Segment(time: 0.1, frame: 0)])
        let take = try closed.finish(cutAt: nil, reason: .finished)
        let written = try samples(take.recording.url)
        #expect(written.count == 3_200)
        #expect(written.allSatisfy { $0 == level(0.25) })
        #expect(take.recording.duration == 0.2)
        #expect(take.recording.micRoute == .builtIn)
    }

    @Test func aGateClosedBeforeAnyInputLeavesNoFile() throws {
        let gate = TakeGate()
        gate.arm(try sink(), micRoute: .builtIn, micName: "Mic")
        #expect(gate.close() == nil)
        #expect(!FileManager.default.fileExists(atPath: url().path))
        #expect(gate.isActive == false)
    }

    @Test func aGapStartsANewSegment() throws {
        let gate = TakeGate()
        gate.arm(try sink(), micRoute: .builtIn, micName: "Mic")
        gate.ingest(buffer(0.25, seconds: 0.5), at: 10)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 10.5)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 12)
        let closed = try #require(gate.close())
        #expect(closed.segments == [
            TakeGate.Segment(time: 10, frame: 0), TakeGate.Segment(time: 12, frame: 16_000),
        ])
        _ = try closed.finish(cutAt: nil, reason: .finished)
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
        let gate = TakeGate()
        gate.arm(try sink(), micRoute: .builtIn, micName: "Mic")
        gate.ingest(buffer(0.25, seconds: 0.5), at: 2)
        gate.ingest(buffer(0.25, seconds: 0.5), at: 2.5)
        gate.ingest(buffer(0.75, seconds: 0.5), at: 3)  // "done"
        gate.ingest(buffer(0, seconds: 1.5), at: 3.5)  // the recognizer's lag
        let closed = try #require(gate.close())

        let take = try closed.finish(cutAt: 3 - DriveAudio.cutMargin, reason: .finished)

        let file = try AVAudioFile(forReading: take.recording.url)
        #expect(file.length == 14_400)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(take.recording.duration == 0.9)
        #expect(take.recording.sampleRate == 16_000)
        #expect(take.sha256 == (try WAVWriter.sha256(of: take.recording.url)))
        #expect(try samples(take.recording.url).allSatisfy { $0 == level(0.25) })
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

        // Stopping ends the recognizer stream; the take is finished before that.
        let clipStart = try await clipStartTime(in: stream, task: heard, audio: audio, threshold: 0.2)
        let take = try #require(try await audio.finishTake(cutAt: clipStart + 1, reason: .finished))
        _ = await audio.stop()

        let written = try samples(take.recording.url)
        #expect(written.filter { $0 == answer }.count == 14_400)
        #expect(!written.contains(done))
        #expect(written.last == answer)
        #expect(take.recording.duration == Double(written.count) / 16_000)
        #expect(take.recording.micName == "Simulated microphone: clip.wav")
        #expect(take.sha256 == (try WAVWriter.sha256(of: take.recording.url)))
        #expect(audio.isRunning == false)
    }

    /// A call mid-take keeps the take up to there and reports it; when the call ends, the
    /// engine restarts and the drive can go on.
    @MainActor
    @Test func anInterruptionKeepsTheTakeAndResumes() async throws {
        let audio = DriveAudio(input: .scripted(ScriptedMicrophone(takeClip: nil, pace: .milliseconds(10))))
        var events: [DriveAudio.Event] = []
        audio.onEvent = { events.append($0) }
        try await audio.start()
        try audio.openTake(url: url())
        while (audio.takeDuration ?? 0) < 0.5 { try await Task.sleep(for: .milliseconds(5)) }

        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(audio.isTakeOpen == false)
        #expect(audio.takeDuration == nil)
        while events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(events.first == .interrupted)
        guard case .takeEnded(let take) = events.last else {
            Issue.record("Expected the take, got \(events)")
            return
        }
        #expect(take.recording.stopReason == .interrupted)
        #expect(take.recording.duration >= 0.5)
        #expect(FileManager.default.fileExists(atPath: take.recording.url.path))

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: session,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        while events.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(events.last == .interruptionEnded(resumed: true))
        try audio.openTake(url: url("after.wav"))
        #expect(audio.isTakeOpen)
        _ = await audio.stop()
    }

    /// Reads the recognizer buffers heard so far and returns the drive time of the clip's first sample.
    @MainActor
    private func clipStartTime(
        in stream: AsyncStream<DriveAudioBuffer>, task: Task<[DriveAudioBuffer], Never>,
        audio: DriveAudio, threshold: Float
    ) async throws -> TimeInterval {
        // A new stream ends the old one, so the collecting task returns what it heard.
        _ = audio.recognizerBuffers()
        let buffers = await task.value
        for item in buffers {
            let data = item.buffer.floatChannelData![0]
            for index in 0..<Int(item.buffer.frameLength) where abs(data[index]) > threshold {
                return item.startTime + Double(index) / item.buffer.format.sampleRate
            }
        }
        throw CancellationError()
    }
}
