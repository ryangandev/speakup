import Foundation
import Observation

enum PracticeRoute: Hashable {
    case prepared
    case impromptu
    case report(takeID: String)
    case comparison(takeID: String)
}

/// Navigation on the Practice tab and the full-screen take flow (product.md#navigation).
///
/// Recording and Processing are one full-screen cover, so a take is never interrupted by
/// navigation. When a take is done the cover closes onto its Report, with Home underneath.
@MainActor
@Observable
final class PracticeCoordinator {
    var path: [PracticeRoute] = []
    var takeFlow: TakeFlowModel?
    /// Shown when the microphone is off for the app.
    var isMicrophoneDeniedAlertPresented = false
    var recordingError: String?

    @ObservationIgnored weak var app: AppModel?

    /// Records a new take of `prompt`. Recording starts here, before the cover appears, so
    /// it starts the moment Record is tapped.
    func record(_ prompt: LocalPrompt) async {
        guard let app else { return }
        guard await MicrophonePermission.request() else {
            isMicrophoneDeniedAlertPresented = true
            return
        }
        app.player.stop()
        let flow = TakeFlowModel(prompt: prompt, app: app, coordinator: self)
        do {
            try await flow.startRecording()
            takeFlow = flow
        } catch {
            recordingError = error.localizedDescription
        }
    }

    /// Retry: the same prompt, again.
    func retry(promptID: String) async {
        guard let prompt = app?.store.prompt(id: promptID) else { return }
        await record(prompt)
    }

    /// The take finished processing: close the cover onto its Report, Home underneath.
    func showReport(takeID: String) {
        takeFlow = nil
        path = [.report(takeID: takeID)]
    }

    /// Back to Home from the take flow; processing continues on the server.
    func backToHome() {
        takeFlow?.leave()
        takeFlow = nil
        path = []
        Task { await app?.sync.refreshOpenSessionTakes() }
    }

    func cancelTakeFlow() {
        takeFlow?.stop()
        takeFlow = nil
    }
}

/// One pass through Recording and Processing for a prompt.
@MainActor
@Observable
final class TakeFlowModel: Identifiable {
    enum Stage {
        case recording
        case processing(ProcessingController)
    }

    let id = UUID()
    let prompt: LocalPrompt
    let recorder = AudioRecorder()
    private(set) var stage: Stage = .recording
    /// Why the recording stopped by itself, shown on Processing.
    private(set) var autoStopReason: AudioRecorder.StopReason?
    private(set) var takeID = IDs.make()
    var errorMessage: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private weak var coordinator: PracticeCoordinator?

    init(prompt: LocalPrompt, app: AppModel, coordinator: PracticeCoordinator) {
        self.prompt = prompt
        self.app = app
        self.coordinator = coordinator
        recorder.onAutoStop = { [weak self] recording in self?.keep(recording) }
    }

    var session: LocalSession? { app.store.session(id: prompt.sessionId) }

    func startRecording() async throws {
        takeID = IDs.make()
        autoStopReason = nil
        stage = .recording
        try await recorder.start(to: app.store.newRecordingURL(takeID: takeID))
    }

    /// Done: stop and keep the take.
    func finish() {
        guard let recording = recorder.stop(reason: .finished) else { return }
        keep(recording)
    }

    /// Cancel: discard the recording. It never gets an attempt number.
    func discard() {
        recorder.cancel()
        coordinator?.cancelTakeFlow()
    }

    private func keep(_ recording: AudioRecorder.Recording) {
        if recording.stopReason != .finished { autoStopReason = recording.stopReason }
        let sha: String
        do {
            sha = try WAVWriter.sha256(of: recording.url)
        } catch {
            errorMessage = "The recording could not be saved."
            return
        }
        guard
            app.store.keepTake(id: takeID, promptID: prompt.id, recording: recording, sha256: sha)
                != nil
        else {
            errorMessage = "The recording could not be saved."
            return
        }
        let sync = app.sync
        let takeID = takeID
        let controller = ProcessingController(
            takeID: takeID, api: app.api, needsUpload: true,
            upload: { progress in try await sync.upload(takeID: takeID, progress: progress) })
        let store = app.store
        controller.onUpdate = { take in store.update(remote: take) }
        stage = .processing(controller)
        controller.start()
    }

    /// Record again on the same prompt, after a take with no speech.
    func recordAgain() async {
        stop()
        do {
            try await startRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        if case .processing(let controller) = stage { controller.stop() }
        if recorder.isRecording { recorder.cancel() }
    }

    /// Back to Home: an upload in flight continues; polling stops.
    func leave() {
        if case .processing(let controller) = stage { controller.detach() }
        if recorder.isRecording { recorder.cancel() }
    }
}
