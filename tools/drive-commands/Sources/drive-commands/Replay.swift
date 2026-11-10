import AVFoundation
import Foundation

/// Replays a device run that the app captured with `-debug.recognizerCapture`: the phone's
/// recognizer input, fed in real time on the same drive clock, with the listening windows
/// opened and closed at the times the phone did. Prints the spotter's updates and events, and
/// writes this run's own trace next to the phone's as `mac-recognizer-trace.txt`.
@MainActor
func replay(_ directory: URL, with transcriber: SpeechAnalyzerEngine.Transcriber) async {
    let inputURL = directory.appending(path: RecognizerCapture.inputName)
    let traceURL = directory.appending(path: RecognizerCapture.traceName)
    guard let trace = try? String(contentsOf: traceURL, encoding: .utf8) else { fail("No \(traceURL.path)") }
    let audio: AVAudioPCMBuffer
    do {
        let file = try AVAudioFile(forReading: inputURL)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { fail("Cannot read \(inputURL.path)") }
        try file.read(into: source)
        audio = try resample(source, to: 48_000)
    } catch {
        fail("Cannot read \(inputURL.path): \(error)")
    }

    // The phone's listening windows, at the input time it had reached when it opened them.
    enum Step { case listen(CommandSpotter.Mode, TimeInterval), stop }
    var steps: [(at: TimeInterval, step: Step)] = []
    for line in trace.split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let at = TimeInterval(fields[0]) else { continue }
        if fields[1] == "listen", fields.count == 5, let from = TimeInterval(fields[4]) {
            steps.append((at, .listen(fields[2] == "recording" ? .recording : .betweenTakes, from)))
        } else if fields[1] == "stop", fields.count >= 3, fields[2] == "listening" {
            steps.append((at, .stop))
        }
    }
    let duration = Double(audio.frameLength) / audio.format.sampleRate
    print(String(format: "Replaying %.1f s with %d window changes", duration, steps.count))

    let recognizer = SpeechCommandRecognizer(
        engine: SpeechAnalyzerEngine(transcriber: transcriber),
        capture: RecognizerCapture(directory: directory, traceName: "mac-recognizer-trace.txt", recordsInput: false))
    let (buffers, input) = AsyncStream.makeStream(of: DriveAudioBuffer.self)
    let events: AsyncStream<CommandRecognizerEvent>
    do {
        try await recognizer.prepare()
        events = try await recognizer.start(buffers: buffers)
    } catch {
        fail("The recognizer did not start: \(error.localizedDescription)")
    }

    let clock = FedClock()
    nonisolated(unsafe) let source = audio
    let feeder = Task.detached {
        let rate = source.format.sampleRate
        let chunk = 4096
        var position = 0
        var deadline = ContinuousClock.now
        while position < Int(source.frameLength), !Task.isCancelled {
            let count = min(chunk, Int(source.frameLength) - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].update(from: source.floatChannelData![0] + position, count: count)
            input.yield(DriveAudioBuffer(buffer: buffer, startTime: Double(position) / rate))
            position += count
            clock.now = Double(position) / rate
            deadline += .seconds(Double(count) / rate)
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
        input.finish()
    }

    var spotter = CommandSpotter()
    var pending = steps[...]
    func applySteps() {
        while let next = pending.first, clock.now >= next.at {
            pending.removeFirst()
            switch next.step {
            case .listen(let mode, let from):
                print(String(format: "%6.2f listen %@ from %.2f", clock.now, "\(mode)", from))
                spotter.listen(mode: mode, from: from)
                recognizer.listen(mode: mode, from: from)
            case .stop:
                print(String(format: "%6.2f stop listening", clock.now))
                spotter.stopListening()
                recognizer.stopListening()
            }
        }
    }
    let stepper = Task {
        while !Task.isCancelled {
            applySteps()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    for await event in events {
        switch event {
        case .update(let update):
            let covering = update.covering.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "-"
            let words = update.words.map { String(format: "%@@%.2f-%.2f", $0.text, $0.start, $0.end) }.joined(separator: " ")
            print(
                String(format: "%6.2f %@ covering %@ progress %@: %@", clock.now, update.isFinal ? "final   " : "volatile", covering,
                    update.progress.map { String(format: "%.2f", $0) } ?? "-", words))
            for spotted in spotter.receive(update) {
                print(String(format: "%6.2f EVENT %@", clock.now, "\(spotted)"))
            }
        case .failed(let message):
            print(String(format: "%6.2f FAILED %@", clock.now, message))
        }
    }
    feeder.cancel()
    stepper.cancel()
    await recognizer.stop()
}
