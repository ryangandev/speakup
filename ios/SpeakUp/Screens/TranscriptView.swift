import SwiftUI

/// The annotated transcript (product.md#report, item 9): fillers, blocks, repetitions,
/// restarts and off-topic stretches marked inline, boundary pauses shown faintly, a legend.
/// Tapping a plain word plays from there; tapping a mark explains it, with a play button.
struct TranscriptCard: View {
    let analysis: Analysis
    let takeID: String
    @State private var selectedMark: TranscriptMark?

    var body: some View {
        let tokens = TranscriptLayout.tokens(for: analysis)
        Card {
            SectionTitle("Transcript")
            Legend(kinds: TranscriptLayout.kindsPresent(in: analysis))
            FlowLayout(spacing: Theme.Spacing.xs, lineSpacing: Theme.Spacing.s) {
                ForEach(tokens) { token in
                    TokenView(token: token, takeID: takeID, selectedMark: $selectedMark)
                }
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .sheet(item: $selectedMark) { mark in
            MarkDetail(mark: mark, takeID: takeID)
        }
    }
}

private struct TokenView: View {
    @Environment(AudioPlayer.self) private var player
    let token: TranscriptToken
    let takeID: String
    @Binding var selectedMark: TranscriptMark?

    var body: some View {
        switch token {
        case .word(let index, let text, let start, let marks, let joinsPrevious):
            WordView(text: text, marks: marks, isPlaying: player.isPlaying("word-\(takeID)-\(index)"))
                .layoutValue(key: FlowJoinsPrevious.self, value: joinsPrevious)
                .onTapGesture {
                    if let mark = marks.first {
                        selectedMark = mark
                    } else {
                        player.toggle(key: "word-\(takeID)-\(index)", takeID: takeID, from: start)
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(marks.isEmpty ? "Plays from this word" : "Explains the mark")
        case .pause(let mark):
            PauseView(mark: mark)
                .onTapGesture { selectedMark = mark }
                .accessibilityAddTraits(.isButton)
        }
    }
}

private struct WordView: View {
    let text: String
    let marks: [TranscriptMark]
    let isPlaying: Bool

    var body: some View {
        let styles = marks.map { Theme.mark($0.kind) }
        let fill = styles.first { $0.fillOpacity > 0 }
        let underline = styles.first { $0.underline }
        Text(text)
            .font(Theme.Fonts.transcript)
            .foregroundStyle(Theme.Colors.textPrimary)
            .underline(underline != nil, color: underline?.color)
            .padding(.horizontal, fill == nil ? 0 : Theme.Spacing.xxs)
            .background(
                (fill.map { $0.color.opacity($0.fillOpacity) } ?? .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.mark))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.mark)
                    .stroke(Theme.Colors.accent, lineWidth: isPlaying ? 2 : 0))
            .accessibilityLabel(marks.isEmpty ? text : "\(text), \(marks.map(\.kind.label).joined(separator: ", "))")
    }
}

private struct PauseView: View {
    let mark: TranscriptMark

    var body: some View {
        let style = Theme.mark(mark.kind)
        Group {
            if style.isFaint {
                Text("·")
                    .font(Theme.Fonts.transcript)
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                Text(Format.seconds(mark.event.duration))
                    .font(Theme.Fonts.captionEmphasis.monospacedDigit())
                    .foregroundStyle(style.color)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .background(style.color.opacity(style.fillOpacity), in: Capsule())
            }
        }
        .accessibilityLabel(mark.title)
    }
}

private struct Legend: View {
    let kinds: [TranscriptMarkKind]

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.m, lineSpacing: Theme.Spacing.xs) {
            ForEach(kinds, id: \.self) { kind in
                LegendItem(kind: kind)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: \(kinds.map(\.label).joined(separator: ", "))")
    }
}

private struct LegendItem: View {
    let kind: TranscriptMarkKind

    var body: some View {
        let style = Theme.mark(kind)
        HStack(spacing: Theme.Spacing.xs) {
            Group {
                switch kind {
                case .block:
                    Text("1.0 s").font(Theme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(style.color)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .background(style.color.opacity(style.fillOpacity), in: Capsule())
                case .boundaryPause:
                    Text("·").font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textTertiary)
                default:
                    Text("abc").font(Theme.Fonts.caption)
                        .underline(style.underline, color: style.color)
                        .padding(.horizontal, Theme.Spacing.xxs)
                        .background(style.color.opacity(style.fillOpacity), in: RoundedRectangle(cornerRadius: Theme.Radius.mark))
                }
            }
            // The sample never truncates; only the label may wrap at large text sizes.
            .fixedSize()
            Text(kind.label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}

private struct MarkDetail: View {
    let mark: TranscriptMark
    let takeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.s) {
                Circle().fill(Theme.mark(mark.kind).color).frame(width: 12, height: 12)
                Text(mark.title).font(Theme.Fonts.title)
            }
            Text(mark.explanation).font(Theme.Fonts.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("At \(Format.clock(mark.event.start))").font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.Colors.textSecondary)
            PlayButton(
                key: "mark-\(takeID)-\(mark.id)", takeID: takeID,
                start: max(0, mark.event.start - 1.5), label: "Play from here")
        }
        .fittedSheet()
    }
}
