import AppIntents
import Foundation

/// "Start a SpeakUp drive": opens the app and starts a drive, exactly as the Home card does
/// (`AppModel.startDrive()`), so nothing needs a touch once Siri has it (product.md#driving-mode).
///
/// It runs in the foreground: a drive starts its audio engine and asks for the microphone, which
/// only an app in the foreground can do. With the phone locked, iOS asks for the unlock first.
/// Starting while locked needs `AudioRecordingIntent` and a Live Activity (plan task 8).
struct StartDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Drive"
    static let description = IntentDescription("Starts a hands-free SpeakUp practice drive.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        switch await app.startDrive() {
        case .started, .alreadyDriving:
            // The drive speaks for itself; a drive already running carries on untouched.
            return .result()
        case .takeInProgress:
            throw StartDriveError.takeInProgress
        case .microphoneDenied:
            throw StartDriveError.microphoneDenied
        }
    }
}

/// Why a drive did not start, as Siri says it.
enum StartDriveError: Error, CustomLocalizedStringResourceConvertible {
    case takeInProgress
    case microphoneDenied

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .takeInProgress: "A take is open in SpeakUp. Finish it or go back to Home, then start the drive."
        case .microphoneDenied: "SpeakUp can't use the microphone. Turn it on in Settings, then start the drive."
        }
    }
}

/// The Siri phrases. Every App Shortcut phrase has to name the app.
struct SpeakUpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveIntent(),
            phrases: [
                "Start a \(.applicationName) drive",
                "Start driving with \(.applicationName)",
                "\(.applicationName) drive",
            ],
            shortTitle: "Start a Drive",
            systemImageName: "car.fill")
    }
}
