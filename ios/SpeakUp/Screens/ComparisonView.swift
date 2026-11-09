import SwiftUI

/// Comparison (product.md#comparison).
struct ComparisonView: View {
    @Environment(AppModel.self) private var app
    let takeID: String
    let context: ReportContext
    @State private var comparison: Comparison?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let comparison {
                content(comparison)
            } else if let errorMessage {
                ScrollView {
                    Banner(
                        tone: .error, systemImage: "exclamationmark.triangle.fill", message: errorMessage,
                        actionTitle: "Try again", isWorking: isLoading
                    ) { Task { await load() } }
                    .padding(Theme.Spacing.screen)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Comparison")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.apiGeneration) { await load() }
        .onDisappear { app.player.stop() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            comparison = try await app.api.comparison(takeID: takeID)
            errorMessage = nil
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }

    /// Retry applies only to a prompt of the open session, from Practice.
    private var retryPromptID: String? {
        guard context == .practice, let take = app.store.take(id: takeID),
            app.store.openSession?.id == take.sessionId
        else { return nil }
        return take.promptId
    }

    private func content(_ comparison: Comparison) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("Take \(comparison.attempt) against take \(comparison.previousAttempt)")
                    .font(Theme.Fonts.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = comparison.summary {
                    Text(summary).font(Theme.Fonts.body).fixedSize(horizontal: false, vertical: true)
                }
                listenCard(comparison)
                if comparison.focusOutcomes.isEmpty && comparison.dimensionChanges.isEmpty {
                    Banner(
                        tone: .info, systemImage: "info.circle",
                        message: "One of these takes has no coaching, so only metric changes are shown.")
                }
                if !comparison.focusOutcomes.isEmpty { focusCard(comparison) }
                if !comparison.dimensionChanges.isEmpty { dimensionsCard(comparison) }
                metricsCard(comparison)
            }
            .padding(Theme.Spacing.screen)
        }
        .safeAreaInset(edge: .bottom) {
            if let promptID = retryPromptID {
                BottomBar {
                    Button {
                        Task { await app.practice.retry(promptID: promptID) }
                    } label: {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.primary(tint: Theme.Colors.recording))
                }
            }
        }
    }

    private func listenCard(_ comparison: Comparison) -> some View {
        Card {
            SectionTitle("Hear the difference")
            takeRow(attempt: comparison.previousAttempt, takeID: comparison.previousTakeId)
            Divider()
            takeRow(attempt: comparison.attempt, takeID: comparison.takeId)
        }
    }

    private func takeRow(attempt: Int, takeID: String) -> some View {
        HStack {
            PlayButton(key: "whole-\(takeID)", takeID: takeID, label: "Take \(attempt)")
            Spacer()
            Button("Report") { openReport(takeID) }
                .font(Theme.Fonts.secondary.weight(.semibold))
        }
    }

    private func openReport(_ id: String) {
        switch context {
        case .practice: app.practice.path.append(.report(takeID: id))
        case .history: app.historyPath.append(.report(takeID: id))
        }
    }

    private func focusCard(_ comparison: Comparison) -> some View {
        Card {
            SectionTitle("Last take's focus")
            ForEach(Array(comparison.focusOutcomes.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(Theme.Fonts.bodyEmphasis)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Spacing.s)
                        Badge(text: item.outcome.label, color: Theme.color(for: item.outcome))
                    }
                    Text(item.dimension.label).font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(item.evidence).font(Theme.Fonts.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let anchor = item.anchor {
                        QuoteButton(anchor: anchor, takeID: comparison.takeId)
                    }
                }
            }
        }
    }

    private func dimensionsCard(_ comparison: Comparison) -> some View {
        Card {
            SectionTitle("Dimensions", detail: "Before → after")
            ForEach(comparison.dimensionChanges, id: \.dimension) { change in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text(change.dimension.label).font(Theme.Fonts.body)
                        Spacer(minLength: Theme.Spacing.s)
                        levels(change)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(change.dimension.label).font(Theme.Fonts.body)
                        levels(change)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func levels(_ change: Comparison.DimensionChange) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Badge(text: change.before.label, color: Theme.color(for: change.before))
            Image(systemName: "arrow.right").font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityLabel("to")
            Badge(text: change.after.label, color: Theme.color(for: change.after))
        }
    }

    private func metricsCard(_ comparison: Comparison) -> some View {
        Card {
            SectionTitle("Metrics", detail: "Before → after")
            ForEach(comparison.metricChanges, id: \.metric) { change in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text(change.label).font(Theme.Fonts.body)
                        Spacer(minLength: Theme.Spacing.s)
                        metricValues(change)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(change.label).font(Theme.Fonts.body)
                        metricValues(change)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func metricValues(_ change: Comparison.MetricChange) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("\(Format.metricValue(change.before, unit: change.unit)) → \(Format.metricValue(change.after, unit: change.unit))")
                .font(Theme.Fonts.numeric)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize()
            Badge(text: change.change.label, color: Theme.color(for: change.change))
        }
    }
}
