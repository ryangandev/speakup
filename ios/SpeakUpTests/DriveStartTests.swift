import Foundation
import Testing
@testable import SpeakUp

/// `AppModel.startDrive()`: the one path the Home card and `StartDriveIntent` share.
@Suite(.serialized)
@MainActor
struct DriveStartTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "drive-start-\(UUID().uuidString)", directoryHint: .isDirectory)
    let server = DriveServer()

    /// An app whose drives run on fakes. The drive waits for its opening rating, which never
    /// comes, so it runs until it is stopped.
    private func makeApp(microphone: Bool = true) throws -> (app: AppModel, drives: () -> Int) {
        let defaults = try #require(UserDefaults(suiteName: "drive-start-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, keychain: Keychain(service: "drive-start-tests-\(UUID().uuidString)"))
        let app = AppModel(settings: settings, store: PracticeStore(directory: directory))
        // The server is captured, not its api alone: a drive's question prefetch can outlive
        // the test, and the api's handlers hold the server unowned.
        let server = server
        var made = 0
        app.makeDrive = { app in
            made += 1
            return DriveLoop(
                audio: FakeDriveAudio(), recognizer: FakeRecognizer(), speech: FakeSpeech(), store: app.store,
                sync: TakeSync(store: app.store, api: { server.api }), api: { server.api },
                questions: DriveQuestions(fileURL: nil, api: { server.api }), clock: ManualDriveClock())
        }
        app.requestMicrophone = { microphone }
        return (app, { made })
    }

    private func stop(_ app: AppModel) async {
        app.drive?.stop()
        await app.drive?.finished()
    }

    @Test func startsADriveOnceTheMicrophoneIsAllowed() async throws {
        let (app, drives) = try makeApp()
        app.isSettingsPresented = true

        #expect(await app.startDrive() == .started)
        let drive = try #require(app.drive)
        #expect(drive.state.isActive)
        #expect(app.isDriving)
        #expect(drives() == 1)
        #expect(!app.isSettingsPresented, "a sheet would keep the drive's cover from showing")
        await stop(app)
    }

    @Test func aDeniedMicrophoneShowsTheAlertAndStartsNothing() async throws {
        let (app, drives) = try makeApp(microphone: false)

        #expect(await app.startDrive() == .microphoneDenied)
        #expect(app.drive == nil)
        #expect(drives() == 0)
        #expect(app.practice.isMicrophoneDeniedAlertPresented)
    }

    @Test func aSecondStartWhileDrivingChangesNothing() async throws {
        let (app, drives) = try makeApp()
        await app.startDrive()
        let first = try #require(app.drive)

        #expect(await app.startDrive() == .alreadyDriving)
        #expect(app.drive === first)
        #expect(drives() == 1)
        #expect(first.state.isActive)
        await stop(app)
    }

    /// Two starts while the permission prompt is up (a tap, then Siri) make one drive.
    @Test func aStartWhileThePermissionPromptIsUpIsIgnored() async throws {
        let (app, drives) = try makeApp()
        let gate = AsyncGate()
        gate.close()
        app.requestMicrophone = {
            await gate.wait()
            return true
        }
        let first = Task { await app.startDrive() }
        while gate.waiting == 0 { await Task.yield() }
        #expect(await app.startDrive() == .alreadyDriving)
        gate.open()
        #expect(await first.value == .started)
        #expect(drives() == 1)
        await stop(app)
    }

    @Test func aHomeTakeInProgressIsLeftAloneAndNoDriveStarts() async throws {
        let (app, drives) = try makeApp()
        let session = app.store.openNewSession(nervousnessBefore: nil)
        let prompt = try #require(
            app.store.addPrompt(
                sessionID: session.id, kind: .prepared, text: "Why Postgres?", notes: nil, category: nil,
                targetSeconds: 120, questionSource: .typed))
        let flow = TakeFlowModel(prompt: prompt, app: app, coordinator: app.practice)
        app.practice.takeFlow = flow

        #expect(await app.startDrive() == .takeInProgress)
        #expect(app.drive == nil)
        #expect(drives() == 0)
        #expect(app.practice.takeFlow === flow)
        #expect(app.store.openHomeSession?.id == session.id)
    }

    @Test func homeRecordingDoesNotStartDuringADrive() async throws {
        let (app, _) = try makeApp()
        await app.startDrive()
        let driveSession = app.store.openNewSession(mode: .driving, nervousnessBefore: nil)
        let prompt = try #require(
            app.store.addPrompt(
                sessionID: driveSession.id, kind: .impromptu, text: "Tell me about a hard call.", notes: nil,
                category: .decision, targetSeconds: 90, questionSource: .bank))

        await app.practice.record(prompt)
        #expect(app.practice.takeFlow == nil)
        await stop(app)
    }

    @Test func doneClosesOnlyAnEndedDriveAndANewDriveCanFollow() async throws {
        let (app, drives) = try makeApp()
        await app.startDrive()
        let first = try #require(app.drive)

        app.closeDrive()
        #expect(app.drive === first, "a running drive keeps its cover")

        await stop(app)
        #expect(first.hasEnded)
        app.closeDrive()
        #expect(app.drive == nil)
        #expect(!app.isDriving)

        #expect(await app.startDrive() == .started)
        #expect(drives() == 2)
        await stop(app)
    }

    /// Siri while the last drive's summary is still up starts the next drive.
    @Test func anEndedDrivesSummaryGivesWayToANewDrive() async throws {
        let (app, drives) = try makeApp()
        await app.startDrive()
        let first = try #require(app.drive)
        await stop(app)

        #expect(await app.startDrive() == .started)
        #expect(app.drive !== first)
        #expect(drives() == 2)
        await stop(app)
    }

    /// The app was killed mid-drive: the next launch closes its session, so Home starts fresh.
    @Test func launchClosesADriveTheAppWasKilledIn() throws {
        let store = PracticeStore(directory: directory)
        let killed = store.openNewSession(mode: .driving, nervousnessBefore: 2)

        let (app, _) = try makeApp()
        #expect(app.store.session(id: killed.id)?.isOpen == false)
        #expect(app.store.openSession == nil)
        #expect(app.store.openHomeSession == nil)
    }
}
