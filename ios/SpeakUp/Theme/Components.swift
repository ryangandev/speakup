import SwiftUI

// Reusable pieces every screen builds from. Each takes its look from `Theme`.

/// A rounded surface holding one section of a screen.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// A section heading inside a card or a scrolling screen.
struct SectionTitle: View {
    let text: String
    var detail: String?

    init(_ text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: Theme.Spacing.s)
            if let detail {
                Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The screen's main action.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Colors.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodyEmphasis)
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, Theme.Spacing.l)
            .background(
                tint.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
    }
}

/// A secondary action next to a primary one. A destructive role reads in the negative colour.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodyEmphasis)
            .foregroundStyle(
                isEnabled
                    ? (configuration.role == .destructive ? Theme.Colors.negative : Theme.Colors.accent)
                    : Theme.Colors.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, Theme.Spacing.m)
            .background(
                Theme.Colors.surfaceSunken.opacity(configuration.isPressed ? 0.6 : 1),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(tint: Color) -> PrimaryButtonStyle { PrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A small colored label: a level, a change, an outcome, a status.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.Fonts.badge)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// A selectable chip, such as an impromptu category.
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.secondary.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.Colors.onAccent : Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(
                    isSelected ? Theme.Colors.accent : Theme.Colors.surfaceSunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A notice across the width of a screen, with an optional action.
struct Banner: View {
    enum Tone { case info, warning, error }

    let tone: Tone
    let systemImage: String
    let message: String
    var actionTitle: String?
    var isWorking = false
    var action: (() -> Void)?

    private var color: Color {
        switch tone {
        case .info: return Theme.Colors.accent
        case .warning: return Theme.Colors.caution
        case .error: return Theme.Colors.negative
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label {
                Text(message).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(color)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: Theme.Spacing.s) {
                        if isWorking { ProgressView() }
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.secondary)
                .disabled(isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// The live input level while recording.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.meterTrack)
                Capsule()
                    .fill(level > 0.9 ? Theme.Colors.meterHot : Theme.Colors.meterFill)
                    .frame(width: max(6, proxy.size.width * level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

/// Plays a stretch of a take; shows Stop while that stretch plays.
struct PlayButton: View {
    @Environment(AudioPlayer.self) private var player
    let key: String
    let takeID: String
    var start: Double = 0
    var end: Double?
    var label: String?

    var body: some View {
        Button {
            player.toggle(key: key, takeID: takeID, from: start, to: end)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if player.isLoading(key) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.isPlaying(key) ? "stop.circle.fill" : "play.circle.fill")
                        .imageScale(.large)
                }
                if let label {
                    Text(label).font(Theme.Fonts.secondary)
                }
            }
            .foregroundStyle(Theme.Colors.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying(key) ? "Stop" : (label ?? "Play"))
    }
}

/// A quote from the take that plays its audio when tapped.
struct QuoteButton: View {
    @Environment(AudioPlayer.self) private var player
    let anchor: Anchor
    let takeID: String

    private var key: String { "quote-\(takeID)-\(anchor.wordStart)-\(anchor.wordEnd)" }

    var body: some View {
        Button {
            player.toggle(key: key, takeID: takeID, from: anchor.start, to: anchor.end)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: player.isPlaying(key) ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(Theme.Colors.accent)
                Text("\u{201C}\(anchor.quote)\u{201D}")
                    .font(Theme.Fonts.quote)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(Format.clock(anchor.start))
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(Theme.Spacing.m)
            .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this part of the take")
    }
}

/// A label with a value on its trailing side, or under it when they do not fit.
/// At accessibility text sizes every row stacks, so a list of rows does not mix the two layouts.
struct LabeledRow<Label: View, Value: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = Theme.Spacing.xs
    @ViewBuilder let label: Label
    @ViewBuilder let value: Value

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    label
                    Spacer(minLength: Theme.Spacing.s)
                    value
                }
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: spacing) {
            label
            value
        }
    }
}

/// A label and a value on one row, wrapping under each other at large text sizes.
struct ValueRow: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        LabeledRow(spacing: Theme.Spacing.xxs) {
            labelStack
        } value: {
            Text(value).font(Theme.Fonts.numeric).foregroundStyle(Theme.Colors.textPrimary)
        }
    }

    private var labelStack: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
            if let note {
                Text(note).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing)
                current.width = itemWidth
            } else {
                current.width = needed
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Picks a nervousness rating from 1 to 5, or skips.
struct NervousnessSheet: View {
    let title: String
    let onFinish: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text(title).font(Theme.Fonts.title).fixedSize(horizontal: false, vertical: true)
            Text("1 is calm, 5 is very nervous.")
                .font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
            HStack(spacing: Theme.Spacing.s) {
                ForEach(1...5, id: \.self) { value in
                    Button("\(value)") { finish(value) }
                        .buttonStyle(.secondary)
                        .accessibilityLabel("\(value) of 5")
                }
            }
            Button("Skip") { finish(nil) }
                .font(Theme.Fonts.body)
                .frame(maxWidth: .infinity)
        }
        .fittedSheet()
    }

    private func finish(_ value: Int?) {
        dismiss()
        onFinish(value)
    }
}

/// A sheet exactly as tall as its content at any text size, up to the full screen.
private struct FittedSheet: ViewModifier {
    @State private var contentHeight: CGFloat = 300

    func body(content: Content) -> some View {
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        .presentationBackground(Theme.Colors.sheet)
        .presentationDragIndicator(.visible)
    }
}

extension View {
    func fittedSheet() -> some View { modifier(FittedSheet()) }

    /// A scrolling screen's content: full width, so short content stays at the leading
    /// margin instead of centering, with the screen's side margins.
    func screenContent() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.screen)
    }
}
