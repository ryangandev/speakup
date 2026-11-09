import AVFoundation
import Foundation
import Testing
@testable import SpeakUp

/// Speech output: the tones, voice choice, the instant-speech log and end times, format
/// conversion, and one real sentence rendered and played through a running `DriveAudio`.
@MainActor
struct SpeechOutputTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "speech-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func instantOutput(
        file: URL? = nil, latency: TimeInterval = 0
    ) -> (SpeechOutput, SpokenLog) {
        let log = SpokenLog(fileURL: file)
        var options = SpeechOutput.Options()
        options.instant = true
        options.log = log
        options.latency = { latency }
        return (SpeechOutput(audio: DriveAudio(input: .microphone), options: options), log)
    }

    // MARK: Tones

    @Test func toneBuffersAreShortMonoFloatAtTheSpeechRate() {
        for tone in DriveTone.allCases {
            let buffer = tone.buffer()
            #expect(buffer.format == SpeechOutput.format)
            #expect(buffer.format.channelCount == 1)
            #expect(buffer.format.commonFormat == .pcmFormatFloat32)
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            #expect(abs(seconds - tone.duration) < 0.001)
            #expect(seconds > 0.2 && seconds < 0.5)
        }
    }

    @Test func tonesAreAudibleWithoutClippingAndStartAndEndAtZero() {
        for tone in DriveTone.allCases {
            let values = samples(tone.buffer())
            let peak = values.map(abs).max() ?? 0
            #expect(peak > 0.2)
            #expect(peak <= DriveTone.peak + 0.001)
            #expect(abs(values.first ?? 1) < 0.01)
            #expect(abs(values.last ?? 1) < 0.001)
            // No click: neighbouring samples never jump more than the highest note's own slope
            // (2 pi f / rate times the peak, with the harmonic) allows.
            let slope = 2 * Double.pi * 987.77 / 22_050 * Double(DriveTone.peak) * 1.5 / 1.25
            let step = zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            #expect(Double(step) < slope * 1.1)
        }
    }

    @Test func theTwoTonesDifferInLengthAndSound() {
        let start = DriveTone.startRecording
        let ended = DriveTone.ended
        #expect(start.duration != ended.duration)
        #expect(start.logName != ended.logName)
        // One rises and the other falls.
        #expect(start.notes[0].frequency < start.notes[1].frequency)
        #expect(ended.notes[0].frequency > ended.notes[1].frequency)
        #expect(samples(start.buffer()) != samples(ended.buffer()))
    }

    // MARK: Voice choice

    private func voice(
        _ id: String, _ quality: VoiceInfo.Quality, language: String = "en-US", special: Bool = false
    ) -> VoiceInfo {
        VoiceInfo(identifier: id, language: language, quality: quality, isSpecial: special)
    }

    @Test func premiumBeatsEnhancedBeatsStandard() {
        let voices = [voice("a", .standard), voice("b", .enhanced), voice("c", .premium), voice("d", .enhanced)]
        #expect(VoiceChoice.best(among: voices)?.identifier == "c")
        #expect(VoiceChoice.best(among: voices.filter { $0.identifier != "c" })?.identifier == "b")
    }

    @Test func onlyEnglishUnitedStatesNonSpecialVoicesAreConsidered() {
        let voices = [
            voice("gb", .premium, language: "en-GB"),
            voice("novelty", .premium, special: true),
            voice("us", .enhanced),
        ]
        #expect(VoiceChoice.best(among: voices)?.identifier == "us")
    }

    @Test func withNoBetterVoiceTheChoiceIsNilAndTheDefaultIsUsed() {
        #expect(VoiceChoice.best(among: [voice("a", .standard), voice("gb", .premium, language: "en-GB")]) == nil)
        #expect(VoiceChoice.best(among: []) == nil)
    }

    @Test func aPreferredVoiceIsEnglishUnitedStates() throws {
        // Whatever is installed, the choice is an en-US voice (or none at all on a bare machine).
        if let voice = VoiceChoice.preferred() { #expect(voice.language == "en-US") }
    }

    // MARK: Format conversion

    @Test func buffersInAnotherFormatAreConvertedWithTheirLength() throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = 0.3 * sin(Float(index) * 0.05) }
        let converted = SpeechOutput.matching([buffer, buffer])
        #expect(!converted.isEmpty)
        #expect(converted.allSatisfy { $0.format == SpeechOutput.format })
        let seconds = SpeechOutput.duration(of: converted)
        #expect(abs(seconds - 2) < 0.05)
        #expect(converted.flatMap { samples($0) }.contains { abs($0) > 0.2 })
    }

    @Test func buffersAlreadyInTheFormatPassThrough() {
        let tone = DriveTone.ended.buffer()
        #expect(SpeechOutput.matching([tone]).first === tone)
    }

    // MARK: Instant speech and the log

    @Test func instantSpeechLogsEveryUtteranceAndToneAndReturnsAtOnce() async throws {
        let (output, log) = instantOutput()
        let first = await output.speak("SpeakUp drive.")
        let segments = await output.speak(segments: ["Got it.", "", "  ", "What worked: the order."])
        let tone = await output.play(.startRecording)
        #expect(first.finished && segments.finished && tone.finished)
        #expect(log.entries.map(\.text) == ["SpeakUp drive.", "Got it.", "What worked: the order.", "start recording"])
        #expect(log.entries.map(\.kind) == [.speech, .speech, .speech, .tone])
        #expect(log.text.contains("say: What worked: the order."))
        #expect(log.text.contains("tone: start recording"))
    }

    @Test func instantSpeechTakesNoTimeSoTheEndIsNowAndNeverRunsAhead() async {
        let (output, log) = instantOutput()
        for _ in 0..<5 { _ = await output.speak("A sentence that would take a few seconds to say aloud.") }
        _ = await output.play(.ended)
        #expect(output.outputEnd == 0)
        #expect(log.entries.allSatisfy { $0.time == 0 })
    }

    @Test func instantSpeechReportsTheEndOnTheDriveClock() async {
        let (output, _) = instantOutput()
        let result = await output.speak("Hello.")
        #expect(result.end == output.outputEnd)
        #expect(result.duration == 0)
    }

    @Test func theLogIsAlsoWrittenToAFile() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "log.txt")
        try "stale\n".write(to: file, atomically: true, encoding: .utf8)
        let (output, log) = instantOutput(file: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
        _ = await output.speak("Got it.")
        _ = await output.play(.ended)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["0.00 say: Got it.", "0.00 tone: ended"])
        #expect(lines.joined(separator: "\n") == log.text)
    }

    @Test func cancelWithNothingPlayingChangesNothing() async {
        let (output, log) = instantOutput()
        _ = await output.speak("One.")
        output.cancel()
        let result = await output.speak("Two.")
        #expect(result.finished)
        #expect(log.entries.map(\.text) == ["One.", "Two."])
    }

    @Test func theDebugLaunchOptionsAreOffByDefault() {
        let options = SpeechOutput.Options.launch
        #expect(options.instant == false)
        #expect(options.log == nil)
    }

    // MARK: A real sentence through a running engine

    /// Renders with `AVSpeechSynthesizer.write`, plays on the drive engine's player and checks
    /// that `speak` returns when the sound has played: not at once, and not long after.
    /// The scripted microphone runs in real time, so the drive clock follows the wall clock.
    @Test func aRealSentenceIsRenderedAndPlayedForItsLength() async throws {
        let audio = DriveAudio(input: .scripted(ScriptedMicrophone(takeClip: nil)))
        try await audio.start()
        var options = SpeechOutput.Options()
        options.latency = { 0 }
        options.log = SpokenLog(fileURL: nil)
        let output = SpeechOutput(audio: audio, options: options)

        let clockBefore = audio.now
        let started = ContinuousClock.now
        let result = await output.speak("Got it. Feedback is ready.")
        let elapsed = started.duration(to: .now).seconds
        let tone = await output.play(.startRecording)
        let afterTone = audio.now

        #expect(result.finished)
        #expect(result.duration > 0.8 && result.duration < 6)
        #expect(elapsed >= result.duration * 0.8)
        #expect(elapsed < result.duration + 3)
        // The reported end is where the clock was when the speech started, plus its length.
        #expect(result.end >= clockBefore + result.duration)
        #expect(result.end < audio.now + 0.5)
        #expect(tone.finished)
        #expect(tone.end >= result.end + DriveTone.startRecording.duration - 0.001)
        #expect(afterTone >= tone.end - 0.4)
        #expect(output.spokenLog?.entries.map(\.kind) == [.speech, .tone])
        _ = await audio.stop()
    }

    @Test func cancelStopsASentenceAndReturnsUnfinished() async throws {
        let audio = DriveAudio(input: .scripted(ScriptedMicrophone(takeClip: nil)))
        try await audio.start()
        var options = SpeechOutput.Options()
        options.latency = { 0 }
        let output = SpeechOutput(audio: audio, options: options)

        let long = Array(repeating: "This is a long sentence that takes a while to say.", count: 6)
        let speaking = Task { await output.speak(segments: long) }
        try await Task.sleep(for: .milliseconds(1_500))
        let cancelAt = ContinuousClock.now
        output.cancel()
        let result = await speaking.value
        #expect(result.finished == false)
        #expect(cancelAt.duration(to: .now).seconds < 1)
        #expect(output.outputEnd <= audio.now + 0.5)

        // The player plays again afterwards.
        let tone = await output.play(.ended)
        #expect(tone.finished)
        _ = await audio.stop()
    }

    @Test func speakingWhileTheDriveIsNotRunningDoesNotWait() async {
        let output = SpeechOutput(audio: DriveAudio(input: .microphone), options: SpeechOutput.Options())
        let result = await output.speak("Nobody can hear this.")
        #expect(result.finished == false)
        #expect(output.outputEnd == 0)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
