import SwiftUI

enum HistoryRoute: Hashable {
    case session(id: String)
    case report(takeID: String)
    case comparison(takeID: String)
}

/// The History tab (product.md#history).
struct HistoryTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.historyPath) {
            SessionsView()
                .navigationDestination(for: HistoryRoute.self) { route in
                    Group {
                        switch route {
                        case .session(let id): SessionDetailView(sessionID: id)
                        case .report(let takeID): ReportView(takeID: takeID, context: .history)
                        case .comparison(let takeID): ComparisonView(takeID: takeID, context: .history)
                        }
                    }
                    .id(route)
                }
        }
    }
}

/// Sessions, newest first, loading more on scroll.
struct SessionsView: View {
    @Environment(AppModel.self) private var app
    @State private var sessions: [SessionListItem] = []
    @State private var nextBefore: Date?
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private static let pageSize = 20

    var body: some View {
        List {
            if let errorMessage, sessions.isEmpty {
                Banner(
                    tone: .error, systemImage: "wifi.exclamationmark", message: errorMessage,
                    actionTitle: "Try again", isWorking: isLoading
                ) { Task { await reload() } }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(sessions) { item in
                NavigationLink(value: HistoryRoute.session(id: item.id)) {
                    SessionRow(item: item)
                }
                .onAppear {
                    if item.id == sessions.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading && !sessions.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
            if let errorMessage, !sessions.isEmpty {
                Text(errorMessage).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.negative)
            }
        }
        .overlay {
            if hasLoaded && sessions.isEmpty && errorMessage == nil {
                ContentUnavailableView(
                    "No sessions yet", systemImage: "clock",
                    description: Text("Sessions appear here once a take is uploaded."))
            } else if !hasLoaded && isLoading {
                ProgressView()
            }
        }
        .navigationTitle("History")
        .refreshable { await reload() }
        .task(id: app.apiGeneration) { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let page = try await app.api.sessions(before: nil, limit: Self.pageSize)
            sessions = page.sessions
            nextBefore = page.nextBefore
            errorMessage = nil
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }

    private func loadMore() async {
        guard let before = nextBefore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await app.api.sessions(before: before, limit: Self.pageSize)
            let known = Set(sessions.map(\.id))
            sessions += page.sessions.filter { !known.contains($0.id) }
            nextBefore = page.nextBefore
            errorMessage = nil
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }
}

private struct SessionRow: View {
    let item: SessionListItem

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.dateTime(item.session.startedAt)).font(Theme.Fonts.bodyEmphasis)
                Spacer(minLength: Theme.Spacing.s)
                Badge(text: item.session.mode.label, color: Theme.Colors.neutral)
            }
            if let first = item.prompts.first {
                Text(first.text).font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
            }
            Text(counts).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            Text(
                "Nervousness \(Format.rating(item.session.nervousnessBefore)) before, \(afterRating) after"
            )
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var afterRating: String {
        if item.session.endedAt == nil { return "open" }
        return Format.rating(item.session.nervousnessAfter)
    }

    private var counts: String {
        let prompts = item.prompts.count == 1 ? "1 prompt" : "\(item.prompts.count) prompts"
        let takes = item.takeCount == 1 ? "1 take" : "\(item.takeCount) takes"
        return "\(prompts), \(takes)"
    }
}

/// One session: its prompts in order, each with its takes.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var app
    let sessionID: String
    @State private var detail: SessionDetail?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let detail {
                Section {
                    LabeledContent("Started", value: Format.dateTime(detail.session.startedAt))
                    LabeledContent("Mode", value: detail.session.mode.label)
                    LabeledContent("Nervousness before", value: Format.rating(detail.session.nervousnessBefore))
                    LabeledContent(
                        "Nervousness after",
                        value: detail.session.endedAt == nil ? "Open" : Format.rating(detail.session.nervousnessAfter))
                }
                ForEach(detail.prompts) { prompt in
                    Section {
                        if prompt.takes.isEmpty {
                            Text("No takes").foregroundStyle(Theme.Colors.textSecondary)
                        }
                        ForEach(prompt.takes) { take in
                            NavigationLink(value: HistoryRoute.report(takeID: take.id)) {
                                HistoryTakeRow(take: take, language: prompt.prompt.language)
                            }
                            .disabled(!(take.status == .done || take.status == .coaching))
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(prompt.prompt.kind.label.uppercased())
                            Text(prompt.prompt.text)
                                .font(Theme.Fonts.secondary.weight(.semibold))
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .textCase(nil)
                        }
                    }
                }
            } else if let errorMessage {
                Banner(
                    tone: .error, systemImage: "wifi.exclamationmark", message: errorMessage,
                    actionTitle: "Try again"
                ) { Task { await load() } }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .overlay { if detail == nil && errorMessage == nil { ProgressView() } }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: app.apiGeneration) { await load() }
    }

    private func load() async {
        do {
            detail = try await app.api.session(id: sessionID)
            errorMessage = nil
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }
}

private struct HistoryTakeRow: View {
    let take: Take
    let language: SpeechLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Take \(take.attempt)").font(Theme.Fonts.bodyEmphasis)
                Text(Format.clock(take.durationS)).font(Theme.Fonts.secondary.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer(minLength: Theme.Spacing.s)
                if take.status != .done {
                    Badge(text: take.status.label, color: take.status == .failed ? Theme.Colors.negative : Theme.Colors.neutral)
                }
            }
            if let verdict = take.summary?.verdict {
                Text(verdict).font(Theme.Fonts.secondary).lineLimit(3)
            } else if take.status == .done {
                Text("No coaching").font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
            } else if let error = take.error {
                Text(error.message).font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.negative)
            }
            if let summary = take.summary {
                Text(metrics(summary)).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func metrics(_ summary: TakeSummary) -> String {
        var parts: [String] = []
        if let fillers = summary.fillersPer100Words { parts.append("\(Format.decimal(fillers)) fillers per 100 \(language == .chinese ? "characters" : "words")") }
        if let blocks = summary.blocks { parts.append(blocks == 1 ? "1 block" : "\(blocks) blocks") }
        return parts.joined(separator: ", ")
    }
}
