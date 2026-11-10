import SwiftUI

/// Report (product.md#report).
struct ReportView: View {
    @Environment(AppModel.self) private var app
    let takeID: String
    let context: ReportContext
    @State private var model: ReportModel

    init(takeID: String, context: ReportContext) {
        self.takeID = takeID
        self.context = context
        _model = State(initialValue: ReportModel(takeID: takeID))
    }

    var body: some View {
        Group {
            if let report = model.report {
                content(report)
            } else if let error = model.errorMessage {
                ScrollView {
                    Banner(
                        tone: .error, systemImage: "exclamationmark.triangle.fill", message: error,
                        actionTitle: "Try again", isWorking: model.isLoading
                    ) { Task { await model.load(app: app) } }
                    .screenContent()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle(model.report.map { "Take \($0.take.attempt)" } ?? "Report")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.apiGeneration) { await model.load(app: app) }
        .onDisappear {
            model.stop()
            app.player.stop()
        }
    }

    /// Practice actions apply only to a take of the open session.
    private func showsPracticeActions(_ report: TakeReport) -> Bool {
        context == .practice && app.store.openHomeSession?.prompts.contains { $0.id == report.prompt.id } == true
    }

    private func content(_ report: TakeReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ReportHeader(report: report)
                if report.take.attempt > 1, let comparison = model.comparison {
                    ComparisonCard(comparison: comparison) { openComparison() }
                }
                if let coaching = report.coaching {
                    VerdictCard(verdict: coaching.verdict)
                    StrengthCard(strength: coaching.strength, takeID: takeID)
                    FocusCard(items: coaching.focus, takeID: takeID)
                } else {
                    coachingBanner(report)
                }
                if let coaching = report.coaching {
                    DimensionsCard(dimensions: coaching.dimensions)
                    OutlineCard(outline: coaching.outline)
                }
                TranscriptCard(analysis: report.analysis, takeID: takeID)
                if let coaching = report.coaching {
                    ReferenceCard(reference: coaching.referenceVersion)
                }
                MetricsCard(analysis: report.analysis, takeID: takeID)
                NervousnessCard(signs: report.analysis.nervousnessSigns, ratings: model.ratings)
            }
            .screenContent()
        }
        .refreshable { await model.load(app: app) }
        .safeAreaInset(edge: .bottom) {
            if showsPracticeActions(report) {
                BottomBar {
                    Button {
                        Task { await app.practice.retry(promptID: report.prompt.id) }
                    } label: {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.primary(tint: Theme.Colors.recording))
                    nextButton
                }
            }
        }
    }

    private var nextButton: some View {
        Button("New topic") { app.practice.path = [] }.buttonStyle(.secondary)
    }

    private func openComparison() {
        switch context {
        case .practice: app.practice.path.append(.comparison(takeID: takeID))
        case .history: app.historyPath.append(.comparison(takeID: takeID))
        }
    }

    @ViewBuilder private func coachingBanner(_ report: TakeReport) -> some View {
        if model.isCoachingRunning || report.take.coachingStatus == .pending {
            Banner(tone: .info, systemImage: "sparkles", message: "Claude is reviewing this take. Its feedback appears here when it is done.")
                .overlay(alignment: .topTrailing) { ProgressView().padding(Theme.Spacing.l) }
        } else if report.take.coachingStatus == .failed {
            Banner(
                tone: .warning, systemImage: "exclamationmark.bubble",
                message: model.coachingError.map { "Coaching failed for this take. \($0)" }
                    ?? "Coaching failed for this take.",
                actionTitle: "Try coaching again"
            ) { model.requestCoaching(app: app) }
        } else if app.serverStatus.coachingAvailable {
            Banner(
                tone: .info, systemImage: "sparkles",
                message: model.coachingError.map { "Coaching is now available on the server. \($0)" }
                    ?? "Coaching was off when this take was processed. It is available now.",
                actionTitle: "Get coaching"
            ) { model.requestCoaching(app: app) }
        } else {
            Banner(
                tone: .info, systemImage: "key",
                message: "Coaching is off because the server has no Anthropic API key.")
        }
    }
}

// MARK: - Sections

private struct ReportHeader: View {
    let report: TakeReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(report.prompt.text)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Take \(report.take.attempt) · \(Format.clock(report.take.durationS)) of \(Format.target(report.prompt.targetSeconds)) target · \(Format.dateTime(report.take.recordedAt))"
            )
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ComparisonCard: View {
    let comparison: Comparison
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Card {
                HStack {
                    SectionTitle("Against take \(comparison.previousAttempt)")
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.textTertiary)
                }
                if let summary = comparison.summary {
                    Text(summary).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                if comparison.focusOutcomes.isEmpty {
                    MetricChangeSummary(changes: comparison.metricChanges)
                } else {
                    ForEach(Array(comparison.focusOutcomes.enumerated()), id: \.offset) { _, outcome in
                        HStack(alignment: .firstTextBaseline) {
                            Text(outcome.title).font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: Theme.Spacing.s)
                            Badge(text: outcome.outcome.label, color: Theme.color(for: outcome.outcome))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("report.comparison")
        .accessibilityHint("Opens the comparison")
    }
}

/// Graded metric changes in one line each, for the card without coaching.
struct MetricChangeSummary: View {
    let changes: [Comparison.MetricChange]

    var body: some View {
        ForEach(changes.filter { $0.change != .info }, id: \.metric) { change in
            HStack(alignment: .firstTextBaseline) {
                Text(change.label).font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: Theme.Spacing.s)
                Text("\(Format.metricValue(change.before, unit: change.unit)) → \(Format.metricValue(change.after, unit: change.unit))")
                    .font(Theme.Fonts.secondary.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
                Badge(text: change.change.label, color: Theme.color(for: change.change))
            }
        }
    }
}

private struct VerdictCard: View {
    let verdict: String

    var body: some View {
        Card {
            SectionTitle("Verdict")
            Text(verdict).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StrengthCard: View {
    let strength: Strength
    let takeID: String

    var body: some View {
        Card {
            SectionTitle("Strength", detail: strength.dimension.label)
            Text(strength.point).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            QuoteButton(anchor: strength.anchor, takeID: takeID)
        }
    }
}

private struct FocusCard: View {
    let items: [FocusItem]
    let takeID: String

    var body: some View {
        Card {
            SectionTitle("Focus for the next take")
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1). \(item.title)").font(Theme.Fonts.bodyEmphasis)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Spacing.s)
                        Badge(text: item.dimension.label, color: Theme.Colors.neutral)
                    }
                    Text(item.problem).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, anchor in
                        QuoteButton(anchor: anchor, takeID: takeID)
                    }
                    Label {
                        Text(item.instruction).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.forward.circle.fill").foregroundStyle(Theme.Colors.accent)
                    }
                    .accessibilityLabel("Next take: \(item.instruction)")
                }
            }
        }
    }
}

private struct DimensionsCard: View {
    let dimensions: Dimensions

    var body: some View {
        Card {
            SectionTitle("Dimensions")
            ForEach(dimensions.rows, id: \.dimension) { row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.dimension.label).font(Theme.Fonts.bodyEmphasis)
                        Spacer(minLength: Theme.Spacing.s)
                        Badge(text: row.result.level.label, color: Theme.color(for: row.result.level))
                    }
                    Text(row.result.evidence).font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if row.dimension != .close { Divider() }
            }
        }
    }
}

private struct OutlineCard: View {
    let outline: Outline

    var body: some View {
        Card {
            SectionTitle("Structure")
            Text(outline.mainPoint).font(Theme.Fonts.bodyEmphasis)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                outline.mainPointFirst ? "The main point came first." : "The main point did not come first.",
                systemImage: outline.mainPointFirst ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(Theme.Fonts.secondary)
            .foregroundStyle(outline.mainPointFirst ? Theme.Colors.positive : Theme.Colors.caution)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(Array(outline.points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text("\(index + 1)").font(Theme.Fonts.caption.monospacedDigit())
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(point.role.label.uppercased()).font(Theme.Fonts.captionEmphasis)
                                .foregroundStyle(point.role == .aside ? Theme.Colors.caution : Theme.Colors.textSecondary)
                            Text(point.summary).font(Theme.Fonts.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct ReferenceCard: View {
    let reference: ReferenceVersion
    @State private var isExpanded = false

    var body: some View {
        Card {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    SectionTitle("Reference version")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Text(reference.structure).font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(reference.text).font(Theme.Fonts.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("A model of structure in your own content, not a script to memorize.")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }
}

private struct MetricsCard: View {
    let analysis: Analysis
    let takeID: String
    @State private var showsFillers = false

    private var metrics: Metrics { analysis.metrics }

    var body: some View {
        Card {
            SectionTitle("Metrics")
            Button {
                withAnimation { showsFillers.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    ValueRow(
                        label: analysis.countsCharacters ? "Fillers per 100 characters" : "Fillers per 100 words",
                        value: Format.decimal(metrics.fillers.per100Words),
                        // The 2 to 6 norm is for English words; there is none yet for characters.
                        note: analysis.countsCharacters
                            ? "\(fillerCount) in this take." : "Normal is about 2 to 6. \(fillerCount) in this take.")
                    Image(systemName: showsFillers ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsFillers ? "Hides each filler" : "Lists each filler")
            if showsFillers { fillerList }
            Divider()
            ValueRow(
                label: "Blocks", value: "\(metrics.blocks.count)",
                note: metrics.blocks.count > 0 ? "Longest \(Format.seconds(metrics.blocks.longestS))" : nil)
            ValueRow(label: "Restarts", value: "\(metrics.restarts)")
            ValueRow(label: "Repetitions", value: "\(metrics.repetitions)")
            Divider()
            Text("For information, not graded").font(Theme.Fonts.captionEmphasis)
                .foregroundStyle(Theme.Colors.textSecondary)
            ValueRow(
                label: "Pace",
                value: "\(Int(metrics.pace.wpmVoiced.rounded())) \(analysis.countsCharacters ? "characters/min" : "wpm")")
            ValueRow(
                label: "Pitch variation",
                value: metrics.pitch.map { "\(Format.decimal($0.variationSt)) st" } ?? "Not measured")
            ValueRow(
                label: "Volume variation",
                value: metrics.volume.map { "\(Format.decimal($0.variationDb)) dB" } ?? "Not measured")
        }
    }

    private var fillerCount: String {
        let count = metrics.fillers.filledPauses + metrics.fillers.lexical
        return count == 1 ? "1 filler" : "\(count) fillers"
    }

    private var fillerList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            let fillers = TranscriptLayout.fillers(in: analysis)
            if fillers.isEmpty {
                Text("No fillers.").font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
            }
            ForEach(fillers, id: \.event.id) { filler in
                HStack {
                    Text(Format.clock(filler.event.start)).font(Theme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(minWidth: 36, alignment: .leading)
                    Text(filler.text).font(Theme.Fonts.body)
                    Spacer()
                    PlayButton(
                        key: "filler-\(filler.event.id)", takeID: takeID,
                        start: max(0, filler.event.start - 1.5), end: filler.event.end + 1)
                }
            }
        }
    }
}

private struct NervousnessCard: View {
    let signs: [NervousnessSign]
    let ratings: (before: Int?, after: Int?, isOpen: Bool)?

    var body: some View {
        Card {
            SectionTitle("Nervousness")
            if let ratings {
                VStack(spacing: Theme.Spacing.s) {
                    ValueRow(label: "Before", value: Format.rating(ratings.before))
                    ValueRow(
                        label: "After",
                        value: ratings.after.map { "\($0)/5" } ?? (ratings.isOpen ? "Session open" : "Skipped"))
                }
            }
            if signs.isEmpty {
                Text("No signs of nervousness found in this take.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
            } else {
                ForEach(Array(signs.enumerated()), id: \.offset) { _, sign in
                    Label {
                        Text(sign.detail).font(Theme.Fonts.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "waveform.path.ecg").foregroundStyle(Theme.Colors.caution)
                    }
                }
            }
            Text("Signs found in the audio, shown next to your own rating. Not a score.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
    }
}
