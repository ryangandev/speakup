import Foundation
import Observation

/// What Home shows about the server (product.md#home-practice-picker).
enum ServerStatus: Equatable {
    case notConfigured
    case checking
    case reachable(Health)
    /// No answer at all; the message is the system's reason.
    case unreachable(String)
    /// The server answered /health with an error, such as a rejected token.
    case failing(String)

    var coachingAvailable: Bool {
        if case .reachable(let health) = self { return health.coaching.available }
        return false
    }

    var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }
}

/// The app's shared state and services. Screens read it from the environment; screen-local
/// state lives in each screen's own model.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let store: PracticeStore
    let player = AudioPlayer()
    let practice: PracticeCoordinator
    private(set) var serverStatus: ServerStatus = .checking
    private(set) var api: any SpeakUpAPI
    var isSettingsPresented = false
    var historyPath: [HistoryRoute] = []
    /// Bumped when the API changes, so screens that loaded from the old server reload.
    private(set) var apiGeneration = 0
    /// The drive on screen: running, or ended and showing its summary until Done.
    private(set) var drive: DriveLoop?

    /// A drive is on screen, running or showing its summary. Home recording waits for it.
    var isDriving: Bool { drive != nil }

    @ObservationIgnored private(set) lazy var sync = TakeSync(store: store, api: { [unowned self] in self.api })
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    /// Makes the drive `startDrive()` runs; tests replace it with one built on fakes.
    @ObservationIgnored var makeDrive: (AppModel) -> DriveLoop = { app in
        DriveLoop.live(store: app.store, sync: app.sync, api: { [unowned app] in app.api })
    }
    /// Asks for the microphone; tests replace it.
    @ObservationIgnored var requestMicrophone: () async -> Bool = { await MicrophonePermission.request() }
    /// Between a start and the drive appearing: the permission prompt can take a while, and a
    /// second start then must not make a second drive.
    @ObservationIgnored private var isStartingDrive = false

    init(settings: AppSettings, store: PracticeStore) {
        self.settings = settings
        self.store = store
        // No drive runs at launch, so a drive session still open was cut off when the app
        // was killed. Home practice must not add to it.
        store.closeInterruptedDrives()
        self.api = Self.makeAPI(settings: settings)
        self.practice = PracticeCoordinator()
        practice.app = self
        player.resolveAudio = { [unowned self] takeID in
            if let local = self.store.audioURL(takeID: takeID) { return local }
            return try await self.api.audio(takeID: takeID)
        }
        if !settings.isConfigured {
            serverStatus = .notConfigured
            isSettingsPresented = true
        }
    }

    static func makeAPI(settings: AppSettings) -> any SpeakUpAPI {
        #if DEBUG
        if settings.useMockServer {
            MockAPI.shared.scenario = settings.mockScenario
            return MockAPI.shared
        }
        #endif
        guard let url = settings.serverURL, !settings.token.isEmpty else { return UnconfiguredAPI() }
        return HTTPAPIClient(baseURL: url, token: settings.token)
    }

    /// Call after any server setting changes.
    func settingsChanged() {
        api = Self.makeAPI(settings: settings)
        apiGeneration += 1
        Task { await refresh() }
    }

    /// Runs on launch and whenever the app comes to the foreground.
    func refresh() async {
        // A drive's session is the drive's to close.
        if !isDriving { store.closeStaleSession() }
        await refreshHealth()
        guard serverStatus.isReachable else { return }
        await sync.syncPending()
        await sync.refreshOpenSessionTakes()
    }

    func refreshHealth() async {
        guard settings.isConfigured else {
            serverStatus = .notConfigured
            return
        }
        if case .reachable = serverStatus {} else { serverStatus = .checking }
        do {
            serverStatus = .reachable(try await api.health())
        } catch {
            let apiError = APIError.wrap(error)
            if case .transport(_, let message) = apiError {
                serverStatus = .unreachable(message)
            } else {
                serverStatus = .failing(apiError.userMessage)
            }
        }
    }

    /// Ends Home's open session with its after-rating and sends it when possible.
    func endOpenSession(nervousnessAfter: Int?) {
        guard let session = store.openHomeSession else { return }
        store.endSession(session.id, endedAt: Date(), nervousnessAfter: nervousnessAfter)
        Task {
            try? await sync.sendEnd(sessionID: session.id)
            store.pruneFinishedSessions()
        }
    }

    /// Retry upload from Home: uploads in place, without the Processing screen. A failure
    /// is recorded on the take, and Home shows it under the row.
    func retryUpload(takeID: String) {
        Task {
            guard (try? await sync.upload(takeID: takeID, progress: { _ in })) != nil else { return }
            // The rest of the queue (session ends, pruning) may have waited on this take.
            await sync.syncPending()
            await sync.refreshOpenSessionTakes()
        }
    }
}

// MARK: - Driving

extension AppModel {
    /// What `startDrive()` did.
    enum DriveStart: Equatable {
        case started
        /// A drive is already on screen or starting; nothing changed.
        case alreadyDriving
        /// The take flow is open at home (recording, or a take on screen). It is left as it is.
        case takeInProgress
        /// The microphone is off for the app; the alert that leads to Settings is shown.
        case microphoneDenied
    }

    /// Starts a drive: the Home card and the Siri intent both come here. It asks for the
    /// microphone first, then puts the drive's screen in place of the tabs and starts it.
    ///
    /// A home take in progress is never touched: a recording is the user's answer, and a take
    /// on the Processing screen is one they are watching. Either way the drive does not start.
    @discardableResult
    func startDrive() async -> DriveStart {
        // An ended drive's summary gives way to the new drive.
        if isStartingDrive { return .alreadyDriving }
        if let drive, !drive.hasEnded { return .alreadyDriving }
        guard !practice.hasTakeInProgress else { return .takeInProgress }
        isStartingDrive = true
        defer { isStartingDrive = false }
        guard await requestMicrophone() else {
            practice.isMicrophoneDeniedAlertPresented = true
            return .microphoneDenied
        }
        // The prompt may have been up for a while.
        guard !practice.hasTakeInProgress else { return .takeInProgress }

        player.stop()
        // The drive takes Settings' sheet away with the tabs; it must not come back after.
        isSettingsPresented = false
        let loop = makeDrive(self)
        drive = loop
        loop.start()
        return .started
    }

    /// Done on the drive's summary: the tabs come back. A drive still running is not closed.
    func closeDrive() {
        guard let drive, drive.hasEnded else { return }
        self.drive = nil
        // Home lists what the drive left uploading.
        Task { await refresh() }
    }
}

extension DriveLoop {
    /// The drive is over: its summary is what is left on screen.
    var hasEnded: Bool {
        if case .ended = state { true } else { false }
    }
}

/// Stands in for the API until Settings has an address and token.
struct UnconfiguredAPI: SpeakUpAPI {
    func health() async throws -> Health { throw APIError.notConfigured }
    func createSession(id: String, _ body: SessionCreateRequest) async throws -> Session { throw APIError.notConfigured }
    func endSession(id: String, _ body: SessionEndRequest) async throws -> Session { throw APIError.notConfigured }
    func sessions(before: Date?, limit: Int) async throws -> SessionList { throw APIError.notConfigured }
    func session(id: String) async throws -> SessionDetail { throw APIError.notConfigured }
    func questions(_ body: QuestionsRequest) async throws -> QuestionsResponse { throw APIError.notConfigured }
    func createPrompt(id: String, _ body: PromptCreateRequest) async throws -> Prompt { throw APIError.notConfigured }
    func prompt(id: String) async throws -> PromptDetail { throw APIError.notConfigured }
    func uploadTake(
        id: String, metadata: TakeUploadMetadata, audioFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Take { throw APIError.notConfigured }
    func take(id: String) async throws -> Take { throw APIError.notConfigured }
    func report(takeID: String) async throws -> TakeReport { throw APIError.notConfigured }
    func comparison(takeID: String) async throws -> Comparison { throw APIError.notConfigured }
    func audio(takeID: String) async throws -> URL { throw APIError.notConfigured }
    func reprocess(takeID: String, from stage: ReprocessStage) async throws -> Take { throw APIError.notConfigured }
}
