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
/// input. So the recognizer asks for finalization, at these points:
///
/// - **A candidate**: the latest volatile text ends in "done" (or "I'm done") while recording,
///   or between takes holds any words (so a command is acted on, and other speech is reported).
///   It is finalized through the end of that volatile result.
/// - **Confirming silence**: the spotter believes silence only as far as the recognizer has
///   reported, and a recognizer reports nothing while nobody talks. After a final that ends in
///   "done" (or, between takes, any final), the recognizer finalizes through its last word plus
///   the spotter's window and `Config.confirmMargin`. The engine has then reported every word
///   before that point, so that time is the spotter's progress.
/// - **The window start**: `listen(mode:from:)` finalizes everything before the window, so a
///   window's volatile text holds only what was said in it.
///
/// It never finalizes audio the engine has not had time to report: a candidate or a
/// confirmation waits until the input is `Config.engineLag` past its time with no newer words.
/// In `tools/drive-commands`, a finalization requested 0.8 s ahead of the engine came back as
/// an empty final over "actually" said 0.6 s after "done", and the take ended. Decisions are made
/// when audio is fed, not when a result arrives, so a burst of results for one chunk of audio is
/// judged by its last result ("got it done by Friday", not "got it done").
///
/// Progress comes only from final results and completed finalizations. A volatile result's
/// range runs to the end of the audio the engine processed, past its words, so it gives none. A
/// completed finalization is believed only after `Config.settle` more seconds of input, because
/// the engine's results and the return of `finalize` reach the recognizer by different paths,
/// and a word in a final result must never arrive after the progress that says there was
/// silence there.
struct CommandRecognitionCore: Sendable {
    struct Config: Sendable, Equatable {
        var spotter = CommandSpotter.Config()
        /// How far past the spotter's silence window the confirming finalization reaches, so a
        /// word that starts just inside the window is heard whole rather than cut.
        var confirmMargin: TimeInterval = 0.3
        /// How long the engine may take to report speech it was fed. `SpeechTranscriber` reports
        /// in chunks of about a second.
        var engineLag: TimeInterval = 1.5
        /// How much more input must be fed after a finalization completes before its time is
        /// believed as progress.
        var settle: TimeInterval = 0.3
        /// A finalization that has not completed after this much more input means the engine is
        /// stuck, and commands fail.
        var finalizeTimeout: TimeInterval = 5
        /// The longest a word that ends a final result is believed to last (see
        /// `trimmingStretchedEnd`).
        var longestWordAtAPause: TimeInterval = 0.5
    }

    enum Action: Sendable, Equatable {
        case update(CommandSpotter.Update)
        /// Ask the engine to finalize everything up to this time, then call `finalized(through:)`.
        case finalize(through: TimeInterval)
        /// The engine stopped working: commands are unavailable from here on.
        case fail(String)
    }

    let config: Config

    private var mode: CommandSpotter.Mode?
    private var fed: TimeInterval = -.infinity
    /// The end of the latest final result: volatile results that start before it are stale.
    private var finalThrough: TimeInterval = -.infinity
    private var requestedThrough: TimeInterval = -.infinity
    private var windowStart: TimeInterval?
    /// The latest volatile text since the last final, if it has words. Its end is how far the
    /// engine had processed when it reported them.
    private var pending: (tokens: [String], end: TimeInterval)?
    /// The tokens and range of the latest volatile result since the last final.
    private var latestVolatile: (tokens: [String], range: ClosedRange<TimeInterval>)?
    private var confirm: (at: TimeInterval, heard: Bool)?
    private var settling: [(through: TimeInterval, readyAt: TimeInterval)] = []
    private var outstanding: [(through: TimeInterval, requestedAt: TimeInterval)] = []

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func listen(mode: CommandSpotter.Mode, from time: TimeInterval) {
        self.mode = mode
        windowStart = time
        confirm = nil
    }

    mutating func stopListening() {
        mode = nil
        windowStart = nil
        confirm = nil
    }

    /// Takes one engine result: the spotter updates for it.
    mutating func receive(_ result: RecognizedResult) -> [Action] {
        let words = Self.words(in: result)
        let updates = result.isFinal ? receiveFinal(result, words: words) : receiveVolatile(result, words: words)
        return updates.map { .update($0) }
    }

    private mutating func receiveVolatile(_ result: RecognizedResult, words: [CommandSpotter.TimedWord])
        -> [CommandSpotter.Update]
    {
        // A volatile result that starts before the last final restates audio that is already
        // final: it says nothing about new speech, and its words spread past the final would
        // block a command.
        guard result.range.lowerBound >= finalThrough - 0.05 else { return [] }
        let tokens = Self.tokens(in: words)
        latestVolatile = (tokens, result.range)
        if tokens.isEmpty {
            pending = nil
            // The engine processed the audio through the confirmation time and heard nothing.
            if let at = confirm?.at, result.range.upperBound >= at { confirm?.heard = true }
        } else {
            pending = (tokens, result.range.upperBound)
            // Speech after the last final: its own finals will confirm or deny.
            confirm = nil
        }
        // Covering only its start retracts the volatile words it replaces, without claiming
        // silence over the rest of its range.
        let start = result.range.lowerBound
        return [.init(words: words, isFinal: false, covering: start...start, progress: result.finalizedThrough)]
    }

    private mutating func receiveFinal(_ result: RecognizedResult, words heard: [CommandSpotter.TimedWord])
        -> [CommandSpotter.Update]
    {
        var words = Self.trimmingStretchedEnd(of: heard, in: result.range, longest: config.longestWordAtAPause)
        let progress = max(result.range.upperBound, result.finalizedThrough)
        finalThrough = max(finalThrough, result.range.upperBound)
        pending = nil
        let leftover = leftover(after: result, words: words)
        latestVolatile = nil
        words += leftover.lost
        var updates: [CommandSpotter.Update] = [.init(words: words, isFinal: true, covering: result.range, progress: progress)]
        if let rest = leftover.rest {
            updates.append(rest.update)
            if !rest.tokens.isEmpty {
                // Speech the final did not cover: it is still pending, and its own final will
                // confirm or deny.
                latestVolatile = (rest.tokens, rest.range)
                pending = (rest.tokens, rest.range.upperBound)
                confirm = nil
                return updates
            }
        }
        if let mode, let last = words.last, let lastToken = Self.tokens(in: [last]).last {
            switch mode {
            case .recording:
                confirm = lastToken == "done" ? (last.end + config.spotter.silenceAfterDone + config.confirmMargin, false) : nil
            case .betweenTakes:
                confirm = (last.end + config.spotter.utteranceGap + config.confirmMargin, false)
            }
        }
        return updates
    }

    /// What a final leaves of the latest volatile text.
    ///
    /// The final's words are lined up with the volatile words by its last word.
    /// - When the volatile text runs past the final, the volatile words after that point are
    ///   restated after the final: they are still pending speech. A volatile result often runs
    ///   into the silence after its last word, and the spotter spreads its words over that
    ///   range, so when nothing is left that part is cleared; otherwise a volatile word spread
    ///   into the silence would keep an utterance open. When the two do not line up, all of the
    ///   volatile text is restated: a word kept by mistake only waits for the next result.
    /// - When the final covers all of the volatile text but has fewer words, the engine dropped
    ///   them (`SpeechTranscriber` does when it is made to finalize audio it has not reported).
    ///   They are kept as final words after the final's own, so they still count as speech:
    ///   retracting them could make a "done" before them look followed by silence.
    private func leftover(after final: RecognizedResult, words: [CommandSpotter.TimedWord]) -> (
        lost: [CommandSpotter.TimedWord],
        rest: (update: CommandSpotter.Update, tokens: [String], range: ClosedRange<TimeInterval>)?
    ) {
        guard let latest = latestVolatile, latest.range.lowerBound <= final.range.lowerBound + 0.05 else { return ([], nil) }
        let heard = Self.tokens(in: words)
        let aligned = Self.alignedEnd(of: heard, in: latest.tokens)
        let end = final.range.upperBound
        if latest.range.upperBound > end + 0.05 {
            let left = Array(latest.tokens[(aligned ?? 0)...])
            let range = end...latest.range.upperBound
            let restated = left.isEmpty ? [] : [CommandSpotter.TimedWord(left.joined(separator: " "), start: end, end: range.upperBound)]
            return ([], (.init(words: restated, isFinal: false, covering: end...end), left, range))
        }
        let lost = latest.tokens.dropFirst(aligned ?? heard.count)
        guard !lost.isEmpty else { return ([], nil) }
        let start = min(words.last?.end ?? final.range.lowerBound, end)
        return ([CommandSpotter.TimedWord(lost.joined(separator: " "), start: start, end: end)], nil)
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
        if let stuck = outstanding.first(where: { fed - $0.requestedAt > config.finalizeTimeout }) {
            outstanding = []
            actions.append(.fail(String(format: "The speech recognizer did not finalize through %.2f s.", stuck.through)))
            return actions
        }
        guard let mode else { return actions }

        if let start = windowStart, fed >= start {
            windowStart = nil
            request(start, into: &actions)
        }
        if let pending, fed >= pending.end + config.engineLag,
            mode == .betweenTakes || pending.tokens.last == "done"
        {
            request(pending.end, into: &actions)
        }
        if let confirm, confirm.heard || fed >= confirm.at + config.engineLag {
            self.confirm = nil
            request(confirm.at, into: &actions)
        }
        return actions
    }

    /// The engine finished a finalization through `time`. It is believed once input has been
    /// fed `settle` past both now and `time` (an engine cannot finalize audio it has not heard).
    mutating func finalized(through time: TimeInterval) {
        outstanding.removeAll { $0.through == time }
        settling.append((time, max(fed, time) + config.settle))
    }

    private mutating func request(_ time: TimeInterval, into actions: inout [Action]) {
        guard time > requestedThrough else { return }
        requestedThrough = time
        outstanding.append((time, fed))
        actions.append(.finalize(through: time))
    }

    // MARK: - Words

    /// The result's words for the spotter, punctuation-only words dropped. Words without their
    /// own times span the result's range; the spotter spreads them over it.
    static func words(in result: RecognizedResult) -> [CommandSpotter.TimedWord] {
        let words =
            result.timedWords.isEmpty
            ? [CommandSpotter.TimedWord(result.text, start: result.range.lowerBound, end: result.range.upperBound)]
            : result.timedWords
        return words.filter { !CommandSpotter.normalize($0.text).isEmpty }
    }

    private static func tokens(in words: [CommandSpotter.TimedWord]) -> [String] {
        words.flatMap { CommandSpotter.normalize($0.text) }
    }

    /// Where a final's words end in the volatile text before it: the index after the last
    /// volatile token that matches the final's last token, also when one of them splits a word
    /// the other writes as one ("trade-offs" and "tradeoffs"). Nil when they do not line up.
    static func alignedEnd(of final: [String], in volatile: [String]) -> Int? {
        guard !final.isEmpty else { return 0 }
        for end in stride(from: volatile.count, to: 0, by: -1) {
            for count in 1...min(3, end) {
                let joined = volatile[(end - count)..<end].joined()
                if (1...min(3, final.count)).contains(where: { final[(final.count - $0)...].joined() == joined }) {
                    return end
                }
            }
        }
        return nil
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
}
