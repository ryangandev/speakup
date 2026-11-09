import Foundation

// The Coaching report and the Comparison (architecture.md#coaching-report).

struct Dimension: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let answerFirst = Self(rawValue: "answer_first")
    static let layering = Self(rawValue: "layering")
    static let focus = Self(rawValue: "focus")
    static let concision = Self(rawValue: "concision")
    static let fluency = Self(rawValue: "fluency")
    static let close = Self(rawValue: "close")

    /// The six dimensions in the order product.md#grading lists them.
    static let all: [Dimension] = [.answerFirst, .layering, .focus, .concision, .fluency, .close]
}

struct Level: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let strong = Self(rawValue: "strong")
    static let okay = Self(rawValue: "okay")
    static let needsWork = Self(rawValue: "needs_work")
}

struct OutlineRole: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let main = Self(rawValue: "main")
    static let support = Self(rawValue: "support")
    static let example = Self(rawValue: "example")
    static let aside = Self(rawValue: "aside")
    static let close = Self(rawValue: "close")
}

struct FocusOutcome: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let improved = Self(rawValue: "improved")
    static let partlyImproved = Self(rawValue: "partly_improved")
    static let notImproved = Self(rawValue: "not_improved")
    static let notApplicable = Self(rawValue: "not_applicable")
}

struct Change: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let better = Self(rawValue: "better")
    static let same = Self(rawValue: "same")
    static let worse = Self(rawValue: "worse")
    static let info = Self(rawValue: "info")
}

/// A quote with its half-open word range and, in a stored report, its audio times.
struct Anchor: Codable, Hashable, Sendable {
    let quote: String
    let wordStart: Int
    let wordEnd: Int
    let start: Double
    let end: Double
}

struct CoachingReport: Codable, Hashable, Sendable {
    let schemaVersion: String
    let takeId: String
    let createdAt: Date
    let model: String
    let rubricVersion: String
    let promptVersion: String
    let verdict: String
    let strength: Strength
    let focus: [FocusItem]
    let dimensions: Dimensions
    let outline: Outline
    let referenceVersion: ReferenceVersion
    let fillerRulings: [FillerRuling]
    let annotations: [Annotation]
    let comparison: CoachingComparison?
}

struct Strength: Codable, Hashable, Sendable {
    let dimension: Dimension
    let point: String
    let anchor: Anchor
}

struct FocusItem: Codable, Hashable, Sendable {
    let dimension: Dimension
    let title: String
    let problem: String
    let evidence: [Anchor]
    let instruction: String
}

struct DimensionResult: Codable, Hashable, Sendable {
    let level: Level
    let evidence: String
}

struct Dimensions: Codable, Hashable, Sendable {
    let answerFirst: DimensionResult
    let layering: DimensionResult
    let focus: DimensionResult
    let concision: DimensionResult
    let fluency: DimensionResult
    let close: DimensionResult

    /// The six rows in display order.
    var rows: [(dimension: Dimension, result: DimensionResult)] {
        [
            (.answerFirst, answerFirst), (.layering, layering), (.focus, focus),
            (.concision, concision), (.fluency, fluency), (.close, close),
        ]
    }
}

struct Outline: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        let summary: String
        let role: OutlineRole
        let wordStart: Int
        let wordEnd: Int
    }

    let mainPoint: String
    let mainPointFirst: Bool
    let points: [Point]
}

struct ReferenceVersion: Codable, Hashable, Sendable {
    let text: String
    let structure: String
}

struct FillerRuling: Codable, Hashable, Sendable {
    let eventId: String
    let isFiller: Bool
}

struct Annotation: Codable, Hashable, Sendable {
    let type: EventType
    let wordStart: Int
    let wordEnd: Int
    let note: String
}

/// The retry judgment inside a coaching report.
struct CoachingComparison: Codable, Hashable, Sendable {
    struct Outcome: Codable, Hashable, Sendable {
        let previousFocusIndex: Int
        let outcome: FocusOutcome
        let evidence: String
        let anchor: Anchor?
    }

    let summary: String
    let focusOutcomes: [Outcome]
}

/// `GET /v1/takes/{id}/comparison`: composed by the server from both takes.
struct Comparison: Codable, Hashable, Sendable {
    struct FocusOutcomeItem: Codable, Hashable, Sendable {
        let title: String
        let dimension: Dimension
        let outcome: FocusOutcome
        let evidence: String
        let anchor: Anchor?
    }

    struct DimensionChange: Codable, Hashable, Sendable {
        let dimension: Dimension
        let before: Level
        let after: Level
        let change: Change
    }

    struct MetricChange: Codable, Hashable, Sendable {
        let metric: String
        let label: String
        let unit: String
        let before: Double?
        let after: Double?
        let change: Change
    }

    let takeId: String
    let previousTakeId: String
    let attempt: Int
    let previousAttempt: Int
    let coachingStatus: CoachingStatus
    let summary: String?
    let focusOutcomes: [FocusOutcomeItem]
    let dimensionChanges: [DimensionChange]
    let metricChanges: [MetricChange]
}
