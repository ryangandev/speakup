import Foundation

/// Finds voice commands in a stream of timed, recognized words (product.md#driving-mode).
///
/// Pure logic: no audio and no Speech framework, so it is tested with word timelines.
/// The recognizer adapter feeds it every volatile and final result; the drive loop tells it
/// what to listen for.
///
/// Two listening modes:
/// - `.recording`: only "done" counts, and only when it is a command rather than part of a
///   sentence (see `Config`). The event carries the time to cut the take at.
/// - `.betweenTakes`: an utterance of a few words between pauses that is exactly a command
///   phrase ("again", "next", "repeat that", "read the better version", "stop").
///
/// Only final (committed) words can make a command; volatile words are guesses that the
/// recognizer revises. They still count as context: a volatile word right before or after
/// a "done" is enough to reject it.
///
/// A listening window ends at its first command, so each call to `listen` yields at most
/// one command. Times are seconds on the drive's single audio clock, the same one the
/// take gate counts frames on.
struct CommandSpotter: Sendable {
    /// Every threshold in one place, tuned on a device.
    struct Config: Sendable, Equatable {
        /// "done" counts only after at least this much silence before it, so "we got it
        /// done" said in one breath is not a command.
        var silenceBeforeDone: TimeInterval = 0.6
        /// ... and only if no new word starts within this long after it ends, so "done"
        /// in the middle of a sentence is not a command.
        var silenceAfterDone: TimeInterval = 1.2
        /// Between takes, a gap this long closes an utterance. A command is acted on once
        /// its utterance is closed.
        var utteranceGap: TimeInterval = 0.8
        /// Between takes, a longer utterance than this is never a command.
        var maxCommandWords = 5
    }

    enum Mode: Sendable, Equatable {
        case recording
        case betweenTakes
    }

    /// A command spoken between takes.
    enum Command: Sendable, Equatable {
        case again
        case next
        case repeatThat
        case betterVersion
        case stop
        /// An answer to a nervousness question, 1 to 5. The loop only accepts it there.
        case rating(Int)
        /// Skips a nervousness question.
        case skip
    }

    enum Event: Sendable, Equatable {
        /// The take ends. `cutAt` is the start of "done" (or of "I'm done") on the audio
        /// clock; the audio core trims the take there, with its own safety margin.
        case done(cutAt: TimeInterval)
        case command(Command)
        /// Between takes: a closed utterance that is not a command. The loop can answer
        /// with the command list, once.
        case unrecognizedSpeech
    }

    /// One word as the recognizer reported it.
    struct TimedWord: Sendable, Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval

        init(_ text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One recognizer result.
    ///
    /// A volatile update replaces every volatile word from its coverage onward. A final
    /// update commits its words and replaces the volatile words it covers.
    struct Update: Sendable, Equatable {
        var words: [TimedWord]
        var isFinal: Bool
        /// The audio span this result speaks for. It defaults to the span of its words; a
        /// result that retracts every word needs it to say what it retracts.
        var covering: ClosedRange<TimeInterval>?
        /// How far the recognizer has got: every word that starts before this time has
        /// been reported at least as volatile. Silence is only believed up to here.
        ///
        /// Contract for the recognizer adapter: take it only from recognizer results, that
        /// is the results' finalization time or the end of the latest result's range. Never
        /// derive it from the microphone tap's clock, with or without a lag estimate. The
        /// recognizer runs about 1.5 s behind the audio, and a "done" that looks followed
        /// by silence on the tap clock may be followed by words the recognizer has not
        /// reported yet, which would make a mid-sentence "done" look like a command.
        var progress: TimeInterval?

        init(
            words: [TimedWord], isFinal: Bool, covering: ClosedRange<TimeInterval>? = nil,
            progress: TimeInterval? = nil
        ) {
            self.words = words
            self.isFinal = isFinal
            self.covering = covering
            self.progress = progress
        }
    }

    let config: Config
    private(set) var mode: Mode = .recording
    /// Whether a window is open: after `listen` and before its first command.
    private(set) var isListening = false

    private var listenFrom: TimeInterval = 0
    private var progress: TimeInterval = 0
    private var committed: [Token] = []
    private var volatile: [Token] = []
    private var finalizedThrough: TimeInterval = -.infinity
    private var reportedThrough: TimeInterval = -.infinity

    init(config: Config = Config()) {
        self.config = config
    }

    /// Opens a listening window. Words that start before `time` are ignored, now and in
    /// later updates: pass the time the app stopped speaking or playing a tone (plus a
    /// little settle time), because on car speakers the microphone hears the app.
    mutating func listen(mode: Mode, from time: TimeInterval) {
        self.mode = mode
        isListening = true
        listenFrom = time
        progress = time
        committed = []
        volatile = []
        finalizedThrough = -.infinity
        reportedThrough = -.infinity
    }

    /// Stops listening until the next `listen`.
    mutating func stopListening() {
        isListening = false
    }

    /// Takes one recognizer result.
    mutating func receive(_ update: Update) -> [Event] {
        guard isListening else { return [] }
        let tokens = Self.tokens(in: update.words, isFinal: update.isFinal)
            .filter { $0.start >= listenFrom }
        let coverStart = update.covering?.lowerBound ?? update.words.map(\.start).min()
        let coverEnd = update.covering?.upperBound ?? update.words.map(\.end).max()
        if let coverStart, let coverEnd {
            if update.isFinal {
                volatile.removeAll { $0.start < coverEnd }
                committed.removeAll { $0.start >= coverStart && $0.start < coverEnd }
                committed += tokens
                finalizedThrough = max(finalizedThrough, coverEnd)
            } else {
                volatile.removeAll { $0.start >= coverStart }
                volatile += tokens.filter { $0.start >= finalizedThrough }
            }
            progress = max(progress, coverEnd)
        }
        if let reported = update.progress { progress = max(progress, reported) }
        return evaluate()
    }

    /// Moves the recognizer's clock forward with no new words: silence has been heard. Same
    /// contract as `Update.progress`: recognizer results only, never the tap clock.
    mutating func advance(progress reported: TimeInterval) -> [Event] {
        guard isListening else { return [] }
        progress = max(progress, reported)
        return evaluate()
    }

    // MARK: - Evaluation

    private mutating func evaluate() -> [Event] {
        let words = (committed + volatile).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        switch mode {
        case .recording:
            guard let cut = doneCut(in: words) else { return [] }
            isListening = false
            return [.done(cutAt: cut)]
        case .betweenTakes:
            return commands(in: words)
        }
    }

    /// The start of the first "done" that is a command, or nil.
    private func doneCut(in words: [Token]) -> TimeInterval? {
        let slack = 1e-9
        for i in words.indices where words[i].norm == "done" {
            guard var first = commandStart(in: words, endingAt: i) else { continue }

            let end = words[i].end
            if i + 1 < words.count {
                // Words after it, final or not: a command only if the next is far enough away.
                guard words[i + 1].start - end >= config.silenceAfterDone - slack else { continue }
            } else {
                // Nothing after it yet: believe the silence only as far as the recognizer got.
                guard progress - end >= config.silenceAfterDone - slack else { continue }
            }

            // "done ... done": the speaker repeated it. Cut at the first of the run, so the
            // first one is not left in the take.
            while first > 0, words[first - 1].norm == "done",
                words[first].start - words[first - 1].end < config.silenceAfterDone - slack,
                let earlier = commandStart(in: words, endingAt: first - 1)
            {
                first = earlier
            }
            return words[first].start
        }
        return nil
    }

    /// The index where a "done" command ending at `i` starts: "done", "I'm done" or "I am
    /// done" (the longest that fits), all final, with enough silence before it.
    private func commandStart(in words: [Token], endingAt i: Int) -> Int? {
        for length in [3, 2, 1] {
            let first = i - (length - 1)
            guard first >= 0, Self.leads(words, endingAt: i, length: length) else { continue }
            let phrase = words[first...i]
            // Volatile words are guesses: only committed ones make a command.
            guard phrase.allSatisfy({ $0.isFinal }) else { continue }
            // The phrase must be said as one: "I'm ... done" is "done" alone.
            let contiguous = zip(phrase, phrase.dropFirst()).allSatisfy {
                $1.start - $0.end < config.silenceBeforeDone
            }
            guard contiguous else { continue }
            let before = words[first].start - (first > 0 ? words[first - 1].end : listenFrom)
            guard before >= config.silenceBeforeDone - 1e-9 else { continue }
            return first
        }
        return nil
    }

    private static func leads(_ words: [Token], endingAt i: Int, length: Int) -> Bool {
        switch length {
        case 3: words[i - 2].norm == "i" && words[i - 1].norm == "am"
        case 2: words[i - 1].norm == "im"
        default: true
        }
    }

    private mutating func commands(in words: [Token]) -> [Event] {
        var events: [Event] = []
        var group: [Token] = []

        func closed(_ group: [Token], next: Token?) -> Bool {
            guard let last = group.last else { return false }
            if let next { return next.start - last.end >= config.utteranceGap }
            return progress - last.end >= config.utteranceGap
        }

        // Splits into utterances, then handles the closed ones in order.
        var utterances: [[Token]] = []
        for word in words {
            if let last = group.last, word.start - last.end >= config.utteranceGap {
                utterances.append(group)
                group = []
            }
            group.append(word)
        }
        if !group.isEmpty { utterances.append(group) }

        for (index, utterance) in utterances.enumerated() {
            let next = index + 1 < utterances.count ? utterances[index + 1].first : nil
            guard closed(utterance, next: next) else { break }
            // A closed utterance still being revised is not acted on, nor are later ones.
            guard utterance.allSatisfy({ $0.isFinal }) else { break }
            let text = utterance.map(\.norm).joined(separator: " ")
            if utterance.count <= config.maxCommandWords, let command = Self.phrases[text] {
                events.append(.command(command))
                isListening = false
                return events
            }
            if utterance[0].start >= reportedThrough {
                events.append(.unrecognizedSpeech)
                reportedThrough = utterance.last!.end
            }
        }
        return events
    }

    // MARK: - Words

    /// What may be said between takes, and the answers to a nervousness question. Only the
    /// synonyms the plan lists; the whole utterance must match, so "stop the car" is not "stop"
    /// and "three things" is not a rating.
    ///
    /// "say that again" means repeat that, not again. Known risk: a pause of 0.8 s or more
    /// after "say that" splits it into "say that" (unrecognized) and "again" (retry).
    ///
    /// The 0.6 s silence before "done" (`Config.silenceBeforeDone`) is a risk to tune on a
    /// device: a block just before "done" followed by a short pause can end the take, and a
    /// speaker who says "done" right after the last word, with no pause, is not heard.
    static let phrases: [String: Command] = [
        "again": .again,
        "try again": .again,
        "next": .next,
        "next question": .next,
        "repeat that": .repeatThat,
        "say that again": .repeatThat,
        "read the better version": .betterVersion,
        "better version": .betterVersion,
        "stop": .stop,
        // Answers to "How nervous are you, one to five?". A recognizer writes a number said
        // alone as a digit or a word, and can hear a lone "two" or "four" as its homophone.
        "1": .rating(1), "one": .rating(1), "won": .rating(1),
        "2": .rating(2), "two": .rating(2), "to": .rating(2), "too": .rating(2),
        "3": .rating(3), "three": .rating(3),
        "4": .rating(4), "four": .rating(4), "for": .rating(4),
        "5": .rating(5), "five": .rating(5),
        "skip": .skip,
    ]

    private struct Token: Sendable {
        var norm: String
        var start: TimeInterval
        var end: TimeInterval
        var isFinal: Bool
    }

    /// Normalized tokens: lower case, no punctuation, no apostrophes ("I'm" is "im"). A
    /// recognizer word that holds several tokens spreads its time evenly over them.
    private static func tokens(in words: [TimedWord], isFinal: Bool) -> [Token] {
        words.flatMap { word -> [Token] in
            let parts = normalize(word.text)
            guard !parts.isEmpty else { return [] }
            let span = (word.end - word.start) / Double(parts.count)
            return parts.enumerated().map {
                Token(
                    norm: $1, start: word.start + span * Double($0),
                    end: word.start + span * Double($0 + 1), isFinal: isFinal)
            }
        }
    }

    /// Lower-cased alphanumeric tokens of `text`, with apostrophes removed and every other
    /// character a separator.
    static func normalize(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var tokens: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" || scalar == "\u{02BC}" {
                continue
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
