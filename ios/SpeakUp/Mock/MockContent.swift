#if DEBUG
import Foundation

/// Builds full, self-consistent Analysis and Coaching documents for the mock server, so the
/// report can be exercised end to end. The contract's own examples are cut short (their
/// events point past the 18 words they include), so they cannot drive a whole screen.
enum MockContent {
    /// One piece of a scripted answer.
    enum Piece {
        case words(String)
        case filled(String)
        case lexical(String, isFiller: Bool)
        case repeated(String)
        case restart(String, cut: String)
        case block(Double, reason: String)
        case boundary(Double, reason: String)
        case offTopicStart
        case offTopicEnd
    }

    struct Script {
        let pieces: [Piece]
        let pitch: Metrics.Pitch?
        let volume: Metrics.Volume?
        let signs: Bool
    }

    /// Attempt 1, 3, ...: a messy answer with every kind of mark.
    static let messy = Script(
        pieces: [
            .lexical("So", isFiller: true), .filled("um"), .restart("we", cut: "nee-"),
            .words("we picked Postgres because,"), .lexical("like,", isFiller: true),
            .block(1.1, reason: "inside_phrase"),
            .words("the reporting queries need joins."), .boundary(0.7, reason: "sentence"),
            .filled("Uh"), .repeated("the"), .words("team also knows Postgres better than Dynamo, and we had,"),
            .filled("um,"), .block(0.9, reason: "before_filler"), .words("a deadline."),
            .boundary(0.6, reason: "sentence"), .offTopicStart,
            .words("Back when I was on the old team we did a DynamoDB migration and it took,"),
            .lexical("you know,", isFiller: true),
            .words("months and it was honestly"), .lexical("kind of", isFiller: false),
            .words("painful for everybody involved."), .offTopicEnd,
            .boundary(0.8, reason: "sentence"), .lexical("So", isFiller: true),
            .words("yeah, that's"), .lexical("kind of", isFiller: true), .words("it."),
        ],
        pitch: Metrics.Pitch(medianHz: 121.4, variationSt: 2.3, rangeSt: 9.8, byQuarterMedianHz: [118.2, 120.5, 122.0, 125.9]),
        volume: Metrics.Volume(medianDb: 61.2, variationDb: 4.1, byQuarterMedianDb: [60.8, 61.5, 61.0, 61.9]),
        signs: true)

    /// Attempt 2, 4, ...: a cleaner retry.
    static let clean = Script(
        pieces: [
            .words("We chose Postgres for billing."), .boundary(0.6, reason: "sentence"),
            .words("Two reasons."), .boundary(0.5, reason: "sentence"),
            .words("First, billing reports join invoices, customers and plans, and joins are painful in DynamoDB."),
            .boundary(0.7, reason: "sentence"),
            .words("Second, an invoice and its ledger entries must change together, so,"),
            .lexical("like,", isFiller: true), .words("we need transactions."),
            .boundary(0.6, reason: "sentence"), .filled("Um"),
            .words("the cost is that we scale writes ourselves,"), .boundary(0.4, reason: "clause"),
            .words("which is fine at our volume for the next two years."), .boundary(0.5, reason: "sentence"),
            .lexical("So", isFiller: true), .words("yeah,"), .block(0.8, reason: "inside_phrase"),
            .words("that's it."),
        ],
        pitch: Metrics.Pitch(medianHz: 119.0, variationSt: 2.6, rangeSt: 10.4, byQuarterMedianHz: [118.0, 119.2, 119.8, 120.1]),
        volume: Metrics.Volume(medianDb: 61.5, variationDb: 4.0, byQuarterMedianDb: [61.0, 61.4, 61.6, 61.7]),
        signs: false)

    static func script(forAttempt attempt: Int) -> Script {
        attempt % 2 == 1 ? messy : clean
    }

    // MARK: Analysis

    static func analysis(takeID: String, attempt: Int, durationS: Double, coached: Bool, date: Date) -> Analysis {
        let script = script(forAttempt: attempt)
        var words: [Word] = []
        var events: [TranscriptEvent] = []
        var time = 0.84
        var offTopicStart: Int?
        var offTopicRange: (Int, Int, Double, Double)?

        func addWord(_ text: String, kind: WordKind = .word, cutoff: Bool = false) -> Int {
            let index = words.count
            let letters = Double(text.filter(\.isLetter).count)
            let length = 0.12 + 0.045 * letters
            let norm = text.lowercased().filter { $0.isLetter || $0 == "'" || $0 == " " }
            words.append(
                Word(i: index, text: text, norm: norm, start: rounded(time), end: rounded(time + length),
                     confidence: 0.95, kind: kind, cutoff: cutoff))
            time += length + 0.08
            return index
        }

        func addEvent(
            _ type: EventType, from first: Int, to end: Int, start: Double, endTime: Double,
            reason: String? = nil, repair: Int? = nil, isFiller: Bool? = nil, note: String? = nil,
            source: EventSource = .rules
        ) {
            let prefix = source == .coaching ? "c" : "e"
            let count = events.filter { $0.source == source }.count
            events.append(
                TranscriptEvent(
                    id: "\(prefix)\(count)", type: type, start: rounded(start), end: rounded(endTime),
                    wordStart: first, wordEnd: end, source: source, reason: reason, repairWord: repair,
                    isFiller: isFiller, fillerResolution: isFiller == nil ? nil : (coached ? "coaching" : "rules"),
                    note: note))
        }

        for piece in script.pieces {
            switch piece {
            case .words(let text):
                for word in text.split(separator: " ") { _ = addWord(String(word)) }
            case .filled(let text):
                let index = addWord(text, kind: .filledPause)
                addEvent(.filledPause, from: index, to: index + 1, start: words[index].start, endTime: words[index].end)
            case .lexical(let text, let isFiller):
                let parts = text.split(separator: " ").map(String.init)
                let first = words.count
                for part in parts { _ = addWord(part) }
                // Without coaching, rules leave "kind of" undecided as a filler.
                let judged = coached ? isFiller : (text.lowercased().hasPrefix("kind") ? false : isFiller)
                addEvent(
                    .lexicalFiller, from: first, to: words.count, start: words[first].start,
                    endTime: words[words.count - 1].end, isFiller: judged)
            case .repeated(let text):
                let first = addWord(text)
                let second = addWord(text)
                addEvent(
                    .repetition, from: first, to: second + 1, start: words[first].start,
                    endTime: words[second].end, reason: "word", repair: second)
            case .restart(let text, let cut):
                let first = addWord(text)
                let cutIndex = addWord(cut, cutoff: true)
                time += 0.35
                addEvent(
                    .restart, from: first, to: cutIndex + 1, start: words[first].start,
                    endTime: words[cutIndex].end, reason: "cutoff", repair: cutIndex + 1)
            case .block(let seconds, let reason):
                let start = time - 0.08
                time += seconds
                addEvent(.block, from: words.count, to: words.count, start: start, endTime: start + seconds, reason: reason)
            case .boundary(let seconds, let reason):
                let start = time - 0.08
                time += seconds
                addEvent(.boundaryPause, from: words.count, to: words.count, start: start, endTime: start + seconds, reason: reason)
            case .offTopicStart:
                offTopicStart = words.count
            case .offTopicEnd:
                if let start = offTopicStart {
                    offTopicRange = (start, words.count, words[start].start, words[words.count - 1].end)
                }
            }
        }
        if coached, let range = offTopicRange {
            addEvent(
                .offTopic, from: range.0, to: range.1, start: range.2, endTime: range.3,
                note: "The story about the old team's DynamoDB migration does not answer why we chose Postgres.",
                source: .coaching)
        }
        events.sort { $0.start < $1.start }

        let wordCount = words.filter { $0.kind == .word }.count
        let filled = events.filter { $0.type == .filledPause }.count
        let lexical = events.filter { $0.type == .lexicalFiller && $0.isFiller == true }.count
        let candidates = events.filter { $0.type == .lexicalFiller }.count
        let blocks = events.filter { $0.type == .block }
        let boundaries = events.filter { $0.type == .boundaryPause }.map(\.duration).sorted()
        let speaking = (words.last?.end ?? 0) - (words.first?.start ?? 0)
        let voiced = speaking - blocks.map(\.duration).reduce(0, +) - boundaries.reduce(0, +)
        let wpmVoiced = Double(wordCount) / max(voiced, 1) * 60
        let quarters = script.signs
            ? [wpmVoiced * 0.92, wpmVoiced * 0.97, wpmVoiced * 1.01, wpmVoiced * 1.09]
            : [wpmVoiced * 0.99, wpmVoiced, wpmVoiced * 1.01, wpmVoiced]

        let metrics = Metrics(
            durationS: max(durationS, time + 0.5), speechStartS: 0.84, speakingS: rounded(speaking),
            voicedS: rounded(voiced), wordCount: wordCount,
            fillers: Metrics.Fillers(
                filledPauses: filled, lexical: lexical, lexicalCandidates: candidates,
                per100Words: rounded(Double(filled + lexical) / Double(max(wordCount, 1)) * 100),
                resolution: coached ? "coaching" : "rules"),
            blocks: Metrics.Blocks(
                count: blocks.count, perMinute: rounded(Double(blocks.count) / max(speaking, 1) * 60),
                longestS: rounded(blocks.map(\.duration).max() ?? 0), totalS: rounded(blocks.map(\.duration).reduce(0, +))),
            boundaryPauses: Metrics.BoundaryPauses(
                count: boundaries.count, medianS: boundaries.isEmpty ? nil : boundaries[boundaries.count / 2]),
            restarts: events.filter { $0.type == .restart }.count,
            repetitions: events.filter { $0.type == .repetition }.count,
            pace: Metrics.Pace(
                wpmVoiced: rounded(wpmVoiced), wpmSpeaking: rounded(Double(wordCount) / max(speaking, 1) * 60),
                byQuarterWpm: quarters.map(rounded)),
            pitch: script.pitch, volume: script.volume)

        let signs = script.signs
            ? [NervousnessSign(
                type: .paceRise, start: rounded(speaking * 0.75), end: rounded(speaking), value: 18.6,
                detail: "Pace rose 19% from the first quarter to the last (\(Int(quarters[0])) to \(Int(quarters[3])) words per minute).")]
            : []

        return Analysis(
            schemaVersion: "analysis/1", takeId: takeID, createdAt: date, coachingApplied: coached,
            provenance: Provenance(
                pipelineVersion: "0.2.0",
                stt: .init(engine: "crisperwhisper", model: "nyrahealth/CrisperWhisper", version: "2.0.4"),
                vad: .init(engine: "silero-vad", model: nil, version: "6.2.0"),
                prosody: .init(engine: "parselmouth", model: nil, version: "0.4.6"),
                thresholdsVersion: "thresholds/0"),
            words: words, events: events, metrics: metrics, nervousnessSigns: signs)
    }

    // MARK: Coaching

    static func coaching(
        takeID: String, attempt: Int, analysis: Analysis, previous: CoachingReport?, date: Date
    ) -> CoachingReport {
        let words = analysis.words
        func anchor(_ quote: String) -> Anchor {
            let target = quote.lowercased().split(separator: " ").map { $0.filter(\.isLetter) }
            let norms = words.map { $0.text.lowercased().filter(\.isLetter) }
            var start = 0
            if target.count <= norms.count {
                for index in 0...(norms.count - target.count) where Array(norms[index..<index + target.count]) == target {
                    start = index
                    break
                }
            }
            let end = min(words.count, start + max(1, target.count))
            return Anchor(quote: quote, wordStart: start, wordEnd: end, start: words[start].start, end: words[end - 1].end)
        }
        func outcomes(_ values: [FocusOutcome]) -> CoachingComparison? {
            guard let previous else { return nil }
            return CoachingComparison(
                summary: attempt % 2 == 0
                    ? "The reasons are now numbered and the long block is gone; the ending still trails off."
                    : "The structure slipped back: the reasons ran together again and the old story came back.",
                focusOutcomes: previous.focus.indices.map { index in
                    CoachingComparison.Outcome(
                        previousFocusIndex: index, outcome: values[min(index, values.count - 1)],
                        evidence: index == 0
                            ? (attempt % 2 == 0 ? "You announced two reasons and numbered them." : "The reasons came as one list again.")
                            : "Fewer fillers before the main point, but one block is still there.",
                        anchor: index == 0 && attempt % 2 == 0 ? anchor("Two reasons.") : nil)
                })
        }

        if attempt % 2 == 1 {
            return CoachingReport(
                schemaVersion: "coaching/1", takeId: takeID, createdAt: date, model: "claude-opus-5-5",
                rubricVersion: "rubric/1", promptVersion: "coach-prompt/1",
                verdict: "You named the decision in the first sentence, which is right, but your reasons came out as one long run and the answer trailed off at the end. Clear enough to follow, not yet crisp.",
                strength: Strength(
                    dimension: .answerFirst,
                    point: "You said what was chosen before explaining anything, so the listener knew where you were going.",
                    anchor: anchor("we picked Postgres because")),
                focus: [
                    FocusItem(
                        dimension: .layering, title: "Number your reasons",
                        problem: "Your reasons came as one unbroken list, so it was hard to tell which one mattered most.",
                        evidence: [anchor("the reporting queries need joins")],
                        instruction: "Say how many reasons there are, then give them in order of weight: \"Two reasons. First, reporting needs joins. Second, ...\""),
                    FocusItem(
                        dimension: .fluency, title: "Stop silently, not mid-phrase",
                        problem: "You froze for over a second in the middle of your main reason, right after a filler.",
                        evidence: [anchor("because like the")],
                        instruction: "When you need a moment, finish the clause, pause in silence, and start the reason fresh."),
                ],
                dimensions: Dimensions(
                    answerFirst: .init(level: .strong, evidence: "The decision is in the first sentence."),
                    layering: .init(level: .needsWork, evidence: "No signposts; the reasons run together."),
                    focus: .init(level: .okay, evidence: "One long aside about the old team's migration did not serve the question."),
                    concision: .init(level: .okay, evidence: "The joins point was made twice in slightly different words."),
                    fluency: .init(level: .okay, evidence: "Fillers are in the normal range; one long block before the main reason."),
                    close: .init(level: .needsWork, evidence: "The answer ended with \"so yeah, that's kind of it\".")),
                outline: Outline(
                    mainPoint: "We chose Postgres because billing reports need joins and the team knows it.",
                    mainPointFirst: true,
                    points: [
                        .init(summary: "Chose Postgres over DynamoDB", role: .main, wordStart: 0, wordEnd: 8),
                        .init(summary: "Reporting queries need joins", role: .support, wordStart: 8, wordEnd: 14),
                        .init(summary: "The team knows Postgres better", role: .support, wordStart: 14, wordEnd: 30),
                        .init(summary: "Story about the old team's DynamoDB migration", role: .aside, wordStart: 30, wordEnd: 50),
                        .init(summary: "Trails off with \"so yeah\"", role: .close, wordStart: 50, wordEnd: words.count),
                    ]),
                referenceVersion: ReferenceVersion(
                    text: "We chose Postgres for billing. Two reasons.\n\nFirst, billing reports join invoices, customers and plans, and joins are painful in DynamoDB. Second, an invoice and its ledger entries must change together, so we need transactions.\n\nThe cost is that we scale writes ourselves, which is fine at our volume for the next two years.",
                    structure: "Decision, two numbered reasons, the trade-off."),
                fillerRulings: analysis.events.filter { $0.type == .lexicalFiller }.map {
                    FillerRuling(eventId: $0.id, isFiller: $0.isFiller ?? false)
                },
                annotations: analysis.events.filter { $0.source == .coaching }.map {
                    Annotation(type: $0.type, wordStart: $0.wordStart, wordEnd: $0.wordEnd, note: $0.note ?? "")
                },
                comparison: outcomes([.notImproved, .partlyImproved]))
        }

        return CoachingReport(
            schemaVersion: "coaching/1", takeId: takeID, createdAt: date, model: "claude-opus-5-5",
            rubricVersion: "rubric/1", promptVersion: "coach-prompt/1",
            verdict: "Much clearer: the decision comes first and the reasons are numbered. The ending still fades out.",
            strength: Strength(
                dimension: .layering,
                point: "You announced two reasons and walked through them in order, so each one landed.",
                anchor: anchor("Two reasons.")),
            focus: [
                FocusItem(
                    dimension: .close, title: "Close on purpose",
                    problem: "After the trade-off you added \"so yeah\" and a pause instead of ending.",
                    evidence: [anchor("So yeah, that's it.")],
                    instruction: "End on the trade-off sentence and stop. Silence after the last point is fine."),
            ],
            dimensions: Dimensions(
                answerFirst: .init(level: .strong, evidence: "The decision is the first sentence."),
                layering: .init(level: .strong, evidence: "Two numbered reasons, then the trade-off."),
                focus: .init(level: .strong, evidence: "Every part serves the question."),
                concision: .init(level: .okay, evidence: "Tight, apart from the closing filler."),
                fluency: .init(level: .okay, evidence: "Two fillers and one short block near the end."),
                close: .init(level: .needsWork, evidence: "Trails off with \"so yeah\".")),
            outline: Outline(
                mainPoint: "We chose Postgres for billing, for joins and transactions.",
                mainPointFirst: true,
                points: [
                    .init(summary: "Chose Postgres for billing", role: .main, wordStart: 0, wordEnd: 5),
                    .init(summary: "Reports need joins", role: .support, wordStart: 7, wordEnd: 22),
                    .init(summary: "Invoices need transactions", role: .support, wordStart: 22, wordEnd: 37),
                    .init(summary: "Trade-off: scaling writes ourselves", role: .example, wordStart: 37, wordEnd: 57),
                    .init(summary: "Trails off with \"so yeah\"", role: .close, wordStart: 57, wordEnd: words.count),
                ]),
            referenceVersion: ReferenceVersion(
                text: "We chose Postgres for billing, for two reasons.\n\nFirst, reports join invoices, customers and plans. Second, invoices and ledger entries must change together.\n\nThe cost is scaling writes ourselves, which is fine for the next two years.",
                structure: "Decision, two numbered reasons, the trade-off, stop."),
            fillerRulings: analysis.events.filter { $0.type == .lexicalFiller }.map {
                FillerRuling(eventId: $0.id, isFiller: $0.isFiller ?? false)
            },
            annotations: [],
            comparison: outcomes([.improved, .partlyImproved]))
    }

    // MARK: Comparison

    static func comparison(
        take: Take, previous: Take, analysis: Analysis, previousAnalysis: Analysis,
        coaching: CoachingReport?, previousCoaching: CoachingReport?
    ) -> Comparison {
        let bothCoached = coaching != nil && previousCoaching != nil
        let focusOutcomes: [Comparison.FocusOutcomeItem] =
            bothCoached
            ? (coaching?.comparison?.focusOutcomes ?? []).compactMap { outcome in
                guard let item = previousCoaching?.focus[safe: outcome.previousFocusIndex] else { return nil }
                return .init(
                    title: item.title, dimension: item.dimension, outcome: outcome.outcome,
                    evidence: outcome.evidence, anchor: outcome.anchor)
            }
            : []
        let dimensionChanges: [Comparison.DimensionChange] =
            bothCoached
            ? zip(previousCoaching!.dimensions.rows, coaching!.dimensions.rows).map { before, after in
                let rank: (Level) -> Int = { $0 == .strong ? 2 : ($0 == .okay ? 1 : 0) }
                let change: Change = rank(after.result.level) > rank(before.result.level)
                    ? .better : (rank(after.result.level) < rank(before.result.level) ? .worse : .same)
                return .init(dimension: before.dimension, before: before.result.level, after: after.result.level, change: change)
            }
            : []
        let before = previousAnalysis.metrics
        let after = analysis.metrics
        func graded(_ metric: String, _ label: String, _ unit: String, _ old: Double, _ new: Double, rate: Bool) -> Comparison.MetricChange {
            let same = rate ? abs(new - old) < max(old, 0.0001) * 0.1 : new == old
            return .init(metric: metric, label: label, unit: unit, before: old, after: new, change: same ? .same : (new < old ? .better : .worse))
        }
        let metricChanges: [Comparison.MetricChange] = [
            graded("fillers_per_100_words", "Fillers per 100 words", "per 100 words", before.fillers.per100Words, after.fillers.per100Words, rate: true),
            graded("blocks", "Blocks", "count", Double(before.blocks.count), Double(after.blocks.count), rate: false),
            graded("restarts", "Restarts", "count", Double(before.restarts), Double(after.restarts), rate: false),
            graded("repetitions", "Repetitions", "count", Double(before.repetitions), Double(after.repetitions), rate: false),
            .init(metric: "wpm_voiced", label: "Pace", unit: "words per minute", before: before.pace.wpmVoiced, after: after.pace.wpmVoiced, change: .info),
            .init(metric: "duration_s", label: "Length", unit: "seconds", before: before.durationS, after: after.durationS, change: .info),
            .init(metric: "pitch_variation_st", label: "Pitch variation", unit: "semitones", before: before.pitch?.variationSt, after: after.pitch?.variationSt, change: .info),
            .init(metric: "volume_variation_db", label: "Volume variation", unit: "dB", before: before.volume?.variationDb, after: after.volume?.variationDb, change: .info),
        ]
        return Comparison(
            takeId: take.id, previousTakeId: previous.id, attempt: take.attempt, previousAttempt: previous.attempt,
            coachingStatus: take.coachingStatus, summary: bothCoached ? coaching?.comparison?.summary : nil,
            focusOutcomes: focusOutcomes, dimensionChanges: dimensionChanges, metricChanges: metricChanges)
    }

    // MARK: Questions

    static let questions: [Question] = [
        Question(text: "Your manager asks why the search rewrite slipped two weeks. Explain what happened and what you are doing about it.", category: .status, targetSeconds: 90),
        Question(text: "Why did you split the notifications service out of the monolith instead of fixing it in place?", category: .decision, targetSeconds: 90),
        Question(text: "A product manager wants a feature by Friday that you think needs two weeks. Push back.", category: .pushback, targetSeconds: 60),
        Question(text: "Why did we choose Postgres over DynamoDB for the billing service?", category: .decision, targetSeconds: 90),
        Question(text: "Explain what a feature flag is to a new teammate who has never used one.", category: .explain, targetSeconds: 90),
        Question(text: "Give a status update on a migration that is half done and behind schedule.", category: .status, targetSeconds: 90),
        Question(text: "A senior engineer wants to rewrite the payments module in a new language. Push back.", category: .pushback, targetSeconds: 60),
        Question(text: "Explain how the deploy pipeline gets code from a merged pull request to production.", category: .explain, targetSeconds: 120),
        Question(text: "Why did you pick a queue instead of calling the service directly?", category: .decision, targetSeconds: 90),
        Question(text: "Your team missed the sprint goal. Give the update at stand-up.", category: .status, targetSeconds: 60),
        Question(text: "Explain the difference between a cache miss and a cache stampede to a product manager.", category: .explain, targetSeconds: 90),
        Question(text: "Leadership asks you to cut testing time in half. Push back on the request.", category: .pushback, targetSeconds: 90),
    ]

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
