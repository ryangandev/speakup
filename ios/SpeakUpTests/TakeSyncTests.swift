import Foundation
import Testing
@testable import SpeakUp

/// The upload queue: one bad take never blocks the others, and a server that lost a
/// session or prompt gets it again with the same ids.
@MainActor
struct TakeSyncTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sync-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A closed session with one prompt and `count` takes recorded a minute apart, each with
    /// an audio file on disk.
    private func store(takes count: Int) throws -> (PracticeStore, LocalSession, LocalPrompt, [String]) {
        let store = PracticeStore(directory: directory)
        let session = store.openNewSession(nervousnessBefore: 3)
        let prompt = try #require(store.addPrompt(
            sessionID: session.id, kind: .prepared, text: "Why Postgres?", notes: nil, category: nil,
            targetSeconds: 120, questionSource: .typed))
        try FileManager.default.createDirectory(at: store.takesDirectory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [String] = []
        for index in 0..<count {
            let id = IDs.make()
            let url = store.newRecordingURL(takeID: id)
            try Data("RIFF".utf8).write(to: url)
            let recording = AudioRecorder.Recording(
                url: url, recordedAt: start.addingTimeInterval(Double(index) * 60), duration: 30,
                sampleRate: 48_000, micRoute: .builtIn, micName: "iPhone Microphone", stopReason: .finished)
            try #require(store.keepTake(id: id, promptID: prompt.id, recording: recording, sha256: "x") != nil)
            ids.append(id)
        }
        store.endSession(session.id, endedAt: start.addingTimeInterval(600), nervousnessAfter: 2)
        return (store, session, prompt, ids)
    }

    private func sync(_ store: PracticeStore, _ api: FakeAPI) -> TakeSync {
        TakeSync(store: store, api: { api }, inBackground: { _, work in try await work() })
    }

    private func acceptParents(_ api: FakeAPI) {
        api.onCreateSession = { _, _ in try Fixture.decode(Session.self, "session") }
        api.onCreatePrompt = { id, body in
            Prompt(
                id: id, sessionId: body.sessionId, kind: body.kind, text: body.text, notes: body.notes,
                category: body.category, targetSeconds: body.targetSeconds,
                questionSource: body.questionSource, createdAt: Date())
        }
        api.onEndSession = { _, _ in try Fixture.decode(Session.self, "session") }
    }

    @Test func aRejectedTakeIsRecordedAndTheQueueMovesOn() async throws {
        let (store, session, _, ids) = try store(takes: 2)
        let api = FakeAPI()
        acceptParents(api)
        let rejected = ids[0]
        api.onUpload = { id, _ in
            if id == rejected {
                throw APIError.server(
                    status: 409, code: "conflict", message: "Attempt 1 of this prompt is taken.", details: nil)
            }
            return TakeFactory.take(id: id, status: .uploaded)
        }

        await sync(store, api).syncPending()

        #expect(store.take(id: ids[0])?.isUploaded == false)
        #expect(store.take(id: ids[0])?.uploadError == "Attempt 1 of this prompt is taken.")
        #expect(store.take(id: ids[1])?.isUploaded == true)
        #expect(store.take(id: ids[1])?.uploadError == nil)
        // The session end still goes out.
        #expect(store.session(id: session.id)?.isEndSent == true)
    }

    @Test func noConnectionStopsThePass() async throws {
        let (store, _, _, ids) = try store(takes: 2)
        let api = FakeAPI()
        acceptParents(api)
        api.onUpload = { _, _ in
            throw APIError.transport(code: .notConnectedToInternet, message: "The Internet connection appears to be offline.")
        }

        await sync(store, api).syncPending()

        #expect(api.calls.filter { $0.hasPrefix("uploadTake") } == ["uploadTake \(ids[0])"])
        #expect(store.take(id: ids[0])?.uploadError?.contains("Can't reach the server") == true)
        #expect(store.take(id: ids[1])?.uploadError == nil)
    }

    @Test func aPromptTheServerLostIsCreatedAgain() async throws {
        let (store, session, prompt, ids) = try store(takes: 1)
        store.markSessionCreated(session.id)
        store.markPromptCreated(prompt.id)
        let api = FakeAPI()
        acceptParents(api)
        let attempts = Counter()
        api.onUpload = { id, _ in
            if attempts.next() == 1 {
                throw APIError.server(
                    status: 404, code: "not_found", message: "No prompt with that id.",
                    details: .object(["field": .string("prompt_id")]))
            }
            return TakeFactory.take(id: id, status: .uploaded)
        }

        _ = try await sync(store, api).upload(takeID: ids[0], progress: { _ in })

        #expect(api.calls.prefix(3) == ["uploadTake \(ids[0])", "createPrompt \(prompt.id)", "uploadTake \(ids[0])"])
        #expect(store.take(id: ids[0])?.isUploaded == true)
        #expect(store.prompt(id: prompt.id)?.isCreated == true)
    }

    @Test func aSessionTheServerLostIsCreatedAgainWithItsPrompts() async throws {
        let (store, session, prompt, ids) = try store(takes: 1)
        store.markSessionCreated(session.id)
        store.markPromptCreated(prompt.id)
        let api = FakeAPI()
        acceptParents(api)
        let attempts = Counter()
        api.onUpload = { id, _ in
            if attempts.next() == 1 {
                throw APIError.server(
                    status: 404, code: "not_found", message: "No session with that id.",
                    details: .object(["field": .string("session_id")]))
            }
            return TakeFactory.take(id: id, status: .uploaded)
        }

        _ = try await sync(store, api).upload(takeID: ids[0], progress: { _ in })

        #expect(api.calls.prefix(4) == [
            "uploadTake \(ids[0])", "createSession \(session.id)", "createPrompt \(prompt.id)", "uploadTake \(ids[0])",
        ])
        #expect(store.take(id: ids[0])?.isUploaded == true)
    }

    @Test func aParentStillMissingAfterRecreatingIsRecordedNotRetriedForever() async throws {
        let (store, _, _, ids) = try store(takes: 2)
        let api = FakeAPI()
        acceptParents(api)
        let first = ids[0]
        api.onUpload = { id, _ in
            if id == first {
                throw APIError.server(
                    status: 404, code: "not_found", message: "No prompt with that id.",
                    details: .object(["field": .string("prompt_id")]))
            }
            return TakeFactory.take(id: id, status: .uploaded)
        }

        await sync(store, api).syncPending()

        #expect(api.calls.filter { $0 == "uploadTake \(first)" }.count == 2)
        #expect(store.take(id: first)?.uploadError == "The server does not know this take's prompt.")
        #expect(store.take(id: ids[1])?.isUploaded == true)
    }

    @Test func anUploadedTakeIsNotSentAgain() async throws {
        let (store, _, _, ids) = try store(takes: 1)
        store.update(remote: TakeFactory.take(id: ids[0], status: .analyzing))
        let api = FakeAPI()

        let take = try await sync(store, api).upload(takeID: ids[0], progress: { _ in })

        #expect(take.status == .analyzing)
        #expect(api.calls.isEmpty)
    }
}
