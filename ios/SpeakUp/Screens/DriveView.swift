import SwiftUI

/// A drive, full screen (product.md#driving-mode): what the drive is doing, in words big enough
/// to read from a mount at a glance, then a summary when it ends.
///
/// Nothing here is ever needed: the drive runs by voice from start to end. Stop is for a
/// passenger, or when parked. The screen stays awake while the drive runs.
struct DriveView: View {
    @Environment(AppModel.self) private var app
    let drive: DriveLoop

    var body: some View {
        Group {
            if case .ended(let reason) = drive.state {
                DriveSummaryView(drive: drive, reason: reason) { app.closeDrive() }
            } else {
                DriveRunningView(drive: drive)
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onChange(of: drive.hasEnded, initial: true) { _, ended in
            UIApplication.shared.isIdleTimerDisabled = !ended
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// The drive in progress: the state, the question, the count of answers, and Stop.
private struct DriveRunningView: View {
    let drive: DriveLoop
    @ScaledMetric(relativeTo: .largeTitle) private var statusSize = Theme.Drive.statusSize
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = Theme.Drive.symbolSize

    private var status: DriveStatus { DriveStatus(drive.state) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Theme.Spacing.xxl) {
                        Spacer(minLength: 0)
                        statusBlock
                        Spacer(minLength: 0)
                        details
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .padding(.horizontal, Theme.Spacing.screen)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            BottomBar {
                #if DEBUG
                SpokenLogText(drive: drive)
                #endif
                Button(role: .destructive) {
                    drive.stop()
                } label: {
                    Label("Stop drive", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
                .disabled(drive.state == .ending)
                .accessibilityHint("Ends the drive. Saying stop does the same.")
            }
        }
    }

    private var statusBlock: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: status.symbol)
                .font(Theme.Drive.symbol(size: symbolSize))
                .foregroundStyle(status.tint)
                // Scales only: a pulse dims the icon, and it must stay readable at a glance.
                .symbolEffect(.breathe.plain, options: .repeating, isActive: drive.state == .recording)
                .frame(height: symbolSize * 1.2)
                .accessibilityHidden(true)
            Text(status.title)
                .font(Theme.Drive.status(size: statusSize))
                .foregroundStyle(Theme.Colors.textPrimary)
            if let detail = status.detail {
                Text(detail)
                    .font(Theme.Drive.detail)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Theme.Spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("drive.status")
    }

    private var details: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let prompt = drive.prompt {
                Text(prompt.text)
                    .font(Theme.Drive.prompt)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("drive.prompt")
            }
            Text(DriveStatus.answersSaved(drive.takesSaved))
                .font(Theme.Fonts.secondary.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .contentTransition(.numericText())
                .accessibilityIdentifier("drive.answersSaved")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Spacing.l)
    }
}

/// The end of a drive: what it saved, and what still has feedback coming.
private struct DriveSummaryView: View {
    let drive: DriveLoop
    let reason: DriveLoop.EndReason
    let onDone: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = Theme.Drive.symbolSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        Image(systemName: "flag.checkered")
                            .font(Theme.Drive.symbol(size: symbolSize))
                            .foregroundStyle(Theme.Colors.accent)
                            .accessibilityHidden(true)
                        Text("Drive ended")
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let note = Self.note(for: reason) {
                        Banner(tone: .warning, systemImage: "exclamationmark.triangle.fill", message: note)
                    }
                    Card {
                        ValueRow(label: "Answers saved", value: "\(drive.takesSaved)")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("drive.summary.saved")
                        Divider().overlay(Theme.Colors.separator)
                        ValueRow(
                            label: "Feedback later", value: "\(drive.feedbackLater.count)",
                            note: drive.feedbackLater.isEmpty
                                ? nil : "Still processing or waiting to upload. Their reports show in History.")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("drive.summary.later")
                    }
                    Text("Full reports for every answer are in History.")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .screenContent()
                .padding(.top, Theme.Spacing.xl)
            }
            BottomBar {
                #if DEBUG
                SpokenLogText(drive: drive)
                #endif
                Button("Done", action: onDone)
                    .buttonStyle(.primary)
            }
        }
    }

    /// Why the drive ended, when it was not by choice.
    static func note(for reason: DriveLoop.EndReason) -> String? {
        switch reason {
        case .stopped, .stoppedFromApp: nil
        case .idle: "The drive ended itself after 10 minutes with no command."
        case .noQuestions: "There were no questions left to ask."
        case .sessionMissing: "The drive's session is no longer on this phone."
        case .commandsUnavailable(let message): "Voice commands weren't available: \(message)"
        case .audioFailed(let message): "The drive's audio stopped: \(message)"
        case .interrupted: "A call or Siri took the audio, and the drive could not go on."
        }
    }
}

#if DEBUG
/// Debug builds only: the `-debug.speechLog` log, for UI tests to read what the drive said,
/// on the running screen and the summary. It shows the last two lines, small; its
/// accessibility value holds every line.
private struct SpokenLogText: View {
    let drive: DriveLoop

    var body: some View {
        if let log = drive.spokenLog {
            Text(log.entries.isEmpty ? "Spoken log" : log.entries.suffix(2).map(\.line).joined(separator: "\n"))
                .font(Theme.Fonts.debug)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(2)
                // A diagnostic, not content: it stays small at large text sizes.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("drive.spokenLog")
                .accessibilityValue(log.text)
        }
    }
}
#endif

/// What the screen says for each state of the drive.
struct DriveStatus: Equatable {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    init(_ state: DriveLoop.State) {
        switch state {
        case .idle, .starting:
            self.init("Starting the drive", nil, "car.fill")
        case .askingNervousness(.before):
            self.init("How nervous are you?", "Say one to five, or skip", "gauge.with.dots.needle.33percent")
        case .askingNervousness(.after):
            self.init("How nervous are you now?", "Say one to five, or skip", "gauge.with.dots.needle.33percent")
        case .preparingPrompt:
            self.init("Getting a question", nil, "text.bubble")
        case .speakingPrompt:
            self.init("Listen to the question", "Answer after the tone", "speaker.wave.2.fill")
        case .recording:
            self.init("Listening for your answer", "Say \u{201C}done\u{201D} when you finish", "mic.fill", Theme.Colors.recording)
        case .finishingTake:
            self.init("Got it", "Saving your answer", "checkmark.circle.fill", Theme.Colors.positive)
        case .uploading:
            self.init("Sending your answer", nil, "arrow.up.circle")
        case .waiting:
            self.init("Waiting for feedback", nil, "hourglass")
        case .speakingFeedback:
            self.init("Listen to the feedback", nil, "speaker.wave.2.fill")
        case .awaitingCommand:
            self.init("Say: again, next, or stop", "Or: repeat that, better version", "waveform")
        case .speakingReference:
            self.init("Reading the better version", nil, "speaker.wave.2.fill")
        case .paused:
            self.init("Paused for a call", "The drive goes on when it ends", "phone.fill", Theme.Colors.caution)
        case .ending:
            self.init("Ending the drive", nil, "flag.checkered")
        case .ended:
            self.init("Drive ended", nil, "flag.checkered")
        }
    }

    private init(_ title: String, _ detail: String?, _ symbol: String, _ tint: Color = Theme.Colors.accent) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    static func answersSaved(_ count: Int) -> String {
        switch count {
        case 0: "No answers saved yet"
        case 1: "1 answer saved"
        default: "\(count) answers saved"
        }
    }
}
