import Foundation

/// The kinds of mark the annotated transcript draws. Several event types share a kind
/// (both filler types are fillers); unknown event types get no mark and show as plain text.
enum TranscriptMarkKind: String, CaseIterable, Hashable, Sendable {
    case filler, repetition, restart, block, boundaryPause, offTopic

    init?(event: TranscriptEvent) {
        switch event.type {
        case .filledPause: self = .filler
        case .lexicalFiller:
            guard event.isFiller == true else { return nil }
            self = .filler
        case .repetition: self = .repetition
        case .restart: self = .restart
        case .block: self = .block
        case .boundaryPause: self = .boundaryPause
        case .offTopic: self = .offTopic
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .filler: return "Filler"
        case .repetition: return "Repetition"
        case .restart: return "Restart"
        case .block: return "Block"
        case .boundaryPause: return "Pause at a boundary"
        case .offTopic: return "Off topic"
        }
    }

    /// The legend's one-line explanation.
    var legend: String {
        switch self {
        case .filler: return "Um, uh, or a word like \"like\" used as a filler"
        case .repetition: return "Words said twice"
        case .restart: return "A broken-off word or abandoned phrase"
        case .block: return "A pause inside a phrase"
        case .boundaryPause: return "A normal pause between sentences or clauses"
        case .offTopic: return "A stretch that does not answer the question"
        }
    }
}

/// One mark in the transcript, with the sentence shown when it is tapped.
struct TranscriptMark: Hashable, Identifiable, Sendable {
    let event: TranscriptEvent
    let kind: TranscriptMarkKind

    var id: String { event.id }

    var title: String {
        switch kind {
        case .block, .boundaryPause:
            return "\(kind.label), \(Format.seconds(event.duration))"
        default:
            return kind.label
        }
    }

    var explanation: String {
        if let note = event.note, !note.isEmpty { return note }
        switch (event.type, event.reason) {
        case (.filledPause, _):
            return "A filled pause. Fillers count toward fillers per 100 words."
        case (.lexicalFiller, _):
            return "Used as a filler here, not for its meaning."
        case (.repetition, "phrase"?):
            return "A phrase said twice in a row."
        case (.repetition, _):
            return "A word said twice in a row."
        case (.restart, "cutoff"?):
            return "A word broken off before it was finished."
        case (.restart, "abandoned_phrase"?):
            return "A phrase started and dropped for a new one."
        case (.restart, "self_correction"?):
            return "A self-correction mid-sentence."
        case (.restart, _):
            return "A restart."
        case (.block, "before_filler"?):
            return "A silence inside a phrase, followed by a filler."
        case (.block, "before_restart"?):
            return "A silence inside a phrase, followed by a restart."
        case (.block, _):
            return "A silence inside a phrase, where a listener expects you to keep going."
        case (.boundaryPause, "clause"?):
            return "A pause between clauses. This is normal and not counted as a problem."
        case (.boundaryPause, _):
            return "A pause between sentences. This is normal and not counted as a problem."
        case (.offTopic, _):
            return "This part does not answer the question."
        default:
            return kind.legend
        }
    }
}

/// What the transcript draws, in reading order: words, and pauses between them.
/// `joinsPrevious` is true for Chinese text that follows Chinese text, which takes no space.
enum TranscriptToken: Hashable, Identifiable, Sendable {
    case word(index: Int, text: String, start: Double, marks: [TranscriptMark], joinsPrevious: Bool)
    case pause(TranscriptMark)

    var id: String {
        switch self {
        case .word(let index, _, _, _, _): return "w\(index)"
        case .pause(let mark): return "p\(mark.event.id)"
        }
    }
}

enum TranscriptLayout {
    /// Builds the tokens from a finalized analysis. Point events (pauses) go into the gap
    /// before their word; range events mark every word they cover. Events whose ranges fall
    /// outside the word list are dropped instead of crashing.
    static func tokens(for analysis: Analysis) -> [TranscriptToken] {
        let words = analysis.words
        var marksByWord = [[TranscriptMark]](repeating: [], count: words.count)
        var pausesBefore = [Int: [TranscriptMark]]()

        for event in analysis.events {
            guard let kind = TranscriptMarkKind(event: event) else { continue }
            let mark = TranscriptMark(event: event, kind: kind)
            if event.isPoint {
                guard event.wordStart >= 0, event.wordStart <= words.count else { continue }
                pausesBefore[event.wordStart, default: []].append(mark)
            } else {
                let lower = max(0, event.wordStart)
                let upper = min(words.count, event.wordEnd)
                guard lower < upper else { continue }
                for index in lower..<upper { marksByWord[index].append(mark) }
            }
        }

        var tokens: [TranscriptToken] = []
        tokens.reserveCapacity(words.count + pausesBefore.count)
        for (index, word) in words.enumerated() {
            for pause in pausesBefore[index] ?? [] { tokens.append(.pause(pause)) }
            let marks = marksByWord[index]
            // Chinese comes one character per word: a marked run such as 那个 becomes one token,
            // so its mark is drawn once, and plain characters sit next to each other with no gap.
            if case .word(let first, let text, let start, let previousMarks, let joins)? = tokens.last,
                joinsWithoutSpace(text, word.text)
            {
                if !marks.isEmpty, marks == previousMarks {
                    tokens[tokens.count - 1] = .word(
                        index: first, text: text + word.text, start: start, marks: marks, joinsPrevious: joins)
                    continue
                }
                tokens.append(.word(index: index, text: word.text, start: word.start, marks: marks, joinsPrevious: true))
                continue
            }
            tokens.append(.word(index: index, text: word.text, start: word.start, marks: marks, joinsPrevious: false))
        }
        for pause in pausesBefore[words.count] ?? [] { tokens.append(.pause(pause)) }
        return tokens
    }

    /// The mark kinds present, for the legend.
    static func kindsPresent(in analysis: Analysis) -> [TranscriptMarkKind] {
        let present = Set(analysis.events.compactMap(TranscriptMarkKind.init(event:)))
        return TranscriptMarkKind.allCases.filter(present.contains)
    }

    /// Every counted filler with its time, for the expandable fillers row.
    static func fillers(in analysis: Analysis) -> [(event: TranscriptEvent, text: String)] {
        analysis.events.filter(\.isCountedFiller).map { event in
            let lower = max(0, event.wordStart)
            let upper = min(analysis.words.count, event.wordEnd)
            let text = lower < upper
                ? join(analysis.words[lower..<upper].map(\.text)) : "filler"
            return (event, text)
        }
    }

    /// Words as one string: a space between words, none between Chinese characters.
    static func join(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            if !result.isEmpty, !joinsWithoutSpace(result, text) { result += " " }
            result += text
        }
        return result
    }

    /// True when `left` ends and `right` starts with Chinese text, including its punctuation.
    static func joinsWithoutSpace(_ left: String, _ right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        return isCJK(last) && isCJK(first)
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK punctuation: 。、「」
            0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,  // Han
            0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF5B...0xFF65:  // Full-width punctuation: ，！？：；（）
            return true
        default:
            return false
        }
    }
}
