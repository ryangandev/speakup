import Foundation
import Testing
@testable import SpeakUp

/// What the phone keeps between launches: the open session, prompts and takes not yet uploaded.
@MainActor
struct PracticeStoreTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "store-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func recording(_ store: PracticeStore, takeID: String, at date: Date, duration: Double = 61.2345)
        -> AudioRecorder.Recording
    {
        AudioRecorder.Recording(
            url: store.newRecordingURL(takeID: takeID), recordedAt: date, duration: duration,
            sampleRate: 48_000, micRoute: .builtIn, micName: "iPhone Microphone", stopReason: .finished)
    }

    private func prompt(_ store: PracticeStore, in session: LocalSession, kind: PromptKind = .prepared)
        -> LocalPrompt
    {
        store.addPrompt(
            sessionID: session.id, kind: kind, text: "Why Postgres?", notes: "Joins, reporting",
            category: .decision, targetSeconds: 120, questionSource: .typed)!
    }

    @Test func attemptsCountUpPerPrompt() throws {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: 3)
        let first = prompt(store, in: session)
        let second = prompt(store, in: session)
        let now = Date()

        let a = store.keepTake(id: IDs.make(), promptID: first.id, recording: recording(store, takeID: "a", at: now), sha256: "x")
        let b = store.keepTake(id: IDs.make(), promptID: first.id, recording: recording(store, takeID: "b", at: now), sha256: "x")
        let c = store.keepTake(id: IDs.make(), promptID: second.id, recording: recording(store, takeID: "c", at: now), sha256: "x")
        #expect(a?.attempt == 1)
        #expect(b?.attempt == 2)
        #expect(c?.attempt == 1)
        #expect(a?.durationS == 61.235)
        #expect(store.keepTake(id: IDs.make(), promptID: "missing", recording: recording(store, takeID: "d", at: now), sha256: "x") == nil)
    }

    @Test func promptKeepsOnlyTheFieldsItsKindAllows() {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: nil)
        let prepared = prompt(store, in: session, kind: .prepared)
        let impromptu = prompt(store, in: session, kind: .impromptu)
        #expect(prepared.notes == "Joins, reporting")
        #expect(prepared.category == nil)
        #expect(impromptu.notes == nil)
        #expect(impromptu.category == .decision)
    }

    @Test func idsAreLowercaseUUIDs() {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: nil)
        #expect(session.id == session.id.lowercased())
        #expect(UUID(uuidString: session.id) != nil)
    }

    @Test func stateSurvivesARelaunch() {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: 4)
        let prompt = prompt(store, in: session)
        let takeID = IDs.make()
        store.keepTake(id: takeID, promptID: prompt.id, recording: recording(store, takeID: takeID, at: Date()), sha256: "abc")
        store.markSessionCreated(session.id)
        store.markPromptCreated(prompt.id)

        let reloaded = PracticeStore(directory: directory)
        #expect(reloaded.openSession?.id == session.id)
        #expect(reloaded.openSession?.isCreated == true)
        #expect(reloaded.prompt(id: prompt.id)?.isCreated == true)
        #expect(reloaded.take(id: takeID)?.audioSha256 == "abc")
        #expect(reloaded.pendingUploads.map(\.id) == [takeID])
    }

    @Test func aDrivingSessionKeepsItsModeAndSendsIt() throws {
        let store = PracticeStore(directory: directory)
        let home = store.openNewSession(nervousnessBefore: nil)
        #expect(home.mode == .home)
        store.endSession(home.id, endedAt: Date(), nervousnessAfter: nil)
        let drive = store.openNewSession(mode: .driving, nervousnessBefore: 3)

        let reloaded = PracticeStore(directory: directory)
        let session = try #require(reloaded.session(id: drive.id))
        #expect(session.mode == .driving)
        #expect(session.createRequest.mode == .driving)
        #expect(reloaded.session(id: home.id)?.mode == .home)
        let body = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(session.createRequest))
        #expect((body as? [String: Any])?["mode"] as? String == "driving")
    }

    @Test func remoteUpdateMarksTheTakeUploaded() {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: nil)
        let prompt = prompt(store, in: session)
        let takeID = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"
        store.keepTake(id: takeID, promptID: prompt.id, recording: recording(store, takeID: takeID, at: Date()), sha256: "abc")
        store.update(remote: TakeFactory.take(id: takeID, status: .transcribing))
        #expect(store.take(id: takeID)?.isUploaded == true)
        #expect(store.take(id: takeID)?.remote?.status == .transcribing)
        #expect(store.pendingUploads.isEmpty)
    }

    @Test func staleSessionClosesAtTheEndOfItsLastTake() {
        let store = PracticeStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = store.openNewSession(nervousnessBefore: 2, now: start)
        let prompt = prompt(store, in: session)
        store.keepTake(
            id: IDs.make(), promptID: prompt.id,
            recording: recording(store, takeID: "a", at: start.addingTimeInterval(60), duration: 90), sha256: "x")
        let lastTakeEnd = start.addingTimeInterval(150)

        store.closeStaleSession(now: lastTakeEnd.addingTimeInterval(2 * 60 * 60))
        #expect(store.openSession != nil)

        store.closeStaleSession(now: lastTakeEnd.addingTimeInterval(2 * 60 * 60 + 1))
        #expect(store.openSession == nil)
        #expect(store.session(id: session.id)?.endedAt == lastTakeEnd)
        #expect(store.session(id: session.id)?.nervousnessAfter == nil)
    }

    @Test func endingTwiceKeepsTheFirstEnd() {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: nil)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        store.endSession(session.id, endedAt: first, nervousnessAfter: 2)
        store.endSession(session.id, endedAt: first.addingTimeInterval(10), nervousnessAfter: 5)
        #expect(store.session(id: session.id)?.endedAt == first)
        #expect(store.session(id: session.id)?.nervousnessAfter == 2)
    }

    @Test func pruneDropsOnlyWhatTheServerHasInFull() {
        let store = PracticeStore(directory: directory)
        let now = Date()

        // Ended with no take: the server never heard of it.
        let empty = store.openNewSession(nervousnessBefore: nil)
        store.endSession(empty.id, endedAt: now, nervousnessAfter: nil)

        // Ended, uploaded, end sent: done.
        let synced = store.openNewSession(nervousnessBefore: nil)
        let syncedPrompt = prompt(store, in: synced)
        let syncedTake = "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"
        store.keepTake(id: syncedTake, promptID: syncedPrompt.id, recording: recording(store, takeID: syncedTake, at: now), sha256: "x")
        store.update(remote: TakeFactory.take(id: syncedTake, status: .done, coaching: .done))
        store.endSession(synced.id, endedAt: now, nervousnessAfter: 3)
        store.markEndSent(synced.id)

        // Ended, but the end was never sent.
        let unsent = store.openNewSession(nervousnessBefore: nil)
        let unsentPrompt = prompt(store, in: unsent)
        let unsentTake = "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4"
        store.keepTake(id: unsentTake, promptID: unsentPrompt.id, recording: recording(store, takeID: unsentTake, at: now), sha256: "x")
        store.update(remote: TakeFactory.take(id: unsentTake, status: .done, coaching: .done))
        store.endSession(unsent.id, endedAt: now, nervousnessAfter: nil)

        // Still open.
        let open = store.openNewSession(nervousnessBefore: nil)

        store.pruneFinishedSessions()
        #expect(store.sessions.map(\.id) == [unsent.id, open.id])
    }

    // MARK: Older and broken files

    /// A file written before fields with defaults existed (`is_created`, `is_end_sent`,
    /// `is_uploaded`, `upload_error`, `remote`), as an app update would find it.
    @Test func aFileMissingNewerFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = """
            [{
              "id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", "mode": "home",
              "started_at": "2026-11-09T08:12:03.115Z", "nervousness_before": 3,
              "prompts": [{
                "id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
                "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", "kind": "prepared",
                "text": "Why Postgres?", "target_seconds": 120, "question_source": "typed",
                "created_at": "2026-11-09T08:12:10.000Z"
              }],
              "takes": [{
                "id": "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21",
                "prompt_id": "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8",
                "session_id": "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", "attempt": 1,
                "recorded_at": "2026-11-09T08:13:00.000Z", "duration_s": 61.2, "mic_route": "built_in",
                "audio_sha256": "abc", "audio_file_name": "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21.wav"
              }]
            }]
            """
        try Data(old.utf8).write(to: directory.appending(path: "practice.json"))

        let store = PracticeStore(directory: directory)
        let session = try #require(store.openSession)
        #expect(session.mode == .home)
        #expect(session.isCreated == false)
        #expect(session.isEndSent == false)
        #expect(store.prompt(id: "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8")?.isCreated == false)
        let take = try #require(store.take(id: "e98b1f37-2a4c-4d1e-9f60-6b5c8a0d3e21"))
        #expect(take.isUploaded == false)
        #expect(take.uploadError == nil)
        #expect(take.remote == nil)
        #expect(store.pendingUploads.map(\.id) == [take.id])
    }

    @Test func aFileThatDoesNotDecodeIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ not the practice state".utf8)
        let stateFile = directory.appending(path: "practice.json")
        try garbage.write(to: stateFile)

        let store = PracticeStore(directory: directory)
        #expect(store.sessions.isEmpty)
        // A save after the failed load writes a fresh file; the old one is kept beside it.
        store.openNewSession(nervousnessBefore: nil)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(files.first { $0.hasPrefix("practice.corrupt-") && $0.hasSuffix(".json") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == garbage)
        #expect(try Data(contentsOf: stateFile) != garbage)
        #expect(PracticeStore(directory: directory).sessions.count == 1)
    }
}
