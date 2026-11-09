// Runs the app's command recognition (SpeechCommandRecognizer + CommandSpotter) on the Mac over
// the clips from make-clips.sh, fed in real time as a drive would feed them, and checks each
// clip's command and cut time.
//
// Usage: drive-commands [--transcriber speech|dictation|both] [--clips <dir>] [--only <name>] [--verbose] [--trace]

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var transcribers: [SpeechAnalyzerEngine.Transcriber] = [.speech]
    var clips = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "clips")
    var only: String?
    var verbose = false
    var trace = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var options = Options()
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--transcriber":
        switch arguments.popFirst() {
        case "speech": options.transcribers = [.speech]
        case "dictation": options.transcribers = [.dictation]
        case "both": options.transcribers = [.speech, .dictation]
        default: fail("--transcriber takes speech, dictation or both")
        }
    case "--clips":
        guard let path = arguments.popFirst() else { fail("--clips takes a directory") }
        options.clips = URL(fileURLWithPath: path)
    case "--only":
        options.only = arguments.popFirst()
    case "--trace":
        options.trace = true
    case "--verbose":
        options.verbose = true
    default:
        fail("usage: drive-commands [--transcriber speech|dictation|both] [--clips <dir>] [--only <name>] [--verbose] [--trace]")
    }
}

// MARK: - Clips

enum Expectation: Equatable {
    case done
    case none
    case command(CommandSpotter.Command)
    case unrecognized

    init?(_ text: String) {
        switch text {
        case "done": self = .done
        case "none": self = .none
        case "unrecognized": self = .unrecognized
        case "again": self = .command(.again)
        case "next": self = .command(.next)
        case "repeatThat": self = .command(.repeatThat)
        case "betterVersion": self = .command(.betterVersion)
        case "stop": self = .command(.stop)
        default: return nil
        }
    }
}

struct Clip {
    let name: String
    let mode: CommandSpotter.Mode
    let expectation: Expectation
    /// The clip at 48 kHz, as the phone's input tap delivers it.
    let audio: AVAudioPCMBuffer
    /// Speech segments in the clip, in seconds from its start, found by level.
    let segments: [ClosedRange<TimeInterval>]
}

@MainActor func loadClips() -> [Clip] {
    let manifest = options.clips.appending(path: "manifest.tsv")
    guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
        fail("No clips at \(options.clips.path). Run make-clips.sh first.")
    }
    return text.split(separator: "\n").compactMap { line -> Clip? in
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 3, let expectation = Expectation(fields[2]) else { fail("Bad manifest line: \(line)") }
        if let only = options.only, only != fields[0] { return nil }
        let mode: CommandSpotter.Mode = fields[1] == "recording" ? .recording : .betweenTakes
        let url = options.clips.appending(path: "\(fields[0]).wav")
        do {
            let file = try AVAudioFile(forReading: url)
            guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { fail("Cannot read \(url.path)") }
            try file.read(into: source)
            return Clip(
                name: fields[0], mode: mode, expectation: expectation, audio: try resample(source, to: 48_000),
                segments: speechSegments(source))
        } catch {
            fail("Cannot read \(url.path): \(error)")
        }
    }
}

func resample(_ source: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    guard let converter = AVAudioConverter(from: source.format, to: format),
        let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(source.frameLength) * rate / source.format.sampleRate) + 1024)
    else { fail("Cannot convert \(source.format)") }
    nonisolated(unsafe) var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if given {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return source
    }
    if let error { throw error }
    return output
}

/// Spans of speech: 10 ms frames above a level, joined across gaps shorter than 0.35 s.
func speechSegments(_ buffer: AVAudioPCMBuffer) -> [ClosedRange<TimeInterval>] {
    let rate = buffer.format.sampleRate
    let frame = Int(rate / 100)
    let count = Int(buffer.frameLength)
    var loud: [Bool] = []
    var index = 0
    while index < count {
        let end = min(count, index + frame)
        var peak: Float = 0
        if let floats = buffer.floatChannelData?[0] {
            for i in index..<end { peak = max(peak, abs(floats[i])) }
        } else if let ints = buffer.int16ChannelData?[0] {
            for i in index..<end { peak = max(peak, abs(Float(ints[i]) / 32768)) }
        }
        loud.append(peak > 0.02)
        index = end
    }
    var segments: [ClosedRange<TimeInterval>] = []
    for (i, isLoud) in loud.enumerated() where isLoud {
        let start = Double(i) / 100
        let end = Double(i + 1) / 100
        if let last = segments.last, start - last.upperBound < 0.35 {
            segments[segments.count - 1] = last.lowerBound...end
        } else {
            segments.append(start...end)
        }
    }
    return segments
}

// MARK: - Running one clip

struct Outcome {
    var event: CommandSpotter.Event?
    /// The drive clock when the spotter acted: how much input had been fed.
    var firedAt: TimeInterval?
    var heard: [String] = []
    var failure: String?
}

/// Where the clip starts on the drive clock. Not zero, as in a drive.
enum Timing {
    static let leadIn: TimeInterval = 1.0
    static let driveStart: TimeInterval = 6.0
    static let tail: TimeInterval = 4.0
}

final class FedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
func run(_ clip: Clip, with transcriber: SpeechAnalyzerEngine.Transcriber) async -> Outcome {
    var outcome = Outcome()
    let recognizer = SpeechCommandRecognizer(engine: SpeechAnalyzerEngine(transcriber: transcriber))
    let (buffers, input) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
    let events: AsyncStream<CommandRecognizerEvent>
    do {
        try await recognizer.prepare()
        events = try await recognizer.start(buffers: buffers)
    } catch {
        outcome.failure = error.localizedDescription
        return outcome
    }

    let clipStart = Timing.driveStart + Timing.leadIn
    var spotter = CommandSpotter()
    spotter.listen(mode: clip.mode, from: Timing.driveStart + 0.5)
    recognizer.listen(mode: clip.mode, from: Timing.driveStart + 0.5)

    // The input tap: 4096-frame buffers at 48 kHz, in real time.
    let clock = FedClock()
    clock.now = Timing.driveStart
    nonisolated(unsafe) let audio = clip.audio
    let feeder = Task.detached {
        let rate = audio.format.sampleRate
        let chunk = 4096
        let lead = Int(Timing.leadIn * rate)
        let total = lead + Int(audio.frameLength) + Int(Timing.tail * rate)
        var position = 0
        var deadline = ContinuousClock.now
        while position < total, !Task.isCancelled {
            let count = min(chunk, total - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let output = buffer.floatChannelData![0]
            let source = audio.floatChannelData![0]
            for i in 0..<count {
                let at = position + i - lead
                output[i] = at >= 0 && at < Int(audio.frameLength) ? source[at] : 0
            }
            let start = Timing.driveStart + Double(position) / rate
            input.yield(DriveAudioBuffer(buffer: buffer, startTime: start))
            position += count
            clock.now = Timing.driveStart + Double(position) / rate
            deadline += .seconds(Double(count) / rate)
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
        input.finish()
    }

    let watchdog = Task {
        try? await Task.sleep(for: .seconds(Timing.leadIn + Double(clip.audio.frameLength) / 48_000 + Timing.tail + 1.5))
        await recognizer.stop()
    }
    for await event in events {
        switch event {
        case .update(let update):
            if options.trace {
                func time(_ value: TimeInterval) -> String { String(format: "%.2f", value - clipStart) }
                let covering = update.covering.map { "\(time($0.lowerBound))-\(time($0.upperBound))" } ?? "-"
                let words = update.words.map { "\($0.text)@\(time($0.start))-\(time($0.end))" }.joined(separator: " ")
                print(
                    "    \(update.isFinal ? "final   " : "volatile") fed \(time(clock.now)) covering \(covering)"
                        + " progress \(update.progress.map(time) ?? "-"): \(words)")
            }
            if update.isFinal, !update.words.isEmpty {
                let text = update.words.map { String(format: "%@@%.2f-%.2f", $0.text, $0.start - clipStart, $0.end - clipStart) }
                outcome.heard += text
                if options.verbose { print("    final: \(text.joined(separator: " "))") }
            }
            if let event = spotter.receive(update).first, outcome.event == nil {
                outcome.event = event
                outcome.firedAt = clock.now
                if options.verbose { print("    event: \(event) at fed \(clock.now - clipStart)") }
                feeder.cancel()
                await recognizer.stop()
            }
        case .failed(let message):
            outcome.failure = message
        }
    }
    feeder.cancel()
    watchdog.cancel()
    await recognizer.stop()
    return outcome
}

// MARK: - Checking

let cutMargin = 0.1  // DriveAudio.cutMargin
/// At most this much of the command may be left in the take after the cut.
let commandLeftAllowance = 0.1

@MainActor func check(_ clip: Clip, _ outcome: Outcome) -> (passed: Bool, detail: String) {
    if let failure = outcome.failure { return (false, "recognizer failed: \(failure)") }
    let clipStart = Timing.driveStart + Timing.leadIn
    let speechEnd = clip.segments.last?.upperBound ?? 0
    let latency = outcome.firedAt.map { String(format: ", acted %.2f s after speech ended", $0 - clipStart - speechEnd) } ?? ""
    switch (clip.expectation, outcome.event) {
    case (.done, .done(let cutAt)?):
        guard clip.segments.count >= 2 else { return (false, "clip has no separate final utterance") }
        let onset = clip.segments[clip.segments.count - 1].lowerBound
        let answerEnd = clip.segments[clip.segments.count - 2].upperBound
        let cut = cutAt - clipStart
        let keptEnd = cut - cutMargin
        let detail = String(
            format: "done: cut at %.2f s, true start %.2f s (error %+.2f s), answer ends %.2f s%@", cut, onset,
            cut - onset, answerEnd, latency)
        if keptEnd < answerEnd { return (false, detail + "; the cut loses the end of the answer") }
        if keptEnd > onset + commandLeftAllowance { return (false, detail + "; the take keeps part of the command") }
        return (true, detail)
    case (.none, nil):
        return (true, "no command")
    case (.command(let expected), .command(let heard)?) where expected == heard:
        return (true, "\(heard)\(latency)")
    case (.unrecognized, .unrecognizedSpeech?):
        return (true, "unrecognized speech\(latency)")
    default:
        let got = outcome.event.map { "\($0)" } ?? "nothing"
        return (false, "expected \(clip.expectation), got \(got)\(latency)")
    }
}

// MARK: - Main

let clips = loadClips()
var failures = 0
for transcriber in options.transcribers {
    print("== \(transcriber.rawValue)")
    for clip in clips {
        let outcome = await run(clip, with: transcriber)
        let (passed, detail) = check(clip, outcome)
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL")  \(clip.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(detail)")
        print("      heard: \(outcome.heard.joined(separator: " "))")
    }
}
print(failures == 0 ? "All clips pass." : "\(failures) clip(s) failed.")
exit(failures == 0 ? 0 : 1)
