import Foundation

/// Text for numbers, times and contract values, in one place so every screen says them the same way.
enum Format {
    /// Elapsed or playback time: 0:07, 2:05, 1:02:03.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// A target length: 30 sec, 1 min, 1.5 min, 2 min.
    static func target(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        let minutes = Double(seconds) / 60
        return "\(minutes.formatted(.number.precision(.fractionLength(0...1)))) min"
    }

    static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }

    static func decimal(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func rating(_ value: Int?) -> String {
        value.map { "\($0)/5" } ?? "Skipped"
    }

    static func metricValue(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        switch unit {
        case "count": return String(Int(value.rounded()))
        case "seconds": return seconds(value)
        case "words per minute": return "\(Int(value.rounded())) wpm"
        case "semitones": return "\(decimal(value)) st"
        case "dB": return "\(decimal(value)) dB"
        default: return decimal(value)
        }
    }
}

// MARK: - Labels for contract values

extension TakeStatus {
    var label: String {
        switch self {
        case .uploaded: return "Waiting to start"
        case .transcribing: return "Transcribing"
        case .analyzing: return "Analyzing"
        case .coaching: return "Coaching"
        case .done: return "Done"
        case .failed: return "Failed"
        default: return fallbackLabel
        }
    }
}

extension Dimension {
    var label: String {
        switch self {
        case .answerFirst: return "Answer first"
        case .layering: return "Layering"
        case .focus: return "Focus"
        case .concision: return "Concision"
        case .fluency: return "Fluency"
        case .close: return "Close"
        default: return fallbackLabel
        }
    }
}

extension Level {
    var label: String {
        switch self {
        case .strong: return "Strong"
        case .okay: return "Okay"
        case .needsWork: return "Needs work"
        default: return fallbackLabel
        }
    }
}

extension FocusOutcome {
    var label: String {
        switch self {
        case .improved: return "Improved"
        case .partlyImproved: return "Partly improved"
        case .notImproved: return "Not improved"
        case .notApplicable: return "Not applicable"
        default: return fallbackLabel
        }
    }
}

extension Change {
    var label: String {
        switch self {
        case .better: return "Better"
        case .same: return "Same"
        case .worse: return "Worse"
        case .info: return "For information"
        default: return fallbackLabel
        }
    }
}

extension OutlineRole {
    var label: String {
        switch self {
        case .main: return "Main point"
        case .support: return "Support"
        case .example: return "Example"
        case .aside: return "Aside"
        case .close: return "Close"
        default: return fallbackLabel
        }
    }
}

extension PromptCategory {
    var label: String {
        switch self {
        case .decision: return "Decision"
        case .status: return "Status"
        case .explain: return "Explain"
        case .pushback: return "Push back"
        case .other: return "Other"
        default: return fallbackLabel
        }
    }
}

extension PromptKind {
    var label: String {
        switch self {
        case .prepared: return "Prepared"
        case .impromptu: return "Impromptu"
        default: return fallbackLabel
        }
    }
}

extension SessionMode {
    var label: String {
        switch self {
        case .home: return "Home"
        case .driving: return "Driving"
        default: return fallbackLabel
        }
    }
}
