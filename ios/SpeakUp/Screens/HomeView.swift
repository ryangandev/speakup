import SwiftUI

/// Home (product.md#home): pick a topic and a length, then record. The open session's takes
/// are listed underneath.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var topic = TopicModel()
    @State private var isStarting = false
    @FocusState private var focusedField: TopicModel.Field?

    private var session: LocalSession? { app.store.openHomeSession }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if app.serverStatus.needsAttention { ServerStatusRow(status: app.serverStatus) }
                TopicPicker(model: topic, focusedField: $focusedField)
                if app.settings.showsDriving {
                    DriveCard { Task { await app.startDrive() } }
                }
                if let session, !session.takes.isEmpty { TakesList(session: session) }
                if !stuckTakes.isEmpty { StuckTakesList(takes: stuckTakes) }
            }
            .screenContent()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Colors.background)
        .navigationTitle("Practice")
        .toolbar {
            // The notes editor takes returns, so the keyboard needs its own way out. It is in
            // the navigation bar, not a keyboard toolbar: SwiftUI logs "Invalid frame
            // dimension" whenever a keyboard toolbar shows.
            if focusedField != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("hideKeyboard")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                Button {
                    record()
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.primary(tint: Theme.Colors.recording))
                .disabled(!topic.canRecord || isStarting)
            }
        }
        .refreshable { await app.refresh() }
        .task { if topic.current == nil { topic.load(api: app.api) } }
        .task(id: processingTakeIDs) {
            // While a take of the open session is processing, keep its status current.
            while !processingTakeIDs.isEmpty, !Task.isCancelled {
                await app.sync.refreshOpenSessionTakes()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Takes of ended sessions the server does not have yet. The open session's own takes
    /// are listed under it.
    private var stuckTakes: [LocalTake] {
        app.store.pendingUploads.filter { app.store.session(id: $0.sessionId)?.isOpen == false }
    }

    private var processingTakeIDs: [String] {
        session?.takes.filter { $0.isUploaded && !($0.remote?.status.isFinal ?? false) }.map(\.id) ?? []
    }

    private func record() {
        focusedField = nil
        isStarting = true
        Task {
            defer { isStarting = false }
            guard await MicrophonePermission.request() else {
                app.practice.isMicrophoneDeniedAlertPresented = true
                return
            }
            // A drive may have started while the permission prompt was up; opening a home
            // session now would close the drive's.
            guard !app.isDriving, let prompt = topic.makePrompt(store: app.store, language: app.settings.language) else { return }
            await app.practice.record(prompt)
            if app.practice.takeFlow != nil { topic.recorded(api: app.api) }
        }
    }
}

/// Starts a drive: hands-free practice in the car (product.md#driving-mode).
private struct DriveCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "car.fill")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(minWidth: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Start a drive").font(Theme.Fonts.title).foregroundStyle(Theme.Colors.textPrimary)
                    Text("Hands-free in the car: questions, answers and feedback by voice")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.Colors.textSecondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Fonts.bodyEmphasis)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start.drive")
        .accessibilityHint("Starts a drive. Siri can too: say Start a SpeakUp drive.")
    }
}

extension ServerStatus {
    /// Home shows the server only when something is wrong; a healthy server stays out of the way.
    var needsAttention: Bool {
        switch self {
        case .reachable(let health): return !health.coaching.available
        case .checking: return false
        case .unreachable, .failing, .notConfigured: return true
        }
    }
}

/// Unreachable, not set up, or reachable without coaching.
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
        case .unreachable, .failing: return Theme.Colors.negative
        case .notConfigured, .checking: return Theme.Colors.neutral
        }
    }

    private var title: String {
        switch status {
        case .reachable(let health):
            return health.coaching.available ? "Server reachable" : "Server reachable, coaching off"
        case .unreachable: return "Can't reach the server"
        case .failing: return "Server problem"
        case .notConfigured: return "Server not set up"
        case .checking: return "Checking the server"
        }
    }

    private var detail: String? {
        switch status {
        case .reachable(let health):
            return health.coaching.available
                ? nil : "Reports show the transcript and metrics only. Add an Anthropic API key on the server."
        case .unreachable(let message), .failing(let message): return message
        case .notConfigured: return "Add the server address and token."
        case .checking: return nil
        }
    }
}

/// The open session's takes, newest first.
private struct TakesList: View {
    @Environment(AppModel.self) private var app
    let session: LocalSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionTitle("Recent")
            ForEach(session.takes.sorted { $0.recordedAt > $1.recordedAt }) { take in
                TakeRow(take: take, prompt: session.prompts.first { $0.id == take.promptId })
            }
        }
    }
}

/// Takes from ended sessions still waiting for upload, oldest first, each with why it failed.
private struct StuckTakesList: View {
    @Environment(AppModel.self) private var app
    let takes: [LocalTake]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionTitle("Waiting to upload")
            ForEach(takes) { take in
                TakeRow(take: take, prompt: app.store.prompt(id: take.promptId))
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
        // Only a take with a report is a button; a disabled button would dim the status text.
        if canOpenReport {
            Button {
                app.practice.path.append(.report(takeID: take.id))
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
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

    @ViewBuilder private var statusView: some View {
        if !take.isUploaded {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Badge(text: "Not uploaded", color: Theme.Colors.caution)
                    if app.store.uploadingTakeIDs.contains(take.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Retry upload") { app.retryUpload(takeID: take.id) }
                            .font(Theme.Fonts.captionEmphasis)
                    }
                }
                if let error = take.uploadError, !app.store.uploadingTakeIDs.contains(take.id) {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.negative)
                        .fixedSize(horizontal: false, vertical: true)
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
