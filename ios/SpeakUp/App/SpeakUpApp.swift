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
        _app = State(initialValue: AppModel(settings: AppSettings(), store: store))
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
enum DebugLaunch {
    @MainActor
    static func apply(store: PracticeStore) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetState") { store.removeAll() }
        if arguments.contains("-debug.syntheticMicrophone") { AudioRecorder.usesSyntheticInput = true }
        if let index = arguments.firstIndex(of: "-slowAfter"), index + 1 < arguments.count,
            let seconds = TimeInterval(arguments[index + 1])
        {
            ProcessingController.slowAfter = seconds
        }
    }
}
#endif
