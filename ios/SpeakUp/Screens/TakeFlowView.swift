import SwiftUI

/// The full-screen take flow: Recording, then Processing.
struct TakeFlowView: View {
    let flow: TakeFlowModel

    var body: some View {
        Group {
            switch flow.stage {
            case .recording:
                RecordingView(flow: flow)
            case .processing(let controller):
                ProcessingView(flow: flow, controller: controller)
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}

/// Recording (product.md#recording).
struct RecordingView: View {
    @Environment(AppModel.self) private var app
    let flow: TakeFlowModel
    @State private var showsNotes = false
    @State private var isConfirmingCancel = false

    private var recorder: AudioRecorder { flow.recorder }
    private var target: Double { Double(flow.prompt.targetSeconds) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    promptHeader
                    timer
                    meter
                    if recorder.isPastWarning {
                        Banner(
                            tone: .warning, systemImage: "exclamationmark.triangle.fill",
                            message: "Recording stops at 15 minutes. The take is kept.")
                    }
                    if let error = flow.errorMessage {
                        Banner(tone: .error, systemImage: "xmark.octagon.fill", message: error)
                    }
                }
                .screenContent()
            }
            BottomBar {
                if flow.unsavedRecording != nil {
                    Button("Save again") { flow.retryKeep() }
                        .buttonStyle(.primary)
                } else {
                    Button {
                        flow.finish()
                    } label: {
                        Label("Done", systemImage: "stop.fill")
                    }
                    .buttonStyle(.primary)
                    .disabled(!recorder.isRecording)
                }
                Button("Cancel", role: .destructive) { isConfirmingCancel = true }
                    .buttonStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Discard this take?", isPresented: $isConfirmingCancel, titleVisibility: .visible
        ) {
            Button("Discard take", role: .destructive) { flow.discard() }
            Button(flow.unsavedRecording == nil ? "Keep recording" : "Keep the take", role: .cancel) {}
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showsNotes = app.settings.showsNotesWhileRecording
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var promptHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Circle().fill(Theme.Colors.recording).frame(width: 10, height: 10)
                    .opacity(recorder.isRecording ? 1 : 0.3)
                    .accessibilityHidden(true)
                Text(recorder.isRecording ? "Recording" : "Stopped")
                    .font(Theme.Fonts.captionEmphasis)
                    .foregroundStyle(Theme.Colors.recording)
                Text("Take \(nextAttempt)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Text(flow.prompt.text)
                .font(Theme.Fonts.question)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = flow.prompt.notes {
                // Open from the start when Home's "Show notes while recording" is on; either way a tap toggles them.
                Button {
                    withAnimation { showsNotes.toggle() }
                } label: {
                    Label(showsNotes ? "Hide notes" : "Show notes",
                          systemImage: showsNotes ? "chevron.up" : "chevron.down")
                        .font(Theme.Fonts.secondary.weight(.semibold))
                }
                if showsNotes {
                    Text(notes)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.m)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
            }
        }
    }

    private var nextAttempt: Int {
        let previous = flow.session?.takes.filter { $0.promptId == flow.prompt.id }.map(\.attempt).max() ?? 0
        return previous + 1
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(Format.clock(recorder.elapsed))
                    .font(Theme.Fonts.timer)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text("of \(Format.target(flow.prompt.targetSeconds))")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            ProgressView(value: min(recorder.elapsed, target), total: max(target, 1))
                .tint(recorder.elapsed > target ? Theme.Colors.caution : Theme.Colors.accent)
        }
        .accessibilityElement(children: .combine)
    }

    private var meter: some View {
        LevelMeter(level: recorder.level)
    }
}

/// Processing (product.md#processing).
struct ProcessingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    let flow: TakeFlowModel
    let controller: ProcessingController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Take \(attempt)")
                            .font(Theme.Fonts.captionEmphasis)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text(flow.prompt.text)
                            .font(Theme.Fonts.title)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = flow.autoStopReason {
                        Banner(tone: .warning, systemImage: "pause.circle", message: Self.message(for: reason))
                    }
                    content
                    if let issue = controller.connectionIssue {
                        switch controller.phase {
                        case .uploading, .processing:
                            Label(issue + " Trying again.", systemImage: "wifi.exclamationmark")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.caution)
                        case .failed:
                            // Try again could not start reprocessing.
                            Banner(
                                tone: .warning, systemImage: "exclamationmark.triangle.fill",
                                message: "Try again did not start. \(issue)")
                        case .uploadFailed, .done:
                            EmptyView()
                        }
                    }
                }
                .screenContent()
            }
            BottomBar {
                actions
            }
        }
        .onChange(of: controller.phase) { _, phase in
            if case .done(let take) = phase { app.practice.showReport(takeID: take.id) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resume() }
        }
    }

    private var attempt: Int {
        app.store.take(id: controller.takeID)?.attempt ?? 1
    }

    static func message(for reason: AudioRecorder.StopReason) -> String {
        switch reason {
        case .interrupted: return "Recording stopped because of a call or another app. The take was kept up to that point."
        case .routeChanged: return "Recording stopped because the microphone changed. The take was kept up to that point."
        case .limit: return "Recording stopped at the 15-minute limit. The take was kept."
        case .finished: return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .uploading(let progress):
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Uploading").font(Theme.Fonts.sectionTitle)
                ProgressView(value: progress)
            }
        case .processing(let status):
            StageList(status: status, controller: controller)
        case .uploadFailed(let message):
            Banner(
                tone: .warning, systemImage: "iphone.and.arrow.forward",
                message: "Saved on this phone. The upload failed: \(message)")
        case .failed(let code, let message):
            if code == .noSpeech {
                Banner(
                    tone: .warning, systemImage: "waveform.slash",
                    message: "No speech detected. Fewer than 5 words were heard; check the microphone and record again.")
            } else {
                Banner(tone: .error, systemImage: "xmark.octagon.fill", message: message)
            }
        case .done:
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                Text("Opening the report").font(Theme.Fonts.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch controller.phase {
        case .uploadFailed:
            Button("Retry upload") { controller.retryUpload() }.buttonStyle(.primary)
        case .failed(let code, _) where code == .noSpeech:
            Button {
                Task { await flow.recordAgain() }
            } label: {
                Label("Record again", systemImage: "mic.fill")
            }
            .buttonStyle(.primary(tint: Theme.Colors.recording))
        case .failed:
            Button("Try again") { controller.tryAgain() }.buttonStyle(.primary)
        default:
            EmptyView()
        }
        Button("Back to Home") { app.practice.backToHome() }
            .buttonStyle(.secondary)
    }
}

/// Transcribing and Analyzing, with the current one spinning. The report
/// opens once analysis is done, and shows coaching while it runs.
private struct StageList: View {
    let status: TakeStatus
    let controller: ProcessingController

    private static let stages: [TakeStatus] = [.transcribing, .analyzing]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ForEach(Self.stages, id: \.self) { stage in
                HStack(spacing: Theme.Spacing.m) {
                    icon(for: stage).frame(width: 24)
                    Text(stage.label)
                        .font(stage == status ? Theme.Fonts.bodyEmphasis : Theme.Fonts.body)
                        .foregroundStyle(state(of: stage) == .pending ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if controller.isSlow(at: context.date) {
                    Label("Taking longer than usual", systemImage: "hourglass")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.Colors.caution)
                }
            }
        }
    }

    private enum StageState { case done, current, pending }

    private func state(of stage: TakeStatus) -> StageState {
        guard let current = Self.stages.firstIndex(of: status) else {
            return .pending
        }
        let index = Self.stages.firstIndex(of: stage) ?? 0
        if index < current { return .done }
        return index == current ? .current : .pending
    }

    @ViewBuilder private func icon(for stage: TakeStatus) -> some View {
        switch state(of: stage) {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.positive)
        case .current:
            ProgressView()
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.Colors.textTertiary)
        }
    }
}
