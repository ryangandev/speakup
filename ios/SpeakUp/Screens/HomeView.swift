import SwiftUI

/// Home, the practice picker (product.md#home-practice-picker).
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingRoute: PracticeRoute?
    @State private var isEndingSession = false

    private var session: LocalSession? { app.store.openSession }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ServerStatusRow(status: app.serverStatus)
                if let session { OpenSessionCard(session: session, onEnd: { isEndingSession = true }) }
                startButtons
                if let session, !session.takes.isEmpty { TakesList(session: session) }
            }
            .screenContent()
        }
        .background(Theme.Colors.background)
        .navigationTitle("Practice")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .refreshable { await app.refresh() }
        .sheet(item: $pendingRoute) { route in
            NervousnessSheet(title: "Before you start: how nervous do you feel?") { rating in
                app.store.openNewSession(nervousnessBefore: rating)
                app.practice.path.append(route)
            }
        }
        .sheet(isPresented: $isEndingSession) {
            NervousnessSheet(title: "Ending the session: how nervous do you feel now?") { rating in
                app.endOpenSession(nervousnessAfter: rating)
            }
        }
        .task(id: processingTakeIDs) {
            // While a take of the open session is processing, keep its status current.
            while !processingTakeIDs.isEmpty, !Task.isCancelled {
                await app.sync.refreshOpenSessionTakes()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var processingTakeIDs: [String] {
        session?.takes.filter { $0.isUploaded && !($0.remote?.status.isFinal ?? false) }.map(\.id) ?? []
    }

    private var startButtons: some View {
        VStack(spacing: Theme.Spacing.m) {
            StartButton(
                title: "Prepared", systemImage: "list.bullet.rectangle",
                detail: "Rehearse what you plan to say") { start(.prepared) }
            StartButton(
                title: "Impromptu", systemImage: "questionmark.bubble",
                detail: "Answer a question right away") { start(.impromptu) }
        }
    }

    private func start(_ route: PracticeRoute) {
        if session == nil {
            pendingRoute = route
        } else {
            app.practice.path.append(route)
        }
    }
}

extension PracticeRoute: Identifiable {
    var id: Self { self }
}

private struct StartButton: View {
    let title: String
    let systemImage: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: systemImage)
                    .font(Theme.Fonts.title)
                    .frame(minWidth: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.Fonts.title)
                    Text(detail).font(Theme.Fonts.secondary).opacity(0.85)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Theme.Fonts.bodyEmphasis)
            }
            .foregroundStyle(Theme.Colors.onAccent)
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start.\(title.lowercased())")
    }
}

/// Reachable, unreachable, or reachable without coaching.
struct ServerStatusRow: View {
    @Environment(AppModel.self) private var app
    let status: ServerStatus

    var body: some View {
        Button {
            if case .notConfigured = status {
                app.isSettingsPresented = true
            } else {
                Task { await app.refreshHealth() }
            }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                indicator
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.Fonts.secondary.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if let detail {
                        Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.m)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(status == .notConfigured ? "Opens Settings" : "Checks the server again")
    }

    @ViewBuilder private var indicator: some View {
        if status == .checking {
            ProgressView().controlSize(.small)
        } else {
            Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
        }
    }

    private var color: Color {
        switch status {
        case .reachable(let health): return health.coaching.available ? Theme.Colors.positive : Theme.Colors.caution
        case .unreachable: return Theme.Colors.negative
        case .notConfigured, .checking: return Theme.Colors.neutral
        }
    }

    private var title: String {
        switch status {
        case .reachable(let health):
            return health.coaching.available ? "Server reachable" : "Server reachable, coaching off"
        case .unreachable: return "Can't reach the server"
        case .notConfigured: return "Server not set up"
        case .checking: return "Checking the server"
        }
    }

    private var detail: String? {
        switch status {
        case .reachable(let health):
            return health.coaching.available
                ? nil : "Reports show the transcript and metrics only. Add an Anthropic API key on the server."
        case .unreachable(let message): return message
        case .notConfigured: return "Add the server address and token."
        case .checking: return nil
        }
    }
}

private struct OpenSessionCard: View {
    let session: LocalSession
    let onEnd: () -> Void

    var body: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    summary
                    Spacer(minLength: Theme.Spacing.s)
                    endButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    summary
                    endButton
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text("Session open").font(Theme.Fonts.sectionTitle)
            Text("Started \(Format.time(session.startedAt)), \(takeCount)")
                .font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private var takeCount: String {
        session.takes.count == 1 ? "1 take" : "\(session.takes.count) takes"
    }

    private var endButton: some View {
        Button("End session", action: onEnd)
            .font(Theme.Fonts.bodyEmphasis)
            .buttonStyle(.bordered)
    }
}

/// The open session's takes, newest first.
private struct TakesList: View {
    @Environment(AppModel.self) private var app
    let session: LocalSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionTitle("This session")
            ForEach(session.takes.sorted { $0.recordedAt > $1.recordedAt }) { take in
                TakeRow(take: take, prompt: session.prompts.first { $0.id == take.promptId })
            }
        }
    }
}

private struct TakeRow: View {
    @Environment(AppModel.self) private var app
    let take: LocalTake
    let prompt: LocalPrompt?

    private var canOpenReport: Bool {
        guard let status = take.remote?.status else { return false }
        return status == .done || status == .coaching
    }

    var body: some View {
        Button {
            if canOpenReport { app.practice.path.append(.report(takeID: take.id)) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(prompt?.text ?? "Prompt")
                        .font(Theme.Fonts.bodyEmphasis)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    Text("Take \(take.attempt), \(Format.clock(take.durationS))")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
                    statusView
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if canOpenReport {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenReport && take.isUploaded)
    }

    @ViewBuilder private var statusView: some View {
        if !take.isUploaded {
            HStack(spacing: Theme.Spacing.s) {
                Badge(text: "Not uploaded", color: Theme.Colors.caution)
                if app.store.uploadingTakeIDs.contains(take.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry upload") { app.retryUpload(takeID: take.id) }
                        .font(Theme.Fonts.captionEmphasis)
                }
            }
        } else if let remote = take.remote {
            switch remote.status {
            case .done:
                if let verdict = remote.summary?.verdict {
                    Text(verdict).font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(3)
                } else {
                    Badge(text: "Done, no coaching", color: Theme.Colors.neutral)
                }
            case .failed:
                Label(remote.error?.message ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.negative)
            default:
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(remote.status.label).font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }
}
