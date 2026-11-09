import SwiftUI

/// Every color, font, spacing, radius and transcript mark the screens use.
///
/// Screens never name a system color or font directly; they ask the theme for a role.
/// The final visual design is decided separately, so applying it means changing the
/// values here (and the components in `Components.swift`), not the screens.
/// Colors are semantic system colors and fonts are text styles, so light and dark mode and
/// Dynamic Type work everywhere already.
enum Theme {
    enum Colors {
        static let accent = Color.accentColor
        static let background = Color(uiColor: .systemGroupedBackground)
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        static let surfaceSunken = Color(uiColor: .tertiarySystemFill)
        /// Short sheets are opaque, so what is under them, like a red Retry button, does not glow through.
        static let sheet = Color(uiColor: .systemBackground)
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = Color(uiColor: .tertiaryLabel)
        static let separator = Color(uiColor: .separator)
        static let onAccent = Color.white

        static let positive = Color.green
        static let caution = Color.orange
        static let negative = Color.red
        static let neutral = Color.gray
        static let recording = Color.red

        static let meterTrack = Color(uiColor: .systemFill)
        static let meterFill = Color.green
        static let meterHot = Color.orange
    }

    enum Fonts {
        static let screenTitle = Font.largeTitle.weight(.bold)
        static let title = Font.title2.weight(.semibold)
        static let question = Font.title2.weight(.semibold)
        static let sectionTitle = Font.headline
        static let body = Font.body
        static let bodyEmphasis = Font.body.weight(.semibold)
        static let secondary = Font.subheadline
        static let caption = Font.caption
        static let captionEmphasis = Font.caption.weight(.semibold)
        static let quote = Font.callout.italic()
        static let timer = Font.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit()
        static let metricValue = Font.title3.weight(.semibold).monospacedDigit()
        static let numeric = Font.body.monospacedDigit()
        static let transcript = Font.body
        static let badge = Font.caption.weight(.semibold)
        /// Debug-only diagnostics, such as the drive's spoken log.
        static let debug = Font.caption2.monospaced()
    }

    /// Driving mode: what the drive is doing, read at a glance from a phone on a mount.
    /// Sizes are bases that Dynamic Type scales (`@ScaledMetric` in the view).
    enum Drive {
        static let statusSize: CGFloat = 40
        static let symbolSize: CGFloat = 56
        static func status(size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
        static func symbol(size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
        static let detail = Font.title3.weight(.medium)
        static let prompt = Font.title3
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Side margin of scrolling screens.
        static let screen: CGFloat = 16
    }

    /// Behind pinned bottom actions.
    static let barMaterial = Material.bar

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 12
        static let mark: CGFloat = 4
    }

    // MARK: Semantic mappings

    static func color(for level: Level) -> Color {
        switch level {
        case .strong: return Colors.positive
        case .okay: return Colors.caution
        case .needsWork: return Colors.negative
        default: return Colors.neutral
        }
    }

    static func color(for change: Change) -> Color {
        switch change {
        case .better: return Colors.positive
        case .worse: return Colors.negative
        default: return Colors.neutral
        }
    }

    static func color(for outcome: FocusOutcome) -> Color {
        switch outcome {
        case .improved: return Colors.positive
        case .partlyImproved: return Colors.caution
        case .notImproved: return Colors.negative
        default: return Colors.neutral
        }
    }

    /// How each kind of transcript mark looks. The legend and the transcript both read this.
    static func mark(_ kind: TranscriptMarkKind) -> MarkStyle {
        switch kind {
        case .filler:
            return MarkStyle(color: .orange, fillOpacity: 0.25, underline: false, isFaint: false)
        case .repetition:
            return MarkStyle(color: .purple, fillOpacity: 0, underline: true, isFaint: false)
        case .restart:
            return MarkStyle(color: .pink, fillOpacity: 0, underline: true, isFaint: false)
        case .block:
            return MarkStyle(color: .red, fillOpacity: 0.2, underline: false, isFaint: false)
        case .boundaryPause:
            return MarkStyle(color: .gray, fillOpacity: 0, underline: false, isFaint: true)
        case .offTopic:
            return MarkStyle(color: .teal, fillOpacity: 0.18, underline: false, isFaint: false)
        }
    }

    struct MarkStyle: Equatable {
        let color: Color
        /// Background tint behind marked words; 0 for none.
        let fillOpacity: Double
        let underline: Bool
        /// Drawn faintly because it is not a problem (boundary pauses).
        let isFaint: Bool
    }
}
