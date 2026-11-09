import Foundation

/// Every sentence the app says in a drive (product.md#driving-mode).
///
/// Pure: strings in, strings out, so the wording is tested without audio. The wording is
/// direct and short, like the rest of the feedback (product.md#feedback): the first focus
/// item only, nothing nitpicky.
///
/// Feedback is a function of the take and its report alone, so it can be spoken at any
/// time, not only right after the take. A late-feedback intro would be one more line here.
/// `Feedback.segments` and `ReferenceReading.segments` are the units speech output can skip
/// between, which is the seam for interrupting speech.
enum DriveScript {
    // MARK: - Start and nervousness

    static let greeting = "SpeakUp drive."
    static let nervousnessBeforeQuestion = "How nervous are you, one to five?"
    static let nervousnessAfterQuestion = "How nervous are you now, one to five?"
    static let nervousnessReask = "Say a number from one to five, or say skip."

    /// The opening line: greeting and the first question in one utterance.
    static var opening: String { "\(greeting) \(nervousnessBeforeQuestion)" }

    /// Confirms a rating; nil means skipped.
    static func nervousnessRecorded(_ rating: Int?) -> String {
        guard let rating, (1...5).contains(rating) else { return "Skipped." }
        return "Nervousness \(numberWords[rating])."
    }

    // MARK: - Prompt and recording

    /// Reads a question and tells the speaker what happens next. A retry says so first.
    static func promptReadOut(question: String, isRetry: Bool = false) -> String {
        let text = sentence(speakable(question))
        return (isRetry ? "Same question. " : "") + "\(text) Answer after the tone."
    }

    static let preparingPrompt = "One moment."
    static let takeEnded = "Got it."
    /// The microphone changed mid-answer (car audio connecting, say), which ends the take.
    static let microphoneChanged = "The microphone changed, so I stopped there. Got it."
    static let timeLimit = "That's the time limit."

    // MARK: - Waiting

    static let stillWorking = "Still working."

    /// Waiting gave up (the take keeps processing and shows in History at home).
    static let waitTimedOut = "Feedback on that one will come later. Say: next, again, or stop."

    // MARK: - Feedback

    /// What kind of feedback a take got, which decides what the speaker can say next.
    enum FeedbackKind: Sendable, Equatable {
        /// Verdict, strength and focus from a coaching report.
        case coached
        /// Coaching is unavailable or failed: a few metrics in plain words.
        case metricsOnly
        /// The take was not understood as an answer (too little speech).
        case noSpeech
        /// Processing failed; the take is kept for home.
        case failed
        /// The server could not be reached, or the result is not ready yet.
        case later
    }

    struct Feedback: Sendable, Equatable {
        var kind: FeedbackKind
        /// The sentences to say, in order.
        var segments: [String]
        /// The commands on offer afterwards.
        var options: String

        var body: String { segments.joined(separator: " ") }
        /// Everything, as one utterance.
        var spoken: String { "\(body) \(options)" }
    }

    /// Feedback for a finished take.
    ///
    /// - Parameters:
    ///   - report: the take's report, when it was fetched. Without it a take that has
    ///     coaching still gets its summary verdict and first focus title.
    ///   - comparison: the retry comparison, when the take is an attempt after the first.
    static func feedback(for take: Take, report: TakeReport?, comparison: Comparison? = nil)
        -> Feedback
    {
        if take.status == .failed {
            if take.error?.code == .noSpeech { return noAnswer }
            return Feedback(
                kind: .failed,
                segments: ["That one didn't process. Your answer is saved for when you're home."],
                options: "Say: again, next, or stop.")
        }
        guard take.status == .done else { return later }

        if take.coachingStatus == .done {
            if let coaching = report?.coaching {
                return coached(coaching, comparison: comparison)
            }
            if let summary = take.summary, summary.verdict != nil {
                return coached(summary: summary, comparison: comparison)
            }
            return later
        }
        if take.coachingStatus == .pending { return later }
        return metricsOnly(take.summary)
    }

    /// No answer: the server found too little speech, or the take held no audio at all
    /// (`DriveAudio.TakeEnd.empty`).
    static var noAnswer: Feedback {
        Feedback(
            kind: .noSpeech, segments: ["I didn't catch an answer."],
            options: "Say: again, next, or stop.")
    }

    /// The take could not be written to the phone (`DriveAudio.TakeEnd.failed`), so nothing
    /// was kept.
    static var notSaved: Feedback {
        Feedback(
            kind: .failed, segments: ["I couldn't save that answer."],
            options: "Say: again, next, or stop.")
    }

    /// The server could not be reached, or the result is not ready: feedback comes later.
    static var offline: Feedback {
        Feedback(
            kind: .later,
            segments: [
                "I couldn't reach the server. Your answer is saved; feedback will come later."
            ],
            options: "Say: next, again, or stop.")
    }

    /// The server answered the upload with an error (it rejected the take, or failed). The
    /// take stays on the phone and is sent again later, but no feedback is promised.
    static var serverError: Feedback {
        Feedback(
            kind: .failed,
            segments: ["The server couldn't take that answer. It's saved on your phone."],
            options: "Say: next, again, or stop.")
    }

    /// The take is saved, but feedback is not ready.
    private static var later: Feedback {
        Feedback(
            kind: .later, segments: ["Feedback on that one will come later."],
            options: "Say: next, again, or stop.")
    }

    private static let coachedOptions =
        "Say: again, next, repeat that, better version, or stop."

    private static func coached(_ coaching: CoachingReport, comparison: Comparison?) -> Feedback {
        var segments: [String] = []
        let retrySummary = sentence(speakable(comparison?.summary ?? coaching.comparison?.summary ?? ""))
        let verdict = sentence(speakable(coaching.verdict))
        if !retrySummary.isEmpty {
            // A retry leads with what changed, then the verdict and the new focus. The
            // strength is left out: the comparison already says what got better.
            segments += [retrySummary, verdict]
        } else {
            let point = sentence(speakable(coaching.strength.point))
            segments += [verdict, point.isEmpty ? "" : "What worked: \(point)"]
        }
        if let focus = coaching.focus.first {
            segments.append(nextTime(title: focus.title, instruction: focus.instruction))
        }
        return feedback(coachedSegments: segments)
    }

    /// Coaching exists but the report was not fetched: the take summary has the verdict and
    /// the focus titles.
    private static func coached(summary: TakeSummary, comparison: Comparison?) -> Feedback {
        var segments = [
            sentence(speakable(comparison?.summary ?? "")),
            sentence(speakable(summary.verdict ?? "")),
        ]
        if let title = summary.focusTitles.first {
            segments.append(nextTime(title: title, instruction: ""))
        }
        return feedback(coachedSegments: segments)
    }

    /// Drops empty segments; a report with nothing speakable in it is not feedback.
    private static func feedback(coachedSegments: [String]) -> Feedback {
        let segments = coachedSegments.filter { !isBlank($0) }
        guard !segments.isEmpty else { return later }
        return Feedback(kind: .coached, segments: segments, options: coachedOptions)
    }

    /// "Next time: title. instruction.", or "" when there is neither.
    private static func nextTime(title: String, instruction: String) -> String {
        let parts = [title, instruction].map { sentence(speakable($0)) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "" : "Next time: " + parts.joined(separator: " ")
    }

    /// No coaching: two or three metrics in plain words, from the take's summary.
    private static func metricsOnly(_ summary: TakeSummary?) -> Feedback {
        var segments = ["No coaching right now."]
        var facts: [String] = []
        if let summary {
            if let fillers = summary.fillersPer100Words {
                let rounded = Int(fillers.rounded())
                if rounded == 0 {
                    facts.append("You used almost no filler words.")
                } else {
                    let noun = rounded == 1 ? "filler" : "fillers"
                    facts.append("You used about \(rounded) \(noun) per 100 words.")
                }
            }
            if let stalls = stallsSentence(blocks: summary.blocks, restarts: summary.restarts) {
                facts.append(stalls)
            }
            if let pace = summary.wpmVoiced {
                let rounded = Int((pace / 5).rounded()) * 5
                facts.append("You spoke at about \(rounded) words per minute.")
            }
        }
        if facts.isEmpty {
            segments.append("Your answer is saved for when you're home.")
        } else {
            segments += facts
        }
        return Feedback(
            kind: .metricsOnly, segments: segments, options: "Say: again, next, or stop.")
    }

    private static func stallsSentence(blocks: Int?, restarts: Int?) -> String? {
        // Only claim what is known: a missing count is never read as zero.
        switch (blocks, restarts) {
        case (nil, nil):
            return nil
        case (let stuck?, nil):
            return stuck > 0 ? "You got stuck mid-phrase \(times(stuck))." : "No long stalls."
        case (nil, let restarted?):
            return restarted > 0 ? "You restarted a sentence \(times(restarted))." : "No restarts."
        case (let stuck?, let restarted?):
            switch (stuck > 0, restarted > 0) {
            case (true, true):
                return "You got stuck mid-phrase \(times(stuck)) and restarted \(times(restarted))."
            case (true, false):
                return "You got stuck mid-phrase \(times(stuck))."
            case (false, true):
                return "You restarted a sentence \(times(restarted))."
            case (false, false):
                return "No long stalls or restarts."
            }
        }
    }

    // MARK: - Better version

    struct ReferenceReading: Sendable, Equatable {
        /// An introduction, then one segment per paragraph.
        var segments: [String]
        var options: String

        var body: String { segments.joined(separator: " ") }
        var spoken: String { "\(body) \(options)" }
    }

    /// The reference version on request, or a short answer when there is none.
    static func referenceVersion(report: TakeReport?) -> ReferenceReading {
        let options = "Say: again, next, or stop."
        guard let reference = report?.coaching?.referenceVersion, !isBlank(reference.text) else {
            return ReferenceReading(
                segments: ["There is no better version without coaching."], options: options)
        }
        let paragraphs = reference.text
            .components(separatedBy: "\n")
            .map { sentence(speakable($0)) }
            .filter { !$0.isEmpty }
        return ReferenceReading(
            segments: ["Here is a better version."] + paragraphs, options: options)
    }

    // MARK: - Commands, errors and the end

    /// What can be said between takes, for unrecognized speech.
    static let commandHelp = "You can say: again, next, repeat that, better version, or stop."
    static let nothingToRepeat = "There is nothing to repeat yet."
    static let cutOff = "Your answer was cut off and saved. Say: again, next, or stop."
    static let idleEnd = "I haven't heard anything, so I'm ending the drive."
    static let microphoneUnavailable = "I can't use the microphone, so I'm ending the drive."
    /// Speech kept being cut short (the audio restarting over and over).
    static let audioUnstable = "The audio keeps cutting out, so I'm ending the drive."
    static let commandsUnavailable =
        "Voice commands aren't available right now, so I'm ending the drive. Check SpeakUp when you're parked."
    static let noQuestions = "I have no questions right now, so I'm ending the drive."

    /// The closing line, with how many answers the drive saved.
    static func driveEnded(takes: Int) -> String {
        switch takes {
        case ..<1: "Drive ended."
        case 1: "Drive ended. One answer saved."
        default: "Drive ended. \(takes) answers saved."
        }
    }

    // MARK: - Text helpers

    private static let numberWords = ["zero", "one", "two", "three", "four", "five"]

    private static func times(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Server text is plain English meant to be read aloud, but it can quote what Ryan
    /// should say, with quotation marks and an ellipsis. Removes quotation marks and
    /// Markdown characters, turns an ellipsis into a pause, and collapses spaces.
    static func speakable(_ text: String) -> String {
        var result = text
        for character in ["\"", "\u{201C}", "\u{201D}", "`", "*", "#", "_"] {
            result = result.replacingOccurrences(of: character, with: "")
        }
        result = result.replacingOccurrences(of: "\u{2026}", with: "...")
        result = result.replacingOccurrences(
            of: #"\s*\.{3,}\s*"#, with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing comma or colon is what an ellipsis at the end leaves.
        while let last = result.last, ",:;".contains(last) { result.removeLast() }
        return result
    }

    /// Ends the text with sentence punctuation; empty stays empty.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
