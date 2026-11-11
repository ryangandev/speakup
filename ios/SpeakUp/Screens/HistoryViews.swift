import SwiftUI

enum HistoryRoute: Hashable {
    case topic(sessionID: String, promptID: String)
    case report(takeID: String)
    case comparison(takeID: String)
}

/// The History tab (product.md#history).
struct HistoryTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.historyPath) {
            DaysView()
                .navigationDestination(for: HistoryRoute.self) { route in
                    Group {
                        switch route {
                        case .topic(let sessionID, let promptID): TopicTakesView(sessionID: sessionID, promptID: promptID)
                        case .report(let takeID): ReportView(takeID: takeID, context: .history)
                        case .comparison(let takeID): ComparisonView(takeID: takeID, context: .history)
                        }
                    }
                    .id(route)
                }
        }
    }
}

/// One day of practice: the topics Ryan answered that day, newest first.
struct HistoryDay: Identifiable, Equatable {
    struct Topic: Identifiable, Equatable {
        let sessionID: String
        let prompt: PromptSummary
        let startedAt: Date
        var id: String { prompt.id }
    }

    let day: Date
    let topics: [Topic]
    var id: Date { day }

    /// Groups sessions (newest first, as the server sends them) by the day they started.
    static func group(_ sessions: [SessionListItem], calendar: Calendar = .current) -> [HistoryDay] {
        var days: [HistoryDay] = []
        for item in sessions.sorted(by: { $0.session.startedAt > $1.session.startedAt }) {
            let day = calendar.startOfDay(for: item.session.startedAt)
            // A session's prompts come oldest first; the day lists the newest first.
            let topics = item.prompts.reversed().map {
                Topic(sessionID: item.id, prompt: $0, startedAt: item.session.startedAt)
            }
            if let last = days.last, last.day == day {
                days[days.count - 1] = HistoryDay(day: day, topics: last.topics + topics)
            } else {
                days.append(HistoryDay(day: day, topics: topics))
            }
        }
        return days.filter { !$0.topics.isEmpty }
    }
}

/// Days, newest first, loading more on scroll.
struct DaysView: View {
    @Environment(AppModel.self) private var app
    @State private var sessions: [SessionListItem] = []
    @State private var nextBefore: Date?
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private static let pageSize = 20

    var body: some View {
        let days = HistoryDay.group(sessions)
        List {
            if let errorMessage, sessions.isEmpty {
                Banner(
                    tone: .error, systemImage: "wifi.exclamationmark", message: errorMessage,
                    actionTitle: "Try again", isWorking: isLoading
                ) { Task { await reload() } }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(days) { day in
                Section(Format.day(day.day)) {
                    ForEach(day.topics) { topic in
                        NavigationLink(value: HistoryRoute.topic(sessionID: topic.sessionID, promptID: topic.prompt.id)) {
                            TopicRow(topic: topic)
                        }
                        .onAppear {
                            if topic.id == days.last?.topics.last?.id { Task { await loadMore() } }
                        }
                    }
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
                ContentUnavailableView("No takes yet", systemImage: "clock")
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

private struct TopicRow: View {
    let topic: HistoryDay.Topic

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(topic.prompt.text).font(Theme.Fonts.body).lineLimit(2)
            Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var detail: String {
        let takes = topic.prompt.takeCount == 1 ? "1 take" : "\(topic.prompt.takeCount) takes"
        return "\(Format.time(topic.startedAt)) · \(takes)"
    }
}

/// One topic's takes, in order.
struct TopicTakesView: View {
    @Environment(AppModel.self) private var app
    let sessionID: String
    let promptID: String
    @State private var prompt: PromptDetail?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let prompt {
                Section {
                    ForEach(prompt.takes) { take in
                        NavigationLink(value: HistoryRoute.report(takeID: take.id)) {
                            HistoryTakeRow(take: take)
                        }
                        .disabled(!(take.status == .done || take.status == .coaching))
                    }
                } header: {
                    Text(prompt.prompt.text)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .textCase(nil)
                        .padding(.bottom, Theme.Spacing.s)
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
        .overlay { if prompt == nil && errorMessage == nil { ProgressView() } }
        .navigationTitle("Takes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: app.apiGeneration) { await load() }
    }

    private func load() async {
        do {
            let detail = try await app.api.session(id: sessionID)
            guard let match = detail.prompts.first(where: { $0.prompt.id == promptID }) else {
                errorMessage = "This topic is no longer on the server."
                return
            }
            prompt = match
            errorMessage = nil
        } catch {
            errorMessage = APIError.wrap(error).userMessage
        }
    }
}

private struct HistoryTakeRow: View {
    let take: Take

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
            } else if let error = take.error {
                Text(error.message).font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.negative)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
