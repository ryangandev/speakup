import Foundation

// The finalized Analysis document (architecture.md#analysis-output).

struct WordKind: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let word = Self(rawValue: "word")
    static let filledPause = Self(rawValue: "filled_pause")
    static let nonSpeech = Self(rawValue: "non_speech")
}

struct EventType: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let filledPause = Self(rawValue: "filled_pause")
    static let lexicalFiller = Self(rawValue: "lexical_filler")
    static let repetition = Self(rawValue: "repetition")
    static let restart = Self(rawValue: "restart")
    static let block = Self(rawValue: "block")
    static let boundaryPause = Self(rawValue: "boundary_pause")
    static let offTopic = Self(rawValue: "off_topic")
}

struct EventSource: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let rules = Self(rawValue: "rules")
    static let coaching = Self(rawValue: "coaching")
}

struct NervousnessSignType: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let paceRise = Self(rawValue: "pace_rise")
    static let blockCluster = Self(rawValue: "block_cluster")
    static let pitchRise = Self(rawValue: "pitch_rise")
}

struct Analysis: Codable, Hashable, Sendable {
    let schemaVersion: String
    let takeId: String
    let createdAt: Date
    let coachingApplied: Bool
    let provenance: Provenance?
    let words: [Word]
    let events: [TranscriptEvent]
    let metrics: Metrics
    let nervousnessSigns: [NervousnessSign]
    /// The take's language; for Chinese a "word" in the metrics is one character. Absent from
    /// servers that predate it, which means English.
    var language: SpeechLanguage? = nil

    var countsCharacters: Bool { language == .chinese }
}

struct Provenance: Codable, Hashable, Sendable {
    struct Component: Codable, Hashable, Sendable {
        let engine: String
        let model: String?
        let version: String?
    }

    let pipelineVersion: String
    let stt: Component
    let vad: Component?
    let prosody: Component?
    let thresholdsVersion: String
}

struct Word: Codable, Hashable, Sendable {
    let i: Int
    let text: String
    let norm: String
    let start: Double
    let end: Double
    let confidence: Double?
    let kind: WordKind
    let cutoff: Bool
}

/// One mark in the transcript. Every event type shares this flat shape.
struct TranscriptEvent: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let type: EventType
    let start: Double
    let end: Double
    /// Half-open word range; an empty range is the gap just before word `wordStart`.
    let wordStart: Int
    let wordEnd: Int
    let source: EventSource
    let reason: String?
    let repairWord: Int?
    let isFiller: Bool?
    let fillerResolution: String?
    let note: String?

    var isPoint: Bool { wordStart == wordEnd }
    var duration: Double { max(0, end - start) }

    /// Whether the event counts as a problem (the table in architecture.md#events).
    var isProblem: Bool {
        switch type {
        case .lexicalFiller: return isFiller == true
        case .boundaryPause: return false
        case .filledPause, .repetition, .restart, .block, .offTopic: return true
        default: return false
        }
    }

    /// Filled pauses, and lexical fillers judged to be fillers.
    var isCountedFiller: Bool {
        type == .filledPause || (type == .lexicalFiller && isFiller == true)
    }
}

struct Metrics: Codable, Hashable, Sendable {
    struct Fillers: Codable, Hashable, Sendable {
        let filledPauses: Int
        let lexical: Int
        let lexicalCandidates: Int
        let per100Words: Double
        let resolution: String
    }

    struct Blocks: Codable, Hashable, Sendable {
        let count: Int
        let perMinute: Double
        let longestS: Double
        let totalS: Double
    }

    struct BoundaryPauses: Codable, Hashable, Sendable {
        let count: Int
        let medianS: Double?
    }

    struct Pace: Codable, Hashable, Sendable {
        let wpmVoiced: Double
        let wpmSpeaking: Double
        let byQuarterWpm: [Double]
    }

    struct Pitch: Codable, Hashable, Sendable {
        let medianHz: Double
        let variationSt: Double
        let rangeSt: Double
        let byQuarterMedianHz: [Double]
    }

    struct Volume: Codable, Hashable, Sendable {
        let medianDb: Double
        let variationDb: Double
        let byQuarterMedianDb: [Double]
    }

    let durationS: Double
    let speechStartS: Double
    let speakingS: Double
    let voicedS: Double
    let wordCount: Int
    let fillers: Fillers
    let blocks: Blocks
    let boundaryPauses: BoundaryPauses
    let restarts: Int
    let repetitions: Int
    let pace: Pace
    let pitch: Pitch?
    let volume: Volume?
}

struct NervousnessSign: Codable, Hashable, Sendable {
    let type: NervousnessSignType
    let start: Double
    let end: Double
    let value: Double
    let detail: String
}
