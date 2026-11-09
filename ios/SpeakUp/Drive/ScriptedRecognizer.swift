#if DEBUG
import Foundation
import os

/// Debug builds only: hears the words a script gives instead of running a speech engine. The
/// iOS simulator has no recognizer for commands (`SpeechTranscriber` is unsupported there and
/// `DictationTranscriber` has no model), so drives in the simulator and their UI tests use it.
///
/// It is driven by the drive's input like the real recognizer: it reads
/// `DriveAudio.recognizerBuffers()` and reports a word only once the drive clock has passed
/// it, `lag` seconds late, as volatile when it starts and final when it ends, with progress
/// following the clock. So the loop, the spotter and the take trim run on the drive clock
/// exactly as with real speech, over the scripted microphone's real audio.
///
/// A script holds one line per listening window, in order, for each mode. Each `listen`
/// takes the next line of its mode; a mode with no lines left hears nothing. A line is words
/// with start times in seconds from the start of the window: `so that is my answer@0.5
/// done@4.2` says "so that is my answer" from 0.5 s, word after word, then "done" at 4.2 s.
/// The window starts at `listen(mode:from:)`'s time, or at the drive clock when `listen` is
/// called later than that, which is when the scripted microphone starts the take clip.
@MainActor
final class ScriptedRecognizer: CommandRecognizing {
    struct Script: Sendable, Equatable, Decodable {
        var recording: [String] = []
        var betweenTakes: [String] = []

        init(recording: [String] = [], betweenTakes: [String] = []) {
            self.recording = recording
            self.betweenTakes = betweenTakes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recording = try container.decodeIfPresent([String].self, forKey: .recording) ?? []
            betweenTakes = try container.decodeIfPresent([String].self, forKey: .betweenTakes) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case recording, betweenTakes
        }

        /// `{"recording": ["... done@41.3"], "betweenTakes": ["again@0.5"]}`. Every line is
        /// checked, so a typo fails at launch rather than mid-drive.
        static func parse(json: String) throws -> Script {
            let script = try JSONDecoder().decode(Script.self, from: Data(json.utf8))
            for line in script.recording + script.betweenTakes { _ = try ScriptedRecognizer.words(in: line) }
            return script
        }
    }

    enum ScriptError: LocalizedError, Equatable {
        case badLine(String)

        var errorDescription: String? {
            switch self {
            case .badLine(let reason): return "Bad recognizer script line: \(reason)"
            }
        }
    }

    /// How long each scripted word lasts, and the gap between words of one phrase.
    nonisolated static let wordLength: TimeInterval = 0.3
    nonisolated static let wordGap: TimeInterval = 0.05

    let lag: TimeInterval
    private var queues: [CommandSpotter.Mode: [String]]
    private let problem: String?
    private var now: TimeInterval = 0
    private var window: [Scheduled] = []
    private var listening = false
    private var reportedProgress = -TimeInterval.infinity
    private var continuation: AsyncStream<CommandRecognizerEvent>.Continuation?
    private var feeding: Task<Void, Never>?

    private struct Scheduled {
        var word: CommandSpotter.TimedWord
        var heard = false
        var final = false
    }

    private static let log = Logger(subsystem: "dev.ryangan.speakup", category: "ScriptedRecognizer")

    /// `lag` is how far behind the drive clock words are reported, as a recognizer's are.
    init(script: Script, lag: TimeInterval = 0.4) {
        self.lag = lag
        queues = [.recording: script.recording, .betweenTakes: script.betweenTakes]
        problem = nil
    }

    /// A recognizer whose `prepare()` fails with `problem`, so a bad launch script is heard.
    private init(problem: String) {
        lag = 0
        queues = [:]
        self.problem = problem
    }

    /// The recognizer `-debug.recognizerScript <json>` asks for, or nil without it.
    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> ScriptedRecognizer? {
        guard let index = arguments.firstIndex(of: "-debug.recognizerScript"), index + 1 < arguments.count else {
            return nil
        }
        do {
            return ScriptedRecognizer(script: try Script.parse(json: arguments[index + 1]))
        } catch {
            log.error("-debug.recognizerScript: \(error.localizedDescription, privacy: .public)")
            return ScriptedRecognizer(problem: "the recognizer script is invalid: \(error.localizedDescription)")
        }
    }

    /// The words of one script line, in seconds from the window start.
    nonisolated static func words(in line: String) throws -> [CommandSpotter.TimedWord] {
        var words: [CommandSpotter.TimedWord] = []
        var phrase: [String] = []
        for token in line.split(whereSeparator: \.isWhitespace) {
            guard let at = token.firstIndex(of: "@") else {
                phrase.append(String(token))
                continue
            }
            let word = token[..<at]
            guard !word.isEmpty, let start = TimeInterval(token[token.index(after: at)...]), start >= 0 else {
                throw ScriptError.badLine("\"\(token)\" in \"\(line)\" needs a word and a time, like done@4.2")
            }
            phrase.append(String(word))
            if let last = words.last, start < last.end {
                throw ScriptError.badLine("\"\(token)\" in \"\(line)\" starts before the words before it end")
            }
            for (index, text) in phrase.enumerated() {
                let wordStart = start + Double(index) * (wordLength + wordGap)
                words.append(.init(text, start: wordStart, end: wordStart + wordLength))
            }
            phrase = []
        }
        guard phrase.isEmpty else {
            throw ScriptError.badLine("\"\(phrase.joined(separator: " "))\" in \"\(line)\" has no time")
        }
        return words
    }

    func prepare() async throws {
        if let problem { throw CommandRecognizerError.unavailable(problem) }
    }

    func start(buffers: AsyncStream<DriveAudioBuffer>) async throws -> AsyncStream<CommandRecognizerEvent> {
        try await prepare()
        feeding?.cancel()
        self.continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: CommandRecognizerEvent.self)
        self.continuation = continuation
        feeding = Task { [weak self] in
            for await buffer in buffers {
                self?.advance(to: buffer.endTime)
            }
            // The drive's audio stopped: so does recognition.
            if !Task.isCancelled { await self?.stop() }
        }
        return stream
    }

    func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        let line = queues[mode]?.first
        if line != nil { queues[mode]?.removeFirst() }
        let anchor = max(time, now)
        let words = line.flatMap { try? Self.words(in: $0) } ?? []
        window = words.map { Scheduled(word: .init($0.text, start: anchor + $0.start, end: anchor + $0.end)) }
        listening = true
    }

    func stopListening() {
        listening = false
        window = []
    }

    func stop() async {
        feeding?.cancel()
        feeding = nil
        continuation?.finish()
        continuation = nil
        listening = false
        window = []
    }

    /// The drive clock reached `time`: reports what a recognizer `lag` seconds behind has heard.
    private func advance(to time: TimeInterval) {
        now = max(now, time)
        let heardThrough = now - lag
        guard listening, let continuation else { return }
        for index in window.indices {
            let word = window[index].word
            if !window[index].heard, word.start <= heardThrough {
                window[index].heard = true
                continuation.yield(.update(.init(words: [word], isFinal: false, covering: word.start...heardThrough)))
            }
            if !window[index].final, word.end <= heardThrough {
                window[index].final = true
                continuation.yield(.update(.init(words: [word], isFinal: true)))
            }
        }
        if heardThrough > reportedProgress {
            reportedProgress = heardThrough
            continuation.yield(.update(.init(words: [], isFinal: false, progress: heardThrough)))
        }
    }
}
#endif
