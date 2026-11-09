import Foundation

/// Where a drive's voice commands come from: the on-device recognizer
/// (`SpeechCommandRecognizer`), or in Debug builds a script (`ScriptedRecognizer`).
///
/// It hears the drive's input and reports what it heard as `CommandSpotter.Update`s; the drive
/// loop passes every update to its `CommandSpotter`, which decides what is a command. The loop
/// also tells the recognizer what it listens for, because that shapes when the recognizer asks
/// its engine for timed final words.
@MainActor
protocol CommandRecognizing: AnyObject {
    /// Checks that commands can work and installs what the recognizer needs. Call it at drive
    /// start, while still online. Throws `CommandRecognizerError.unavailable`; the loop then
    /// ends the drive with `DriveScript.commandsUnavailable`.
    func prepare() async throws
    /// Starts hearing the drive's input (`DriveAudio.recognizerBuffers()`). The stream ends after
    /// `stop()`, or after a `.failed` event. Throws `CommandRecognizerError.unavailable`.
    func start(buffers: AsyncStream<DriveAudioBuffer>) async throws -> AsyncStream<CommandRecognizerEvent>
    /// Mirrors `CommandSpotter.listen(mode:from:)`: call both with the same arguments.
    func listen(mode: CommandSpotter.Mode, from time: TimeInterval)
    /// Mirrors `CommandSpotter.stopListening()`.
    func stopListening()
    func stop() async
}

enum CommandRecognizerEvent: Sendable, Equatable {
    /// Pass it to `CommandSpotter.receive(_:)`.
    case update(CommandSpotter.Update)
    /// The recognizer stopped working mid-drive, so commands are unavailable from here on. The
    /// stream ends after it.
    case failed(String)
}

enum CommandRecognizerError: LocalizedError, Equatable {
    /// Commands cannot work on this phone right now: no recognizer, no English model, or its
    /// assets could not be installed.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Voice commands are unavailable: \(reason)"
        }
    }
}

/// One result from a speech engine, with times in seconds on the drive clock.
struct RecognizedResult: Sendable, Equatable {
    var text: String
    /// Words with their own times. Final results carry them. Volatile results from
    /// `SpeechAnalyzer` carry one run for the whole result instead, so they come as one entry
    /// that spans `range`, or none.
    var timedWords: [CommandSpotter.TimedWord]
    var range: ClosedRange<TimeInterval>
    var isFinal: Bool
    /// The engine's `resultsFinalizationTime`: every result before it is final.
    var finalizedThrough: TimeInterval
}

/// The recognizer's decisions, kept pure so they are tested without the Speech framework.
///
/// It turns engine results into spotter updates and decides when to ask the engine to
/// finalize. Volatile results from `SpeechAnalyzer` carry no per-word times, and while someone
/// keeps talking a final result (the only one with word times) can take until the end of the
/// input. So the recognizer asks for finalization, but only at these points:
///
/// - **A candidate**: the latest volatile text ends in a command. While recording that is
///   "done" (or "I'm done"); between takes, a short utterance that ends in a command phrase.
///   The timed final follows in about 0.15 s.
/// - **Confirming silence**: the spotter believes silence only as far as the recognizer has
///   reported, and a recognizer reports nothing while nobody talks. After a final that ends in
///   "done" (or, between takes, any final), once the input is past its last word plus the
///   spotter's window, the recognizer finalizes through that point. The engine then has
///   reported every word before it, so that time is the spotter's progress.
/// - **A quiet utterance** (between takes only): volatile words that stay unchanged for
///   `Config.quietFinalize` of input, so speech that is not a command is closed and reported too.
/// - **The window start**: `listen(mode:from:)` finalizes everything before the window, so a
///   window's volatile text holds only what was said in it.
///
/// It never finalizes on a timer: finalizing in the middle of speech makes the engine guess
/// words from partial audio. Decisions are made when audio is fed, not when a result
/// arrives, so a burst of results for one chunk of audio is judged by its last result ("got it
/// done by Friday", not "got it done").
///
/// Progress comes only from the engine: the end of a result's range, its finalization time, or
/// a finalization the engine completed. A completed finalization is believed only after
/// `Config.settle` more seconds of input, because the engine's results and the return of
/// `finalize` reach the recognizer by different paths, and a word in a final result must
/// never arrive after the progress that says there was silence there.
struct CommandRecognitionCore: Sendable {
    struct Config: Sendable, Equatable {
        var spotter = CommandSpotter.Config()
        /// How far past the spotter's silence window the confirming finalization reaches.
        var confirmMargin: TimeInterval = 0.1
        /// How much more input must be fed after a finalization completes before its time is
        /// believed as progress.
        var settle: TimeInterval = 0.3
        /// Between takes: volatile words unchanged for this long are finalized. Longer than the
        /// gap between `SpeechTranscriber`'s volatile results while someone talks (about 1 s).
        var quietFinalize: TimeInterval = 1.5
        /// The longest a word that ends a final result is believed to last (see
        /// `trimmingStretchedEnd`).
        var longestWordAtAPause: TimeInterval = 0.5
    }

    enum Action: Sendable, Equatable {
        case update(CommandSpotter.Update)
        /// Ask the engine to finalize everything up to this time.
        case finalize(through: TimeInterval)
    }

    /// Words the recognizer is known to mishear, mapped to what was said. Only mishearings seen
    /// in tests with real recognizers belong here:
    /// - `SpeechTranscriber` writes "done" as "Don." in final results (task 0 spike, macOS 27).
    ///
    /// Known risk: someone named Don, said alone after a pause while recording, ends the take.
    static let misheard: [String: String] = ["don": "done"]

    let config: Config

    private var mode: CommandSpotter.Mode?
    private var fed: TimeInterval = -.infinity
    /// The end of the latest final result: volatile results that start before it are stale.
    private var finalThrough: TimeInterval = -.infinity
    private var requestedThrough: TimeInterval = -.infinity
    private var windowStart: TimeInterval?
    private var pending: Pending?
    /// The tokens and range of the latest volatile result since the last final.
    private var latestVolatile: (tokens: [String], range: ClosedRange<TimeInterval>)?
    private var confirmAt: TimeInterval?
    private var settling: [(through: TimeInterval, readyAt: TimeInterval)] = []

    /// The latest volatile text since the last final, if it has words.
    private struct Pending {
        var tokens: [String]
        var end: TimeInterval
        var arrivedAt: TimeInterval
        var quietRequested = false
    }

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        self.mode = mode
        windowStart = time
        confirmAt = nil
    }

    mutating func stopListening() {
        mode = nil
        windowStart = nil
        confirmAt = nil
    }

    /// Takes one engine result: the spotter update for it.
    mutating func receive(_ result: RecognizedResult) -> [Action] {
        var words = Self.words(in: result)
        var updates: [CommandSpotter.Update] = []
        if result.isFinal {
            words = Self.trimmingStretchedEnd(of: words, in: result.range, longest: config.longestWordAtAPause)
            let progress = max(result.range.upperBound, result.finalizedThrough)
            updates.append(.init(words: words, isFinal: true, covering: result.range, progress: progress))
            pending = nil
            finalThrough = max(finalThrough, result.range.upperBound)
            let remainder = remainder(after: result, words: words, progress: progress)
            latestVolatile = nil
            if let remainder {
                updates.append(remainder)
                if let rest = remainder.words.first, let end = remainder.covering?.upperBound {
                    // Speech the final did not cover: it is still pending, and its own final will
                    // confirm or deny.
                    pending = Pending(tokens: CommandSpotter.normalize(rest.text), end: end, arrivedAt: fed)
                    confirmAt = nil
                    return updates.map { .update($0) }
                }
            }
            if let mode, let last = words.last, let lastToken = CommandSpotter.normalize(last.text).last {
                switch mode {
                case .recording:
                    confirmAt = lastToken == "done" ? last.end + config.spotter.silenceAfterDone + config.confirmMargin : nil
                case .betweenTakes:
                    confirmAt = last.end + config.spotter.utteranceGap + config.confirmMargin
                }
            }
        } else {
            updates.append(.init(words: words, isFinal: false, covering: result.range, progress: result.finalizedThrough))
            // A volatile result that starts before the last final restates audio that is already
            // final; it says nothing about new speech.
            if result.range.lowerBound >= finalThrough - 0.05 {
                let tokens = words.flatMap { CommandSpotter.normalize($0.text) }
                latestVolatile = (tokens, result.range)
                if tokens.isEmpty {
                    pending = nil
                } else {
                    pending = Pending(tokens: tokens, end: result.range.upperBound, arrivedAt: fed)
                    // Speech after the last final: its own finals will confirm or deny.
                    confirmAt = nil
                }
            }
        }
        return updates.map { .update($0) }
    }

    /// What a final leaves of the latest volatile text.
    ///
    /// A volatile result covers everything since the last final, often well into the silence
    /// after the last word, and the spotter spreads its words over that range. A final that
    /// covers only the first part of it replaces only the volatile words in its own range, and
    /// the engine does not always follow it with a new volatile result. So the words the final
    /// did not account for (by count) are restated over the rest of the range, and when there
    /// are none the rest is cleared; otherwise a volatile word spread into the silence would
    /// keep an utterance open forever.
    private func remainder(after final: RecognizedResult, words: [CommandSpotter.TimedWord], progress: TimeInterval)
        -> CommandSpotter.Update?
    {
        guard let latest = latestVolatile, latest.range.upperBound > final.range.upperBound,
            latest.range.lowerBound <= final.range.lowerBound + 0.05
        else { return nil }
        let left = latest.tokens.dropFirst(words.flatMap { CommandSpotter.normalize($0.text) }.count)
        let rest = final.range.upperBound...latest.range.upperBound
        let restated =
            left.isEmpty ? [] : [CommandSpotter.TimedWord(left.joined(separator: " "), start: rest.lowerBound, end: rest.upperBound)]
        return .init(words: restated, isFinal: false, covering: rest, progress: progress)
    }

    /// Input has been fed to the engine up to `time`: the decisions that depend on it.
    mutating func fed(through time: TimeInterval) -> [Action] {
        fed = max(fed, time)
        var actions: [Action] = []
        settling.removeAll { item in
            guard fed >= item.readyAt else { return false }
            actions.append(.update(.init(words: [], isFinal: false, progress: item.through)))
            return true
        }
        guard let mode else { return actions }

        if let start = windowStart, fed >= start {
            windowStart = nil
            request(start, into: &actions)
        }
        if let pending {
            if Self.isCandidate(pending.tokens, mode: mode, config: config.spotter) {
                request(pending.end, into: &actions)
            } else if mode == .betweenTakes, !pending.quietRequested,
                fed >= pending.arrivedAt + config.quietFinalize
            {
                self.pending?.quietRequested = true
                request(fed, into: &actions)
            }
        }
        if let at = confirmAt, fed >= at {
            confirmAt = nil
            request(at, into: &actions)
        }
        return actions
    }

    /// The engine finished a finalization through `time`. It is believed once input has been
    /// fed `settle` past both now and `time` (an engine cannot finalize audio it has not heard).
    mutating func finalized(through time: TimeInterval) {
        settling.append((time, max(fed, time) + config.settle))
    }

    private mutating func request(_ time: TimeInterval, into actions: inout [Action]) {
        guard time > requestedThrough else { return }
        requestedThrough = time
        actions.append(.finalize(through: time))
    }

    // MARK: - Words

    /// The result's words for the spotter: mishearings mapped, punctuation-only words dropped.
    /// Words without their own times span the result's range; the spotter spreads them over it.
    static func words(in result: RecognizedResult) -> [CommandSpotter.TimedWord] {
        let words =
            result.timedWords.isEmpty
            ? [CommandSpotter.TimedWord(result.text, start: result.range.lowerBound, end: result.range.upperBound)]
            : result.timedWords
        return words.compactMap { word in
            let tokens = CommandSpotter.normalize(word.text)
            guard !tokens.isEmpty else { return nil }
            guard tokens.contains(where: { misheard[$0] != nil }) else { return word }
            let text = tokens.map { misheard[$0] ?? $0 }.joined(separator: " ")
            return CommandSpotter.TimedWord(text, start: word.start, end: word.end)
        }
    }

    /// `SpeechTranscriber` stretches the last word before a pause to the end of the audio it
    /// processed with it (chunks of about a second), so the word seems to last into the pause:
    /// in `tools/drive-commands`, "trade-offs." ran to 2.54 s where the speech ended at 1.72 s.
    /// That hides the pause before a "done" that follows. So the last word of a final result,
    /// when it ends at the end of the result, is believed to last at most `longest`.
    ///
    /// Known risk: a long word said slowly before a short pause seems followed by more silence
    /// than there was.
    static func trimmingStretchedEnd(
        of words: [CommandSpotter.TimedWord], in range: ClosedRange<TimeInterval>, longest: TimeInterval
    ) -> [CommandSpotter.TimedWord] {
        guard var last = words.last, range.upperBound - last.end < 0.1, last.end - last.start > longest else { return words }
        last.end = last.start + longest
        return words.dropLast() + [last]
    }

    /// Whether volatile text ends in something that may be a command, so it is worth finalizing.
    static func isCandidate(_ tokens: [String], mode: CommandSpotter.Mode, config: CommandSpotter.Config) -> Bool {
        switch mode {
        case .recording:
            return tokens.last == "done"
        case .betweenTakes:
            guard tokens.count <= config.maxCommandWords else { return false }
            return tokens.indices.contains { start in
                CommandSpotter.phrases[tokens[start...].joined(separator: " ")] != nil
            }
        }
    }
}
