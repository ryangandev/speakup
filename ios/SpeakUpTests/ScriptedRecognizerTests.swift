import AVFoundation
import Foundation
import Testing
@testable import SpeakUp

/// The Debug recognizer that replays scripted words on the drive clock.
@MainActor
struct ScriptedRecognizerTests {
    typealias Word = CommandSpotter.TimedWord

    @Test func aLineIsPhrasesThatStartAtTheirTimes() throws {
        let words = try ScriptedRecognizer.words(in: "so that is my answer@0.5 done@4.2")
        #expect(words.map(\.text) == ["so", "that", "is", "my", "answer", "done"])
        #expect(words.first == Word("so", start: 0.5, end: 0.8))
        #expect(abs(words[4].start - (0.5 + 4 * 0.35)) < 1e-9)
        #expect(words.last == Word("done", start: 4.2, end: 4.5))
    }

    @Test func aBadLineIsRejected() {
        for line in ["done", "done@soon", "@3", "so that@2 done@2.1", "done@-1"] {
            #expect(throws: ScriptedRecognizer.ScriptError.self, "\(line)") { try ScriptedRecognizer.words(in: line) }
        }
    }

    @Test func theLaunchArgumentTakesJSONWithEitherModeLeftOut() throws {
        let script = try ScriptedRecognizer.Script.parse(json: #"{"betweenTakes": ["again@0.5", "stop@0.5"]}"#)
        #expect(script == .init(recording: [], betweenTakes: ["again@0.5", "stop@0.5"]))
        #expect(ScriptedRecognizer.fromLaunchArguments(["SpeakUp"]) == nil)
        #expect(ScriptedRecognizer.fromLaunchArguments(["SpeakUp", "-debug.recognizerScript", #"{"recording": []}"#]) != nil)
    }

    @Test func aBadLaunchScriptMakesCommandsUnavailable() async throws {
        let recognizer = try #require(
            ScriptedRecognizer.fromLaunchArguments(["SpeakUp", "-debug.recognizerScript", #"{"recording": ["done"]}"#]))
        await #expect(throws: CommandRecognizerError.self) { try await recognizer.prepare() }
    }

    /// Plays drive-clock buffers from 9 s to `end` through the recognizer and a spotter, and
    /// returns the spotter's events, each with the progress it had seen when it fired.
    private func run(
        _ recognizer: ScriptedRecognizer, listen windows: [(CommandSpotter.Mode, TimeInterval)], to end: TimeInterval
    ) async throws -> [(CommandSpotter.Event, TimeInterval)] {
        let (buffers, input) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
        let events = try await recognizer.start(buffers: buffers)
        var spotter = CommandSpotter()
        var windows = windows
        let (mode, from) = windows.removeFirst()
        spotter.listen(mode: mode, from: from)
        recognizer.listen(mode: mode, from: from)

        // One buffer at a time, each handled before the next, as the drive clock moves.
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var iterator = events.makeAsyncIterator()
        var found: [(CommandSpotter.Event, TimeInterval)] = []
        var progress = -TimeInterval.infinity
        let steps = Int(((end - 9) * 10).rounded())
        for step in 0..<steps {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
            buffer.frameLength = 1_600
            let start = 9 + Double(step) / 10
            input.yield(DriveAudioBuffer(buffer: buffer, startTime: start))
            let heard = start + 0.1 - recognizer.lag
            while let event = await iterator.next() {
                guard case .update(let update) = event else { continue }
                progress = max(progress, update.progress ?? -.infinity)
                for spotted in spotter.receive(update) {
                    found.append((spotted, progress))
                    if let (mode, from) = windows.first {
                        windows.removeFirst()
                        spotter.listen(mode: mode, from: from)
                        recognizer.listen(mode: mode, from: from)
                    }
                }
                if update.words.isEmpty, progress >= heard - 1e-9 { break }
            }
        }
        input.finish()
        return found
    }

    /// "done" at 4.2 s into a take that starts at 10 s: the cut is at 14.2 s, and only once the
    /// recognizer, 0.4 s behind the clock, has heard 1.2 s of silence after it.
    @Test func doneEndsTheTakeAtItsScriptedTimeAfterTheSilence() async throws {
        let recognizer = ScriptedRecognizer(script: .init(recording: ["so that is my answer@0.5 done@4.2"]))
        let found = try await run(recognizer, listen: [(.recording, 10)], to: 20)
        try #require(found.count == 1)
        guard case .done(let cutAt) = found[0].0 else { throw TestFailure("Expected done, got \(found[0].0)") }
        #expect(abs(cutAt - 14.2) < 1e-9)
        #expect(found[0].1 >= 14.5 + 1.2 - 1e-9)
        #expect(found[0].1 < 14.5 + 1.2 + 0.15)
    }

    @Test func eachWindowTakesTheNextLineOfItsMode() async throws {
        let recognizer = ScriptedRecognizer(
            script: .init(recording: ["done@1"], betweenTakes: ["read the better version@0.5", "stop@0.5"]))
        let found = try await run(
            recognizer, listen: [(.betweenTakes, 10), (.betweenTakes, 13), (.recording, 16), (.betweenTakes, 20)], to: 26)
        #expect(found.map(\.0) == [.command(.betterVersion), .command(.stop), .done(cutAt: 17)])
    }
}
