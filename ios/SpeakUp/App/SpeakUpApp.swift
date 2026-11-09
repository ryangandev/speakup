import AppIntents
import SwiftUI

@main
struct SpeakUpApp: App {
    @State private var app: AppModel

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let directory =
            isTesting
            ? FileManager.default.temporaryDirectory.appending(path: "SpeakUpHost-\(UUID().uuidString)")
            : PracticeStore.defaultDirectory()
        let store = PracticeStore(directory: directory)
        #if DEBUG
        DebugLaunch.apply(store: store)
        #endif
        let app = AppModel(settings: AppSettings(), store: store)
        // `StartDriveIntent` starts its drive through the same model as the screens.
        AppDependencyManager.shared.add(dependency: app)
        _app = State(initialValue: app)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.player)
                .environment(app.settings)
        }
    }
}

#if DEBUG
/// Launch arguments for exercising screens in the simulator without a server.
///
/// - `-debug.useMockServer YES` and `-debug.mockScenario <name>` set the mock server
///   (they are read from the argument domain of UserDefaults).
/// - `-resetState` deletes the phone's practice state at launch.
/// - `-slowAfter <seconds>` shortens the "Taking longer than usual" threshold.
/// - `-debug.syntheticMicrophone` records a generated signal instead of the microphone, for
///   simulators with no audio input.
/// - `-debug.microphoneFile <path>` records that audio file instead, for real speech in an
///   end-to-end run against the server.
/// - `-debug.startDrive` starts a drive at launch, as the Home card or Siri would.
enum DebugLaunch {
    static var startsDrive: Bool { ProcessInfo.processInfo.arguments.contains("-debug.startDrive") }

    @MainActor
    static func apply(store: PracticeStore) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetState") { store.removeAll() }
        if arguments.contains("-debug.syntheticMicrophone") { AudioRecorder.usesSyntheticInput = true }
        if let index = arguments.firstIndex(of: "-debug.microphoneFile"), index + 1 < arguments.count {
            AudioRecorder.usesSyntheticInput = true
            AudioRecorder.syntheticInputFile = URL(fileURLWithPath: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "-slowAfter"), index + 1 < arguments.count,
            let seconds = TimeInterval(arguments[index + 1])
        {
            ProcessingController.slowAfter = seconds
        }
    }
}
#endif
